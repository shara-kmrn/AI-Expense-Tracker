from typing import Annotated

from fastapi import APIRouter, Depends

from app.api.v1.auth import PrivateRoute
from app.auth.dependencies import get_current_user
from app.auth.schemas import UserResponse

router = APIRouter(prefix="/users", tags=["users"], route_class=PrivateRoute)


@router.get("/me")
def me(user: Annotated[UserResponse, Depends(get_current_user)]) -> UserResponse:
    return user
