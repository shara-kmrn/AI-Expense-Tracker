"""Add per-account categories and backfill the version 1 defaults."""

import sqlalchemy as sa
from alembic import op

from app.categories.defaults import ICONS_V1, seed_rows_v1

revision = "0004"
down_revision = "0003"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "categories",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("name", sa.String(80), nullable=False),
        sa.Column("normalized_name", sa.String(320), nullable=False),
        sa.Column("type", sa.String(7), nullable=False),
        sa.Column("icon", sa.String(24), nullable=False),
        sa.Column("color", sa.String(7), nullable=False),
        sa.Column("default_code", sa.String(32)),
        sa.Column("is_active", sa.Boolean(), server_default=sa.true(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("user_id", "type", "normalized_name", name="uq_categories_owner_type_name"),
        sa.UniqueConstraint("user_id", "default_code", name="uq_categories_owner_default"),
        sa.CheckConstraint("type IN ('INCOME', 'EXPENSE')", name="ck_categories_type"),
        sa.CheckConstraint("color ~ '^#[0-9A-F]{6}$'", name="ck_categories_color"),
        sa.CheckConstraint(f"icon IN ({', '.join(repr(icon) for icon in sorted(ICONS_V1))})", name="ck_categories_icon"),
        sa.CheckConstraint("default_code IS NULL OR is_active", name="ck_categories_default_active"),
    )
    op.create_index("ix_categories_owner_active_type", "categories", ["user_id", "is_active", "type"])
    op.get_bind().execute(sa.text("""
        INSERT INTO categories (id, user_id, default_code, type, name, normalized_name, icon, color)
        SELECT gen_random_uuid(), id, :default_code, :type, :name, :normalized_name, :icon, :color
        FROM users
        ON CONFLICT DO NOTHING
    """), list(seed_rows_v1()))


def downgrade():
    op.drop_table("categories")
