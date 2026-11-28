"""Add immutable internal transfers and operation-scoped replay results."""

import sqlalchemy as sa
from alembic import op
from alembic.util import CommandError
from sqlalchemy.dialects.postgresql import JSONB

revision = "0008"
down_revision = "0007"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "wallet_transfers",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("source_wallet_id", sa.Uuid(), nullable=False),
        sa.Column("destination_wallet_id", sa.Uuid(), nullable=False),
        sa.Column("amount", sa.Numeric(18, 2), nullable=False),
        sa.Column("currency", sa.String(3), nullable=False),
        sa.Column("transfer_date", sa.Date(), nullable=False),
        sa.Column("note", sa.String(1000)),
        sa.Column("reversal_of_id", sa.Uuid()),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("user_id", "id", name="uq_transfers_owner_id"),
        sa.UniqueConstraint("user_id", "reversal_of_id", name="uq_transfers_reversal"),
        sa.ForeignKeyConstraint(["user_id", "source_wallet_id"], ["wallets.user_id", "wallets.id"],
                                name="fk_transfers_source_owner", deferrable=True, initially="DEFERRED"),
        sa.ForeignKeyConstraint(["user_id", "destination_wallet_id"], ["wallets.user_id", "wallets.id"],
                                name="fk_transfers_destination_owner", deferrable=True, initially="DEFERRED"),
        sa.ForeignKeyConstraint(["user_id", "reversal_of_id"], ["wallet_transfers.user_id", "wallet_transfers.id"],
                                name="fk_transfers_reversal_owner", deferrable=True, initially="DEFERRED"),
        sa.CheckConstraint("source_wallet_id <> destination_wallet_id", name="ck_transfers_distinct_wallets"),
        sa.CheckConstraint("reversal_of_id <> id", name="ck_transfers_not_self_reversal"),
        sa.CheckConstraint("amount > 0 AND amount <= 9999999999999999.99", name="ck_transfers_amount"),
        sa.CheckConstraint("currency = 'LKR'", name="ck_transfers_currency"),
    )
    op.create_index("ix_transfers_history", "wallet_transfers", ["user_id", "transfer_date", "created_at", "id"])
    op.create_index("ix_transfers_source", "wallet_transfers", ["user_id", "source_wallet_id", "transfer_date"])
    op.create_index("ix_transfers_destination", "wallet_transfers", ["user_id", "destination_wallet_id", "transfer_date"])
    op.create_table(
        "transfer_replays",
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("operation", sa.String(7), primary_key=True),
        sa.Column("key", sa.Uuid(), primary_key=True),
        sa.Column("fingerprint", sa.String(64), nullable=False),
        sa.Column("response", JSONB(), nullable=False),
        sa.CheckConstraint("operation IN ('create', 'reverse')", name="ck_transfer_replays_operation"),
    )


def downgrade():
    connection = op.get_bind()
    connection.execute(sa.text("LOCK TABLE transfer_replays, wallet_transfers IN ACCESS EXCLUSIVE MODE"))
    if connection.scalar(sa.text(
        "SELECT EXISTS (SELECT 1 FROM wallet_transfers) OR EXISTS (SELECT 1 FROM transfer_replays)"
    )):
        raise CommandError("Transfer history exists. Financial reconciliation is required before downgrade.")
    op.drop_table("transfer_replays")
    op.drop_table("wallet_transfers")
