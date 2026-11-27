from argparse import Namespace
from datetime import UTC, datetime, timedelta
from functools import partial
from pathlib import Path
from unittest.mock import MagicMock

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import inspect, select, text, update
from sqlalchemy.exc import SQLAlchemyError

from app.auth import account
from app.auth.models import PasswordResetToken, RefreshSession, User
from app.auth.recovery import smtp_delivery
from app.auth.tokens import digest_token
from app.core.config import Settings
from test_authentication import account as registration
from test_authentication import bearer, concurrently, context, login, me, refresh, register

AUTH = "/api/v1/auth"
ME = "/api/v1/users/me"
NEW_PASSWORD = "A different synthetic password Ω"


def create_account(context, suffix="user"):
    data = registration(context, suffix)
    assert register(context[0], data).status_code == 201
    return data, login(context[0], data).json()


def forgot(client, email):
    return client.post(f"{AUTH}/forgot-password", json={"email": email})


def reset(client, token, password=NEW_PASSWORD):
    return client.post(f"{AUTH}/reset-password", json={"reset_token": token, "new_password": password})


def change(client, tokens, current, new=NEW_PASSWORD):
    return client.post(
        f"{AUTH}/change-password", headers=bearer(tokens["access_token"]),
        json={"current_password": current, "new_password": new},
    )


def remove(client, tokens, password):
    return client.request(
        "DELETE", ME, headers=bearer(tokens["access_token"]), json={"current_password": password}
    )


@pytest.fixture
def emails(context):
    delivery = MagicMock()
    context[1].state.recovery_delivery = delivery
    return delivery


def token_from(delivery):
    return delivery.call_args.args[1]


def test_profile_update_is_private_and_sanitized(context):
    client = context[0]
    first, tokens = create_account(context)
    second, other_tokens = create_account(context, "other")
    before = me(client, tokens["access_token"]).json()
    headers = bearer(tokens["access_token"])
    assert client.patch(ME, json={"full_name": "Changed"}).status_code == 401
    for fields in ({"full_name": "  "}, {"full_name": "x" * 121}, {"email": second["email"]},
                   {"full_name": "Changed", "active": False}):
        response = client.patch(ME, json=fields, headers=headers)
        assert response.status_code == 422 and response.json() == {"detail": "Invalid request"}
    response = client.patch(ME, json={"full_name": "  Changed Ω "}, headers=headers)
    assert response.status_code == 200 and response.headers["cache-control"] == "no-store"
    profile = response.json()
    assert profile["full_name"] == "Changed Ω"
    assert profile["email"] == first["email"]
    assert profile["updated_at"] > before["updated_at"]
    assert set(profile) == set(before)
    assert me(client, other_tokens["access_token"]).json()["full_name"] == "Example User"


def test_change_revokes_every_session_and_reset_token(context, emails):
    client = context[0]
    data, first = create_account(context)
    second = login(client, data).json()
    _, other = create_account(context, "other")
    assert forgot(client, data["email"]).status_code == 202
    recovery = token_from(emails)
    assert change(client, first, "wrong").status_code == 400
    assert change(client, first, data["password"], "short").status_code == 422
    assert change(client, first, data["password"], data["password"]).status_code == 400
    response = change(client, first, data["password"])
    assert response.status_code == 204 and response.content == b""
    assert response.headers["cache-control"] == "no-store"
    for tokens in (first, second):
        assert me(client, tokens["access_token"]).status_code == 401
        assert refresh(client, tokens["refresh_token"]).status_code == 401
    assert login(client, data).status_code == 401
    assert login(client, {**data, "password": NEW_PASSWORD}).status_code == 200
    assert reset(client, recovery).status_code == 400
    assert me(client, other["access_token"]).status_code == 200


@pytest.mark.parametrize("operation", ["login", "refresh"])
def test_change_cannot_leave_stale_credentials_usable(context, operation):
    client = context[0]
    data, tokens = create_account(context)
    actions = iter([
        lambda: change(client, tokens, data["password"]),
        lambda: login(client, data) if operation == "login" else refresh(client, tokens["refresh_token"]),
    ])
    responses = concurrently(lambda: next(actions)())
    assert any(response.status_code == 204 for response in responses)
    for response in responses:
        if response.status_code == 200:
            issued = response.json()
            assert me(client, issued["access_token"]).status_code == 401
            assert refresh(client, issued["refresh_token"]).status_code == 401
        else:
            assert response.status_code in (204, 401)


def test_forgot_generic_delivery_digest_and_account_limit(context, emails):
    client, _, engine, _ = context
    active, _ = create_account(context)
    inactive, _ = create_account(context, "inactive")
    with engine.begin() as conn:
        conn.execute(update(User).where(User.email == inactive["email"]).values(active=False))
    unknown = registration(context, "unknown")["email"]
    responses = [forgot(client, email) for email in (unknown, inactive["email"], active["email"].upper())]
    assert {response.status_code for response in responses} == {202}
    assert len({response.content for response in responses}) == 1
    assert all(response.headers["cache-control"] == "no-store" for response in responses)
    emails.assert_called_once()
    recipient, first, lifetime = emails.call_args.args
    assert recipient == active["email"] and len(first) == 43 and lifetime == 15
    assert all(first not in response.text for response in responses)
    assert forgot(client, active["email"]).status_code == 202
    second = token_from(emails)
    with engine.connect() as conn:
        records = dict(conn.execute(select(PasswordResetToken.token_digest, PasswordResetToken.revoked_at)).all())
    assert records[digest_token(first)] is not None
    assert records[digest_token(second)] is None
    assert first not in records and second not in records
    assert reset(client, first).status_code == 400
    for _ in range(2):
        assert forgot(client, active["email"]).status_code == 202
    assert emails.call_count == 3


def test_concurrent_forgot_leaves_one_usable_token(context, emails):
    client, _, engine, _ = context
    data, _ = create_account(context)
    assert all(r.status_code == 202 for r in concurrently(lambda: forgot(client, data["email"])))
    assert emails.call_count == 2
    with engine.connect() as conn:
        active = conn.execute(
            select(PasswordResetToken.token_digest)
            .join(User)
            .where(User.email == data["email"], PasswordResetToken.revoked_at.is_(None))
        ).scalar_one()
    codes = [call.args[1] for call in emails.call_args_list]
    assert active in {digest_token(code) for code in codes}
    assert reset(client, next(code for code in codes if digest_token(code) == active)).status_code == 204


def test_delivery_failure_does_not_disclose_data(context, emails, caplog):
    client = context[0]
    data, _ = create_account(context)
    emails.side_effect = RuntimeError("synthetic provider credential")
    assert forgot(client, data["email"]).status_code == 202
    assert "Password recovery could not be completed" in caplog.text
    assert "synthetic provider credential" not in caplog.text
    assert token_from(emails) not in caplog.text
    assert data["email"] not in caplog.text


def test_smtp_missing_config_is_rejected_safely():
    with pytest.raises(ValueError, match="SMTP is unconfigured"):
        smtp_delivery(Settings(_env_file=None, SMTP_HOST=None), "recipient@example.com", "fixture", 15)


def test_forgot_without_smtp_stays_generic(context, caplog):
    client, app, _, _ = context
    data, _ = create_account(context)
    app.state.recovery_delivery = partial(smtp_delivery, Settings(_env_file=None, SMTP_HOST=None))
    known = forgot(client, data["email"])
    unknown = forgot(client, registration(context, "unknown")["email"])
    assert known.status_code == unknown.status_code == 202 and known.content == unknown.content
    assert "Password recovery could not be completed" in caplog.text
    assert data["email"] not in caplog.text


def test_delivery_runs_after_database_transaction(context, emails):
    client, _, engine, _ = context
    data, _ = create_account(context)
    observed = []

    def check_committed(recipient, token, lifetime):
        with engine.begin() as conn:
            user_id = conn.execute(
                select(User.id).where(User.email == recipient).with_for_update(nowait=True)
            ).scalar_one()
            observed.append(conn.execute(select(PasswordResetToken.id).where(
                PasswordResetToken.user_id == user_id,
                PasswordResetToken.token_digest == digest_token(token),
            )).scalar_one())

    emails.side_effect = check_committed
    assert forgot(client, data["email"]).status_code == 202
    assert len(observed) == 1


@pytest.mark.parametrize("security,constructor", [("starttls", "SMTP"), ("tls", "SMTP_SSL")])
def test_smtp_uses_authenticated_verified_tls(monkeypatch, security, constructor):
    connect = MagicMock()
    monkeypatch.setattr(f"app.auth.recovery.smtplib.{constructor}", connect)
    config = Settings(
        _env_file=None, SMTP_HOST="smtp.example.com", SMTP_PORT=587, SMTP_USERNAME="fixture",
        SMTP_PASSWORD="fixture", SMTP_FROM_EMAIL="sender@example.com", SMTP_SECURITY=security,
    )
    smtp_delivery(config, "recipient@example.com", "fixture-code", 15)
    connection = connect.return_value
    assert connect.call_args.kwargs["timeout"] == 5
    tls_context = (
        connection.starttls.call_args.kwargs["context"] if security == "starttls"
        else connect.call_args.kwargs["context"]
    )
    assert tls_context.check_hostname
    assert [call[0] for call in connection.method_calls if call[0] in {"starttls", "login", "send_message"}] == (
        ["starttls", "login", "send_message"] if security == "starttls" else ["login", "send_message"]
    )


def test_reset_single_use_expiry_and_revocation(context, emails):
    client, _, engine, _ = context
    data, old = create_account(context)
    assert reset(client, "bad").status_code == 400
    assert forgot(client, data["email"]).status_code == 202
    expired = token_from(emails)
    with engine.begin() as conn:
        conn.execute(update(PasswordResetToken).where(
            PasswordResetToken.token_digest == digest_token(expired)
        ).values(expires_at=datetime.now(UTC) - timedelta(seconds=1)))
    assert reset(client, expired).status_code == 400
    assert forgot(client, data["email"]).status_code == 202
    token = token_from(emails)
    response = reset(client, token, "short")
    assert response.status_code == 422 and token not in response.text
    results = concurrently(lambda: reset(client, token))
    assert sorted(r.status_code for r in results) == [204, 400]
    assert reset(client, token).status_code == 400
    assert me(client, old["access_token"]).status_code == 401
    assert refresh(client, old["refresh_token"]).status_code == 401
    assert login(client, data).status_code == 401
    assert login(client, {**data, "password": NEW_PASSWORD}).status_code == 200


def test_failed_reset_rolls_back_password_token_and_sessions(context, emails, monkeypatch):
    client = context[0]
    data, tokens = create_account(context)
    assert forgot(client, data["email"]).status_code == 202
    token = token_from(emails)
    with monkeypatch.context() as patch:
        patch.setattr(account, "revoke_reset_tokens", MagicMock(side_effect=SQLAlchemyError("fixture")))
        response = reset(client, token)
        assert response.status_code == 503 and token not in response.text
    assert me(client, tokens["access_token"]).status_code == 200
    assert login(client, data).status_code == 200
    assert reset(client, token).status_code == 204


def test_account_deletion_cascades_without_touching_other_users(context, emails):
    client, _, engine, _ = context
    data, tokens = create_account(context)
    _, other = create_account(context, "other")
    assert forgot(client, data["email"]).status_code == 202
    recovery = token_from(emails)
    assert client.request("DELETE", ME, json={"current_password": data["password"]}).status_code == 401
    assert remove(client, tokens, "wrong").status_code == 400
    with engine.connect() as conn:
        user_id = conn.execute(select(User.id).where(User.email == data["email"])).scalar_one()
    outcome = iter([
        lambda: remove(client, tokens, data["password"]),
        lambda: refresh(client, tokens["refresh_token"]),
    ])
    responses = concurrently(lambda: next(outcome)())
    assert any(r.status_code == 204 and not r.content for r in responses)
    for response in responses:
        if response.status_code == 200:
            assert me(client, response.json()["access_token"]).status_code == 401
        else:
            assert response.status_code in (204, 401)
    assert login(client, data).status_code == 401
    assert me(client, tokens["access_token"]).status_code == 401
    assert refresh(client, tokens["refresh_token"]).status_code == 401
    assert reset(client, recovery).status_code == 400
    assert me(client, other["access_token"]).status_code == 200
    with engine.connect() as conn:
        assert conn.execute(select(RefreshSession.id).where(RefreshSession.user_id == user_id)).first() is None
        assert conn.execute(select(PasswordResetToken.id).where(PasswordResetToken.user_id == user_id)).first() is None


def test_migration_roundtrip_preserves_authentication_tables(context):
    engine = context[2]
    config = Config(str(Path(__file__).resolve().parents[1] / "alembic.ini"))
    config.cmd_opts = Namespace(x=["target=test"])
    with engine.connect() as conn, conn.begin():
        assert tuple(conn.execute(text("SELECT current_database(), current_user")).one()) == (
            "expense_tracker_test", "expense_tracker_test_app"
        )
        config.attributes["connection"] = conn
        try:
            command.downgrade(config, "0002")
            assert not inspect(conn).has_table("password_reset_tokens")
            assert inspect(conn).has_table("users") and inspect(conn).has_table("refresh_sessions")
            command.upgrade(config, "0003")
            assert inspect(conn).has_table("password_reset_tokens")
        finally:
            conn.rollback()
