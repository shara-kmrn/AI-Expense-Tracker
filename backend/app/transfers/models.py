from datetime import date, datetime
from decimal import Decimal
from uuid import UUID

from sqlalchemy import CheckConstraint, Date, DateTime, ForeignKey, ForeignKeyConstraint, Index, Numeric, String, UniqueConstraint, func
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base


class WalletTransfer(Base):
    __tablename__ = "wallet_transfers"
    __table_args__ = (
        UniqueConstraint("user_id", "id", name="uq_transfers_owner_id"),
        UniqueConstraint("user_id", "reversal_of_id", name="uq_transfers_reversal"),
        ForeignKeyConstraint(
            ["user_id", "source_wallet_id"], ["wallets.user_id", "wallets.id"],
            name="fk_transfers_source_owner", deferrable=True, initially="DEFERRED",
        ),
        ForeignKeyConstraint(
            ["user_id", "destination_wallet_id"], ["wallets.user_id", "wallets.id"],
            name="fk_transfers_destination_owner", deferrable=True, initially="DEFERRED",
        ),
        ForeignKeyConstraint(
            ["user_id", "reversal_of_id"], ["wallet_transfers.user_id", "wallet_transfers.id"],
            name="fk_transfers_reversal_owner", deferrable=True, initially="DEFERRED",
        ),
        CheckConstraint("source_wallet_id <> destination_wallet_id", name="ck_transfers_distinct_wallets"),
        CheckConstraint("reversal_of_id <> id", name="ck_transfers_not_self_reversal"),
        CheckConstraint("amount > 0 AND amount <= 9999999999999999.99", name="ck_transfers_amount"),
        CheckConstraint("currency = 'LKR'", name="ck_transfers_currency"),
        Index("ix_transfers_history", "user_id", "transfer_date", "created_at", "id"),
        Index("ix_transfers_source", "user_id", "source_wallet_id", "transfer_date"),
        Index("ix_transfers_destination", "user_id", "destination_wallet_id", "transfer_date"),
    )

    id: Mapped[UUID] = mapped_column(primary_key=True)
    user_id: Mapped[UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    source_wallet_id: Mapped[UUID]
    destination_wallet_id: Mapped[UUID]
    amount: Mapped[Decimal] = mapped_column(Numeric(18, 2))
    currency: Mapped[str] = mapped_column(String(3))
    transfer_date: Mapped[date] = mapped_column(Date)
    note: Mapped[str | None] = mapped_column(String(1000))
    reversal_of_id: Mapped[UUID | None]
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class TransferReplay(Base):
    __tablename__ = "transfer_replays"
    __table_args__ = (
        CheckConstraint("operation IN ('create', 'reverse')", name="ck_transfer_replays_operation"),
    )

    user_id: Mapped[UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    operation: Mapped[str] = mapped_column(String(7), primary_key=True)
    key: Mapped[UUID] = mapped_column(primary_key=True)
    fingerprint: Mapped[str] = mapped_column(String(64))
    response: Mapped[dict] = mapped_column(JSONB)
