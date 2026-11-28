"""Add expense records and persisted creation operation results."""

import sqlalchemy as sa
from alembic import op
from alembic.util import CommandError
from sqlalchemy.dialects.postgresql import JSONB

revision = "0007"
down_revision = "0006"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "expenses",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("wallet_id", sa.Uuid(), nullable=False),
        sa.Column("category_id", sa.Uuid(), nullable=False),
        sa.Column("title", sa.String(120), nullable=False),
        sa.Column("amount", sa.Numeric(18, 2), nullable=False),
        sa.Column("currency", sa.String(3), nullable=False),
        sa.Column("expense_date", sa.Date(), nullable=False),
        sa.Column("note", sa.String(1000)),
        sa.Column("version", sa.Integer(), server_default="1", nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("deleted_at", sa.DateTime(timezone=True)),
        sa.ForeignKeyConstraint(["user_id", "wallet_id"], ["wallets.user_id", "wallets.id"],
                                name="fk_expenses_wallet_owner", deferrable=True, initially="DEFERRED"),
        sa.ForeignKeyConstraint(["user_id", "category_id"], ["categories.user_id", "categories.id"],
                                name="fk_expenses_category_owner", deferrable=True, initially="DEFERRED"),
        sa.CheckConstraint("amount > 0 AND amount <= 9999999999999999.99", name="ck_expenses_amount"),
        sa.CheckConstraint("currency = 'LKR'", name="ck_expenses_currency"),
        sa.CheckConstraint("version > 0", name="ck_expenses_version"),
    )
    op.create_index("ix_expenses_history", "expenses", ["user_id", "deleted_at", "expense_date", "created_at", "id"])
    op.create_index("ix_expenses_wallet", "expenses", ["user_id", "wallet_id", "deleted_at", "expense_date"])
    op.create_index("ix_expenses_category", "expenses", ["user_id", "category_id", "deleted_at", "expense_date"])
    op.create_table(
        "expense_creations",
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("key", sa.Uuid(), primary_key=True),
        sa.Column("fingerprint", sa.String(64), nullable=False),
        sa.Column("response", JSONB(), nullable=False),
    )


def downgrade():
    connection = op.get_bind()
    connection.execute(sa.text("LOCK TABLE expense_creations, expenses IN ACCESS EXCLUSIVE MODE"))
    if connection.scalar(sa.text("SELECT EXISTS (SELECT 1 FROM expenses) OR EXISTS (SELECT 1 FROM expense_creations)")):
        raise CommandError("Expense history exists. Financial reconciliation is required before downgrade.")
    op.drop_table("expense_creations")
    op.drop_table("expenses")
