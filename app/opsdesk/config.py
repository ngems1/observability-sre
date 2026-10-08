from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """All runtime configuration comes from environment variables (12-factor)."""

    model_config = SettingsConfigDict(env_prefix="OPSDESK_", env_file=".env", extra="ignore")

    service_name: str = "ticket-api"
    environment: str = "local"
    log_level: str = "INFO"

    # Database
    database_url: str = "postgresql+psycopg://opsdesk:opsdesk@localhost:5432/opsdesk"
    db_pool_size: int = 5
    db_max_overflow: int = 5
    db_pool_timeout_s: int = 5

    # Queue (SQS on AWS, ElasticMQ locally)
    aws_region: str = "us-east-1"
    sqs_endpoint_url: str | None = None  # set only for ElasticMQ / LocalStack
    sqs_queue_name: str = "opsdesk-notifications"
    sqs_wait_time_s: int = 10
    sqs_visibility_timeout_s: int = 30
    sqs_max_receive_count: int = 3  # must match the queue's redrive policy
    queue_metrics_interval_s: int = 30  # ticket-api samples queue depth (main + DLQ); 0 = off

    # Notifications: empty webhook = "log only" mode (no real Slack call)
    slack_webhook_url: str | None = None
    notify_timeout_s: float = 5.0

    # Telemetry: empty endpoint = tracing disabled
    otel_exporter_otlp_endpoint: str | None = None
    otel_sample_ratio: float = 1.0

    # Worker
    worker_metrics_port: int = 9100
    worker_heartbeat_max_age_s: int = 60

    # Behaviour
    auto_assign: bool = True

    # Alertmanager webhook (POST /integrations/alertmanager): empty token = integration disabled (503)
    alert_webhook_token: str | None = None
    alert_ticket_severities: str = "critical"  # comma-separated; other severities are acknowledged and ignored

    # Web UI
    grafana_url: str | None = None  # enables "Open trace in Grafana" links
    bootstrap_users: str = ""  # same var the migrate step reads; shown as demo logins ONLY when environment=local

    # Chaos switches for failure drills (all off by default)
    chaos_latency_ms: int = 0
    chaos_error_rate: float = 0.0
    chaos_worker_fail_rate: float = 0.0


@lru_cache
def get_settings() -> Settings:
    return Settings()
