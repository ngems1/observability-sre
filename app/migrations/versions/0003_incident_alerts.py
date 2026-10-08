"""incident alerts: tickets.source + incident_alerts (Alertmanager webhook -> follow-up tickets)

Revision ID: 0003
Revises: 0002
Create Date: 2026-10-08
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB

revision = "0003"
down_revision = "0002"
branch_labels = None
depends_on = None

TS = sa.DateTime(timezone=True)


def upgrade() -> None:
    # Expand-only: new column with a default + a new table; the previous image keeps working.
    op.add_column("tickets", sa.Column("source", sa.String(10), nullable=False, server_default="manual"))
    op.create_check_constraint("ck_tickets_source", "tickets", "source IN ('manual', 'alert')")

    op.create_table(
        "incident_alerts",
        sa.Column("id", sa.BigInteger, primary_key=True),
        sa.Column("fingerprint", sa.String(64), nullable=False),
        sa.Column("ticket_id", sa.BigInteger, sa.ForeignKey("tickets.id"), nullable=False),
        sa.Column("alertname", sa.String(200), nullable=False),
        sa.Column("severity", sa.String(20), nullable=False),
        sa.Column("started_at", TS, nullable=False),
        sa.Column("resolved_at", TS),
        sa.Column("labels", JSONB, nullable=False, server_default="{}"),
        sa.Column("annotations", JSONB, nullable=False, server_default="{}"),
        sa.Column("generator_url", sa.Text),
        sa.Column("created_at", TS, server_default=sa.func.now(), nullable=False),
    )
    op.create_index("ix_incident_alerts_fingerprint", "incident_alerts", ["fingerprint"])
    op.create_index("ix_incident_alerts_ticket_id", "incident_alerts", ["ticket_id"])
    # At most one OPEN (unresolved) incident per alert fingerprint: concurrent webhook
    # deliveries from an HA Alertmanager pair cannot create duplicate tickets.
    op.create_index(
        "uq_incident_alerts_open_fingerprint",
        "incident_alerts",
        ["fingerprint"],
        unique=True,
        postgresql_where=sa.text("resolved_at IS NULL"),
    )


def downgrade() -> None:
    op.drop_table("incident_alerts")
    op.drop_constraint("ck_tickets_source", "tickets", type_="check")
    op.drop_column("tickets", "source")
