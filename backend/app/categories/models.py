from datetime import datetime
from uuid import UUID

from sqlalchemy import Boolean, CheckConstraint, DateTime, ForeignKey, Index, String, UniqueConstraint, func, true
from sqlalchemy.orm import Mapped, mapped_column

from app.categories.defaults import ICONS_V1
from app.db.base import Base


class Category(Base):
    __tablename__ = "categories"
    __table_args__ = (
        UniqueConstraint("user_id", "id", name="uq_categories_owner_id"),
        UniqueConstraint("user_id", "type", "normalized_name", name="uq_categories_owner_type_name"),
        UniqueConstraint("user_id", "default_code", name="uq_categories_owner_default"),
        CheckConstraint("type IN ('INCOME', 'EXPENSE')", name="ck_categories_type"),
        CheckConstraint("color ~ '^#[0-9A-F]{6}$'", name="ck_categories_color"),
        CheckConstraint(f"icon IN ({', '.join(repr(icon) for icon in sorted(ICONS_V1))})", name="ck_categories_icon"),
        CheckConstraint("default_code IS NULL OR is_active", name="ck_categories_default_active"),
        Index("ix_categories_owner_active_type", "user_id", "is_active", "type"),
    )

    id: Mapped[UUID] = mapped_column(primary_key=True)
    user_id: Mapped[UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    name: Mapped[str] = mapped_column(String(80))
    normalized_name: Mapped[str] = mapped_column(String(320))
    type: Mapped[str] = mapped_column(String(7))
    icon: Mapped[str] = mapped_column(String(24))
    color: Mapped[str] = mapped_column(String(7))
    default_code: Mapped[str | None] = mapped_column(String(32))
    is_active: Mapped[bool] = mapped_column(Boolean, server_default=true())
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now(),
    )

    @property
    def is_default(self) -> bool:
        return self.default_code is not None
