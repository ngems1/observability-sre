import json

from sqlalchemy import select

CHANGE = {"type": "change_request", "title": "Patch ingress controller", "priority": "medium"}


class RecordingNotifier:
    channel = "slack"

    def __init__(self, fail: bool = False):
        self.sent: list[str] = []
        self.fail = fail

    def send(self, text: str, ticket_id: int) -> None:
        if self.fail:
            raise RuntimeError("slack 503")
        self.sent.append(text)


def make_worker(app, notifier):
    from opsdesk.worker.main import Worker

    return Worker(app.state.settings, queue=app.state.queue, notifier=notifier)


def notification_rows(app):
    from opsdesk.db import session_factory
    from opsdesk.models import Notification

    with session_factory()() as s:
        return list(s.scalars(select(Notification).order_by(Notification.id)))


def queue_depth(aws, name):
    url = aws.get_queue_url(QueueName=name)["QueueUrl"]
    attrs = aws.get_queue_attributes(
        QueueUrl=url, AttributeNames=["ApproximateNumberOfMessages", "ApproximateNumberOfMessagesNotVisible"]
    )
    a = attrs["Attributes"]
    return int(a["ApproximateNumberOfMessages"]) + int(a["ApproximateNumberOfMessagesNotVisible"])


def test_worker_delivers_and_records_timing(app, client, headers, aws):
    client.post("/tickets", json=CHANGE, headers=headers("alice"))
    notifier = RecordingNotifier()
    worker = make_worker(app, notifier)
    outcomes = [worker.handle(m) for m in worker.queue.receive()]
    assert outcomes == ["sent"]
    assert "New ticket" in notifier.sent[0]
    row = notification_rows(app)[0]
    assert row.status == "sent" and row.attempts == 1 and row.sent_at >= row.enqueued_at
    assert queue_depth(aws, "opsdesk-notifications") == 0


def test_duplicate_message_is_skipped(app, client, headers, aws):
    client.post("/tickets", json=CHANGE, headers=headers("alice"))
    notifier = RecordingNotifier()
    worker = make_worker(app, notifier)
    msg = worker.queue.receive()[0]
    assert worker.handle(msg) == "sent"
    # simulate SQS at-least-once redelivery of the same body
    worker.queue.publish(json.loads(msg["Body"]))
    assert [worker.handle(m) for m in worker.queue.receive()] == ["duplicate_skipped"]
    assert len(notifier.sent) == 1


def test_failures_retry_then_mark_failed(app, client, headers, aws):
    client.post("/tickets", json=CHANGE, headers=headers("alice"))
    worker = make_worker(app, RecordingNotifier(fail=True))
    msg = worker.queue.receive()[0]
    assert worker.handle(msg) == "retried"
    assert notification_rows(app)[0].status == "retrying"
    msg["Attributes"]["ApproximateReceiveCount"] = "3"  # third and last attempt
    assert worker.handle(msg) == "retried"
    row = notification_rows(app)[0]
    assert row.status == "failed" and row.attempts == 2 and "slack 503" in row.last_error
    assert queue_depth(aws, "opsdesk-notifications") == 1  # not deleted -> SQS redrives to DLQ


def test_poison_message_left_for_dlq(app, aws):
    worker = make_worker(app, RecordingNotifier())
    worker.queue.client.send_message(QueueUrl=worker.queue.url, MessageBody="{not json")
    assert [worker.handle(m) for m in worker.queue.receive()] == ["poison"]
    assert queue_depth(aws, "opsdesk-notifications") == 1


def test_worker_health_and_metrics_endpoint(app):
    import urllib.request

    from opsdesk.worker.main import serve_probes

    worker = make_worker(app, RecordingNotifier())
    server = serve_probes(worker, 0)
    port = server.server_address[1]
    assert urllib.request.urlopen(f"http://127.0.0.1:{port}/healthz").status == 200
    body = urllib.request.urlopen(f"http://127.0.0.1:{port}/metrics").read().decode()
    assert "opsdesk_notifications_total" in body
    server.shutdown()


def test_seed_tickets(app):
    from opsdesk.db import session_factory
    from opsdesk.models import Ticket
    from opsdesk.seed import seed_tickets

    seed_tickets(500)
    with session_factory()() as s:
        assert s.query(Ticket).count() == 500


def test_one_trace_spans_api_queue_and_worker(app, client, headers):
    """The worker's span must continue the API request's trace (traceparent via SQS)."""
    from opentelemetry import trace
    from opentelemetry.sdk.trace.export import SimpleSpanProcessor
    from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter

    from opsdesk.db import session_factory
    from opsdesk.models import AuditLog

    exporter = InMemorySpanExporter()
    trace.get_tracer_provider().add_span_processor(SimpleSpanProcessor(exporter))

    client.post("/tickets", json=CHANGE, headers=headers("alice"))
    with session_factory()() as s:
        api_trace_id = s.scalar(select(AuditLog.trace_id))
    assert api_trace_id

    worker = make_worker(app, RecordingNotifier())
    [worker.handle(m) for m in worker.queue.receive()]
    consumer = [sp for sp in exporter.get_finished_spans() if sp.name == "process notification"]
    assert format(consumer[0].context.trace_id, "032x") == api_trace_id
    names = {sp.name for sp in exporter.get_finished_spans()}
    assert any("SQS.SendMessage" in n or "send" in n.lower() for n in names), names
