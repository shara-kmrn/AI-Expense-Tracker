import re
import unicodedata
from enum import StrEnum
from typing import Annotated
from uuid import UUID

from pydantic import AfterValidator, BaseModel, ConfigDict, model_validator

from app.auth.schemas import UtcTimestamp
from app.categories.defaults import ICONS_V1


class CategoryType(StrEnum):
    INCOME = "INCOME"
    EXPENSE = "EXPENSE"


def clean_name(value: str) -> str:
    if len(value) > 1024 or any(unicodedata.category(char) in {"Cc", "Cf", "Cs"} for char in value):
        raise ValueError("Invalid category name")
    cleaned = " ".join(unicodedata.normalize("NFKC", value).split())
    if not 1 <= len(cleaned) <= 80:
        raise ValueError("Category name must contain 1–80 characters")
    return cleaned


def name_key(value: str) -> str:
    return unicodedata.normalize("NFKC", value.casefold())


def check_icon(value: str) -> str:
    if value not in ICONS_V1:
        raise ValueError("Unsupported category icon")
    return value


def check_color(value: str) -> str:
    if re.fullmatch(r"#[0-9A-Fa-f]{6}", value) is None:
        raise ValueError("Unsupported category color")
    return value.upper()


Name = Annotated[str, AfterValidator(clean_name)]
Icon = Annotated[str, AfterValidator(check_icon)]
Color = Annotated[str, AfterValidator(check_color)]


class CategoryCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: Name
    type: CategoryType
    icon: Icon
    color: Color


class CategoryUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: Name | None = None
    icon: Icon | None = None
    color: Color | None = None

    @model_validator(mode="after")
    def require_changes(self):
        if not self.model_fields_set or any(getattr(self, name) is None for name in self.model_fields_set):
            raise ValueError("Provide at least one non-null editable field")
        return self


class CategoryResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    name: str
    type: CategoryType
    icon: str
    color: str
    is_default: bool
    is_active: bool
    created_at: UtcTimestamp
    updated_at: UtcTimestamp


class CategoryPage(BaseModel):
    items: list[CategoryResponse]
    next_offset: int | None
