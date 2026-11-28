from datetime import datetime
from decimal import Decimal
from uuid import UUID

from sqlalchemy import Boolean, CheckConstraint, DateTime, ForeignKey, Index, Numeric, String, UniqueConstraint, func, true
from sqlalchemy.orm import Mapped, mapped_column

from app.categories.defaults import ICONS_V1
from app.db.base import Base


class Wallet(Base):
    __tablename__ = "wallets"
    __table_args__ = (
        UniqueConstraint("user_id", "id", name="uq_wallets_owner_id"),
        UniqueConstraint("user_id", "normalized_name", name="uq_wallets_owner_name"),
        CheckConstraint("type IN ('CASH', 'BANK', 'DIGITAL')", name="ck_wallets_type"),
        CheckConstraint("currency = 'LKR'", name="ck_wallets_currency"),
        CheckConstraint("opening_balance BETWEEN 0 AND 9999999999999999.99", name="ck_wallets_opening_balance"),
        CheckConstraint("current_balance BETWEEN 0 AND 9999999999999999.99", name="ck_wallets_current_balance"),
        CheckConstraint("is_active OR current_balance = 0", name="ck_wallets_archived_balance"),
        CheckConstraint("color ~ '^#[0-9A-F]{6}$'", name="ck_wallets_color"),
        CheckConstraint(f"icon IN ({', '.join(repr(icon) for icon in sorted(ICONS_V1))})", name="ck_wallets_icon"),
        Index("ix_wallets_owner_active_type", "user_id", "is_active", "type"),
    )

    id: Mapped[UUID] = mapped_column(primary_key=True)
    user_id: Mapped[UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    name: Mapped[str] = mapped_column(String(80))
    normalized_name: Mapped[str] = mapped_column(String(320))
    type: Mapped[str] = mapped_column(String(7))
    currency: Mapped[str] = mapped_column(String(3))
    opening_balance: Mapped[Decimal] = mapped_column(Numeric(18, 2))
    current_balance: Mapped[Decimal] = mapped_column(Numeric(18, 2))
    icon: Mapped[str] = mapped_column(String(24))
    color: Mapped[str] = mapped_column(String(7))
    is_active: Mapped[bool] = mapped_column(Boolean, server_default=true())
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())
