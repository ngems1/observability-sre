"""Tests run against a real PostgreSQL (schema built by the Alembic migration)
and a moto-mocked SQS queue with a DLQ redrive policy."""

import json
import os
import pathlib

import pytest

os.environ.setdefault("OPSDESK_DATABASE_URL", "postgresql+psycopg://opsdesk:opsdesk@localhost:5432/opsdesk_test")
os.environ.setdefault("OPSDESK_LOG_LEVEL", "WARNING")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "test")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "test")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from alembic import command  # noqa: E402
from alembic.config import Config  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
from moto import mock_aws  # noqa: E402
from sqlalchemy import create_engine, text  # noqa: E402

from opsdesk.config import Settings  # noqa: E402

APP_DIR = pathlib.Path(__file__).resolve().parents[1]
KEYS = {"alice": "alice-key", "bob": "bob-key", "carol": "carol-key", "dave": "dave-key"}
ALERT_TOKEN = "test-alert-token"
BOOTSTRAP = "alice:requester:alice-key,bob:approver:bob-key,carol:admin:carol-key,dave:approver:dave-key"


@pytest.fixture(scope="session")
def settings() -> Settings:
    return Settings(
        sqs_wait_time_s=0,
        queue_metrics_interval_s=0,  # tests call Queue.sample_depth() directly
        alert_webhook_token=ALERT_TOKEN,
        alert_ticket_severities="critical,warning",
    )


@pytest.fixture(scope="session", autouse=True)
def schema(settings):
    engine = create_engine(settings.database_url)
    with engine.begin() as conn:
        conn.execute(text("DROP SCHEMA public CASCADE; CREATE SCHEMA public"))
    cfg = Config(str(APP_DIR / "alembic.ini"))
    cfg.set_main_option("script_location", str(APP_DIR / "migrations"))
    command.upgrade(cfg, "head")
    yield
    engine.dispose()


@pytest.fixture
def aws():
    with mock_aws():
        import boto3

        sqs = boto3.client("sqs", region_name="us-east-1")
        dlq_url = sqs.create_queue(QueueName="opsdesk-notifications-dlq")["QueueUrl"]
        dlq_arn = sqs.get_queue_attributes(QueueUrl=dlq_url, AttributeNames=["QueueArn"])["Attributes"]["QueueArn"]
        sqs.create_queue(
            QueueName="opsdesk-notifications",
            Attributes={"RedrivePolicy": json.dumps({"deadLetterTargetArn": dlq_arn, "maxReceiveCount": "3"})},
        )
        yield sqs


@pytest.fixture
def app(settings, aws):
    from opsdesk.api.main import create_app
    from opsdesk.queue import Queue
    from opsdesk.seed import seed_users

    application = create_app(settings, queue=Queue(settings))
    engine = create_engine(settings.database_url)
    with engine.begin() as conn:
        conn.execute(
            text(
                "TRUNCATE incident_alerts, notifications, audit_log, comments, access_requests, tickets, users "
                "RESTART IDENTITY CASCADE"
            )
        )
    engine.dispose()
    seed_users(BOOTSTRAP)
    return application


@pytest.fixture
def client(app):
    return TestClient(app)


def h(user: str) -> dict:
    return {"X-API-Key": KEYS[user]}


@pytest.fixture
def headers():
    return h
