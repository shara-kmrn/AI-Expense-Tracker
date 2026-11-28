from typing import Annotated, Literal
from uuid import UUID

from fastapi import APIRouter, Depends, Header, Query

from app.api.v1.auth import PrivateRoute
from app.auth.dependencies import Database, get_current_user
from app.auth.errors import AuthError
from app.auth.schemas import UserResponse
from app.incomes.schemas import CalendarDate
from app.transfers import repository, service
from app.transfers.schemas import TransferCreate, TransferPage, TransferResponse, TransferReverse

router = APIRouter(prefix="/transfers", tags=["transfers"], route_class=PrivateRoute)
Owner = Annotated[UserResponse, Depends(get_current_user)]
Key = Annotated[str, Header(alias="Idempotency-Key", min_length=36, max_length=36,
                            pattern=r"^[0-9a-fA-F-]{36}$")]
MISSING = {404: {"description": "Transfer or wallet not found"}}
CONFLICT = {409: {"description": "Idempotency, eligibility, wallet state, or balance conflict"}}


def _parse_key(key):
    try:
        parsed = UUID(key)
        if parsed.version == 4 and str(parsed) == key.lower():
            return parsed
    except ValueError:
        pass
    raise AuthError(422, "Use a UUIDv4 idempotency key")


@router.get("")
def list_owned(
    owner: Owner, db: Database, date_from: CalendarDate | None = None,
    date_to: CalendarDate | None = None, wallet_id: UUID | None = None,
    source_wallet_id: UUID | None = None, destination_wallet_id: UUID | None = None,
    kind: Literal["original", "reversal"] | None = None,
    q: Annotated[str | None, Query(max_length=120)] = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
    offset: Annotated[int, Query(ge=0, le=1_000_000)] = 0,
) -> TransferPage:
    if date_from is not None and date_to is not None and date_from > date_to:
        raise AuthError(422, "Start date must precede the end date")
    if q is not None and "\0" in q:
        raise AuthError(422, "Invalid search text")
    rows = repository.history(
        db, owner.id, date_from=date_from, date_to=date_to, wallet_id=wallet_id,
        source_wallet_id=source_wallet_id, destination_wallet_id=destination_wallet_id,
        kind=kind, search=q.strip() if q else None, limit=limit, offset=offset,
    )
    return TransferPage(
        items=[repository.view(*row) for row in rows[:limit]],
        next_offset=offset + limit if len(rows) > limit and offset + limit <= 1_000_000 else None,
    )


@router.get("/{transfer_id}", responses=MISSING)
def retrieve(transfer_id: UUID, owner: Owner, db: Database) -> TransferResponse:
    record = repository.get(db, owner.id, transfer_id)
    if record is None:
        raise AuthError(404, "Transfer not found")
    return record


@router.post("", status_code=201, responses={**MISSING, **CONFLICT})
def create(data: TransferCreate, owner: Owner, db: Database, key: Key) -> TransferResponse:
    return service.create(db, owner.id, _parse_key(key), data)


@router.post("/{transfer_id}/reverse", status_code=201, responses={**MISSING, **CONFLICT})
def reverse(transfer_id: UUID, owner: Owner, db: Database, key: Key,
            data: TransferReverse | None = None) -> TransferResponse:
    return service.reverse(db, owner.id, _parse_key(key), transfer_id, data or TransferReverse())
