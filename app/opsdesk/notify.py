"""Notification channel. Empty webhook URL = log-only mode (safe for local and demo)."""

import logging

import httpx

from opsdesk.config import Settings
from opsdesk.deps import record_failure

log = logging.getLogger(__name__)


class SlackNotifier:
    channel = "slack"

    def __init__(self, settings: Settings):
        self.webhook = settings.slack_webhook_url
        self.client = httpx.Client(timeout=settings.notify_timeout_s)

    def send(self, text: str, ticket_id: int) -> None:
        if not self.webhook:
            log.info("notification (log-only mode)", extra={"ticket_id": ticket_id, "text": text})
            return
        try:
            resp = self.client.post(self.webhook, json={"text": text})
            resp.raise_for_status()
        except Exception as exc:
            record_failure(exc, "slack")
            raise


def render(event: str, ticket) -> str:
    labels = {
        "ticket_created": "New ticket",
        "access_approved": "Access approved",
        "access_rejected": "Access rejected",
        "assigned": "Assigned",
        "alert_resolved": "Alert resolved",
        "alert_refired": "Alert fired again",
    }
    head = labels.get(event, event.replace("_", " ").capitalize())
    if getattr(ticket, "source", "manual") == "alert":
        head = f"[ALERT] {head}"
    return (
        f"[OpsDesk] {head}: OPS-{ticket.id} {ticket.title} "
        f"(type={ticket.type}, priority={ticket.priority}, team={ticket.team}, status={ticket.status})"
    )
