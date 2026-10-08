"""Business logic shared by the API routes: audit, notifications, auto-assignment."""

import logging

from sqlalchemy import func, select, text
from sqlalchemy.orm import Session

from opsdesk.deps import record_failure
from opsdesk.metrics import NOTIFICATIONS_ENQUEUED
from opsdesk.models import AuditLog, Notification, Ticket, User
from opsdesk.queue import Queue
from opsdesk.telemetry import current_trace_id

log = logging.getLogger(__name__)

OPEN_STATUSES = ("open", "triaged", "in_progress")


def audit(session: Session, ticket_id: int, action: str, actor: User, old=None, new=None) -> None:
    session.add(
        AuditLog(
            ticket_id=ticket_id,
            action=action,
            actor_id=actor.id,
            old_value=old,
            new_value=new,
            trace_id=current_trace_id(),
        )
    )


def pick_assignee(session: Session) -> int | None:
    """Least-loaded approver by open ticket count.

    Failure drill 2 relies on this query: with ~200k tickets and no index on
    tickets(status, assignee_id), Postgres falls back to a sequential scan and
    ticket creation latency climbs. The fix is chaos/02-latency/fix-index.sql,
    which you then codify as a new Alembic migration."""
    open_count = (
        select(Ticket.assignee_id, func.count().label("n"))
        .where(Ticket.status.in_(OPEN_STATUSES), Ticket.assignee_id.is_not(None))
        .group_by(Ticket.assignee_id)
        .subquery()
    )
    stmt = (
        select(User.id)
        .outerjoin(open_count, open_count.c.assignee_id == User.id)
        .where(User.role == "approver")
        .order_by(func.coalesce(open_count.c.n, 0), User.id)
        .limit(1)
    )
    return session.scalar(stmt)


def enqueue_notification(session: Session, queue: Queue, ticket: Ticket, event: str) -> Notification:
    """Write the notification row first (committed), then publish to SQS.

    If publishing fails the API call still succeeds; the row is marked
    publish_failed and counted, so the gap is visible on the dashboard."""
    notification = Notification(ticket_id=ticket.id, event=event, channel="slack", status="queued")
    session.add(notification)
    session.commit()
    try:
        queue.publish({"notification_id": notification.id, "ticket_id": ticket.id, "event": event})
        NOTIFICATIONS_ENQUEUED.labels(event, "ok").inc()
    except Exception as exc:  # noqa: BLE001
        dep = record_failure(exc, "sqs")
        log.error(
            "publish failed",
            extra={"ticket_id": ticket.id, "event": event, "dependency": "sqs", "error_kind": dep and dep[1]},
            exc_info=True,
        )
        notification.status = "publish_failed"
        notification.last_error = str(exc)[:500]
        session.commit()
        NOTIFICATIONS_ENQUEUED.labels(event, "error").inc()
    return notification


def db_ping(session: Session) -> bool:
    try:
        session.execute(text("SELECT 1"))
        return True
    except Exception as exc:  # noqa: BLE001
        dep = record_failure(exc, "postgres")
        log.warning(
            "database not reachable", extra={"dependency": "postgres", "error_kind": dep and dep[1]}, exc_info=True
        )
        return False
