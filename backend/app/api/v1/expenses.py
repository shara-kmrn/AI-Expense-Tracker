from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Header, Query, Response

from app.api.v1.auth import PrivateRoute
from app.auth.dependencies import Database, get_current_user
from app.auth.errors import AuthError
from app.auth.schemas import UserResponse
from app.expenses import repository, service
from app.expenses.models import Expense
from app.incomes.schemas import CalendarDate
from app.expenses.schemas import ExpenseCreate, ExpensePage, ExpenseResponse, ExpenseSummary, ExpenseUpdate, Period

router = APIRouter(prefix="/expenses", tags=["expenses"], route_class=PrivateRoute)
Owner = Annotated[UserResponse, Depends(get_current_user)]
CONFLICT = {409: {"description": "Stale version, idempotency mismatch, or financial constraint"}}
MISSING = {404: {"description": "Record or reference not found"}}


@router.get("")
def list_owned(
    owner: Owner, db: Database, date_from: CalendarDate | None = None,
    date_to: CalendarDate | None = None, category_id: UUID | None = None,
    wallet_id: UUID | None = None, q: Annotated[str | None, Query(max_length=120)] = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
    offset: Annotated[int, Query(ge=0, le=1_000_000)] = 0,
) -> ExpensePage:
    if date_from is not None and date_to is not None and date_from > date_to:
        raise AuthError(422, "Start date must precede the end date")
    if q is not None and "\0" in q:
        raise AuthError(422, "Invalid search text")
    rows = repository.history(db, owner.id, date_from=date_from, date_to=date_to,
                              category_id=category_id, wallet_id=wallet_id,
                              search=q.strip() if q else None, limit=limit, offset=offset)
    return ExpensePage(items=[repository.view(*row) for row in rows[:limit]],
                      next_offset=offset + limit if len(rows) > limit and offset + limit <= 1_000_000 else None)


@router.get("/summary")
def summary(owner: Owner, db: Database, period: Period,
            anchor: Annotated[CalendarDate, Query(alias="date")]) -> ExpenseSummary:
    return repository.summarize(db, owner.id, period, anchor)


@router.get("/{expense_id}", responses=MISSING)
def retrieve(expense_id: UUID, owner: Owner, db: Database) -> ExpenseResponse:
    row = db.execute(repository.visible(owner.id).where(Expense.id == expense_id)).one_or_none()
    if row is None:
        raise AuthError(404, "Expense not found")
    return repository.view(*row)


@router.post("", status_code=201, responses={**MISSING, **CONFLICT})
def create(data: ExpenseCreate, owner: Owner, db: Database,
           key: Annotated[str, Header(alias="Idempotency-Key", min_length=36, max_length=36,
                                       pattern=r"^[0-9a-fA-F-]{36}$")]) -> ExpenseResponse:
    try:
        parsed = UUID(key)
        if parsed.version != 4 or str(parsed) != key.lower():
            raise ValueError
    except ValueError:
        raise AuthError(422, "Use a UUIDv4 idempotency key") from None
    return service.create(db, owner.id, parsed, data)


@router.patch("/{expense_id}", responses={**MISSING, **CONFLICT})
def edit(expense_id: UUID, data: ExpenseUpdate, owner: Owner, db: Database) -> ExpenseResponse:
    return service.edit(db, owner.id, expense_id, data)


@router.delete("/{expense_id}", status_code=204, responses={**MISSING, **CONFLICT})
def delete(expense_id: UUID, owner: Owner, db: Database,
           expected_version: Annotated[int, Header(alias="If-Match", gt=0, le=2_147_483_647)]) -> Response:
    service.delete(db, owner.id, expense_id, expected_version)
    return Response(status_code=204)
