from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Query, Response

from app.api.v1.auth import PrivateRoute
from app.auth.dependencies import Database, get_current_user
from app.auth.schemas import UserResponse
from app.categories import service
from app.categories.repository import list_categories
from app.categories.schemas import CategoryCreate, CategoryPage, CategoryResponse, CategoryType, CategoryUpdate, Name

router = APIRouter(
    prefix="/categories", tags=["categories"], route_class=PrivateRoute,
    responses={401: {"description": "Authentication required"}, 422: {"description": "Invalid request"}},
)
Owner = Annotated[UserResponse, Depends(get_current_user)]


@router.get("")
def list_owned(
    owner: Owner, db: Database, type: CategoryType | None = None,
    q: Annotated[Name | None, Query(description="Normalized name substring")] = None,
    active: bool = True, default: bool | None = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
    offset: Annotated[int, Query(ge=0, le=1_000_000)] = 0,
) -> CategoryPage:
    rows = list_categories(db, owner.id, kind=type, search=q, active=active,
                           default=default, limit=limit, offset=offset)
    return CategoryPage(
        items=[CategoryResponse.model_validate(row) for row in rows[:limit]],
        next_offset=offset + limit if len(rows) > limit and offset + limit <= 1_000_000 else None,
    )


@router.get("/{category_id}", responses={404: {"description": "Category not found"}})
def get_one(category_id: UUID, owner: Owner, db: Database) -> CategoryResponse:
    return CategoryResponse.model_validate(service.get(db, owner.id, category_id))


@router.post("", status_code=201, responses={409: {"description": "Name already reserved"}})
def create(data: CategoryCreate, owner: Owner, db: Database) -> CategoryResponse:
    return service.create(db, owner.id, data)


_protected = {403: {"description": "Default category is protected"}, 404: {"description": "Category not found"}}


@router.patch("/{category_id}", responses={**_protected, 409: {"description": "Name already reserved"}})
def update(category_id: UUID, data: CategoryUpdate, owner: Owner, db: Database) -> CategoryResponse:
    return service.update(db, owner.id, category_id, data)


@router.delete("/{category_id}", status_code=204, responses=_protected)
def archive(category_id: UUID, owner: Owner, db: Database) -> Response:
    service.change_active(db, owner.id, category_id, False)
    return Response(status_code=204)


@router.post("/{category_id}/restore", responses=_protected)
def restore(category_id: UUID, owner: Owner, db: Database) -> CategoryResponse:
    return service.change_active(db, owner.id, category_id, True)
