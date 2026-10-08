"""Alertmanager -> incident follow-up tickets.

Prometheus fires an alert -> Alertmanager POSTs it to /integrations/alertmanager -> OpsDesk opens an
incident_followup ticket for the owning team (labels.team), auto-assigned like any other ticket.
When the alert resolves, the ticket gets a time-to-recover comment and the MTTR histogram is observed;
the ticket itself stays open for the follow-up / postmortem work.

Idempotent by design (Alertmanager re-sends firing alerts every repeat_interval, and an HA pair sends
everything twice): one open incident per alert fingerprint, enforced by a per-fingerprint advisory lock
plus a partial unique index (migration 0003).
"""

import logging
import secrets
from datetime import UTC, datetime

from sqlalchemy import select, text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from opsdesk.config import Settings
from opsdesk.metrics import ALERT_WEBHOOK, INCIDENT_TIME_TO_RECOVER, TICKETS_CREATED
from opsdesk.models import TEAMS, Comment, IncidentAlert, Ticket, User
from opsdesk.queue import Queue
from opsdesk.schemas import AmAlert
from opsdesk.services import OPEN_STATUSES, audit, enqueue_notification, pick_assignee

log = logging.getLogger(__name__)

SYSTEM_USER = "alertmanager"
SEVERITY_TO_PRIORITY = {"critical": "critical", "warning": "high", "info": "low"}


def system_user(session: Session) -> User:
    """The requester of alert-driven tickets. Its key hash starts with '!' so no API key can ever match it."""
    user = session.scalar(select(User).where(User.name == SYSTEM_USER))
    if user is not None:
        return user
    try:
        with session.begin_nested():
            user = User(name=SYSTEM_USER, role="requester", api_key_hash="!" + secrets.token_hex(31))
            session.add(user)
    except IntegrityError:  # created concurrently by another request
        user = session.scalar(select(User).where(User.name == SYSTEM_USER))
    return user


def _fmt_duration(seconds: int) -> str:
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    return f"{h}h {m}m {s}s" if h else f"{m}m {s}s"


def _ends_at(alert: AmAlert) -> datetime:
    """Alertmanager sends endsAt=0001-01-01 for firing alerts; fall back to now when it is unusable."""
    now = datetime.now(UTC)
    if alert.endsAt is None or alert.endsAt < alert.startsAt or alert.endsAt > now:
        return now
    return alert.endsAt


LAYER_NAMES = {
    "kubernetes": "Kubernetes",
    "app": "application",
    "queue": "queue (SQS / worker)",
    "database": "database",
    "network": "network",
}


def _layer_line(labels: dict) -> str:
    layer = labels.get("layer")
    if layer in LAYER_NAMES:
        return f"Suspected layer: {LAYER_NAMES[layer]}"
    if layer == "slo":
        return "Suspected layer: unknown (user-facing symptom) - check the 'Where is the fault?' dashboard"
    return "Suspected layer: not labelled"


def _description(alert: AmAlert) -> str:
    a, labels = alert.annotations, alert.labels
    lines = [
        "Opened automatically by Alertmanager.",
        "",
        f"Alert: {labels.get('alertname', 'unknown')} (severity {labels.get('severity', 'none')})",
        _layer_line(labels),
        f"Started: {alert.startsAt.isoformat()}",
    ]
    if a.get("description"):
        lines += ["", a["description"]]
    if a.get("runbook_url"):
        lines += ["", f"Runbook: {a['runbook_url']}"]
    if alert.generatorURL:
        lines.append(f"Source query: {alert.generatorURL}")
    shown = {k: v for k, v in sorted(labels.items()) if k not in {"alertname", "severity"}}
    if shown:
        lines += ["", "Labels: " + ", ".join(f"{k}={v}" for k, v in shown.items())]
    lines += ["", "Follow-up: confirm recovery, link the trace/dashboard evidence, write the postmortem."]
    return "\n".join(lines)[:10000]


def _open_incident(session: Session, fingerprint: str) -> IncidentAlert | None:
    return session.scalar(
        select(IncidentAlert).where(IncidentAlert.fingerprint == fingerprint, IncidentAlert.resolved_at.is_(None))
    )


def _ticket_still_open(session: Session, fingerprint: str) -> Ticket | None:
    """The newest ticket for this fingerprint if nobody has resolved/closed it yet (flapping alert)."""
    return session.scalar(
        select(Ticket)
        .join(IncidentAlert, IncidentAlert.ticket_id == Ticket.id)
        .where(IncidentAlert.fingerprint == fingerprint, Ticket.status.in_(OPEN_STATUSES))
        .order_by(IncidentAlert.id.desc())
        .limit(1)
    )


def handle_alert(session: Session, queue: Queue, settings: Settings, alert: AmAlert) -> dict:
    labels = alert.labels
    alertname = labels.get("alertname", "unknown")[:200]
    severity = labels.get("severity", "none")[:20]
    result = {"fingerprint": alert.fingerprint, "alertname": alertname, "status": alert.status}
    allowed = {s.strip() for s in settings.alert_ticket_severities.split(",") if s.strip()}

    # Serialize work on one fingerprint (HA Alertmanager pairs deliver every notification twice).
    session.execute(text("SELECT pg_advisory_xact_lock(hashtextextended(:fp, 0))"), {"fp": alert.fingerprint})
    current = _open_incident(session, alert.fingerprint)

    # ------------------------------------------------------------------ resolved
    if alert.status == "resolved":
        if current is None:
            session.rollback()
            return {**result, "result": "resolved_unknown"}
        bot = system_user(session)
        current.resolved_at = _ends_at(alert)
        ttr = current.time_to_recover_s or 0
        ticket = current.ticket
        session.add(
            Comment(
                ticket_id=ticket.id,
                author_id=bot.id,
                body=f"[alert resolved] {alertname} recovered after {_fmt_duration(ttr)} (time to recover). "
                "Ticket stays open for the follow-up.",
            )
        )
        audit(session, ticket.id, "alert_resolved", bot, new={"alertname": alertname, "time_to_recover_s": ttr})
        session.commit()
        INCIDENT_TIME_TO_RECOVER.labels(alertname, severity).observe(ttr)
        log.info("alert resolved", extra={"ticket_id": ticket.id, "alertname": alertname, "ttr_s": ttr})
        enqueue_notification(session, queue, ticket, "alert_resolved")
        return {**result, "result": "resolved", "ticket_id": ticket.id, "time_to_recover_s": ttr}

    # -------------------------------------------------------------------- firing
    if severity not in allowed:
        session.rollback()
        return {**result, "result": "ignored", "reason": f"severity {severity!r} not in {sorted(allowed)}"}
    if current is not None:  # repeat_interval re-send or second HA replica
        session.rollback()
        return {**result, "result": "duplicate", "ticket_id": current.ticket_id}

    row = dict(
        fingerprint=alert.fingerprint,
        alertname=alertname,
        severity=severity,
        started_at=alert.startsAt,
        labels=labels,
        annotations=alert.annotations,
        generator_url=alert.generatorURL,
    )
    bot = system_user(session)
    reopened = _ticket_still_open(session, alert.fingerprint)
    if reopened is not None:  # flapping: fired again before anyone closed the ticket -> same ticket
        session.add(IncidentAlert(ticket_id=reopened.id, **row))
        session.add(
            Comment(
                ticket_id=reopened.id,
                author_id=bot.id,
                body=f"[alert fired again] {alertname} at {alert.startsAt.isoformat()}",
            )
        )
        audit(session, reopened.id, "alert_refired", bot, new={"alertname": alertname})
        session.commit()
        enqueue_notification(session, queue, reopened, "alert_refired")
        return {**result, "result": "refired", "ticket_id": reopened.id}

    summary = alert.annotations.get("summary") or alert.annotations.get("description") or "alert firing"
    priority = SEVERITY_TO_PRIORITY.get(severity, "medium")
    team = labels.get("team") if labels.get("team") in TEAMS else "platform"
    ticket = Ticket(
        type="incident_followup",
        source="alert",
        title=f"{alertname}: {summary}"[:200],  # the UI shows an "Alert" badge (source=alert)
        description=_description(alert),
        priority=priority,
        team=team,
        status="open",
        requester_id=bot.id,
        assignee_id=pick_assignee(session) if settings.auto_assign else None,
    )
    session.add(ticket)
    session.flush()
    session.add(IncidentAlert(ticket_id=ticket.id, **row))
    audit(
        session,
        ticket.id,
        "created",
        bot,
        new={
            "type": "incident_followup",
            "source": "alert",
            "alertname": alertname,
            "priority": priority,
            "team": team,
            "assignee_id": ticket.assignee_id,
        },
    )
    session.commit()
    session.refresh(ticket)
    TICKETS_CREATED.labels("incident_followup", priority).inc()
    log.info("incident ticket created from alert", extra={"ticket_id": ticket.id, "alertname": alertname})
    enqueue_notification(session, queue, ticket, "ticket_created")
    return {**result, "result": "created", "ticket_id": ticket.id}


def handle_webhook(session: Session, queue: Queue, settings: Settings, alerts: list[AmAlert]) -> list[dict]:
    results = []
    for alert in alerts:
        try:
            outcome = handle_alert(session, queue, settings, alert)
        except IntegrityError:  # lost a race on the partial unique index: the other request created it
            session.rollback()
            outcome = {"fingerprint": alert.fingerprint, "status": alert.status, "result": "duplicate"}
        ALERT_WEBHOOK.labels(outcome["result"]).inc()
        results.append(outcome)
    return results
