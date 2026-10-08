"""Which dependency failed, and how: the signal that tells the layers apart during an outage.

Every failure talking to PostgreSQL, SQS or Slack is counted as
    opsdesk_dependency_errors_total{dependency, kind}
and logged with the same two fields. The kind points at the layer:

    kind              usual layer      meaning
    dns               network          name does not resolve (CoreDNS, VPC DNS, wrong endpoint)
    connect_timeout   network          no answer to the TCP connect (NetworkPolicy, security group, NACL, route)
    refused           network / dep.   host reachable but nothing listening on the port (service down, wrong port)
    connection_lost   network / dep.   connection dropped mid-request (failover, reset, idle timeout)
    auth              security / IAM   credentials or permissions rejected (secret, IRSA role, KMS)
    read_timeout      dependency       connected, but the dependency answered too slowly
    query_timeout     database         statement cancelled by the server
    too_many_connections database      max_connections reached on the server
    pool_timeout      app config       no free DB connection in the pool (pool too small for the load)
    server_error      dependency       the dependency answered with an error (HTTP 5xx, AWS 5xx)
    client_error      app              the dependency rejected our request (HTTP 4xx, bad parameter)
    other             app              anything else (read the trace / stack trace)
"""

import logging
import socket

from opsdesk.metrics import DEPENDENCY_ERRORS

log = logging.getLogger(__name__)

KINDS = (
    "dns",
    "connect_timeout",
    "refused",
    "connection_lost",
    "auth",
    "read_timeout",
    "query_timeout",
    "too_many_connections",
    "pool_timeout",
    "server_error",
    "client_error",
    "other",
)
NETWORK_KINDS = ("dns", "connect_timeout", "refused", "connection_lost")

_DNS = ("could not translate host name", "name or service not known", "temporary failure in name resolution",
        "nodename nor servname", "getaddrinfo failed", "no address associated")  # fmt: skip
_REFUSED = ("connection refused", "econnrefused")
_LOST = ("server closed the connection", "connection reset", "connection was closed", "broken pipe",
         "connection is closed", "ssl syscall error", "terminating connection")  # fmt: skip
_TIMEOUT = ("timeout expired", "timed out", "connect timeout")
_AUTH = ("password authentication failed", "no pg_hba.conf entry", "authentication failed")
_AWS_AUTH = {"AccessDenied", "AccessDeniedException", "InvalidClientTokenId", "UnrecognizedClientException",
             "ExpiredToken", "ExpiredTokenException", "SignatureDoesNotMatch", "KMS.AccessDeniedException",
             "KmsAccessDenied", "KMSAccessDeniedException"}  # fmt: skip


def _chain(exc: BaseException):
    """The exception, what it wraps (SQLAlchemy .orig) and its causes."""
    seen: set[int] = set()
    todo = [exc]
    while todo:
        e = todo.pop(0)
        if e is None or id(e) in seen:
            continue
        seen.add(id(e))
        yield e
        todo += [getattr(e, "orig", None), e.__cause__, e.__context__]


def _module(e: BaseException) -> str:
    return type(e).__module__.split(".")[0]


def guess_dependency(exc: BaseException) -> str | None:
    for e in _chain(exc):
        mod = _module(e)
        if mod in ("sqlalchemy", "psycopg", "psycopg2"):
            return "postgres"
        if mod in ("botocore", "boto3"):
            return "sqs"
        if mod in ("httpx", "httpcore"):
            return "slack"
    return None


def classify(exc: BaseException) -> str:
    """Map an exception to one of KINDS."""
    for e in _chain(exc):
        name = type(e).__name__
        mod = _module(e)
        text = str(e).lower()
        # --- typed checks first
        if mod == "sqlalchemy" and name == "TimeoutError":  # QueuePool limit ... timed out
            return "pool_timeout"
        if name == "QueryCanceled" or "canceling statement due to statement timeout" in text:
            return "query_timeout"
        if "too many clients" in text or "remaining connection slots are reserved" in text:
            return "too_many_connections"
        if isinstance(e, socket.gaierror):
            return "dns"
        if isinstance(e, ConnectionRefusedError):
            return "refused"
        if isinstance(e, (ConnectionResetError, BrokenPipeError)):
            return "connection_lost"
        if mod == "botocore":
            if name == "ClientError":
                code = getattr(e, "response", {}).get("Error", {}).get("Code", "")
                status = getattr(e, "response", {}).get("ResponseMetadata", {}).get("HTTPStatusCode", 0)
                if code in _AWS_AUTH or status == 403:
                    return "auth"
                return "server_error" if status >= 500 else "client_error"
            if name in ("NoCredentialsError", "PartialCredentialsError", "CredentialRetrievalError"):
                return "auth"
            if name in ("ConnectTimeoutError",):
                return "connect_timeout"
            if name in ("ReadTimeoutError",):
                return "read_timeout"
            if name in ("EndpointConnectionError", "ConnectionClosedError"):
                if any(s in text for s in _DNS):
                    return "dns"
                return "connection_lost" if name == "ConnectionClosedError" else "refused"
        if mod in ("httpx", "httpcore"):
            if name == "HTTPStatusError":
                status = getattr(getattr(e, "response", None), "status_code", 0)
                if status in (401, 403):
                    return "auth"
                return "server_error" if status >= 500 else "client_error"
            if name in ("ConnectTimeout", "PoolTimeout"):
                return "connect_timeout"
            if name in ("ReadTimeout", "WriteTimeout"):
                return "read_timeout"
            if name == "RemoteProtocolError":
                return "connection_lost"
        # --- message checks (psycopg OperationalError carries the libpq text)
        if any(s in text for s in _DNS):
            return "dns"
        if any(s in text for s in _REFUSED):
            return "refused"
        if any(s in text for s in _AUTH):
            return "auth"
        if any(s in text for s in _LOST):
            return "connection_lost"
        if any(s in text for s in _TIMEOUT) and ("connect" in text or "timeout expired" in text):
            return "connect_timeout"
        if isinstance(e, TimeoutError):
            return "connect_timeout"
    return "other"


def record_failure(exc: BaseException, dependency: str | None = None) -> tuple[str, str] | None:
    """Count a dependency failure once (an exception that bubbles through two handlers is counted once).

    Returns (dependency, kind), or None when the exception is not a dependency failure."""
    if getattr(exc, "_opsdesk_dep", None):
        return exc._opsdesk_dep  # type: ignore[attr-defined]
    dependency = dependency or guess_dependency(exc)
    if dependency is None:
        return None
    kind = classify(exc)
    DEPENDENCY_ERRORS.labels(dependency, kind).inc()
    try:
        exc._opsdesk_dep = (dependency, kind)  # type: ignore[attr-defined]
    except AttributeError:  # exceptions with __slots__
        pass
    return dependency, kind
