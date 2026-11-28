from datetime import date
from enum import StrEnum

from pydantic import BaseModel

from app.incomes.schemas import CategoryTotal, FinancialCreate, FinancialResponse, FinancialUpdate, ReceivedDate
from app.wallets.schemas import Currency, Money


class ExpenseCreate(FinancialCreate):
    expense_date: ReceivedDate


class ExpenseUpdate(FinancialUpdate):
    expense_date: ReceivedDate | None = None


class ExpenseResponse(FinancialResponse):
    expense_date: date


class ExpensePage(BaseModel):
    items: list[ExpenseResponse]
    next_offset: int | None


class Period(StrEnum):
    DAY = "day"
    WEEK = "week"
    MONTH = "month"


class ExpenseSummary(BaseModel):
    currency: Currency = "LKR"
    period: Period
    start_date: date
    end_date: date
    total: Money
    count: int
    categories: list[CategoryTotal]
