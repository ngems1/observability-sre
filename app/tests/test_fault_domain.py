"""Fault-domain signals: which dependency failed and how (network vs database vs config)."""

import json

import botocore.exceptions as bexc
import httpx
import psycopg
import pytest
from prometheus_client import REGISTRY
from sqlalchemy import create_engine, text
from sqlalchemy.exc import OperationalError

from opsdesk.deps import classify, guess_dependency, record_failure


def pg(msg: str) -> OperationalError:
    return OperationalError("SELECT 1", {}, psycopg.OperationalError(msg))


def aws_error(code: str, status: int) -> bexc.ClientError:
    return bexc.ClientError({"Error": {"Code": code}, "ResponseMetadata": {"HTTPStatusCode": status}}, "SendMessage")


SQS = "https://sqs.us-east-1.amazonaws.com"


def errors(dependency: str, kind: str) -> float:
    return REGISTRY.get_sample_value("opsdesk_dependency_errors_total", {"dependency": dependency, "kind": kind}) or 0.0


def pg_error(url: str) -> Exception:
    engine = create_engine(url, connect_args={"connect_timeout": 2})
    try:
        with engine.connect() as conn:
            conn.execute(text("SELECT 1"))
    except Exception as exc:  # noqa: BLE001
        return exc
    finally:
        engine.dispose()
    raise AssertionError("expected a connection error")


def test_real_postgres_failures_are_classified():
    refused = pg_error("postgresql+psycopg://x:y@127.0.0.1:1/x")
    assert (guess_dependency(refused), classify(refused)) == ("postgres", "refused")
    dns = pg_error("postgresql+psycopg://x:y@db.does-not-exist.invalid:5432/x")
    assert classify(dns) == "dns"
    auth = pg_error("postgresql+psycopg://opsdesk:wrong-password@localhost:5432/opsdesk_test")
    assert classify(auth) == "auth"


def test_pool_exhaustion_is_app_config_not_database(settings):
    engine = create_engine(settings.database_url, pool_size=1, max_overflow=0, pool_timeout=0.1)
    held = engine.connect()
    try:
        with pytest.raises(Exception) as info:
            engine.connect()
        assert classify(info.value) == "pool_timeout"
    finally:
        held.close()
        engine.dispose()


@pytest.mark.parametrize(
    ("exc", "dependency", "kind"),
    [
        (pg("connection timeout expired"), "postgres", "connect_timeout"),
        (pg("server closed the connection unexpectedly"), "postgres", "connection_lost"),
        (pg("FATAL:  sorry, too many clients already"), "postgres", "too_many_connections"),
        (aws_error("AccessDenied", 403), "sqs", "auth"),
        (aws_error("InternalError", 500), "sqs", "server_error"),
        (bexc.EndpointConnectionError(endpoint_url=SQS), "sqs", "refused"),
        (bexc.ConnectTimeoutError(endpoint_url=SQS), "sqs", "connect_timeout"),
        (bexc.ReadTimeoutError(endpoint_url=SQS), "sqs", "read_timeout"),
        (httpx.ConnectTimeout("timed out"), "slack", "connect_timeout"),
        (
            httpx.HTTPStatusError(
                "503", request=httpx.Request("POST", "https://hooks"), response=httpx.Response(503)
            ),
            "slack",
            "server_error",
        ),
        (RuntimeError("chaos: injected worker failure"), None, "other"),
    ],
)  # fmt: skip
def test_classification_table(exc, dependency, kind):
    assert guess_dependency(exc) == dependency
    assert classify(exc) == kind


def test_failure_counted_once_when_reraised():
    exc = httpx.ConnectTimeout("timed out")
    before = errors("slack", "connect_timeout")
    assert record_failure(exc, "slack") == ("slack", "connect_timeout")
    assert record_failure(exc) == ("slack", "connect_timeout")
    assert errors("slack", "connect_timeout") == before + 1
    assert record_failure(RuntimeError("bug")) is None


def test_api_500_names_the_failing_dependency(client, headers, monkeypatch, caplog):
    def broken(_session):
        raise OperationalError("SELECT", {}, psycopg.OperationalError("connection refused"))

    monkeypatch.setattr("opsdesk.api.main.pick_assignee", broken)
    before = errors("postgres", "refused")
    r = client.post("/tickets", json={"type": "change_request", "title": "boom"}, headers=headers("alice"))
    assert r.status_code == 500
    assert errors("postgres", "refused") == before + 1
    rec = [x for x in caplog.records if x.getMessage() == "unhandled error"][-1]
    assert (rec.dependency, rec.error_kind) == ("postgres", "refused")


def test_readyz_counts_database_unreachable(settings, aws):
    from opsdesk.api.main import create_app
    from opsdesk.queue import Queue

    bad = settings.model_copy(update={"database_url": "postgresql+psycopg://x:y@127.0.0.1:1/x"})
    from fastapi.testclient import TestClient

    before = errors("postgres", "refused")
    r = TestClient(create_app(bad, queue=Queue(bad))).get("/readyz")
    assert r.status_code == 503
    assert errors("postgres", "refused") >= before + 1


def test_db_query_time_is_measured(client, headers):
    before = REGISTRY.get_sample_value("opsdesk_db_query_duration_seconds_count", {"operation": "select"}) or 0
    client.get("/tickets", headers=headers("carol"))
    assert REGISTRY.get_sample_value("opsdesk_db_query_duration_seconds_count", {"operation": "select"}) > before


def test_queue_depth_sampled_for_main_queue_and_dlq(app, aws):
    url = aws.get_queue_url(QueueName="opsdesk-notifications")["QueueUrl"]
    for i in range(3):
        aws.send_message(QueueUrl=url, MessageBody=json.dumps({"n": i}))
    app.state.queue.sample_depth()
    gauge = lambda q, s: REGISTRY.get_sample_value("opsdesk_queue_messages", {"queue": q, "state": s})  # noqa: E731
    assert gauge("main", "visible") == 3
    assert gauge("dlq", "visible") == 0
