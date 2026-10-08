"""Thin SQS wrapper used by both workloads. Works with AWS SQS and ElasticMQ."""

import json
import logging
import threading

import boto3
from botocore.config import Config

from opsdesk.config import Settings
from opsdesk.deps import record_failure
from opsdesk.metrics import QUEUE_MESSAGES
from opsdesk.telemetry import inject_message_attributes

log = logging.getLogger(__name__)


class Queue:
    def __init__(self, settings: Settings):
        self.settings = settings
        self.client = boto3.client(
            "sqs",
            region_name=settings.aws_region,
            endpoint_url=settings.sqs_endpoint_url,
            config=Config(retries={"max_attempts": 3, "mode": "standard"}, connect_timeout=3, read_timeout=15),
        )
        self._url: str | None = None
        self._dlq: str | None = None
        self._lock = threading.Lock()

    @property
    def url(self) -> str:
        if self._url is None:
            with self._lock:
                if self._url is None:
                    self._url = self.client.get_queue_url(QueueName=self.settings.sqs_queue_name)["QueueUrl"]
        return self._url

    def publish(self, body: dict) -> str:
        """Send one event; the current trace context rides along as message attributes."""
        resp = self.client.send_message(
            QueueUrl=self.url,
            MessageBody=json.dumps(body),
            MessageAttributes=inject_message_attributes(),
        )
        return resp["MessageId"]

    def receive(self, max_messages: int = 10) -> list[dict]:
        resp = self.client.receive_message(
            QueueUrl=self.url,
            MaxNumberOfMessages=max_messages,
            WaitTimeSeconds=self.settings.sqs_wait_time_s,
            VisibilityTimeout=self.settings.sqs_visibility_timeout_s,
            MessageAttributeNames=["All"],
            AttributeNames=["ApproximateReceiveCount", "SentTimestamp"],
        )
        return resp.get("Messages", [])

    def delete(self, receipt_handle: str) -> None:
        self.client.delete_message(QueueUrl=self.url, ReceiptHandle=receipt_handle)

    def sample_depth(self) -> None:
        """Queue depth for the main queue and its DLQ as Prometheus gauges.

        Sampled by ticket-api, not the worker, so the backlog is still visible when the worker is down."""
        names = {"main": self.settings.sqs_queue_name, "dlq": f"{self.settings.sqs_queue_name}-dlq"}
        for label, name in names.items():
            try:
                url = self.url if label == "main" else self._dlq_url(name)
                attrs = self.client.get_queue_attributes(
                    QueueUrl=url,
                    AttributeNames=["ApproximateNumberOfMessages", "ApproximateNumberOfMessagesNotVisible"],
                )["Attributes"]
                QUEUE_MESSAGES.labels(label, "visible").set(int(attrs.get("ApproximateNumberOfMessages", 0)))
                QUEUE_MESSAGES.labels(label, "in_flight").set(
                    int(attrs.get("ApproximateNumberOfMessagesNotVisible", 0))
                )
            except Exception as exc:  # noqa: BLE001
                dep = record_failure(exc, "sqs")
                log.warning("queue depth sample failed", extra={"queue": name, "error_kind": dep and dep[1]})

    def _dlq_url(self, name: str) -> str:
        if self._dlq is None:
            self._dlq = self.client.get_queue_url(QueueName=name)["QueueUrl"]
        return self._dlq

    @property
    def resolved(self) -> bool:
        """True once the queue URL has been looked up successfully (no network call)."""
        return self._url is not None

    def ping(self) -> bool:
        try:
            _ = self.url
            return True
        except Exception as exc:  # noqa: BLE001
            dep = record_failure(exc, "sqs")
            log.warning("queue not reachable", extra={"dependency": "sqs", "error_kind": dep and dep[1]}, exc_info=True)
            return False
