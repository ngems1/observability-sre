"""Seed helpers.

  python -m opsdesk.seed users            # upsert users from OPSDESK_BOOTSTRAP_USERS
  python -m opsdesk.seed tickets 200000   # bulk tickets for failure drill 2

OPSDESK_BOOTSTRAP_USERS format: "name:role:api_key,name:role:api_key"
"""

import os
import sys

from sqlalchemy import select, text

from opsdesk.auth import hash_key
from opsdesk.config import get_settings
from opsdesk.db import init_engine, session_factory
from opsdesk.models import ROLES, User


def seed_users(spec: str) -> list[str]:
    created = []
    with session_factory()() as session:
        for entry in filter(None, (e.strip() for e in spec.split(","))):
            name, role, key = entry.split(":", 2)
            if role not in ROLES:
                raise SystemExit(f"invalid role {role!r} for {name}")
            user = session.scalar(select(User).where(User.name == name))
            if user is None:
                session.add(User(name=name, role=role, api_key_hash=hash_key(key)))
                created.append(name)
            else:
                user.role, user.api_key_hash = role, hash_key(key)
        session.commit()
    return created


def seed_tickets(count: int) -> None:
    """Fast server-side insert; ~70% of rows end up in non-open statuses."""
    with session_factory()() as session:
        approvers = session.scalars(select(User.id).where(User.role == "approver")).all()
        requester = session.scalar(select(User.id).order_by(User.id))
        if not approvers or requester is None:
            raise SystemExit("seed users first (need at least one approver)")
        session.execute(
            text(
                """
                INSERT INTO tickets (type, title, description, priority, status, team, requester_id, assignee_id,
                                     created_at, updated_at)
                SELECT (ARRAY['access_request','change_request','incident_followup'])[1 + g % 3],
                       'seeded ticket ' || g, 'bulk seed for drill 2',
                       (ARRAY['low','medium','high','critical'])[1 + g % 4],
                       (ARRAY['open','triaged','in_progress','resolved','closed','closed','closed',
                              'resolved','closed','closed'])[1 + g % 10],
                       (ARRAY['platform','network_ops','security','database','core_network'])[1 + g % 5],
                       :requester,
                       (:approvers)[1 + g % array_length(:approvers, 1)],
                       now() - (g || ' minutes')::interval, now()
                FROM generate_series(1, :count) AS g
                """
            ),
            {"requester": requester, "approvers": list(approvers), "count": count},
        )
        session.execute(text("ANALYZE tickets"))
        session.commit()


def main(argv: list[str]) -> None:
    init_engine(get_settings())
    if not argv or argv[0] not in {"users", "tickets"}:
        raise SystemExit(__doc__)
    if argv[0] == "users":
        spec = os.environ.get("OPSDESK_BOOTSTRAP_USERS", "")
        if not spec:
            raise SystemExit("OPSDESK_BOOTSTRAP_USERS is empty")
        print(f"users created: {seed_users(spec) or 'none (all existed, keys refreshed)'}")
    else:
        count = int(argv[1]) if len(argv) > 1 else 200_000
        seed_tickets(count)
        print(f"seeded {count} tickets")


if __name__ == "__main__":
    main(sys.argv[1:])
