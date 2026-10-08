"""Run DB migrations (and optional user bootstrap) safely from several pods at once.

Used as the ticket-api initContainer:  python -m opsdesk.migrate
A Postgres advisory lock makes concurrent replicas run Alembic one at a time.
"""

import logging
import os
import pathlib

from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, pool, text

from opsdesk.config import get_settings
from opsdesk.logging_setup import configure_logging

LOCK_ID = 727_001  # arbitrary, constant
APP_DIR = pathlib.Path(__file__).resolve().parents[1]
log = logging.getLogger("opsdesk.migrate")


def main() -> None:
    settings = get_settings()
    configure_logging("opsdesk-migrate", settings.environment, settings.log_level)
    engine = create_engine(settings.database_url, poolclass=pool.NullPool)
    with engine.connect() as conn:
        log.info("waiting for migration lock")
        conn.execute(text("SELECT pg_advisory_lock(:id)"), {"id": LOCK_ID})
        try:
            cfg = Config(str(APP_DIR / "alembic.ini"))
            cfg.set_main_option("script_location", str(APP_DIR / "migrations"))
            command.upgrade(cfg, "head")
            log.info("migrations at head")
            spec = os.environ.get("OPSDESK_BOOTSTRAP_USERS", "")
            if spec:
                from opsdesk.db import init_engine
                from opsdesk.seed import seed_users

                init_engine(settings)
                created = seed_users(spec)
                log.info("bootstrap users ensured", extra={"users_created": created})
        finally:
            conn.execute(text("SELECT pg_advisory_unlock(:id)"), {"id": LOCK_ID})
            conn.commit()


if __name__ == "__main__":
    main()
