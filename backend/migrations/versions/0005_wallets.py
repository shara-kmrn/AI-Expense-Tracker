"""Add owner-scoped wallets and exact balances."""

import sqlalchemy as sa
from alembic import op

from app.categories.defaults import ICONS_V1

revision = "0005"
down_revision = "0004"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "wallets",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("name", sa.String(80), nullable=False),
        sa.Column("normalized_name", sa.String(320), nullable=False),
        sa.Column("type", sa.String(7), nullable=False),
        sa.Column("currency", sa.String(3), nullable=False),
        sa.Column("opening_balance", sa.Numeric(18, 2), nullable=False),
        sa.Column("current_balance", sa.Numeric(18, 2), nullable=False),
        sa.Column("icon", sa.String(24), nullable=False),
        sa.Column("color", sa.String(7), nullable=False),
        sa.Column("is_active", sa.Boolean(), server_default=sa.true(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("user_id", "normalized_name", name="uq_wallets_owner_name"),
        sa.CheckConstraint("type IN ('CASH', 'BANK', 'DIGITAL')", name="ck_wallets_type"),
        sa.CheckConstraint("currency = 'LKR'", name="ck_wallets_currency"),
        sa.CheckConstraint("opening_balance BETWEEN 0 AND 9999999999999999.99", name="ck_wallets_opening_balance"),
        sa.CheckConstraint("current_balance BETWEEN 0 AND 9999999999999999.99", name="ck_wallets_current_balance"),
        sa.CheckConstraint("is_active OR current_balance = 0", name="ck_wallets_archived_balance"),
        sa.CheckConstraint("color ~ '^#[0-9A-F]{6}$'", name="ck_wallets_color"),
        sa.CheckConstraint(f"icon IN ({', '.join(repr(icon) for icon in sorted(ICONS_V1))})", name="ck_wallets_icon"),
    )
    op.create_index("ix_wallets_owner_active_type", "wallets", ["user_id", "is_active", "type"])


def downgrade():
    op.drop_table("wallets")
