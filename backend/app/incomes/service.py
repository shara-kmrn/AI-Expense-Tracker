from app.financial import service
from app.incomes.models import Income, IncomeCreation
from app.incomes.repository import view
from app.incomes.schemas import IncomeResponse

_OPERATION = service.FinancialOperation("Income", 1, Income, IncomeCreation, IncomeResponse, view)


def create(db, owner, key, data):
    return service.create(db, owner, key, data, _OPERATION)


def edit(db, owner, record_id, data):
    return service.edit(db, owner, record_id, data, _OPERATION)


def delete(db, owner, record_id, expected):
    service.delete(db, owner, record_id, expected, _OPERATION)
