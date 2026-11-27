from typing import Annotated

from fastapi import APIRouter, Depends, Response

from app.api.v1.auth import Identity, PrivateRoute
from app.auth import account
from app.auth.dependencies import Database, get_current_user, guard_auth
from app.auth.schemas import CurrentPasswordRequest, ProfileUpdate, UserResponse

router = APIRouter(prefix="/users", tags=["users"], route_class=PrivateRoute)


@router.get("/me")
def me(user: Annotated[UserResponse, Depends(get_current_user)]) -> UserResponse:
    return user


@router.patch("/me")
def update_me(data: ProfileUpdate, identity: Identity, db: Database) -> UserResponse:
    return account.update_profile(db, identity, data.full_name)


@router.delete("/me", status_code=204, dependencies=[Depends(guard_auth)])
def delete_me(data: CurrentPasswordRequest, identity: Identity, db: Database) -> Response:
    account.delete_account(db, identity, data.current_password.get_secret_value())
    return Response(status_code=204)
