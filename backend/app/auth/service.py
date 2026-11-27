from datetime import UTC, datetime, timedelta
from uuid import uuid4

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.auth.errors import AuthError, InvalidCredentials
from app.auth.models import RefreshSession, User
from app.auth.passwords import hash_password, verify_password
from app.auth.repository import lock_family, token_location, user_by_email
from app.auth.schemas import LoginRequest, RegisterRequest, TokenResponse, UserResponse
from app.auth.tokens import digest_token, issue_access, new_refresh_token
from app.core.config import Settings


def register(db: Session, data: RegisterRequest) -> UserResponse:
    user = User(
        id=uuid4(), full_name=data.full_name, email=data.email,
        password_hash=hash_password(data.password.get_secret_value()),
    )
    try:
        with db.begin():
            db.add(user)
            db.flush()
            return UserResponse.model_validate(user)
    except IntegrityError as error:
        if getattr(getattr(error.orig, "diag", None), "constraint_name", None) == "uq_users_email":
            raise AuthError(409, "Account cannot be registered") from None
        raise


def issue_session_tokens(db, settings, user_id, family_id, session_id, deadline, now) -> TokenResponse:
    token, digest = new_refresh_token()
    db.add(RefreshSession(
        id=session_id, user_id=user_id, family_id=family_id,
        token_digest=digest, expires_at=deadline,
    ))
    expires = min(deadline, now + timedelta(minutes=settings.access_token_minutes))
    lifetime = int(expires.timestamp()) - int(now.timestamp())
    if lifetime <= 0:
        raise InvalidCredentials
    return TokenResponse(
        access_token=issue_access(settings, user_id, family_id, now, expires),
        refresh_token=token, expires_in=lifetime, refresh_expires_at=deadline,
    )


def login(db: Session, settings: Settings, data: LoginRequest) -> TokenResponse:
    with db.begin():
        user = user_by_email(db, data.email)
        valid, replacement = verify_password(
            data.password.get_secret_value(), user.password_hash if user else None
        )
        if not valid or user is None or not user.active:
            raise InvalidCredentials
        if replacement:
            user.password_hash = replacement
        now = datetime.now(UTC)
        family_id = uuid4()
        deadline = now + timedelta(days=settings.refresh_session_days)
        return issue_session_tokens(db, settings, user.id, family_id, family_id, deadline, now)


def refresh(db: Session, settings: Settings, token: str) -> TokenResponse:
    with db.begin():
        location = token_location(db, digest_token(token))
        if location is None:
            raise InvalidCredentials
        family = lock_family(db, location.family_id)
        now = datetime.now(UTC)
        if family is None or family.revoked_at is not None or family.expires_at <= now:
            raise InvalidCredentials
        previous = db.get(RefreshSession, location.id, populate_existing=True)
        if previous is None or previous.user_id != family.user_id:
            raise InvalidCredentials
        if previous.rotated_at is not None:
            family.revoked_at = now
        else:
            user = db.get(User, family.user_id)
            if user is None or not user.active or previous.expires_at <= now:
                raise InvalidCredentials
            previous.rotated_at = now
            return issue_session_tokens(
                db, settings, user.id, family.id, uuid4(), family.expires_at, now
            )
    # Exit the transaction before returning 401 so reuse revocation is durable.
    raise InvalidCredentials


def current_user(db: Session, user_id, family_id) -> UserResponse:
    user = db.scalar(
        select(User).join(RefreshSession, RefreshSession.user_id == User.id).where(
            User.id == user_id, User.active.is_(True), RefreshSession.id == family_id,
            RefreshSession.family_id == family_id, RefreshSession.revoked_at.is_(None),
            RefreshSession.expires_at > datetime.now(UTC),
        )
    )
    if user is None:
        raise InvalidCredentials
    return UserResponse.model_validate(user)


def logout(db: Session, user_id, family_id) -> None:
    with db.begin():
        family = lock_family(db, family_id)
        if family is None or family.user_id != user_id:
            raise InvalidCredentials
        if family.revoked_at is None:
            family.revoked_at = datetime.now(UTC)
