from datetime import UTC
from typing import Annotated, Literal
from uuid import UUID

from email_validator import validate_email
from pydantic import AfterValidator, AwareDatetime, BaseModel, ConfigDict, Field, SecretStr, field_validator

UtcTimestamp = Annotated[AwareDatetime, AfterValidator(lambda value: value.astimezone(UTC))]


class LoginRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    email: Annotated[str, Field(min_length=1, max_length=254)]
    password: Annotated[SecretStr, Field(min_length=1, max_length=128)]

    @field_validator("email")
    @classmethod
    def normalize_email(cls, value: str) -> str:
        normalized = validate_email(value.strip(), check_deliverability=False).normalized.casefold()
        if len(normalized.encode("utf-8")) > 254:
            raise ValueError("Email is too long")
        return normalized


class RegisterRequest(LoginRequest):
    full_name: Annotated[str, Field(min_length=1, max_length=120)]
    password: Annotated[SecretStr, Field(min_length=15, max_length=128)]

    @field_validator("full_name", mode="before")
    @classmethod
    def trim_name(cls, value):
        if isinstance(value, str):
            return value.strip()
        return value


class RefreshRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    refresh_token: Annotated[SecretStr, Field(min_length=1, max_length=128)]


class UserResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    full_name: str
    email: str
    created_at: UtcTimestamp
    updated_at: UtcTimestamp


class TokenResponse(BaseModel):
    access_token: str
    refresh_token: str
    token_type: Literal["bearer"] = "bearer"
    expires_in: int
    refresh_expires_at: UtcTimestamp
