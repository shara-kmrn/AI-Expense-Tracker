import re
import unicodedata
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
from typing import Annotated
from uuid import UUID

from pydantic import AfterValidator, BaseModel, BeforeValidator, ConfigDict, Field, model_validator

from app.auth.schemas import UtcTimestamp
from app.wallets.schemas import AmountInput, Currency, Money, validate_amount

COLOMBO = timezone(timedelta(hours=5, minutes=30))


def clean_text(value: str, limit: int, *, multiline: bool = False) -> str:
    if len(value) > limit or any(
        unicodedata.category(char) in {"Cc", "Cf", "Cs"} and not (multiline and char in "\n\r\t")
        for char in value
    ):
        raise ValueError("Invalid text")
    return value.strip()


def title_text(value: str) -> str:
    title = clean_text(value, 120)
    if not title:
        raise ValueError("Enter a title")
    return title


def positive_amount(value: str) -> str:
    if Decimal(validate_amount(value)) <= 0:
        raise ValueError("Income must be positive")
    return value


def calendar_text(value):
    if not isinstance(value, str) or re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", value) is None:
        raise ValueError("Use a calendar date in YYYY-MM-DD format")
    return value


def received_date(value: date) -> date:
    if value > datetime.now(COLOMBO).date():
        raise ValueError("Income date cannot be in the future")
    return value


Title = Annotated[str, AfterValidator(title_text)]
Note = Annotated[str, AfterValidator(lambda value: clean_text(value, 1000, multiline=True) or None)]
Amount = Annotated[AmountInput, AfterValidator(positive_amount)]
CalendarDate = Annotated[date, BeforeValidator(calendar_text)]
ReceivedDate = Annotated[CalendarDate, AfterValidator(received_date)]
Version = Annotated[int, Field(strict=True, gt=0, le=2_147_483_647)]


class FinancialCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    title: Title
    amount: Amount
    currency: Currency
    category_id: UUID
    wallet_id: UUID
    note: Note | None = None


class IncomeCreate(FinancialCreate):
    income_date: ReceivedDate


class FinancialUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    expected_version: Version
    title: Title | None = None
    amount: Amount | None = None
    category_id: UUID | None = None
    wallet_id: UUID | None = None
    note: Note | None = None

    @model_validator(mode="after")
    def require_edit(self):
        edited = self.model_fields_set - {"expected_version"}
        if not edited or any(getattr(self, field) is None for field in edited - {"note"}):
            raise ValueError("Provide at least one valid editable field")
        return self


class IncomeUpdate(FinancialUpdate):
    income_date: ReceivedDate | None = None


class FinancialResponse(BaseModel):
    id: UUID
    title: str
    amount: Money
    currency: Currency
    note: str | None
    category_id: UUID
    category_name: str
    category_icon: str
    category_color: str
    category_active: bool
    wallet_id: UUID
    wallet_name: str
    wallet_active: bool
    version: int
    created_at: UtcTimestamp
    updated_at: UtcTimestamp


class IncomeResponse(FinancialResponse):
    income_date: date


class IncomePage(BaseModel):
    items: list[IncomeResponse]
    next_offset: int | None


class CategoryTotal(BaseModel):
    category_id: UUID
    name: str
    total: Money


class IncomeSummary(BaseModel):
    currency: Currency = "LKR"
    year: int
    month: int
    total: Money
    count: int
    categories: list[CategoryTotal]
