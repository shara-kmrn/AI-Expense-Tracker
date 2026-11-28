from calendar import monthrange
from datetime import date, timedelta

from app.expenses.models import Expense
from app.expenses.schemas import ExpenseResponse, ExpenseSummary, Period
from app.incomes import repository


def view(expense, wallet, category):
    return repository.view_record(expense, wallet, category, ExpenseResponse, expense_date=expense.expense_date)


def history(db, owner, **filters):
    return repository.history(db, owner, model=Expense, date_column=Expense.expense_date, **filters)


def visible(owner):
    return repository.visible(owner, Expense)


def summarize(db, owner, period, anchor):
    if period == Period.WEEK:
        start = anchor - timedelta(days=anchor.weekday())
        end = start + timedelta(days=min(6, (date.max - start).days))
    elif period == Period.MONTH:
        start = anchor.replace(day=1)
        end = anchor.replace(day=monthrange(anchor.year, anchor.month)[1])
    else:
        start = end = anchor
    rows = repository.period_rows(db, owner, start, end, Expense, Expense.expense_date)
    return ExpenseSummary(period=period, start_date=start, end_date=end, **repository.summary_totals(rows))
