from datetime import UTC
from typing import Annotated, Literal
from uuid import UUID

from email_validator import validate_email
from pydantic import AfterValidator, AwareDatetime, BaseModel, ConfigDict, Field, SecretStr, field_validator

UtcTimestamp = Annotated[AwareDatetime, AfterValidator(lambda value: value.astimezone(UTC))]


def normalize_full_name(value: str) -> str:
    value = value.strip()
    if "\x00" in value:
        raise ValueError("Invalid full name")
    return value


FullName = Annotated[str, Field(min_length=1, max_length=120)]
NewPassword = Annotated[SecretStr, Field(min_length=15, max_length=128)]
CurrentPassword = Annotated[SecretStr, Field(min_length=1, max_length=128)]


class EmailRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    email: Annotated[str, Field(min_length=1, max_length=254)]

    @field_validator("email")
    @classmethod
    def normalize_email(cls, value: str) -> str:
        normalized = validate_email(value.strip(), check_deliverability=False).normalized.casefold()
        if len(normalized.encode("utf-8")) > 254:
            raise ValueError("Email is too long")
        return normalized


class LoginRequest(EmailRequest):
    password: CurrentPassword


class ProfileUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)

    full_name: FullName

    _normalize_name = field_validator("full_name")(normalize_full_name)


class RegisterRequest(LoginRequest):
    full_name: FullName
    password: NewPassword

    @field_validator("full_name", mode="before")
    @classmethod
    def trim_name(cls, value):
        if isinstance(value, str):
            return normalize_full_name(value)
        return value


class CurrentPasswordRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    current_password: CurrentPassword


class ChangePasswordRequest(CurrentPasswordRequest):
    new_password: NewPassword


class ResetPasswordRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    reset_token: Annotated[SecretStr, Field(min_length=1, max_length=128)]
    new_password: NewPassword


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
