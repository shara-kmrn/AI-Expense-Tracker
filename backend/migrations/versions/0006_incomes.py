"""Add income records and persisted creation operation results."""

import sqlalchemy as sa
from alembic import op
from alembic.util import CommandError
from sqlalchemy.dialects.postgresql import JSONB

revision = "0006"
down_revision = "0005"
branch_labels = None
depends_on = None


def upgrade():
    op.create_unique_constraint("uq_wallets_owner_id", "wallets", ["user_id", "id"])
    op.create_unique_constraint("uq_categories_owner_id", "categories", ["user_id", "id"])
    op.create_table(
        "incomes",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("wallet_id", sa.Uuid(), nullable=False),
        sa.Column("category_id", sa.Uuid(), nullable=False),
        sa.Column("title", sa.String(120), nullable=False),
        sa.Column("amount", sa.Numeric(18, 2), nullable=False),
        sa.Column("currency", sa.String(3), nullable=False),
        sa.Column("income_date", sa.Date(), nullable=False),
        sa.Column("note", sa.String(1000)),
        sa.Column("version", sa.Integer(), server_default="1", nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("deleted_at", sa.DateTime(timezone=True)),
        sa.ForeignKeyConstraint(["user_id", "wallet_id"], ["wallets.user_id", "wallets.id"],
                                name="fk_incomes_wallet_owner", deferrable=True, initially="DEFERRED"),
        sa.ForeignKeyConstraint(["user_id", "category_id"], ["categories.user_id", "categories.id"],
                                name="fk_incomes_category_owner", deferrable=True, initially="DEFERRED"),
        sa.CheckConstraint("amount > 0 AND amount <= 9999999999999999.99", name="ck_incomes_amount"),
        sa.CheckConstraint("currency = 'LKR'", name="ck_incomes_currency"),
        sa.CheckConstraint("version > 0", name="ck_incomes_version"),
    )
    op.create_index("ix_incomes_history", "incomes", ["user_id", "deleted_at", "income_date", "created_at", "id"])
    op.create_index("ix_incomes_wallet", "incomes", ["user_id", "wallet_id", "deleted_at", "income_date"])
    op.create_index("ix_incomes_category", "incomes", ["user_id", "category_id", "deleted_at", "income_date"])
    op.create_table(
        "income_creations",
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("key", sa.Uuid(), primary_key=True),
        sa.Column("fingerprint", sa.String(64), nullable=False),
        sa.Column("response", JSONB(), nullable=False),
    )


def downgrade():
    connection = op.get_bind()
    connection.execute(sa.text("LOCK TABLE income_creations, incomes IN ACCESS EXCLUSIVE MODE"))
    if connection.scalar(sa.text("SELECT EXISTS (SELECT 1 FROM incomes) OR EXISTS (SELECT 1 FROM income_creations)")):
        raise CommandError("Income history exists. Financial reconciliation is required before downgrade.")
    op.drop_table("income_creations")
    op.drop_table("incomes")
    op.drop_constraint("uq_categories_owner_id", "categories", type_="unique")
    op.drop_constraint("uq_wallets_owner_id", "wallets", type_="unique")
