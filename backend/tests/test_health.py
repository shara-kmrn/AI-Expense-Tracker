import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError

from app.core.config import Settings
from app.main import create_app


@pytest.fixture
def client():
    settings = Settings(_env_file=None, app_version="0.1.0", cors_origins=())
    with TestClient(create_app(settings)) as test_client:
        yield test_client


def test_health(client):
    response = client.get("/api/v1/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok", "version": "0.1.0"}


@pytest.mark.parametrize("path", ["/health", "/api/v2/health", "/api/v1/missing"])
def test_unknown_route(client, path):
    assert client.get(path).status_code == 404


@pytest.mark.parametrize("path, title", [("/docs", "Swagger UI"), ("/redoc", "ReDoc")])
def test_documentation(client, path, title):
    response = client.get(path)
    assert response.status_code == 200
    assert title in response.text


def test_openapi(client):
    response = client.get("/openapi.json")
    assert response.status_code == 200
    schema = response.json()
    assert schema["info"]["version"] == "0.1.0"
    assert "get" in schema["paths"]["/api/v1/health"]


def test_cors_is_disabled_by_default(client):
    response = client.get("/api/v1/health", headers={"Origin": "http://localhost:5173"})
    assert "access-control-allow-origin" not in response.headers


def test_cors_allows_only_configured_origins(monkeypatch):
    allowed = "http://localhost:5173"
    monkeypatch.setenv("EXPENSE_TRACKER_CORS_ORIGINS", '["http://localhost:5173"]')
    with TestClient(create_app(Settings(_env_file=None))) as client:
        headers = {"Origin": allowed, "Access-Control-Request-Method": "GET"}
        response = client.options("/api/v1/health", headers=headers)
        assert response.status_code == 200
        assert response.headers["access-control-allow-origin"] == allowed

        response = client.get("/api/v1/health", headers={"Origin": "http://localhost:5174"})
        assert "access-control-allow-origin" not in response.headers


@pytest.mark.parametrize(
    "origin",
    ["*", "https://*.example.com", "http://localhost/path", "http://localhost:", "http://localhost\\other"],
)
def test_cors_rejects_invalid_origins(origin):
    with pytest.raises(ValidationError):
        Settings(_env_file=None, cors_origins=(origin,))
