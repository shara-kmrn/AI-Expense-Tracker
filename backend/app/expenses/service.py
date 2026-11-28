from app.financial import service
from app.expenses.models import Expense, ExpenseCreation
from app.expenses.repository import view
from app.expenses.schemas import ExpenseResponse

_OPERATION = service.FinancialOperation("Expense", -1, Expense, ExpenseCreation, ExpenseResponse, view)


def create(db, owner, key, data):
    return service.create(db, owner, key, data, _OPERATION)


def edit(db, owner, record_id, data):
    return service.edit(db, owner, record_id, data, _OPERATION)


def delete(db, owner, record_id, expected):
    service.delete(db, owner, record_id, expected, _OPERATION)
