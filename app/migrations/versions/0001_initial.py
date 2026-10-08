"""initial schema: users, tickets, access_requests, comments, audit_log, notifications

Revision ID: 0001
Revises:
Create Date: 2026-10-08
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None

TS = sa.DateTime(timezone=True)


def upgrade() -> None:
    op.create_table(
        "users",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("name", sa.String(100), nullable=False, unique=True),
        sa.Column("role", sa.String(20), nullable=False),
        sa.Column("api_key_hash", sa.String(64), nullable=False, unique=True),
        sa.Column("created_at", TS, server_default=sa.func.now(), nullable=False),
        sa.CheckConstraint("role IN ('requester', 'approver', 'admin')", name="ck_users_role"),
    )
    op.create_table(
        "tickets",
        sa.Column("id", sa.BigInteger, primary_key=True),
        sa.Column("type", sa.String(30), nullable=False),
        sa.Column("title", sa.String(200), nullable=False),
        sa.Column("description", sa.Text, nullable=False, server_default=""),
        sa.Column("priority", sa.String(10), nullable=False, server_default="medium"),
        sa.Column("status", sa.String(20), nullable=False, server_default="open"),
        sa.Column("requester_id", sa.Integer, sa.ForeignKey("users.id"), nullable=False),
        sa.Column("assignee_id", sa.Integer, sa.ForeignKey("users.id")),
        sa.Column("created_at", TS, server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", TS, server_default=sa.func.now(), nullable=False),
        sa.Column("triaged_at", TS),
        sa.Column("resolved_at", TS),
        sa.CheckConstraint("type IN ('access_request', 'change_request', 'incident_followup')", name="ck_tickets_type"),
        sa.CheckConstraint("priority IN ('low', 'medium', 'high', 'critical')", name="ck_tickets_priority"),
        sa.CheckConstraint(
            "status IN ('open', 'triaged', 'in_progress', 'resolved', 'closed')", name="ck_tickets_status"
        ),
    )
    op.create_index("ix_tickets_requester_id", "tickets", ["requester_id"])
    # NOTE: no index on tickets(status, assignee_id) on purpose -> failure drill 2.

    op.create_table(
        "access_requests",
        sa.Column("ticket_id", sa.BigInteger, sa.ForeignKey("tickets.id"), primary_key=True),
        sa.Column("resource", sa.String(200), nullable=False),
        sa.Column("requested_role", sa.String(100), nullable=False),
        sa.Column("justification", sa.Text, nullable=False),
        sa.Column("duration_days", sa.Integer, nullable=False, server_default="7"),
        sa.Column("decision", sa.String(10), nullable=False, server_default="pending"),
        sa.Column("approver_id", sa.Integer, sa.ForeignKey("users.id")),
        sa.Column("decided_at", TS),
        sa.Column("expires_at", TS),
        sa.CheckConstraint("decision IN ('pending', 'approved', 'rejected')", name="ck_access_decision"),
    )
    op.create_table(
        "comments",
        sa.Column("id", sa.BigInteger, primary_key=True),
        sa.Column("ticket_id", sa.BigInteger, sa.ForeignKey("tickets.id"), nullable=False),
        sa.Column("author_id", sa.Integer, sa.ForeignKey("users.id"), nullable=False),
        sa.Column("body", sa.Text, nullable=False),
        sa.Column("created_at", TS, server_default=sa.func.now(), nullable=False),
    )
    op.create_index("ix_comments_ticket_id", "comments", ["ticket_id"])

    op.create_table(
        "audit_log",
        sa.Column("id", sa.BigInteger, primary_key=True),
        sa.Column("ticket_id", sa.BigInteger, sa.ForeignKey("tickets.id"), nullable=False),
        sa.Column("action", sa.String(50), nullable=False),
        sa.Column("actor_id", sa.Integer, sa.ForeignKey("users.id"), nullable=False),
        sa.Column("old_value", JSONB),
        sa.Column("new_value", JSONB),
        sa.Column("trace_id", sa.String(32)),
        sa.Column("created_at", TS, server_default=sa.func.now(), nullable=False),
    )
    op.create_index("ix_audit_log_ticket_id", "audit_log", ["ticket_id"])
    # Append-only, enforced by the database itself (works whatever role the app uses)
    op.execute(
        """
        CREATE FUNCTION audit_log_append_only() RETURNS trigger AS $$
        BEGIN
            RAISE EXCEPTION 'audit_log is append-only (% blocked)', TG_OP;
        END;
        $$ LANGUAGE plpgsql;
        """
    )
    op.execute(
        """
        CREATE TRIGGER audit_log_no_update_delete
        BEFORE UPDATE OR DELETE ON audit_log
        FOR EACH ROW EXECUTE FUNCTION audit_log_append_only();
        """
    )

    op.create_table(
        "notifications",
        sa.Column("id", sa.BigInteger, primary_key=True),
        sa.Column("ticket_id", sa.BigInteger, sa.ForeignKey("tickets.id"), nullable=False),
        sa.Column("event", sa.String(50), nullable=False),
        sa.Column("channel", sa.String(20), nullable=False, server_default="slack"),
        sa.Column("status", sa.String(20), nullable=False, server_default="queued"),
        sa.Column("attempts", sa.Integer, nullable=False, server_default="0"),
        sa.Column("last_error", sa.Text),
        sa.Column("enqueued_at", TS, server_default=sa.func.now(), nullable=False),
        sa.Column("sent_at", TS),
        sa.CheckConstraint(
            "status IN ('queued', 'publish_failed', 'retrying', 'sent', 'failed')", name="ck_notifications_status"
        ),
    )
    op.create_index("ix_notifications_ticket_id", "notifications", ["ticket_id"])


def downgrade() -> None:
    op.drop_table("notifications")
    op.execute("DROP TRIGGER IF EXISTS audit_log_no_update_delete ON audit_log")
    op.execute("DROP FUNCTION IF EXISTS audit_log_append_only()")
    op.drop_table("audit_log")
    op.drop_table("comments")
    op.drop_table("access_requests")
    op.drop_table("tickets")
    op.drop_table("users")
