from datetime import UTC, datetime, timedelta

from sqlalchemy import (
    BigInteger,
    CheckConstraint,
    DateTime,
    ForeignKey,
    Integer,
    String,
    Text,
    func,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship

ROLES = ("requester", "approver", "admin")
TICKET_TYPES = ("access_request", "change_request", "incident_followup")
PRIORITIES = ("low", "medium", "high", "critical")
TEAMS = ("platform", "network_ops", "security", "database", "core_network")
STATUSES = ("open", "triaged", "in_progress", "resolved", "closed")
DECISIONS = ("pending", "approved", "rejected")
NOTIFICATION_STATUSES = ("queued", "publish_failed", "retrying", "sent", "failed")
SOURCES = ("manual", "alert")

# Time-to-triage targets by priority (wall clock; business-hours calendars are out of scope)
TRIAGE_SLA = {
    "critical": timedelta(minutes=30),
    "high": timedelta(hours=2),
    "medium": timedelta(hours=8),
    "low": timedelta(hours=24),
}


def _in(column: str, values: tuple[str, ...]) -> str:
    return f"{column} IN ({', '.join(repr(v) for v in values)})"


class Base(DeclarativeBase):
    pass


class User(Base):
    __tablename__ = "users"
    __table_args__ = (CheckConstraint(_in("role", ROLES), name="ck_users_role"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    name: Mapped[str] = mapped_column(String(100), unique=True)
    role: Mapped[str] = mapped_column(String(20))
    api_key_hash: Mapped[str] = mapped_column(String(64), unique=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class Ticket(Base):
    __tablename__ = "tickets"
    __table_args__ = (
        CheckConstraint(_in("type", TICKET_TYPES), name="ck_tickets_type"),
        CheckConstraint(_in("priority", PRIORITIES), name="ck_tickets_priority"),
        CheckConstraint(_in("status", STATUSES), name="ck_tickets_status"),
        CheckConstraint(_in("team", TEAMS), name="ck_tickets_team"),
        CheckConstraint(_in("source", SOURCES), name="ck_tickets_source"),
    )

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    type: Mapped[str] = mapped_column(String(30))
    title: Mapped[str] = mapped_column(String(200))
    description: Mapped[str] = mapped_column(Text, default="")
    priority: Mapped[str] = mapped_column(String(10), default="medium")
    status: Mapped[str] = mapped_column(String(20), default="open")
    team: Mapped[str] = mapped_column(String(20), default="platform")
    source: Mapped[str] = mapped_column(String(10), default="manual")  # alert = opened by Alertmanager
    requester_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    assignee_id: Mapped[int | None] = mapped_column(ForeignKey("users.id"))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )
    triaged_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    resolved_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    access_request: Mapped["AccessRequest | None"] = relationship(
        back_populates="ticket", uselist=False, lazy="selectin"
    )
    comments: Mapped[list["Comment"]] = relationship(back_populates="ticket", order_by="Comment.id", lazy="selectin")
    requester: Mapped[User] = relationship(foreign_keys=[requester_id], lazy="selectin")
    assignee: Mapped[User | None] = relationship(foreign_keys=[assignee_id], lazy="selectin")
    alerts: Mapped[list["IncidentAlert"]] = relationship(
        back_populates="ticket", order_by="IncidentAlert.id", lazy="selectin"
    )

    # ---- derived fields read by the API schemas (from_attributes) ----
    @property
    def key(self) -> str:
        return f"OPS-{self.id}"

    @property
    def requester_name(self) -> str | None:
        return self.requester.name if self.requester else None

    @property
    def assignee_name(self) -> str | None:
        return self.assignee.name if self.assignee else None

    @property
    def next_statuses(self) -> list[str]:
        from opsdesk.workflow import ALLOWED_TRANSITIONS

        order = list(STATUSES)
        return sorted(ALLOWED_TRANSITIONS.get(self.status, set()), key=order.index)

    @property
    def alert(self) -> "IncidentAlert | None":
        """Latest alert firing linked to this ticket (None for manual tickets)."""
        return self.alerts[-1] if self.alerts else None

    @property
    def sla(self) -> dict:
        return triage_sla(self.priority, self.created_at, self.triaged_at, self.status)


def triage_sla(
    priority: str, created_at: datetime, triaged_at: datetime | None, status: str, now: datetime | None = None
) -> dict:
    """Time-to-triage SLA state: met | breached | due_soon | on_track."""
    now = now or datetime.now(UTC)
    target = TRIAGE_SLA.get(priority, TRIAGE_SLA["medium"])
    due = created_at + target
    if triaged_at is not None or status != "open":
        done = triaged_at or now
        return {"due_at": due, "state": "met" if done <= due else "breached", "minutes_left": None}
    left = (due - now).total_seconds() / 60
    if left < 0:
        state = "breached"
    elif left <= target.total_seconds() / 60 * 0.25:
        state = "due_soon"
    else:
        state = "on_track"
    return {"due_at": due, "state": state, "minutes_left": round(left)}


class AccessRequest(Base):
    __tablename__ = "access_requests"
    __table_args__ = (CheckConstraint(_in("decision", DECISIONS), name="ck_access_decision"),)

    ticket_id: Mapped[int] = mapped_column(ForeignKey("tickets.id"), primary_key=True)
    resource: Mapped[str] = mapped_column(String(200))
    requested_role: Mapped[str] = mapped_column(String(100))
    justification: Mapped[str] = mapped_column(Text)
    duration_days: Mapped[int] = mapped_column(Integer, default=7)
    decision: Mapped[str] = mapped_column(String(10), default="pending")
    approver_id: Mapped[int | None] = mapped_column(ForeignKey("users.id"))
    decided_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    ticket: Mapped[Ticket] = relationship(back_populates="access_request")


class Comment(Base):
    __tablename__ = "comments"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    ticket_id: Mapped[int] = mapped_column(ForeignKey("tickets.id"), index=True)
    author_id: Mapped[int] = mapped_column(ForeignKey("users.id"))
    body: Mapped[str] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    ticket: Mapped[Ticket] = relationship(back_populates="comments")
    author: Mapped[User] = relationship(lazy="selectin")

    @property
    def author_name(self) -> str | None:
        return self.author.name if self.author else None


class AuditLog(Base):
    """Append-only: a DB trigger rejects UPDATE and DELETE (see migration 0001)."""

    __tablename__ = "audit_log"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    ticket_id: Mapped[int] = mapped_column(ForeignKey("tickets.id"), index=True)
    action: Mapped[str] = mapped_column(String(50))
    actor_id: Mapped[int] = mapped_column(ForeignKey("users.id"))
    old_value: Mapped[dict | None] = mapped_column(JSONB)
    new_value: Mapped[dict | None] = mapped_column(JSONB)
    trace_id: Mapped[str | None] = mapped_column(String(32))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    actor: Mapped[User] = relationship(lazy="selectin")

    @property
    def actor_name(self) -> str | None:
        return self.actor.name if self.actor else None


class Notification(Base):
    __tablename__ = "notifications"
    __table_args__ = (CheckConstraint(_in("status", NOTIFICATION_STATUSES), name="ck_notifications_status"),)

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    ticket_id: Mapped[int] = mapped_column(ForeignKey("tickets.id"), index=True)
    event: Mapped[str] = mapped_column(String(50))
    channel: Mapped[str] = mapped_column(String(20), default="slack")
    status: Mapped[str] = mapped_column(String(20), default="queued")
    attempts: Mapped[int] = mapped_column(Integer, default=0)
    last_error: Mapped[str | None] = mapped_column(Text)
    enqueued_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    sent_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class IncidentAlert(Base):
    """One Alertmanager firing (fingerprint + startsAt) linked to an incident follow-up ticket.

    A partial unique index allows only one unresolved row per fingerprint (migration 0003)."""

    __tablename__ = "incident_alerts"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    fingerprint: Mapped[str] = mapped_column(String(64), index=True)
    ticket_id: Mapped[int] = mapped_column(ForeignKey("tickets.id"), index=True)
    alertname: Mapped[str] = mapped_column(String(200))
    severity: Mapped[str] = mapped_column(String(20))
    started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    resolved_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    labels: Mapped[dict] = mapped_column(JSONB, default=dict)
    annotations: Mapped[dict] = mapped_column(JSONB, default=dict)
    generator_url: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    ticket: Mapped[Ticket] = relationship(back_populates="alerts")

    @property
    def runbook_url(self) -> str | None:
        return (self.annotations or {}).get("runbook_url")

    @property
    def summary(self) -> str | None:
        a = self.annotations or {}
        return a.get("summary") or a.get("description")

    @property
    def time_to_recover_s(self) -> int | None:
        if self.resolved_at is None:
            return None
        return max(0, round((self.resolved_at - self.started_at).total_seconds()))
