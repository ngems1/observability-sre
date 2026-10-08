import time
from collections.abc import Iterator

from sqlalchemy import create_engine, event
from sqlalchemy.engine import Engine
from sqlalchemy.orm import Session, sessionmaker

from opsdesk.config import Settings
from opsdesk.metrics import DB_POOL, DB_QUERY_DURATION

_engine: Engine | None = None
_SessionLocal: sessionmaker | None = None


def init_engine(settings: Settings) -> Engine:
    global _engine, _SessionLocal
    _engine = create_engine(
        settings.database_url,
        pool_size=settings.db_pool_size,
        max_overflow=settings.db_max_overflow,
        pool_timeout=settings.db_pool_timeout_s,
        pool_pre_ping=True,
        connect_args={"connect_timeout": 3},
    )
    _SessionLocal = sessionmaker(bind=_engine, expire_on_commit=False)
    _time_queries(_engine)
    return _engine


_OPERATIONS = ("select", "insert", "update", "delete")


def _time_queries(engine: Engine) -> None:
    """Database time per statement: if requests are slow but this stays fast, the problem is not the DB."""

    @event.listens_for(engine, "before_cursor_execute")
    def _start(conn, cursor, statement, parameters, context, executemany):
        conn.info.setdefault("_opsdesk_t0", []).append(time.perf_counter())

    @event.listens_for(engine, "after_cursor_execute")
    def _stop(conn, cursor, statement, parameters, context, executemany):
        starts = conn.info.get("_opsdesk_t0")
        if not starts:
            return
        elapsed = time.perf_counter() - starts.pop()
        verb = statement.lstrip().split(None, 1)[0].lower() if statement.strip() else "other"
        DB_QUERY_DURATION.labels(verb if verb in _OPERATIONS else "other").observe(elapsed)

    @event.listens_for(engine, "handle_error")
    def _failed(ctx):
        starts = ctx.connection.info.get("_opsdesk_t0") if ctx.connection is not None else None
        if starts:
            starts.pop()


def get_engine() -> Engine:
    assert _engine is not None, "init_engine() not called"
    return _engine


def get_session() -> Iterator[Session]:
    assert _SessionLocal is not None, "init_engine() not called"
    session = _SessionLocal()
    try:
        yield session
    finally:
        session.close()


def session_factory() -> sessionmaker:
    assert _SessionLocal is not None, "init_engine() not called"
    return _SessionLocal


def update_pool_metrics() -> None:
    if _engine is None:
        return
    pool = _engine.pool
    try:
        DB_POOL.labels("in_use").set(pool.checkedout())
        DB_POOL.labels("idle").set(pool.checkedin())
        DB_POOL.labels("overflow").set(max(pool.overflow(), 0))
        DB_POOL.labels("size").set(pool.size())
    except AttributeError:  # e.g. NullPool in tests
        pass
