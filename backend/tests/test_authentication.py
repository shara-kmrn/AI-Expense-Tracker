from argparse import Namespace
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
from pathlib import Path
from secrets import token_urlsafe
from threading import Barrier
from uuid import uuid4

import jwt
import pytest
from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
from sqlalchemy import delete, inspect, select, text, update

from app.auth.dependencies import AuthLimiter
from app.auth.models import RefreshSession, User
from app.auth.passwords import verify_password
from app.auth.tokens import digest_token
from app.core.config import Settings
from app.db.session import build_engine
from app.main import create_app

API = "/api/v1"
PASSWORD = "A synthetic passphrase with spaces and Ω"
TEST_KEY = token_urlsafe(48)


@pytest.fixture
def context():
    config = Settings()
    assert config.test_database_url is not None, "Authentication integration requires TEST_DATABASE_URL"
    settings = Settings(
        _env_file=None, DATABASE_URL=config.test_database_url, jwt_secret=TEST_KEY
    )
    engine = build_engine(settings.database_url)
    prefix = f"auth-test-{uuid4().hex}"
    verified = False
    try:
        with engine.connect() as conn:
            identity = conn.execute(text("SELECT current_database(), current_user")).one()
            assert tuple(identity) == ("expense_tracker_test", "expense_tracker_test_app")
            assert conn.execute(text("SELECT version_num FROM alembic_version")).scalar_one() == "0003"
            verified = True
        app = create_app(settings)
        with TestClient(app) as client:
            yield client, app, engine, prefix
    finally:
        try:
            if verified:
                with engine.begin() as conn:
                    conn.execute(delete(User).where(User.email.startswith(prefix)))
        finally:
            engine.dispose()


def account(context, suffix="user"):
    return {
        "email": f"{context[3]}-{suffix}@example.com",
        "full_name": "  Example User  ",
        "password": PASSWORD,
    }


def register(client, data):
    return client.post(f"{API}/auth/register", json=data)


def login(client, data):
    return client.post(f"{API}/auth/login", json={key: data[key] for key in ("email", "password")})


def refresh(client, token):
    return client.post(f"{API}/auth/refresh", json={"refresh_token": token})


def bearer(token):
    return {"Authorization": f"Bearer {token}"}


def me(client, token):
    return client.get(f"{API}/users/me", headers=bearer(token))


def assert_unauthorized(response):
    assert response.status_code == 401
    assert response.json() == {"detail": "Invalid authentication credentials"}
    assert response.headers["www-authenticate"] == "Bearer"
    assert response.headers["cache-control"] == "no-store"


def test_registration_normalizes_and_hashes(context):
    client, _, engine, _ = context
    data = account(context)
    response = register(client, {**data, "email": data["email"].upper()})
    assert response.status_code == 201
    profile = response.json()
    assert profile["email"] == data["email"]
    assert profile["full_name"] == "Example User"
    assert set(profile) == {"id", "full_name", "email", "created_at", "updated_at"}
    assert response.headers["cache-control"] == "no-store"
    with engine.connect() as conn:
        stored = conn.execute(select(User.password_hash).where(User.email == data["email"])).scalar_one()
        assert stored.startswith("$argon2id$")
        assert PASSWORD not in stored and verify_password(PASSWORD, stored)[0]
        assert conn.execute(select(RefreshSession.id).join(User).where(User.email == data["email"])).first() is None
    assert register(client, data).status_code == 409
    assert login(client, {**data, "email": data["email"].upper()}).status_code == 200


@pytest.mark.parametrize("change", [
    {"password": "short"}, {"password": "x" * 129}, {"email": "bad"},
    {"full_name": "   "}, {"unknown": "synthetic private input"},
])
def test_invalid_registration_does_not_echo_input(context, change):
    response = register(context[0], {**account(context), **change})
    assert response.status_code == 422 and response.json() == {"detail": "Invalid request"}


def test_long_unicode_passphrase_is_not_truncated(context):
    client = context[0]
    data = {**account(context), "password": "Ω" * 127 + " "}
    assert register(client, data).status_code == 201
    assert login(client, data).status_code == 200
    assert_unauthorized(login(client, {**data, "password": "Ω" * 127 + "x"}))


def concurrently(action):
    start = Barrier(2)

    def run():
        start.wait(timeout=5)
        return action()

    with ThreadPoolExecutor(max_workers=2) as pool:
        calls = [pool.submit(run) for _ in range(2)]
        return [call.result(timeout=10) for call in calls]


def test_concurrent_duplicate_registration(context):
    client = context[0]
    data = account(context)
    assert sorted(r.status_code for r in concurrently(lambda: register(client, data))) == [201, 409]


def test_invalid_and_inactive_login(context):
    client, _, engine, _ = context
    data = account(context)
    assert_unauthorized(login(client, data))
    assert register(client, data).status_code == 201
    assert_unauthorized(login(client, {**data, "password": "wrong"}))
    with engine.begin() as conn:
        conn.execute(update(User).where(User.email == data["email"]).values(active=False))
    assert_unauthorized(login(client, data))


def test_me_isolated_and_refresh_digest_only(context):
    client, _, engine, _ = context
    first, second = account(context, "first"), account(context, "second")
    for data in (first, second):
        assert register(client, data).status_code == 201
    assert_unauthorized(client.get(f"{API}/users/me"))
    for data in (first, second):
        response = login(client, data)
        assert response.status_code == 200 and response.headers["cache-control"] == "no-store"
        tokens = response.json()
        result = me(client, tokens["access_token"])
        assert result.status_code == 200 and result.json()["email"] == data["email"]
        assert set(tokens) == {"access_token", "refresh_token", "token_type", "expires_in", "refresh_expires_at"}
        with engine.connect() as conn:
            stored = conn.execute(
                select(RefreshSession.token_digest).join(User).where(User.email == data["email"])
            ).scalar_one()
        assert stored == digest_token(tokens["refresh_token"])


@pytest.mark.parametrize("change", ["signature", "expired", "type", "issuer", "audience", "missing", "algorithm"])
def test_access_token_claim_rejections(context, change):
    client = context[0]
    data = account(context)
    assert register(client, data).status_code == 201
    access = login(client, data).json()["access_token"]
    claims = jwt.decode(access, options={"verify_signature": False})
    key, algorithm = TEST_KEY, "HS256"
    if change == "signature":
        key = token_urlsafe(48)
    elif change == "algorithm":
        algorithm = "HS384"
    elif change == "expired":
        claims["iat"], claims["exp"] = 1, 2
    elif change == "missing":
        del claims["jti"]
    else:
        claims[{"type": "type", "issuer": "iss", "audience": "aud"}[change]] = "invalid"
    assert_unauthorized(me(client, jwt.encode(claims, key, algorithm=algorithm)))


def test_rotation_reuse_revokes_family(context):
    client = context[0]
    data = account(context)
    assert register(client, data).status_code == 201
    first = login(client, data).json()
    response = refresh(client, first["refresh_token"])
    assert response.status_code == 200
    second = response.json()
    assert second["refresh_token"] != first["refresh_token"]
    assert second["refresh_expires_at"] == first["refresh_expires_at"]
    assert_unauthorized(refresh(client, first["refresh_token"]))
    assert_unauthorized(refresh(client, second["refresh_token"]))
    assert_unauthorized(me(client, first["access_token"]))
    assert_unauthorized(me(client, second["access_token"]))


def test_concurrent_refresh_has_only_one_successor(context):
    client, _, engine, _ = context
    data = account(context)
    assert register(client, data).status_code == 201
    first = login(client, data).json()
    results = concurrently(lambda: refresh(client, first["refresh_token"]))
    assert sorted(r.status_code for r in results) == [200, 401]
    successor = next(r.json() for r in results if r.status_code == 200)
    assert_unauthorized(refresh(client, successor["refresh_token"]))
    with engine.connect() as conn:
        assert len(conn.execute(
            select(RefreshSession.id).join(User).where(User.email == data["email"])
        ).all()) == 2


def test_expired_session_rejects_refresh_and_access(context):
    client, _, engine, _ = context
    data = account(context)
    assert register(client, data).status_code == 201
    tokens = login(client, data).json()
    with engine.begin() as conn:
        conn.execute(update(RefreshSession).where(
            RefreshSession.token_digest == digest_token(tokens["refresh_token"])
        ).values(expires_at=datetime.now(UTC) - timedelta(seconds=1)))
    assert_unauthorized(refresh(client, tokens["refresh_token"]))
    assert_unauthorized(me(client, tokens["access_token"]))


def test_logout_is_idempotent_and_session_scoped(context):
    client = context[0]
    data = account(context)
    assert register(client, data).status_code == 201
    first, second = login(client, data).json(), login(client, data).json()
    for _ in range(2):
        response = client.post(f"{API}/auth/logout", headers=bearer(first["access_token"]))
        assert response.status_code == 204 and response.content == b""
    assert_unauthorized(me(client, first["access_token"]))
    assert_unauthorized(refresh(client, first["refresh_token"]))
    assert me(client, second["access_token"]).status_code == 200


def test_missing_secret_preserves_health_and_limiter_is_bounded():
    settings = Settings(_env_file=None, jwt_secret=None, DATABASE_URL=None, TEST_DATABASE_URL=None)
    app = create_app(settings)
    app.state.auth_limiter = AuthLimiter(limit=1, capacity=1)
    with TestClient(app) as client:
        assert client.get(f"{API}/health").status_code == 200
        assert register(client, {}).status_code == 503
        assert register(client, {}).status_code == 429
    assert not app.state.auth_limiter.allow("another-source")


def test_authentication_migration_roundtrip(context):
    engine = context[2]
    config = Config(str(Path(__file__).resolve().parents[1] / "alembic.ini"))
    config.cmd_opts = Namespace(x=["target=test"])
    with engine.connect() as conn, conn.begin():
        identity = conn.execute(text("SELECT current_database(), current_user")).one()
        assert tuple(identity) == ("expense_tracker_test", "expense_tracker_test_app")
        config.attributes["connection"] = conn
        try:
            command.downgrade(config, "0001")
            assert not inspect(conn).has_table("users")
            assert not inspect(conn).has_table("refresh_sessions")
            command.upgrade(config, "0002")
            assert inspect(conn).has_table("users")
            assert inspect(conn).has_table("refresh_sessions")
        finally:
            conn.rollback()
