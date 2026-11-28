from datetime import date, datetime
from decimal import Decimal
from uuid import UUID

from sqlalchemy import CheckConstraint, Date, DateTime, ForeignKey, ForeignKeyConstraint, Index, Integer, Numeric, String, func
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base


class Income(Base):
    __tablename__ = "incomes"
    __table_args__ = (
        ForeignKeyConstraint(
            ["user_id", "wallet_id"], ["wallets.user_id", "wallets.id"],
            name="fk_incomes_wallet_owner", deferrable=True, initially="DEFERRED",
        ),
        ForeignKeyConstraint(
            ["user_id", "category_id"], ["categories.user_id", "categories.id"],
            name="fk_incomes_category_owner", deferrable=True, initially="DEFERRED",
        ),
        CheckConstraint("amount > 0 AND amount <= 9999999999999999.99", name="ck_incomes_amount"),
        CheckConstraint("currency = 'LKR'", name="ck_incomes_currency"),
        CheckConstraint("version > 0", name="ck_incomes_version"),
        Index("ix_incomes_history", "user_id", "deleted_at", "income_date", "created_at", "id"),
        Index("ix_incomes_wallet", "user_id", "wallet_id", "deleted_at", "income_date"),
        Index("ix_incomes_category", "user_id", "category_id", "deleted_at", "income_date"),
    )

    id: Mapped[UUID] = mapped_column(primary_key=True)
    user_id: Mapped[UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    wallet_id: Mapped[UUID]
    category_id: Mapped[UUID]
    title: Mapped[str] = mapped_column(String(120))
    amount: Mapped[Decimal] = mapped_column(Numeric(18, 2))
    currency: Mapped[str] = mapped_column(String(3))
    income_date: Mapped[date] = mapped_column(Date)
    note: Mapped[str | None] = mapped_column(String(1000))
    version: Mapped[int] = mapped_column(Integer, server_default="1")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class IncomeCreation(Base):
    __tablename__ = "income_creations"

    user_id: Mapped[UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    key: Mapped[UUID] = mapped_column(primary_key=True)
    fingerprint: Mapped[str] = mapped_column(String(64))
    response: Mapped[dict] = mapped_column(JSONB)
