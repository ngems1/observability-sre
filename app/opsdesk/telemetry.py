"""OpenTelemetry tracing setup plus helpers to carry trace context through SQS."""

import logging

from opentelemetry import context, propagate, trace
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.trace.sampling import ParentBased, TraceIdRatioBased

from opsdesk.config import Settings

log = logging.getLogger(__name__)
_configured = False


def configure_tracing(settings: Settings) -> None:
    """Install a tracer provider. Without an OTLP endpoint, spans are created
    (so trace_id still appears in logs) but never exported."""
    global _configured
    if _configured:
        return
    resource = Resource.create(
        {
            "service.name": settings.service_name,
            "service.namespace": "opsdesk",
            "deployment.environment": settings.environment,
        }
    )
    provider = TracerProvider(resource=resource, sampler=ParentBased(TraceIdRatioBased(settings.otel_sample_ratio)))
    if settings.otel_exporter_otlp_endpoint:
        from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter

        endpoint = settings.otel_exporter_otlp_endpoint.rstrip("/") + "/v1/traces"
        provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(endpoint=endpoint)))
        log.info("tracing enabled", extra={"otlp_endpoint": endpoint})
    trace.set_tracer_provider(provider)

    from opentelemetry.instrumentation.botocore import BotocoreInstrumentor
    from opentelemetry.instrumentation.sqlalchemy import SQLAlchemyInstrumentor

    BotocoreInstrumentor().instrument()
    SQLAlchemyInstrumentor().instrument()  # patches create_engine: call before init_engine()
    _configured = True


def current_trace_id() -> str | None:
    ctx = trace.get_current_span().get_span_context()
    return format(ctx.trace_id, "032x") if ctx.is_valid else None


def inject_message_attributes() -> dict:
    """W3C traceparent -> SQS MessageAttributes (string values)."""
    carrier: dict[str, str] = {}
    propagate.inject(carrier)
    return {k: {"DataType": "String", "StringValue": v} for k, v in carrier.items()}


def extract_context(message_attributes: dict | None) -> context.Context:
    carrier = {k: v.get("StringValue", "") for k, v in (message_attributes or {}).items() if isinstance(v, dict)}
    return propagate.extract(carrier)
