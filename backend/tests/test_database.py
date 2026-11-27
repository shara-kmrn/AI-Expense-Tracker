from unittest.mock import MagicMock

import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError
from sqlalchemy.exc import OperationalError

from app.core.config import Settings
from app.db.session import build_engine, session_scope
from app.main import create_app


@pytest.mark.parametrize(
    "value",
    [
        "not-a-url",
        "postgresql://app:placeholder@localhost/example",
        "postgresql+psycopg://postgres:placeholder@localhost/example",
        "postgresql+psycopg://app@localhost/example",
        "postgresql+psycopg://app:placeholder@localhost/example?dbname=other",
    ],
)
def test_invalid_database_url_is_redacted(value):
    with pytest.raises(ValidationError) as error:
        Settings(_env_file=None, DATABASE_URL=value)
    assert value not in str(error.value)


def test_engine_is_lazy_and_uses_decoded_credentials():
    settings = Settings(
        _env_file=None,
        DATABASE_URL="postgresql+psycopg://app:a%40b%3A%25@localhost:5433/example",
    )
    engine = build_engine(settings.database_url)
    try:
        assert engine.url.password == "a@b:%"
        assert "a@b:%" not in repr(engine)
        assert engine.pool.timeout() == 5
        assert engine.hide_parameters is True
        assert engine.pool._pre_ping is True
        assert engine.pool.checkedout() == 0
    finally:
        engine.dispose()


def test_session_is_closed_on_error():
    factory = MagicMock()
    session_context = factory.return_value
    with pytest.raises(RuntimeError):
        with session_scope(factory):
            raise RuntimeError("test failure")
    assert session_context.__exit__.call_args.args[0] is RuntimeError
    session_context.__enter__.return_value.commit.assert_not_called()


@pytest.fixture
def app():
    return create_app(Settings(_env_file=None, DATABASE_URL=None))


def test_missing_database_configuration_keeps_liveness_available(app):
    with TestClient(app) as client:
        assert client.get("/api/v1/health").status_code == 200
        response = client.get("/api/v1/health/ready")
        assert response.status_code == 503
        assert response.json() == {"status": "unavailable"}
        assert "/api/v1/health/ready" in client.get("/openapi.json").json()["paths"]


def test_readiness_success_releases_session(app):
    factory = MagicMock()
    app.state.session_factory = factory
    session = factory.return_value.__enter__.return_value
    with TestClient(app) as client:
        response = client.get("/api/v1/health/ready")
    assert response.status_code == 200
    assert response.json() == {"status": "ready"}
    assert str(session.execute.call_args.args[0]) == "SELECT 1"
    factory.return_value.__exit__.assert_called_once_with(None, None, None)
    session.commit.assert_not_called()


def test_readiness_database_error_is_sanitized(app, caplog):
    factory = MagicMock()
    app.state.session_factory = factory
    session = factory.return_value.__enter__.return_value
    internal_message = "internal host db.internal and sensitive connection details"
    session.execute.side_effect = OperationalError(None, None, RuntimeError(internal_message))
    with TestClient(app) as client:
        response = client.get("/api/v1/health/ready")
    assert response.status_code == 503
    assert response.json() == {"status": "unavailable"}
    assert internal_message not in caplog.text
    factory.return_value.__exit__.assert_called_once()
