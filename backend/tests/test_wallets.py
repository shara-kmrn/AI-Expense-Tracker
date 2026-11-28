from argparse import Namespace
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Barrier
from uuid import uuid4

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import func, select, text, update
from sqlalchemy.exc import IntegrityError

from app.auth.models import User
from app.categories.models import Category
from app.wallets.models import Wallet
from test_authentication import (
    account, assert_unauthorized, bearer, context, login, register,
)

URL = "/api/v1/wallets"
DRAFT = dict(name="Personal Cash", type="CASH", currency="LKR", opening_balance="0",
             icon="wallet", color="#d4af37")


def authenticate(ctx, suffix="wallet"):
    client = ctx[0]
    data = account(ctx, suffix)
    assert register(client, data).status_code == 201
    result = login(client, data)
    assert result.status_code == 200
    return data, bearer(result.json()["access_token"])


def create(client, headers, **override):
    return client.post(URL, headers=headers, json={**DRAFT, **override})


def test_exact_summary_list_and_storage(context):
    client, _, engine, _ = context
    _, owner = authenticate(context)
    _, other = authenticate(context, "other")
    empty = client.get(f"{URL}/summary", headers=owner).json()
    assert empty == dict(currency="LKR", total_active_balance="0.00", active_count=0,
                         archived_count=0, balances_by_type={"CASH": "0.00", "BANK": "0.00", "DIGITAL": "0.00"})
    balances = {"CASH": "9999999999999999.99", "BANK": "9999999999999999.99", "DIGITAL": "0.02"}
    for kind, amount in balances.items():
        result = create(client, owner, name=f"{kind} 100%", type=kind, opening_balance=amount)
        assert result.status_code == 201
        row = result.json()
        assert row["current_balance"] == row["opening_balance"] == amount
        assert row["color"] == "#D4AF37"
    assert create(client, other, name="BANK 100%", type="BANK").status_code == 201
    inactive = create(client, owner, name="Empty").json()
    assert client.delete(f"{URL}/{inactive['id']}", headers=owner).status_code == 204
    response = client.get(URL, headers=owner, params={"limit": 1, "q": "１００%", "type": "BANK"})
    assert response.status_code == 200
    assert [item["name"] for item in response.json()["items"]] == ["BANK 100%"]
    first = client.get(URL, headers=owner, params={"limit": 1}).json()
    second = client.get(URL, headers=owner, params={"limit": 1, "offset": first["next_offset"]}).json()
    assert first["items"][0]["id"] != second["items"][0]["id"]
    summary = client.get(f"{URL}/summary", headers=owner)
    assert summary.headers["cache-control"] == "no-store"
    assert summary.json() == dict(currency="LKR", total_active_balance="20000000000000000.00",
                                  active_count=3, archived_count=1, balances_by_type=balances)
    assert client.get(f"{URL}/summary", headers=other).json()["active_count"] == 1
    assert client.get(URL, headers=other).json()["items"][0]["current_balance"] == "0.00"
    with engine.connect() as conn:
        from decimal import Decimal
        assert conn.execute(select(Wallet.current_balance).where(
            Wallet.name == "CASH 100%")).scalar_one() == Decimal("9999999999999999.99")


@pytest.mark.parametrize("field,value", [
    ("opening_balance", "-0.01"), ("opening_balance", "1.001"),
    ("opening_balance", "NaN"), ("opening_balance", "Infinity"), ("opening_balance", "1e2"),
    ("opening_balance", 15), ("opening_balance", "+1"), ("opening_balance", " 1 "),
    ("opening_balance", "10000000000000000"), ("currency", "USD"), ("type", "cash"),
    ("name", " "), ("name", "A\u202eB"), ("icon", "unknown"), ("color", "#ABC"),
    ("current_balance", "5.00"), ("is_active", False), ("user_id", str(uuid4())),
])
def test_invalid_create_leaves_no_partial_wallet(context, field, value):
    client = context[0]
    _, owner = authenticate(context)
    assert create(client, owner, **{field: value}).status_code == 422
    assert client.get(URL, headers=owner).json()["items"] == []


def test_lifecycle_conflicts_and_account_cascade(context):
    client, _, engine, _ = context
    data, owner = authenticate(context)
    _, other = authenticate(context, "other")
    zero = create(client, owner).json()
    funded = create(client, owner, name="Savings", opening_balance="1.2").json()
    path = f"{URL}/{zero['id']}"
    balance_path = f"{URL}/{funded['id']}"
    assert client.delete(balance_path, headers=owner).status_code == 409
    assert client.get(balance_path, headers=owner).json()["current_balance"] == "1.20"
    assert create(client, owner, name="ＰＥＲＳＯＮＡＬ   cash", type="BANK").status_code == 409
    for field, value in {"type": "BANK", "currency": "LKR", "opening_balance": "0.00",
                         "current_balance": "0.00", "user_id": str(uuid4()), "is_active": False,
                         "created_at": "2026-01-01T00:00:00Z"}.items():
        assert client.patch(path, headers=owner, json={field: value}).status_code == 422
    renamed = client.patch(path, headers=owner, json={"name": "Daily Cash", "icon": "home"})
    assert renamed.status_code == 200
    for _ in range(2):
        assert client.delete(path, headers=owner).status_code == 204
    assert client.get(URL, headers=owner, params={"active": False}).json()["items"][0]["id"] == zero["id"]
    assert create(client, owner, name="Daily Cash").status_code == 409
    assert client.patch(path, headers=owner, json={"name": "Hidden"}).status_code == 409
    for _ in range(2):
        restored = client.post(f"{path}/restore", headers=owner).json()
        assert restored["is_active"] and restored["id"] == zero["id"]
        assert restored["name"] == "Daily Cash"
    assert client.get(URL, headers=other).json()["items"] == []
    for method, suffix, body in [("GET", "", None), ("PATCH", "", {"name": "Foreign"}),
                                  ("DELETE", "", None), ("POST", "/restore", None)]:
        foreign = client.request(method, path + suffix, headers=other, json=body)
        missing = client.request(method, f"{URL}/{uuid4()}{suffix}", headers=other, json=body)
        assert (foreign.status_code, foreign.json()) == (404, missing.json())
        assert missing.status_code == 404
    with engine.connect() as conn:
        owner_id = conn.execute(select(User.id).where(User.email == data["email"])).scalar_one()
        assert conn.execute(select(func.count()).select_from(Category).where(Category.user_id == owner_id)).scalar_one() == 16
    assert client.request("DELETE", "/api/v1/users/me", headers=owner,
                          json={"current_password": data["password"]}).status_code == 204
    with engine.connect() as conn:
        for model in (Wallet, Category):
            assert conn.execute(select(func.count()).select_from(model).where(model.user_id == owner_id)).scalar_one() == 0
    assert_unauthorized(client.get(f"{URL}/summary", headers=owner))


def test_concurrent_creation_and_revoked_access(context):
    client = context[0]
    _, owner = authenticate(context)
    barrier = Barrier(2)

    def submit(kind):
        barrier.wait(timeout=10)
        return create(client, owner, type=kind).status_code

    with ThreadPoolExecutor(max_workers=2) as pool:
        assert sorted(pool.map(submit, ["BANK", "DIGITAL"])) == [201, 409]
    assert len(client.get(URL, headers=owner).json()["items"]) == 1
    assert_unauthorized(client.get(URL))
    assert client.post("/api/v1/auth/logout", headers=owner).status_code == 204
    assert_unauthorized(client.get(URL, headers=owner))


def test_migration_roundtrip_preserves_account_and_categories(context):
    client, _, engine, _ = context
    data, owner = authenticate(context)
    config = Config(str(Path(__file__).resolve().parents[1] / "alembic.ini"))
    config.cmd_opts = Namespace(x=["target=test"])
    with engine.connect() as conn, conn.begin():
        assert tuple(conn.execute(text("SELECT current_database(), current_user")).one()) == (
            "expense_tracker_test", "expense_tracker_test_app",
        )
        config.attributes["connection"] = conn
        user = conn.execute(select(User.id).where(User.email == data["email"])).scalar_one()
        category_ids = select(Category.id).where(Category.user_id == user)
        original = set(conn.execute(category_ids).scalars())
        command.downgrade(config, "0004")
        assert conn.execute(text("SELECT to_regclass('wallets')")).scalar_one() is None
        command.upgrade(config, "0005")
        assert conn.execute(select(User.id).where(User.id == user)).scalar_one() == user
        assert set(conn.execute(category_ids).scalars()) == original
        values = dict(id=uuid4(), user_id=user, name="Constraint proof", normalized_name="constraint proof",
                      type="CASH", currency="LKR", opening_balance=0, current_balance=0,
                      icon="wallet", color="#D4AF37")
        conn.execute(Wallet.__table__.insert().values(**values))
        for override in [{"opening_balance": -1}, {"current_balance": -1}, {"current_balance": "NaN"},
                         {"is_active": False, "current_balance": 1}, {"user_id": uuid4()},
                         {"currency": "USD"}, {"type": "INVALID"}]:
            with pytest.raises(IntegrityError), conn.begin_nested():
                conn.execute(update(Wallet).where(Wallet.id == values["id"]).values(**override))
        conn.rollback()
    assert client.get("/api/v1/categories", headers=owner).status_code == 200
