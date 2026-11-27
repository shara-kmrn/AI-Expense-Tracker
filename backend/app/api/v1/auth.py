from typing import Annotated

from fastapi import APIRouter, BackgroundTasks, Depends, Request, Response
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from fastapi.routing import APIRoute
from sqlalchemy.exc import SQLAlchemyError

from app.auth import account, service
from app.auth.dependencies import Database, access_identity, guard_auth, settings_for
from app.auth.errors import AuthError
from app.auth.recovery import recover_account
from app.auth.schemas import (
    ChangePasswordRequest, EmailRequest, LoginRequest, RefreshRequest, RegisterRequest,
    ResetPasswordRequest, TokenResponse, UserResponse,
)
from app.auth.tokens import digest_token
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
Identity = Annotated[tuple, Depends(access_identity)]


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
def logout(identity: Identity, db: Database) -> Response:
    service.logout(db, *identity)
    return Response(status_code=204)


@router.post("/change-password", status_code=204)
def change_password(data: ChangePasswordRequest, identity: Identity, db: Database) -> Response:
    account.change_password(
        db, identity, data.current_password.get_secret_value(), data.new_password.get_secret_value()
    )
    return Response(status_code=204)


@router.post("/forgot-password", status_code=202)
def forgot_password(data: EmailRequest, request: Request, tasks: BackgroundTasks):
    state = request.app.state
    if state.recovery_limiter.allow(digest_token(data.email)) and state.recovery_slots.acquire(False):
        tasks.add_task(
            recover_account, state.session_factory, data.email, state.settings.reset_token_minutes,
            state.recovery_delivery, state.recovery_slots,
        )
    return {"detail": "If the account is eligible, a recovery email will be sent."}


@router.post("/reset-password", status_code=204)
def reset_password(data: ResetPasswordRequest, db: Database) -> Response:
    account.reset_password(db, data.reset_token.get_secret_value(), data.new_password.get_secret_value())
    return Response(status_code=204)
