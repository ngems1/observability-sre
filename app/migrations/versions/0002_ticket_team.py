"""tickets.team: route tickets to an engineering team (UI filter + dashboard dimension)

Revision ID: 0002
Revises: 0001
Create Date: 2026-10-08
"""

import sqlalchemy as sa
from alembic import op

revision = "0002"
down_revision = "0001"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # Expand-only change: a new column with a default, safe while the old image still runs.
    op.add_column("tickets", sa.Column("team", sa.String(20), nullable=False, server_default="platform"))
    op.create_check_constraint(
        "ck_tickets_team",
        "tickets",
        "team IN ('platform', 'network_ops', 'security', 'database', 'core_network')",
    )


def downgrade() -> None:
    op.drop_constraint("ck_tickets_team", "tickets", type_="check")
    op.drop_column("tickets", "team")
