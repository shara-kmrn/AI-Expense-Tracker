from uuid import UUID, uuid4

from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.auth.errors import AuthError
from app.categories.models import Category
from app.categories.repository import owned_category
from app.categories.schemas import CategoryCreate, CategoryResponse, CategoryUpdate, name_key


def get(db: Session, owner: UUID, category_id: UUID, *, edit: bool = False) -> Category:
    category = owned_category(db, owner, category_id, lock=edit)
    if category is None:
        raise AuthError(404, "Category not found")
    if edit and category.is_default:
        raise AuthError(403, "Default categories are protected")
    return category


def save(db: Session, category: Category) -> CategoryResponse:
    try:
        db.flush()
        result = CategoryResponse.model_validate(category)
        db.commit()
    except IntegrityError as error:
        db.rollback()
        if getattr(getattr(error.orig, "diag", None), "constraint_name", None) == "uq_categories_owner_type_name":
            raise AuthError(409, "Category name is already reserved for this type") from None
        raise
    return result


def create(db: Session, owner: UUID, data: CategoryCreate) -> CategoryResponse:
    category = Category(
        id=uuid4(), user_id=owner, name=data.name, normalized_name=name_key(data.name),
        type=data.type.value, icon=data.icon, color=data.color,
    )
    db.add(category)
    return save(db, category)


def update(db: Session, owner: UUID, category_id: UUID, data: CategoryUpdate) -> CategoryResponse:
    category = get(db, owner, category_id, edit=True)
    for field, value in data.model_dump(exclude_unset=True).items():
        setattr(category, field, value)
    if data.name is not None:
        category.normalized_name = name_key(data.name)
    return save(db, category)


def change_active(db: Session, owner: UUID, category_id: UUID, active: bool) -> CategoryResponse:
    category = get(db, owner, category_id, edit=True)
    category.is_active = active
    return save(db, category)
