from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Query, Response

from app.api.v1.auth import PrivateRoute
from app.auth.dependencies import Database, get_current_user
from app.auth.schemas import UserResponse
from app.categories.schemas import Name
from app.wallets import service
from app.wallets.repository import list_wallets, summarize
from app.wallets.schemas import WalletCreate, WalletPage, WalletResponse, WalletSummary, WalletType, WalletUpdate

router = APIRouter(prefix="/wallets", tags=["wallets"], route_class=PrivateRoute,
                   responses={401: {"description": "Authentication required"},
                              422: {"description": "Invalid request"}})
Owner = Annotated[UserResponse, Depends(get_current_user)]
NOT_FOUND = {404: {"description": "Wallet not found"}}


@router.get("")
def list_owned(
    owner: Owner, db: Database, type: WalletType | None = None,
    q: Annotated[Name | None, Query(description="Normalized name substring")] = None,
    active: bool = True,
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
    offset: Annotated[int, Query(ge=0, le=1_000_000)] = 0,
) -> WalletPage:
    rows = list_wallets(db, owner.id, kind=type, search=q, active=active, limit=limit, offset=offset)
    return WalletPage(items=[WalletResponse.model_validate(row) for row in rows[:limit]],
                      next_offset=offset + limit if len(rows) > limit and offset + limit <= 1_000_000 else None)


@router.get("/summary")
def summary(owner: Owner, db: Database) -> WalletSummary:
    return summarize(db, owner.id)


@router.get("/{wallet_id}", responses=NOT_FOUND)
def retrieve(wallet_id: UUID, owner: Owner, db: Database) -> WalletResponse:
    return WalletResponse.model_validate(service.get(db, owner.id, wallet_id))


@router.post("", status_code=201, responses={409: {"description": "Name already reserved"}})
def create(data: WalletCreate, owner: Owner, db: Database) -> WalletResponse:
    return service.create(db, owner.id, data)


@router.patch("/{wallet_id}", responses={**NOT_FOUND, 409: {"description": "Name reserved or wallet archived"}})
def update(wallet_id: UUID, data: WalletUpdate, owner: Owner, db: Database) -> WalletResponse:
    return service.update(db, owner.id, wallet_id, data)


@router.delete("/{wallet_id}", status_code=204,
               responses={**NOT_FOUND, 409: {"description": "Wallet has a nonzero balance"}})
def archive(wallet_id: UUID, owner: Owner, db: Database) -> Response:
    service.change_active(db, owner.id, wallet_id, False)
    return Response(status_code=204)


@router.post("/{wallet_id}/restore", responses=NOT_FOUND)
def restore(wallet_id: UUID, owner: Owner, db: Database) -> WalletResponse:
    return service.change_active(db, owner.id, wallet_id, True)
