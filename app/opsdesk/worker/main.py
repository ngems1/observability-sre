"""ticket-worker: consumes notification events from SQS and delivers them.

Delivery semantics:
- SQS is at-least-once, so notifications.id is the idempotency key: a row already
  marked 'sent' is skipped and the duplicate message deleted.
- On failure the message is NOT deleted; it becomes visible again after the
  visibility timeout. After maxReceiveCount (3) SQS moves it to the DLQ.
- Unparseable (poison) messages are left undeleted too, so they land in the DLQ.
"""

import json
import logging
import random
import signal
import threading
import time
from datetime import UTC, datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from opentelemetry import trace
from opentelemetry.trace import SpanKind, Status, StatusCode
from prometheus_client import REGISTRY
from prometheus_client.exposition import choose_encoder

from opsdesk.config import Settings, get_settings
from opsdesk.db import init_engine, session_factory, update_pool_metrics
from opsdesk.deps import record_failure
from opsdesk.logging_setup import configure_logging
from opsdesk.metrics import NOTIFICATION_DELIVERY, NOTIFICATIONS, WORKER_LAST_POLL
from opsdesk.models import Notification, Ticket
from opsdesk.notify import SlackNotifier, render
from opsdesk.queue import Queue
from opsdesk.telemetry import configure_tracing, extract_context

log = logging.getLogger("opsdesk.worker")
tracer = trace.get_tracer("opsdesk.worker")


class PoisonMessage(Exception):
    pass


class Worker:
    def __init__(self, settings: Settings, queue: Queue | None = None, notifier=None):
        self.settings = settings
        self.queue = queue or Queue(settings)
        self.notifier = notifier or SlackNotifier(settings)
        self.Session = session_factory()
        self.stop = threading.Event()
        self.last_poll = time.time()

    # ------------------------------------------------------------- processing
    def handle(self, message: dict) -> str:
        """Process one SQS message. Returns the outcome; deletes the message only on success."""
        parent = extract_context(message.get("MessageAttributes"))
        with tracer.start_as_current_span("process notification", context=parent, kind=SpanKind.CONSUMER) as span:
            span.set_attribute("messaging.system", "aws_sqs")
            span.set_attribute("messaging.message.id", message.get("MessageId", ""))
            receive_count = int(message.get("Attributes", {}).get("ApproximateReceiveCount", "1"))
            span.set_attribute("messaging.receive_count", receive_count)
            try:
                outcome = self._process(message, span, receive_count)
            except PoisonMessage as exc:
                span.set_status(Status(StatusCode.ERROR, str(exc)))
                NOTIFICATIONS.labels("slack", "poison").inc()
                log.error(
                    "poison message, leaving it for the DLQ",
                    extra={"message_id": message.get("MessageId"), "receive_count": receive_count},
                )
                return "poison"
            except Exception as exc:  # noqa: BLE001
                span.record_exception(exc)
                span.set_status(Status(StatusCode.ERROR, str(exc)))
                NOTIFICATIONS.labels("slack", "retried").inc()
                dep = record_failure(exc)  # postgres / slack failures, classified (chaos errors are not)
                if dep:
                    span.set_attribute("opsdesk.dependency", dep[0])
                    span.set_attribute("opsdesk.error_kind", dep[1])
                log.warning(
                    "delivery failed, will retry",
                    extra={
                        "message_id": message.get("MessageId"),
                        "receive_count": receive_count,
                        "error": str(exc)[:300],
                        "dependency": dep and dep[0],
                        "error_kind": dep and dep[1],
                    },
                )
                return "retried"
            self.queue.delete(message["ReceiptHandle"])
            return outcome

    def _process(self, message: dict, span, receive_count: int) -> str:
        try:
            body = json.loads(message["Body"])
            notification_id = int(body["notification_id"])
        except (KeyError, TypeError, ValueError) as exc:
            raise PoisonMessage(f"cannot parse message: {exc}") from exc
        span.set_attribute("opsdesk.notification_id", notification_id)

        with self.Session() as session:
            notification = session.get(Notification, notification_id, with_for_update=True)
            if notification is None:
                raise PoisonMessage(f"notification {notification_id} does not exist")
            span.set_attribute("opsdesk.ticket_id", notification.ticket_id)
            if notification.status == "sent":
                NOTIFICATIONS.labels(notification.channel, "duplicate_skipped").inc()
                log.info("duplicate delivery skipped", extra={"notification_id": notification_id})
                return "duplicate_skipped"

            notification.attempts += 1
            try:
                if self.settings.chaos_worker_fail_rate > 0 and random.random() < self.settings.chaos_worker_fail_rate:
                    raise RuntimeError("chaos: injected worker failure")
                ticket = session.get(Ticket, notification.ticket_id)
                self.notifier.send(render(notification.event, ticket), ticket.id)
            except Exception as exc:
                # last attempt before SQS moves the message to the DLQ
                final = receive_count >= self.settings.sqs_max_receive_count
                notification.status = "failed" if final else "retrying"
                notification.last_error = str(exc)[:500]
                session.commit()
                raise

            now = datetime.now(UTC)
            notification.status = "sent"
            notification.sent_at = now
            notification.last_error = None
            session.commit()

            delay = (now - notification.enqueued_at).total_seconds()
            trace_id = format(span.get_span_context().trace_id, "032x")
            NOTIFICATION_DELIVERY.observe(max(delay, 0), exemplar={"trace_id": trace_id})
            NOTIFICATIONS.labels(notification.channel, "sent").inc()
            log.info(
                "notification sent",
                extra={
                    "notification_id": notification_id,
                    "ticket_id": notification.ticket_id,
                    "event": notification.event,
                    "delivery_seconds": round(delay, 3),
                },
            )
            return "sent"

    # ------------------------------------------------------------------- loop
    def run(self) -> None:
        log.info("worker started", extra={"queue": self.settings.sqs_queue_name})
        while not self.stop.is_set():
            try:
                messages = self.queue.receive()
                self.last_poll = time.time()
                WORKER_LAST_POLL.set(self.last_poll)
                for message in messages:
                    self.handle(message)
                update_pool_metrics()
            except Exception as exc:  # noqa: BLE001
                dep = record_failure(exc) or record_failure(exc, "sqs")  # receive() failures are SQS
                log.exception(
                    "poll failed; backing off", extra={"dependency": dep and dep[0], "error_kind": dep and dep[1]}
                )
                self.stop.wait(5)
        log.info("worker stopped")

    def healthy(self) -> bool:
        return time.time() - self.last_poll < self.settings.worker_heartbeat_max_age_s


def serve_probes(worker: Worker, port: int) -> ThreadingHTTPServer:
    """/healthz (poll loop alive) and /metrics on one small HTTP server."""

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802
            if self.path == "/healthz":
                ok = worker.healthy()
                self._reply(200 if ok else 503, b"ok" if ok else b"stale", "text/plain")
            elif self.path == "/metrics":
                encoder, content_type = choose_encoder(self.headers.get("Accept", ""))
                self._reply(200, encoder(REGISTRY), content_type)
            else:
                self._reply(404, b"not found", "text/plain")

        def _reply(self, code: int, body: bytes, content_type: str):
            self.send_response(code)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):  # silence default access log
            pass

    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def main() -> None:
    settings = get_settings()
    configure_logging(settings.service_name, settings.environment, settings.log_level)
    configure_tracing(settings)
    init_engine(settings)
    worker = Worker(settings)
    serve_probes(worker, settings.worker_metrics_port)

    def shutdown(signum, _frame):
        log.info("shutdown signal received", extra={"signal": signum})
        worker.stop.set()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    worker.run()
    trace.get_tracer_provider().shutdown()


if __name__ == "__main__":
    main()
