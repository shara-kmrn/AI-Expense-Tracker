from pathlib import Path
from typing import Annotated
from urllib.parse import urlsplit

from pydantic import AfterValidator
from pydantic_settings import BaseSettings, SettingsConfigDict


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
        extra="ignore",
    )

    app_name: str = "AI-Powered Personal Expense Tracker API"
    app_version: str = "0.1.0"
    cors_origins: tuple[Annotated[str, AfterValidator(validate_origin)], ...] = ()
