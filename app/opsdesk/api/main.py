"""ticket-api: tickets, access requests, comments, audit trail."""

import asyncio
import hmac
import logging
import pathlib
import random
import threading
import time
from datetime import UTC, datetime, timedelta

from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request, Response, status
from fastapi.responses import JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from prometheus_client import REGISTRY
from prometheus_client.exposition import choose_encoder
from sqlalchemy import case, func, literal, or_, select
from sqlalchemy.orm import Session

from opsdesk import __version__
from opsdesk.auth import current_user, require_role
from opsdesk.config import Settings, get_settings
from opsdesk.db import get_session, init_engine, update_pool_metrics
from opsdesk.deps import record_failure
from opsdesk.incidents import handle_webhook
from opsdesk.logging_setup import configure_logging
from opsdesk.metrics import (
    ACCESS_DECISIONS,
    HTTP_DURATION,
    INVALID_TRANSITIONS,
    STATUS_TRANSITIONS,
    TICKETS_CREATED,
    TIME_TO_TRIAGE,
    TRIAGE_SLA_RESULTS,
    exemplar,
)
from opsdesk.models import TRIAGE_SLA, AccessRequest, AuditLog, Comment, Notification, Ticket, User
from opsdesk.queue import Queue
from opsdesk.schemas import (
    AmWebhook,
    AmWebhookResult,
    AssigneeUpdate,
    AuditOut,
    CommentCreate,
    CommentOut,
    DecisionIn,
    DemoUser,
    NotificationOut,
    StatusUpdate,
    SummaryOut,
    TicketCreate,
    TicketDetail,
    TicketOut,
    UiConfig,
    UserOut,
)
from opsdesk.services import audit, db_ping, enqueue_notification, pick_assignee
from opsdesk.telemetry import configure_tracing
from opsdesk.workflow import can_transition

log = logging.getLogger("opsdesk.api")

PROBE_ROUTES = {"/healthz", "/readyz", "/metrics"}
UI_DIR = pathlib.Path(__file__).resolve().parents[1] / "ui"
VIEWS = ("all", "mine", "pending_approval", "open", "breached")
OPEN_STATUSES = ("open", "triaged", "in_progress")

# Strict CSP for the UI: no inline script, no third-party origins.
UI_HEADERS = {
    "Content-Security-Policy": "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; "
    "connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
    "X-Frame-Options": "DENY",
}


def create_app(settings: Settings | None = None, queue: Queue | None = None) -> FastAPI:
    settings = settings or get_settings()
    configure_logging(settings.service_name, settings.environment, settings.log_level)
    configure_tracing(settings)
    init_engine(settings)

    app = FastAPI(
        title="OpsDesk API",
        version=__version__,
        description="Internal DevOps ticketing and access request portal (Week 4 SRE project).",
    )
    app.state.settings = settings
    app.state.queue = queue or Queue(settings)
    # Resolve the queue URL in the background so a slow or absent queue never
    # blocks startup or the readiness probe.
    threading.Thread(target=app.state.queue.ping, daemon=True).start()
    if settings.queue_metrics_interval_s > 0:
        stop = threading.Event()
        app.state.stop_sampler = stop

        def sample_queue_depth() -> None:
            while not stop.wait(settings.queue_metrics_interval_s):
                app.state.queue.sample_depth()

        threading.Thread(target=sample_queue_depth, daemon=True, name="queue-depth").start()

    # ---------------------------------------------------------------- middleware
    @app.middleware("http")
    async def observe(request: Request, call_next):
        start = time.perf_counter()
        path = request.url.path
        is_static = path == "/" or path.startswith("/ui")
        is_probe = path in PROBE_ROUTES or is_static  # no chaos, no request log line
        # Drills break the user-facing API, not the incident pipeline that records the outage.
        chaos = not is_probe and not path.startswith("/integrations/")
        try:
            if chaos and settings.chaos_latency_ms > 0:
                await asyncio.sleep(settings.chaos_latency_ms / 1000)
            if chaos and settings.chaos_error_rate > 0 and random.random() < settings.chaos_error_rate:
                response = JSONResponse({"detail": "chaos: injected error"}, status_code=500)
            else:
                response = await call_next(request)
        except Exception as exc:
            # Which dependency failed and how (network vs database vs config): metric + log fields
            dep = record_failure(exc)
            fields = {"path": path, "dependency": dep[0], "error_kind": dep[1]} if dep else {"path": path}
            log.exception("unhandled error", extra=fields)
            response = JSONResponse({"detail": "internal error"}, status_code=500)

        if is_static:
            response.headers.update(UI_HEADERS)
        elapsed = time.perf_counter() - start
        route = getattr(request.scope.get("route"), "path", "unmatched")
        HTTP_DURATION.labels(route, request.method, str(response.status_code)).observe(elapsed, exemplar=exemplar())
        if not is_probe:
            log.info(
                "request",
                extra={
                    "method": request.method,
                    "route": route,
                    "status": response.status_code,
                    "duration_ms": round(elapsed * 1000, 1),
                },
            )
        return response

    # Added AFTER the middleware above so the OTel middleware is outermost and
    # our metrics/log middleware runs inside the request span (exemplars, trace_id).
    # Always instrumented: spans give every log line a trace_id even when no
    # OTLP endpoint is configured (then spans are simply not exported).
    from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

    FastAPIInstrumentor.instrument_app(app, excluded_urls="healthz,readyz,metrics")

    # ------------------------------------------------------------------- probes
    @app.get("/healthz", include_in_schema=False)
    def healthz():
        return {"status": "ok"}

    @app.get("/readyz", include_in_schema=False)
    def readyz(session: Session = Depends(get_session)):
        db_ok = db_ping(session)
        body = {"database": db_ok, "queue": app.state.queue.resolved}
        # Only the DB gates readiness: a queue outage degrades notifications,
        # it must not take the API out of the load balancer.
        return JSONResponse(body, status_code=200 if db_ok else 503)

    @app.get("/metrics", include_in_schema=False)
    def metrics(request: Request):
        update_pool_metrics()
        encoder, content_type = choose_encoder(request.headers.get("accept", ""))
        return Response(encoder(REGISTRY), media_type=content_type)

    # ------------------------------------------------------------------ helpers
    def load_ticket(session: Session, ticket_id: int, user: User) -> Ticket:
        ticket = session.get(Ticket, ticket_id)
        if ticket is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "ticket not found")
        if user.role == "requester" and ticket.requester_id != user.id:
            raise HTTPException(status.HTTP_403_FORBIDDEN, "requesters can only see their own tickets")
        return ticket

    def visible(stmt, user: User):
        """Requesters only ever see their own tickets."""
        return stmt.where(Ticket.requester_id == user.id) if user.role == "requester" else stmt

    sla_interval = case(
        {p: literal(td) for p, td in TRIAGE_SLA.items()}, value=Ticket.priority, else_=literal(TRIAGE_SLA["medium"])
    )

    def apply_view(stmt, view: str, user: User):
        if view == "mine":
            return stmt.where(or_(Ticket.requester_id == user.id, Ticket.assignee_id == user.id))
        if view == "pending_approval":
            return stmt.join(AccessRequest, AccessRequest.ticket_id == Ticket.id).where(
                AccessRequest.decision == "pending"
            )
        if view == "open":
            return stmt.where(Ticket.status.in_(OPEN_STATUSES))
        if view == "breached":  # still untriaged and past its time-to-triage target
            return stmt.where(Ticket.status == "open", Ticket.created_at + sla_interval < func.now())
        return stmt

    # ------------------------------------------------------------- session/meta
    @app.get("/", include_in_schema=False)
    def root():
        return RedirectResponse("/ui/")

    @app.get("/config", response_model=UiConfig, tags=["meta"])
    def ui_config():
        """Public UI bootstrap. Demo logins are exposed only in the local environment."""
        demo = []
        if settings.environment == "local" and settings.bootstrap_users:
            for entry in filter(None, (e.strip() for e in settings.bootstrap_users.split(","))):
                name, role, key = entry.split(":", 2)
                demo.append(DemoUser(name=name, role=role, api_key=key))
        return UiConfig(
            environment=settings.environment, version=__version__, grafana_url=settings.grafana_url, demo_users=demo
        )

    @app.get("/me", response_model=UserOut, tags=["meta"])
    def me(user: User = Depends(current_user)):
        return user

    @app.get("/users", response_model=list[UserOut], tags=["meta"])
    def list_users(
        role: str | None = None, user: User = Depends(current_user), session: Session = Depends(get_session)
    ):
        stmt = select(User).order_by(User.name)
        if role:
            stmt = stmt.where(User.role == role)
        return list(session.scalars(stmt))

    # ------------------------------------------------------------------ tickets
    @app.post("/tickets", response_model=TicketOut, status_code=201, tags=["tickets"])
    def create_ticket(
        body: TicketCreate,
        user: User = Depends(current_user),
        session: Session = Depends(get_session),
    ):
        ticket = Ticket(
            type=body.type,
            title=body.title,
            description=body.description,
            priority=body.priority,
            team=body.team,
            status="open",
            requester_id=user.id,
            assignee_id=pick_assignee(session) if settings.auto_assign else None,
        )
        session.add(ticket)
        session.flush()
        if body.access:
            session.add(AccessRequest(ticket_id=ticket.id, **body.access.model_dump()))
        audit(
            session,
            ticket.id,
            "created",
            user,
            new={"type": body.type, "priority": body.priority, "team": body.team, "assignee_id": ticket.assignee_id},
        )
        session.commit()
        session.refresh(ticket)
        TICKETS_CREATED.labels(body.type, body.priority).inc()
        log.info("ticket created", extra={"ticket_id": ticket.id, "type": body.type})
        enqueue_notification(session, app.state.queue, ticket, "ticket_created")
        return ticket

    @app.get("/tickets/summary", response_model=SummaryOut, tags=["tickets"])
    def ticket_summary(user: User = Depends(current_user), session: Session = Depends(get_session)):
        """Counts for the UI tabs."""
        counts = {}
        for view in ("mine", "pending_approval", "open", "breached", "all"):
            stmt = apply_view(visible(select(func.count()).select_from(Ticket), user), view, user)
            counts[view] = session.scalar(stmt) or 0
        return counts

    @app.get("/tickets", response_model=list[TicketOut], tags=["tickets"])
    def list_tickets(
        view: str = Query(default="all", pattern="^(" + "|".join(VIEWS) + ")$"),
        status_: str | None = Query(default=None, alias="status"),
        type_: str | None = Query(default=None, alias="type"),
        team: str | None = None,
        priority: str | None = None,
        assignee_id: int | None = None,
        q: str | None = Query(default=None, max_length=100, description="search in title"),
        limit: int = Query(default=50, ge=1, le=100),
        offset: int = Query(default=0, ge=0),
        user: User = Depends(current_user),
        session: Session = Depends(get_session),
    ):
        stmt = apply_view(visible(select(Ticket), user), view, user)
        if status_:
            stmt = stmt.where(Ticket.status == status_)
        if type_:
            stmt = stmt.where(Ticket.type == type_)
        if team:
            stmt = stmt.where(Ticket.team == team)
        if priority:
            stmt = stmt.where(Ticket.priority == priority)
        if assignee_id is not None:
            stmt = stmt.where(Ticket.assignee_id == assignee_id)
        if q:
            stmt = stmt.where(Ticket.title.ilike(f"%{q}%"))
        stmt = stmt.order_by(Ticket.id.desc()).limit(limit).offset(offset)
        return list(session.scalars(stmt))

    @app.get("/tickets/{ticket_id}", response_model=TicketDetail, tags=["tickets"])
    def get_ticket(ticket_id: int, user: User = Depends(current_user), session: Session = Depends(get_session)):
        return load_ticket(session, ticket_id, user)

    @app.patch("/tickets/{ticket_id}/status", response_model=TicketOut, tags=["tickets"])
    def update_status(
        ticket_id: int,
        body: StatusUpdate,
        user: User = Depends(require_role("approver", "admin")),
        session: Session = Depends(get_session),
    ):
        ticket = load_ticket(session, ticket_id, user)
        old = ticket.status
        if not can_transition(old, body.status):
            INVALID_TRANSITIONS.inc()
            raise HTTPException(status.HTTP_409_CONFLICT, f"invalid transition {old} -> {body.status}")
        now = datetime.now(UTC)
        ticket.status = body.status
        if body.status == "triaged":
            ticket.triaged_at = now
            sla = ticket.sla
            TRIAGE_SLA_RESULTS.labels(ticket.priority, sla["state"]).inc()
            TIME_TO_TRIAGE.labels(ticket.priority).observe((now - ticket.created_at).total_seconds())
        elif body.status == "resolved":
            ticket.resolved_at = now
        elif old == "resolved" and body.status == "in_progress":
            ticket.resolved_at = None
        audit(session, ticket.id, "status_changed", user, old={"status": old}, new={"status": body.status})
        session.commit()
        session.refresh(ticket)
        STATUS_TRANSITIONS.labels(old, body.status).inc()
        enqueue_notification(session, app.state.queue, ticket, f"status_{body.status}")
        return ticket

    @app.patch("/tickets/{ticket_id}/assignee", response_model=TicketOut, tags=["tickets"])
    def update_assignee(
        ticket_id: int,
        body: AssigneeUpdate,
        user: User = Depends(require_role("approver", "admin")),
        session: Session = Depends(get_session),
    ):
        ticket = load_ticket(session, ticket_id, user)
        if body.assignee_id is not None:
            target = session.get(User, body.assignee_id)
            if target is None or target.role == "requester":
                raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "assignee must be an approver or admin")
        old = ticket.assignee_id
        ticket.assignee_id = body.assignee_id
        audit(session, ticket.id, "assigned", user, old={"assignee_id": old}, new={"assignee_id": body.assignee_id})
        session.commit()
        session.refresh(ticket)
        enqueue_notification(session, app.state.queue, ticket, "assigned")
        return ticket

    # ----------------------------------------------------------------- comments
    @app.post("/tickets/{ticket_id}/comments", response_model=CommentOut, status_code=201, tags=["comments"])
    def add_comment(
        ticket_id: int,
        body: CommentCreate,
        user: User = Depends(current_user),
        session: Session = Depends(get_session),
    ):
        ticket = load_ticket(session, ticket_id, user)
        comment = Comment(ticket_id=ticket.id, author_id=user.id, body=body.body)
        session.add(comment)
        session.flush()
        audit(session, ticket.id, "commented", user, new={"comment_id": comment.id})
        session.commit()
        session.refresh(comment)
        return comment

    # ---------------------------------------------------------- access requests
    def decide(ticket_id: int, decision: str, body: DecisionIn, user: User, session: Session) -> Ticket:
        ticket = load_ticket(session, ticket_id, user)
        if ticket.type != "access_request" or ticket.access_request is None:
            raise HTTPException(status.HTTP_409_CONFLICT, "ticket is not an access request")
        if ticket.requester_id == user.id:
            raise HTTPException(status.HTTP_403_FORBIDDEN, "self-approval is not allowed")
        ar = ticket.access_request
        if ar.decision != "pending":
            raise HTTPException(status.HTTP_409_CONFLICT, f"already {ar.decision}")
        now = datetime.now(UTC)
        ar.decision = decision
        ar.approver_id = user.id
        ar.decided_at = now
        if decision == "approved":
            ar.expires_at = now + timedelta(days=ar.duration_days)
        audit(
            session,
            ticket.id,
            f"access_{decision}",
            user,
            old={"decision": "pending"},
            new={"decision": decision, "reason": body.reason},
        )
        if body.reason:
            session.add(Comment(ticket_id=ticket.id, author_id=user.id, body=f"[{decision}] {body.reason}"))
        session.commit()
        session.refresh(ticket)
        ACCESS_DECISIONS.labels(decision).inc()
        enqueue_notification(session, app.state.queue, ticket, f"access_{decision}")
        return ticket

    @app.post("/tickets/{ticket_id}/approve", response_model=TicketOut, tags=["access requests"])
    def approve(
        ticket_id: int,
        body: DecisionIn | None = None,
        user: User = Depends(require_role("approver", "admin")),
        session: Session = Depends(get_session),
    ):
        return decide(ticket_id, "approved", body or DecisionIn(), user, session)

    @app.post("/tickets/{ticket_id}/reject", response_model=TicketOut, tags=["access requests"])
    def reject(
        ticket_id: int,
        body: DecisionIn | None = None,
        user: User = Depends(require_role("approver", "admin")),
        session: Session = Depends(get_session),
    ):
        return decide(ticket_id, "rejected", body or DecisionIn(), user, session)

    # -------------------------------------------------------- audit + delivery
    @app.get("/tickets/{ticket_id}/audit", response_model=list[AuditOut], tags=["audit"])
    def get_audit(
        ticket_id: int, user: User = Depends(require_role("approver", "admin")), session: Session = Depends(get_session)
    ):
        load_ticket(session, ticket_id, user)
        return list(session.scalars(select(AuditLog).where(AuditLog.ticket_id == ticket_id).order_by(AuditLog.id)))

    @app.get("/tickets/{ticket_id}/notifications", response_model=list[NotificationOut], tags=["audit"])
    def get_notifications(ticket_id: int, user: User = Depends(current_user), session: Session = Depends(get_session)):
        load_ticket(session, ticket_id, user)
        stmt = select(Notification).where(Notification.ticket_id == ticket_id).order_by(Notification.id)
        return list(session.scalars(stmt))

    # ------------------------------------------------------------- integrations
    def alertmanager_auth(authorization: str | None = Header(default=None)) -> None:
        """Alertmanager authenticates with a bearer token (http_config.authorization), not an X-API-Key."""
        expected = settings.alert_webhook_token
        if not expected:
            raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "alert webhook not configured")
        scheme, _, token = (authorization or "").partition(" ")
        if scheme.lower() != "bearer" or not hmac.compare_digest(token.encode(), expected.encode()):
            raise HTTPException(status.HTTP_401_UNAUTHORIZED, "invalid bearer token")

    @app.post(
        "/integrations/alertmanager",
        response_model=AmWebhookResult,
        tags=["integrations"],
        dependencies=[Depends(alertmanager_auth)],
    )
    def alertmanager_webhook(body: AmWebhook, session: Session = Depends(get_session)):
        """Alertmanager webhook receiver: firing alerts open incident follow-up tickets, resolved alerts
        record the time to recover. Idempotent per alert fingerprint."""
        results = handle_webhook(session, app.state.queue, settings, body.alerts)
        return AmWebhookResult(received=len(body.alerts), results=results)

    # ----------------------------------------------------------------------- UI
    app.mount("/ui", StaticFiles(directory=UI_DIR, html=True), name="ui")

    return app


def build() -> FastAPI:
    """Entry point for uvicorn: `uvicorn opsdesk.api.main:build --factory`."""
    return create_app()
