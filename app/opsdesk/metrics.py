"""Prometheus metrics. Names match the SLO and alert definitions in the plan."""

from prometheus_client import Counter, Gauge, Histogram

from opsdesk.telemetry import current_trace_id

HTTP_DURATION = Histogram(
    "http_server_request_duration_seconds",
    "HTTP request latency",
    ["route", "method", "status_code"],
    buckets=(0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0),
)
TICKETS_CREATED = Counter("opsdesk_tickets_created_total", "Tickets created", ["type", "priority"])
STATUS_TRANSITIONS = Counter(
    "opsdesk_status_transitions_total", "Ticket status transitions", ["from_status", "to_status"]
)
INVALID_TRANSITIONS = Counter("opsdesk_invalid_transitions_total", "Rejected status transitions (HTTP 409)")
ACCESS_DECISIONS = Counter("opsdesk_access_decisions_total", "Access request decisions", ["decision"])
NOTIFICATIONS_ENQUEUED = Counter(
    "opsdesk_notifications_enqueued_total", "Notification events published", ["event", "result"]
)
NOTIFICATIONS = Counter(
    "opsdesk_notifications_total",
    "Notification processing outcomes in the worker",
    ["channel", "result"],  # result: sent, retried, failed, duplicate_skipped, poison
)
NOTIFICATION_DELIVERY = Histogram(
    "opsdesk_notification_delivery_seconds",
    "Time from enqueue to delivered notification",
    buckets=(1, 2, 5, 10, 15, 30, 60, 120, 300),
)
TRIAGE_SLA_RESULTS = Counter(
    "opsdesk_triage_sla_total", "Tickets triaged inside / outside their time-to-triage SLA", ["priority", "result"]
)
TIME_TO_TRIAGE = Histogram(
    "opsdesk_time_to_triage_seconds",
    "Ticket creation to triage",
    ["priority"],
    buckets=(60, 300, 900, 1800, 3600, 7200, 14400, 28800, 86400),
)
ALERT_WEBHOOK = Counter(
    "opsdesk_alert_webhook_total",
    "Alertmanager alerts received by the webhook",
    ["result"],  # created, refired, duplicate, resolved, resolved_unknown, ignored
)
INCIDENT_TIME_TO_RECOVER = Histogram(
    "opsdesk_incident_time_to_recover_seconds",
    "Alert startsAt to resolved (MTTR of alert-driven incidents)",
    ["alertname", "severity"],
    buckets=(60, 120, 300, 600, 900, 1800, 3600, 7200, 14400, 86400),
)
# ---- fault-domain signals: which layer is failing (see opsdesk/deps.py for the kinds)
DEPENDENCY_ERRORS = Counter(
    "opsdesk_dependency_errors_total",
    "Failed calls to a dependency, by dependency and failure kind",
    ["dependency", "kind"],  # dependency: postgres, sqs, slack
)
DB_QUERY_DURATION = Histogram(
    "opsdesk_db_query_duration_seconds",
    "Time spent in PostgreSQL per statement (slow database vs slow app code)",
    ["operation"],  # select, insert, update, delete, other
    buckets=(0.002, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
)
QUEUE_MESSAGES = Gauge(
    "opsdesk_queue_messages",
    "SQS queue depth sampled by ticket-api (stays visible when the worker is down)",
    ["queue", "state"],  # queue: main, dlq; state: visible, in_flight
)
DB_POOL = Gauge("opsdesk_db_pool_connections", "SQLAlchemy pool connections", ["state"])
WORKER_LAST_POLL = Gauge("opsdesk_worker_last_poll_timestamp_seconds", "Unix time of the worker's last SQS poll")


def exemplar() -> dict | None:
    """Attach the current trace_id to histogram samples (Grafana exemplars)."""
    trace_id = current_trace_id()
    return {"trace_id": trace_id} if trace_id else None
