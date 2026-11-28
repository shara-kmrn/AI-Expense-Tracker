from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Header, Query, Response

from app.api.v1.auth import PrivateRoute
from app.auth.dependencies import Database, get_current_user
from app.auth.errors import AuthError
from app.auth.schemas import UserResponse
from app.incomes import repository, service
from app.incomes.models import Income
from app.incomes.schemas import CalendarDate, IncomeCreate, IncomePage, IncomeResponse, IncomeSummary, IncomeUpdate

router = APIRouter(prefix="/incomes", tags=["incomes"], route_class=PrivateRoute)
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
) -> IncomePage:
    if date_from is not None and date_to is not None and date_from > date_to:
        raise AuthError(422, "Start date must precede the end date")
    if q is not None and "\0" in q:
        raise AuthError(422, "Invalid search text")
    rows = repository.history(db, owner.id, date_from=date_from, date_to=date_to,
                              category_id=category_id, wallet_id=wallet_id,
                              search=q.strip() if q else None, limit=limit, offset=offset)
    return IncomePage(items=[repository.view(*row) for row in rows[:limit]],
                      next_offset=offset + limit if len(rows) > limit and offset + limit <= 1_000_000 else None)


@router.get("/summary")
def summary(owner: Owner, db: Database,
            year: Annotated[int, Query(ge=1, le=9999)], month: Annotated[int, Query(ge=1, le=12)]) -> IncomeSummary:
    return repository.summarize(db, owner.id, year, month)


@router.get("/{income_id}", responses=MISSING)
def retrieve(income_id: UUID, owner: Owner, db: Database) -> IncomeResponse:
    row = db.execute(repository.visible(owner.id).where(Income.id == income_id)).one_or_none()
    if row is None:
        raise AuthError(404, "Income not found")
    return repository.view(*row)


@router.post("", status_code=201, responses={**MISSING, **CONFLICT})
def create(data: IncomeCreate, owner: Owner, db: Database,
           key: Annotated[str, Header(alias="Idempotency-Key", min_length=36, max_length=36,
                                       pattern=r"^[0-9a-fA-F-]{36}$")]) -> IncomeResponse:
    try:
        parsed = UUID(key)
        if parsed.version != 4 or str(parsed) != key.lower():
            raise ValueError
    except ValueError:
        raise AuthError(422, "Use a UUIDv4 idempotency key") from None
    return service.create(db, owner.id, parsed, data)


@router.patch("/{income_id}", responses={**MISSING, **CONFLICT})
def edit(income_id: UUID, data: IncomeUpdate, owner: Owner, db: Database) -> IncomeResponse:
    return service.edit(db, owner.id, income_id, data)


@router.delete("/{income_id}", status_code=204, responses={**MISSING, **CONFLICT})
def delete(income_id: UUID, owner: Owner, db: Database,
           expected_version: Annotated[int, Header(alias="If-Match", gt=0, le=2_147_483_647)]) -> Response:
    service.delete(db, owner.id, income_id, expected_version)
    return Response(status_code=204)
