from uuid import UUID, uuid4

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import Session

from app.categories.defaults import seed_rows_v1
from app.categories.models import Category
from app.categories.schemas import CategoryType, name_key


def provision_defaults(db: Session, user_id: UUID) -> None:
    rows = [dict(row, id=uuid4(), user_id=user_id) for row in seed_rows_v1()]
    db.execute(insert(Category).values(rows).on_conflict_do_nothing())


def owned_category(db: Session, user_id: UUID, category_id: UUID, *, lock: bool = False):
    query = select(Category).where(Category.user_id == user_id, Category.id == category_id)
    return db.scalar(query.with_for_update() if lock else query)


def list_categories(
    db: Session, user_id: UUID, *, kind: CategoryType | None, search: str | None,
    active: bool, default: bool | None, limit: int, offset: int,
):
    query = select(Category).where(Category.user_id == user_id, Category.is_active == active)
    if kind is not None:
        query = query.where(Category.type == kind.value)
    if search is not None:
        query = query.where(Category.normalized_name.contains(name_key(search), autoescape=True))
    if default is not None:
        query = query.where(Category.default_code.is_not(None) if default else Category.default_code.is_(None))
    return db.scalars(query.order_by(
        Category.default_code.is_(None), Category.normalized_name, Category.type, Category.id,
    ).limit(limit + 1).offset(offset)).all()
