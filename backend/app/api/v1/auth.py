from typing import Annotated

from fastapi import APIRouter, Depends, Request, Response
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from fastapi.routing import APIRoute
from sqlalchemy.exc import SQLAlchemyError

from app.auth import service
from app.auth.dependencies import Database, access_identity, guard_auth, settings_for
from app.auth.errors import AuthError
from app.auth.schemas import LoginRequest, RefreshRequest, RegisterRequest, TokenResponse, UserResponse
from app.core.config import Settings
from app.db.session import DatabaseNotConfigured


class PrivateRoute(APIRoute):
    def get_route_handler(self):
        handler = super().get_route_handler()

        async def safe_response(request: Request) -> Response:
            try:
                response = await handler(request)
            except AuthError as error:
                response = JSONResponse(
                    {"detail": error.detail}, error.status_code, error.headers
                )
            except RequestValidationError:
                response = JSONResponse({"detail": "Invalid request"}, 422)
            except (DatabaseNotConfigured, SQLAlchemyError):
                response = JSONResponse({"detail": "Authentication is unavailable"}, 503)
            response.headers["Cache-Control"] = "no-store"
            return response

        return safe_response


router = APIRouter(
    prefix="/auth", tags=["auth"], route_class=PrivateRoute, dependencies=[Depends(guard_auth)]
)
AuthSettings = Annotated[Settings, Depends(settings_for)]


@router.post("/register", status_code=201)
def register(data: RegisterRequest, db: Database) -> UserResponse:
    return service.register(db, data)


@router.post("/login")
def login(data: LoginRequest, db: Database, settings: AuthSettings) -> TokenResponse:
    return service.login(db, settings, data)


@router.post("/refresh")
def refresh(data: RefreshRequest, db: Database, settings: AuthSettings) -> TokenResponse:
    return service.refresh(db, settings, data.refresh_token.get_secret_value())


@router.post("/logout", status_code=204)
def logout(identity: Annotated[tuple, Depends(access_identity)], db: Database) -> Response:
    service.logout(db, *identity)
    return Response(status_code=204)
