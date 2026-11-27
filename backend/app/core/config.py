from pathlib import Path
from typing import Annotated, Literal
from urllib.parse import urlsplit

from pydantic import AfterValidator, Field, SecretStr, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict
from sqlalchemy.engine import make_url
from sqlalchemy.exc import ArgumentError


def validate_origin(value: str) -> str:
    origin = urlsplit(value)
    if (
        origin.scheme not in {"http", "https"}
        or not origin.hostname
        or origin.username is not None
        or origin.port == 0
        or origin.netloc.endswith(":")
        or "\\" in value
        or "*" in value
        or any(character.isspace() for character in value)
        or value != f"{origin.scheme}://{origin.netloc}"
    ):
        raise ValueError("Use an explicit HTTP(S) origin with no path")
    return value


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="EXPENSE_TRACKER_",
        env_file=Path(__file__).resolve().parents[2] / ".env",
        env_file_encoding="utf-8",
        hide_input_in_errors=True,
        extra="ignore",
    )

    app_name: str = "AI-Powered Personal Expense Tracker API"
    app_version: str = "0.1.0"
    cors_origins: tuple[Annotated[str, AfterValidator(validate_origin)], ...] = ()
    jwt_secret: SecretStr | None = None
    jwt_issuer: str = Field(default="expense-tracker-api", min_length=1)
    jwt_audience: str = Field(default="expense-tracker-android", min_length=1)
    access_token_minutes: int = Field(default=15, ge=1, le=60)
    refresh_session_days: int = Field(default=7, ge=1, le=30)
    smtp_host: str | None = Field(default=None, validation_alias="SMTP_HOST")
    smtp_port: int = Field(default=587, ge=1, le=65535, validation_alias="SMTP_PORT")
    smtp_username: str | None = Field(default=None, validation_alias="SMTP_USERNAME")
    smtp_password: SecretStr | None = Field(default=None, validation_alias="SMTP_PASSWORD")
    smtp_from_email: str | None = Field(default=None, validation_alias="SMTP_FROM_EMAIL")
    smtp_security: Literal["starttls", "tls"] = Field(default="starttls", validation_alias="SMTP_SECURITY")
    smtp_timeout_seconds: float = Field(default=5, gt=0, le=30, validation_alias="SMTP_TIMEOUT_SECONDS")
    reset_token_minutes: int = Field(
        default=15, ge=1, le=60, validation_alias="PASSWORD_RESET_TOKEN_EXPIRE_MINUTES"
    )
    database_url: SecretStr | None = Field(default=None, validation_alias="DATABASE_URL")
    test_database_url: SecretStr | None = Field(
        default=None, validation_alias="TEST_DATABASE_URL"
    )

    @field_validator("database_url", "test_database_url")
    @classmethod
    def validate_database_url(cls, value: SecretStr | None) -> SecretStr | None:
        if value is None:
            return None
        try:
            url = make_url(value.get_secret_value())
            if (
                url.drivername == "postgresql+psycopg"
                and url.username
                and url.username.casefold() != "postgres"
                and url.password
                and url.host
                and url.database
                and (url.port is None or 1 <= url.port <= 65535)
                and not url.query.keys() - {"sslmode"}
                and isinstance(url.query.get("sslmode", ""), str)
            ):
                return value
        except (ArgumentError, ValueError):
            pass
        raise ValueError("Use a postgresql+psycopg URL with an application role, host and database")
