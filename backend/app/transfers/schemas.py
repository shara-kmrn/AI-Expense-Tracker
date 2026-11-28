from datetime import date
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, model_validator

from app.auth.schemas import UtcTimestamp
from app.incomes.schemas import Amount, Note, ReceivedDate
from app.wallets.schemas import Currency, Money, WalletType


class TransferReverse(BaseModel):
    model_config = ConfigDict(extra="forbid")
    note: Note | None = None


class TransferCreate(TransferReverse):
    source_wallet_id: UUID
    destination_wallet_id: UUID
    amount: Amount
    currency: Currency
    transfer_date: ReceivedDate

    @model_validator(mode="after")
    def require_distinct_wallets(self):
        if self.source_wallet_id == self.destination_wallet_id:
            raise ValueError("Select two different wallets")
        return self


class TransferWallet(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    name: str
    type: WalletType
    icon: str
    color: str
    is_active: bool


class TransferResponse(BaseModel):
    id: UUID
    source_wallet: TransferWallet
    destination_wallet: TransferWallet
    amount: Money
    currency: Currency
    transfer_date: date
    note: str | None
    created_at: UtcTimestamp
    reversal_of_id: UUID | None
    reversal_id: UUID | None
    status: Literal["original", "reversed", "reversal"]


class TransferPage(BaseModel):
    items: list[TransferResponse]
    next_offset: int | None
