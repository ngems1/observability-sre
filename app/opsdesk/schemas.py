from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

TicketType = Literal["access_request", "change_request", "incident_followup"]
Priority = Literal["low", "medium", "high", "critical"]
Status = Literal["open", "triaged", "in_progress", "resolved", "closed"]
Team = Literal["platform", "network_ops", "security", "database", "core_network"]


class AccessRequestIn(BaseModel):
    resource: str = Field(min_length=1, max_length=200, examples=["prod-eks-cluster"])
    requested_role: str = Field(min_length=1, max_length=100, examples=["read-only"])
    justification: str = Field(min_length=5, max_length=2000)
    duration_days: int = Field(default=7, ge=1, le=90)


class TicketCreate(BaseModel):
    type: TicketType
    title: str = Field(min_length=3, max_length=200)
    description: str = Field(default="", max_length=10000)
    priority: Priority = "medium"
    team: Team = "platform"
    access: AccessRequestIn | None = None

    @model_validator(mode="after")
    def access_matches_type(self) -> "TicketCreate":
        if self.type == "access_request" and self.access is None:
            raise ValueError("access details are required for type=access_request")
        if self.type != "access_request" and self.access is not None:
            raise ValueError("access details are only allowed for type=access_request")
        return self


class StatusUpdate(BaseModel):
    status: Status


class AssigneeUpdate(BaseModel):
    assignee_id: int | None


class CommentCreate(BaseModel):
    body: str = Field(min_length=1, max_length=5000)


class DecisionIn(BaseModel):
    reason: str = Field(default="", max_length=1000)


class AccessRequestOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    resource: str
    requested_role: str
    justification: str
    duration_days: int
    decision: str
    approver_id: int | None
    decided_at: datetime | None
    expires_at: datetime | None


class CommentOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    author_id: int
    author_name: str | None = None
    body: str
    created_at: datetime


class SlaOut(BaseModel):
    due_at: datetime
    state: Literal["on_track", "due_soon", "breached", "met"]
    minutes_left: int | None


class AlertOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    alertname: str
    severity: str
    summary: str | None = None
    started_at: datetime
    resolved_at: datetime | None
    time_to_recover_s: int | None = None
    runbook_url: str | None = None
    generator_url: str | None = None
    labels: dict = {}


class TicketOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    key: str
    type: str
    title: str
    description: str
    priority: str
    status: str
    team: str
    source: str = "manual"
    requester_id: int
    requester_name: str | None = None
    assignee_id: int | None
    assignee_name: str | None = None
    sla: SlaOut
    next_statuses: list[str] = []
    created_at: datetime
    updated_at: datetime
    triaged_at: datetime | None
    resolved_at: datetime | None
    access_request: AccessRequestOut | None = None


class TicketDetail(TicketOut):
    comments: list[CommentOut] = []
    alert: AlertOut | None = None  # latest Alertmanager firing for source=alert tickets


# ---- Alertmanager webhook payload (version 4). Unknown fields are ignored.
class AmAlert(BaseModel):
    status: Literal["firing", "resolved"]
    labels: dict[str, str] = {}
    annotations: dict[str, str] = {}
    startsAt: datetime
    endsAt: datetime | None = None
    generatorURL: str | None = None
    fingerprint: str = Field(min_length=1, max_length=64)


class AmWebhook(BaseModel):
    version: str = "4"
    status: str | None = None
    receiver: str | None = None
    groupKey: str | None = None
    alerts: list[AmAlert] = Field(default=[], max_length=500)


class AmWebhookResult(BaseModel):
    received: int
    results: list[dict]


class AuditOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    action: str
    actor_id: int
    actor_name: str | None = None
    old_value: dict | None
    new_value: dict | None
    trace_id: str | None
    created_at: datetime


class NotificationOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    event: str
    channel: str
    status: str
    attempts: int
    last_error: str | None
    enqueued_at: datetime
    sent_at: datetime | None


class UserOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    name: str
    role: str


class SummaryOut(BaseModel):
    mine: int
    pending_approval: int
    open: int
    breached: int
    all: int


class DemoUser(BaseModel):
    name: str
    role: str
    api_key: str


class UiConfig(BaseModel):
    environment: str
    version: str
    grafana_url: str | None
    demo_users: list[DemoUser] = []
