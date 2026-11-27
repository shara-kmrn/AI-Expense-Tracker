import re
from datetime import UTC, datetime, timedelta
from uuid import uuid4

from sqlalchemy import delete, select, update
from sqlalchemy.orm import Session

from app.auth.errors import AuthError, InvalidCredentials
from app.auth.models import PasswordResetToken, RefreshSession
from app.auth.passwords import hash_password, verify_password
from app.auth.repository import lock_family, lock_user, user_by_email
from app.auth.schemas import UserResponse
from app.auth.tokens import digest_token, new_refresh_token


def active_account(db: Session, identity):
    user_id, family_id = identity
    user = lock_user(db, user_id)
    if user is None or not user.active:
        raise InvalidCredentials
    family = lock_family(db, family_id)
    if (
        family is None or family.user_id != user_id or family.revoked_at is not None
        or family.expires_at <= datetime.now(UTC)
    ):
        raise InvalidCredentials
    return user


def update_profile(db: Session, identity, full_name: str) -> UserResponse:
    with db.begin():
        user = active_account(db, identity)
        user.full_name = full_name
        user.updated_at = datetime.now(UTC)
        db.flush()
        return UserResponse.model_validate(user)


def revoke_reset_tokens(db: Session, user_id, now):
    db.execute(update(PasswordResetToken).where(
        PasswordResetToken.user_id == user_id,
        PasswordResetToken.consumed_at.is_(None),
        PasswordResetToken.revoked_at.is_(None),
    ).values(revoked_at=now))


def replace_password(db: Session, user, password_hash: str, now, *, consumed=None):
    user.password_hash = password_hash
    user.updated_at = now
    db.execute(update(RefreshSession).where(
        RefreshSession.user_id == user.id, RefreshSession.revoked_at.is_(None)
    ).values(revoked_at=now))
    if consumed is not None:
        consumed.consumed_at = now
        db.flush()
    revoke_reset_tokens(db, user.id, now)


def change_password(db: Session, identity, current: str, new: str):
    with db.begin():
        user = active_account(db, identity)
        if not verify_password(current, user.password_hash)[0]:
            raise AuthError(400, "Current password is incorrect")
        if new == current:
            raise AuthError(400, "New password must differ from current password")
        replace_password(db, user, hash_password(new), datetime.now(UTC))


def delete_account(db: Session, identity, current: str):
    with db.begin():
        user = active_account(db, identity)
        if not verify_password(current, user.password_hash)[0]:
            raise AuthError(400, "Current password is incorrect")
        db.delete(user)


def create_recovery(db: Session, email: str, lifetime_minutes: int):
    with db.begin():
        user = user_by_email(db, email, lock=True)
        if user is None or not user.active:
            return None
        now = datetime.now(UTC)
        db.execute(delete(PasswordResetToken).where(
            PasswordResetToken.user_id == user.id,
            PasswordResetToken.expires_at < now - timedelta(days=7),
        ))
        revoke_reset_tokens(db, user.id, now)
        token, digest = new_refresh_token()
        db.add(PasswordResetToken(
            id=uuid4(), user_id=user.id, token_digest=digest,
            expires_at=now + timedelta(minutes=lifetime_minutes),
        ))
        return user.email, token


def reset_password(db: Session, token: str, new: str):
    invalid = AuthError(400, "Invalid or expired reset token")
    if re.fullmatch(r"[A-Za-z0-9_-]{43}", token) is None:
        raise invalid
    digest = digest_token(token)
    with db.begin():
        user_id = db.scalar(select(PasswordResetToken.user_id).where(
            PasswordResetToken.token_digest == digest
        ))
        if user_id is None:
            raise invalid
        user = lock_user(db, user_id)
        if user is None or not user.active:
            raise invalid
        recovery = db.scalar(select(PasswordResetToken).where(
            PasswordResetToken.token_digest == digest
        ))
        now = datetime.now(UTC)
        if (
            recovery is None or recovery.expires_at <= now
            or recovery.consumed_at is not None or recovery.revoked_at is not None
        ):
            raise invalid
        new_hash = hash_password(new)
        now = datetime.now(UTC)
        if recovery.expires_at <= now:
            raise invalid
        replace_password(db, user, new_hash, now, consumed=recovery)
