import re
from decimal import Decimal
from enum import StrEnum
from typing import Annotated, Literal
from uuid import UUID

from pydantic import AfterValidator, BaseModel, ConfigDict, PlainSerializer, StringConstraints, model_validator

from app.auth.schemas import UtcTimestamp
from app.categories.schemas import Color, Icon, Name

AMOUNT_PATTERN = r"^[0-9]{1,16}(\.[0-9]{1,2})?$"
AmountInput = Annotated[str, StringConstraints(strict=True, max_length=19, pattern=AMOUNT_PATTERN)]
Money = Annotated[Decimal, PlainSerializer(lambda value: format(value, ".2f"), return_type=str)]
Currency = Literal["LKR"]


class WalletType(StrEnum):
    CASH = "CASH"
    BANK = "BANK"
    DIGITAL = "DIGITAL"


def validate_amount(value: str) -> str:
    if re.fullmatch(AMOUNT_PATTERN, value) is None:
        raise ValueError("Use an unsigned decimal with up to two fractional digits")
    return value


class WalletCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: Name
    type: WalletType
    currency: Currency
    opening_balance: Annotated[AmountInput, AfterValidator(validate_amount)]
    icon: Icon
    color: Color


class WalletUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: Name | None = None
    icon: Icon | None = None
    color: Color | None = None

    @model_validator(mode="after")
    def require_changes(self):
        if not self.model_fields_set or any(getattr(self, field) is None for field in self.model_fields_set):
            raise ValueError("Provide at least one non-null editable field")
        return self


class WalletResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    name: str
    type: WalletType
    currency: Currency
    opening_balance: Money
    current_balance: Money
    icon: str
    color: str
    is_active: bool
    created_at: UtcTimestamp
    updated_at: UtcTimestamp


class WalletPage(BaseModel):
    items: list[WalletResponse]
    next_offset: int | None


class WalletSummary(BaseModel):
    currency: Currency = "LKR"
    total_active_balance: Money
    active_count: int
    archived_count: int
    balances_by_type: dict[WalletType, Money]
