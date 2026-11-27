from sqlalchemy import select
from sqlalchemy.orm import Session

from app.auth.models import RefreshSession, User


def user_by_email(db: Session, email: str, *, lock: bool = False) -> User | None:
    query = select(User).where(User.email == email)
    return db.scalar(query.with_for_update() if lock else query)


def lock_user(db: Session, user_id) -> User | None:
    return db.scalar(select(User).where(User.id == user_id).with_for_update())


def lock_family(db: Session, family_id) -> RefreshSession | None:
    return db.scalar(
        select(RefreshSession)
        .where(RefreshSession.id == family_id, RefreshSession.family_id == family_id)
        .with_for_update()
    )


def token_location(db: Session, digest: str):
    return db.execute(
        select(RefreshSession.id, RefreshSession.family_id, RefreshSession.user_id).where(
            RefreshSession.token_digest == digest
        )
    ).one_or_none()
