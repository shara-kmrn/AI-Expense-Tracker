from argparse import Namespace
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Barrier
from uuid import uuid4

import pytest
from alembic import command
from alembic.config import Config
from alembic.util import CommandError
from sqlalchemy import func, select, update
from sqlalchemy.exc import IntegrityError, SQLAlchemyError

from app.auth.models import User
from app.incomes.models import Income, IncomeCreation
from app.financial import service
from app.wallets.models import Wallet
from test_authentication import assert_unauthorized, context
from test_wallets import authenticate, create as create_wallet

URL = "/api/v1/incomes"


def setup(context, suffix="income", opening="10.01"):
    client = context[0]
    account, headers = authenticate(context, suffix)
    wallet = create_wallet(client, headers, opening_balance=opening).json()["id"]
    category = client.get("/api/v1/categories", params={"type": "INCOME"}, headers=headers).json()["items"][0]["id"]
    return account, headers, dict(title="Salary 100%", amount="5.02", currency="LKR", wallet_id=wallet,
                                  category_id=category, income_date="2024-02-29", note="February credit")


def post(client, headers, draft, key=None):
    return client.post(URL, headers={**headers, "Idempotency-Key": str(key or uuid4())}, json=draft)


def balance(client, headers, wallet):
    return client.get(f"/api/v1/wallets/{wallet}", headers=headers).json()["current_balance"]


def test_financial_lifecycle_isolation_and_replay(context):
    client, _, engine, _ = context
    account, owner, draft = setup(context)
    _, other, foreign = setup(context, "other")
    source = draft["wallet_id"]
    target = create_wallet(client, owner, name="Bank", type="BANK", opening_balance="0").json()["id"]
    key = uuid4()
    created = post(client, owner, draft, key)
    assert created.status_code == 201
    original = created.json()
    record = f"{URL}/{original['id']}"
    assert balance(client, owner, source) == "15.03"
    assert post(client, owner, {**draft, "amount": "05.02"}, key).json() == original
    assert post(client, owner, {**draft, "amount": "5.03"}, key).status_code == 409
    assert balance(client, owner, source) == "15.03"
    for field in ("wallet_id", "category_id"):
        assert post(client, owner, {**draft, field: foreign[field]}).status_code == 404
    assert client.get(record, headers=other).status_code == 404
    assert client.patch(record, headers=other, json={"title": "Other", "expected_version": 1}).status_code == 404
    assert client.delete(record, headers={**other, "If-Match": "1"}).status_code == 404
    assert client.get(URL, headers=other).json()["items"] == []
    assert client.get(f"{URL}/summary?year=2024&month=2", headers=other).json()["total"] == "0.00"
    changed = client.patch(record, headers=owner, json={"amount": "5.12", "expected_version": 1}).json()
    assert changed["version"] == 2
    assert balance(client, owner, source) == "15.13"
    moved = client.patch(record, headers=owner, json={"amount": "4.99", "wallet_id": target, "expected_version": 2}).json()
    assert moved["version"] == 3
    assert balance(client, owner, source) == "10.01"
    assert balance(client, owner, target) == "4.99"
    assert post(client, owner, draft, key).json() == original
    assert client.patch(record, headers=owner, json={"title": "Stale", "expected_version": 1}).status_code == 409
    assert client.delete(record, headers={**owner, "If-Match": "2"}).status_code == 409
    history = client.get(URL, headers=owner, params={"date_from": "2024-02-29", "date_to": "2024-02-29",
                         "q": "CREDIT", "category_id": draft["category_id"], "wallet_id": target}).json()
    assert history["items"] == [moved]
    summary = client.get(f"{URL}/summary?year=2024&month=2", headers=owner).json()
    assert (summary["count"], summary["total"], summary["categories"][0]["total"]) == (1, "4.99", "4.99")
    assert client.get(f"{URL}/summary?year=2024&month=3", headers=owner).json()["total"] == "0.00"
    for _ in range(2):
        assert client.delete(record, headers={**owner, "If-Match": "3"}).status_code == 204
        assert balance(client, owner, target) == "0.00"
    assert client.get(record, headers=owner).status_code == 404
    assert client.get(f"{URL}/summary?year=2024&month=2", headers=owner).json()["count"] == 0
    assert post(client, owner, draft, key).json() == original
    with engine.connect() as conn:
        owner_id = conn.scalar(select(User.id).where(User.email == account["email"]))
    assert client.request("DELETE", "/api/v1/users/me", headers=owner,
                          json={"current_password": account["password"]}).status_code == 204
    with engine.connect() as conn:
        for model in (Income, IncomeCreation, Wallet):
            assert conn.scalar(select(func.count()).select_from(model).where(model.user_id == owner_id)) == 0
    assert_unauthorized(client.get(URL, headers=owner))


@pytest.mark.parametrize("override", [
    {"amount": "0"}, {"amount": "-1"}, {"amount": "1.001"}, {"amount": "NaN"}, {"amount": "Infinity"},
    {"amount": "1e2"}, {"amount": 1}, {"amount": "10000000000000000"}, {"currency": "USD"},
    {"income_date": "2024-02-30"}, {"income_date": "9999-01-01"}, {"income_date": "2024-2-9"},
    {"title": " "}, {"title": "x" * 121}, {"note": "x" * 1001}, {"version": 3},
])
def test_invalid_create_leaves_balances_unchanged(context, override):
    client = context[0]
    _, owner, draft = setup(context)
    assert post(client, owner, {**draft, **override}).status_code == 422
    assert client.get(URL, headers=owner).json()["items"] == []
    assert balance(client, owner, draft["wallet_id"]) == "10.01"


def test_historical_references_balance_conflicts_and_large_aggregates(context):
    client, _, engine, _ = context
    _, owner, draft = setup(context, opening="0")
    custom = client.post("/api/v1/categories", headers=owner, json={
        "name": "Custom", "type": "INCOME", "icon": "wallet", "color": "#D4AF37",
    }).json()["id"]
    expense = client.get("/api/v1/categories", params={"type": "EXPENSE"}, headers=owner).json()["items"][0]["id"]
    first = {**draft, "category_id": custom, "amount": "9999999999999999.99"}
    created = post(client, owner, first)
    assert created.status_code == 201
    item = created.json()
    assert client.delete(f"/api/v1/categories/{custom}", headers=owner).status_code == 204
    assert post(client, owner, first).status_code == 409
    assert post(client, owner, {**draft, "category_id": expense}).status_code == 409
    assert post(client, owner, draft).status_code == 409
    record = f"{URL}/{item['id']}"
    assert client.patch(record, headers=owner, json={"note": None, "expected_version": 1}).json()["category_active"] is False
    second = create_wallet(client, owner, name="Second").json()["id"]
    assert post(client, owner, {**draft, "wallet_id": second, "amount": "9999999999999999.99"}).status_code == 201
    assert client.get(URL, headers=owner, params={"limit": 1}).json()["next_offset"] == 1
    totals = client.get(f"{URL}/summary?year=2024&month=2", headers=owner).json()
    assert totals["total"] == "19999999999999999.98"
    assert len(totals["categories"]) == 2
    assert client.patch(record, headers=owner, json={"wallet_id": second, "expected_version": 2}).status_code == 409
    assert balance(client, owner, draft["wallet_id"]) == "9999999999999999.99"
    assert balance(client, owner, second) == "9999999999999999.99"
    # Represent a future intervening debit to exercise insufficient-balance rollback.
    with engine.begin() as conn:
        conn.execute(update(Wallet).where(Wallet.id == item["wallet_id"]).values(current_balance=0))
    assert client.delete(record, headers={**owner, "If-Match": "2"}).status_code == 409
    assert client.get(record, headers=owner).json()["version"] == 2
    assert client.delete(f"/api/v1/wallets/{item['wallet_id']}", headers=owner).status_code == 204
    assert client.get(record, headers=owner).json()["wallet_active"] is False
    assert post(client, owner, draft).status_code == 409


def test_concurrent_creation_and_edit_delete(context):
    client = context[0]
    _, owner, draft = setup(context, opening="0")
    key = uuid4()

    def race(functions):
        gate = Barrier(len(functions))
        def worker(function):
            gate.wait(timeout=10)
            return function()
        with ThreadPoolExecutor(max_workers=len(functions)) as pool:
            return list(pool.map(worker, functions))

    first, second = race([lambda: post(client, owner, draft, key)] * 2)
    assert first.status_code == second.status_code == 201
    assert first.json() == second.json()
    assert balance(client, owner, draft["wallet_id"]) == "5.02"
    assert [r.status_code for r in race([lambda: post(client, owner, draft)] * 2)] == [201, 201]
    assert balance(client, owner, draft["wallet_id"]) == "15.06"
    path = f"{URL}/{first.json()['id']}"
    edit, delete = race([
        lambda: client.patch(path, headers=owner, json={"amount": "4.00", "expected_version": 1}),
        lambda: client.delete(path, headers={**owner, "If-Match": "1"}),
    ])
    assert (edit.status_code, delete.status_code) in {(200, 409), (404, 204)}
    assert balance(client, owner, draft["wallet_id"]) == ("14.04" if edit.status_code == 200 else "10.04")


def test_migration_round_trip_and_populated_downgrade_guard(context):
    client, _, engine, _ = context
    _, owner, draft = setup(context)
    config = Config(str(Path(__file__).resolve().parents[1] / "alembic.ini"))
    config.cmd_opts = Namespace(x=["target=test"])
    with engine.connect() as conn, conn.begin():
        config.attributes["connection"] = conn
        command.downgrade(config, "0005")
        command.upgrade(config, "0006")
        conn.rollback()
    assert balance(client, owner, draft["wallet_id"]) == "10.01"
    assert post(client, owner, draft).status_code == 201
    with engine.connect() as conn, conn.begin():
        config.attributes["connection"] = conn
        with pytest.raises(CommandError, match="Financial reconciliation"):
            command.downgrade(config, "0005")
        conn.rollback()
    assert balance(client, owner, draft["wallet_id"]) == "15.03"


def test_creation_rolls_back_when_persisting_replay_fails(context, monkeypatch):
    client = context[0]
    _, owner, draft = setup(context)
    key = uuid4()

    def fail_after_flush(*_):
        raise SQLAlchemyError("Synthetic database failure after flush")

    with monkeypatch.context() as patch:
        patch.setattr(service, "update", fail_after_flush)
        response = post(client, owner, draft, key)
        assert response.status_code == 503
        assert "Synthetic" not in response.text
    assert balance(client, owner, draft["wallet_id"]) == "10.01"
    assert client.get(URL, headers=owner).json()["items"] == []
    assert post(client, owner, draft, key).status_code == 201
    assert balance(client, owner, draft["wallet_id"]) == "15.03"


def test_database_rejects_cross_owner_references(context):
    client, _, engine, _ = context
    account, owner, draft = setup(context)
    _, _, foreign = setup(context, "other")
    assert post(client, owner, draft).status_code == 201
    with engine.connect() as conn, conn.begin():
        owner_id = conn.scalar(select(User.id).where(User.email == account["email"]))
        for field in ("wallet_id", "category_id"):
            with pytest.raises(IntegrityError), conn.begin_nested():
                conn.execute(update(Income).where(Income.user_id == owner_id).values(**{field: foreign[field]}))
                conn.exec_driver_sql("SET CONSTRAINTS ALL IMMEDIATE")
        conn.rollback()


def test_wallet_and_category_archive_races(context):
    client = context[0]
    _, owner, draft = setup(context, opening="0")
    category = client.post("/api/v1/categories", headers=owner, json={
        "name": "Side work", "type": "INCOME", "icon": "wallet", "color": "#D4AF37",
    }).json()["id"]

    def race(archive_path, data):
        gate = Barrier(2)
        def archive():
            gate.wait(timeout=10)
            return client.delete(archive_path, headers=owner).status_code
        def credit():
            gate.wait(timeout=10)
            return post(client, owner, data).status_code
        with ThreadPoolExecutor(max_workers=2) as pool:
            left, right = pool.submit(archive), pool.submit(credit)
            return left.result(), right.result()

    wallet = draft["wallet_id"]
    archived, credited = race(f"/api/v1/wallets/{wallet}", draft)
    assert (archived, credited) in {(204, 409), (409, 201)}
    assert balance(client, owner, wallet) == ("5.02" if credited == 201 else "0.00")
    if archived == 204:
        assert client.post(f"/api/v1/wallets/{wallet}/restore", headers=owner).status_code == 200
    response = race(f"/api/v1/categories/{category}", {**draft, "category_id": category})
    assert response in {(204, 201), (204, 409)}


def test_opposing_wallet_reassignments_reconcile(context):
    client, _, engine, _ = context
    account, owner, draft = setup(context)
    left = draft["wallet_id"]
    right = create_wallet(client, owner, name="Destination", opening_balance="3.01").json()["id"]
    first = post(client, owner, draft).json()
    second = post(client, owner, {**draft, "wallet_id": right, "amount": "1.51"}).json()
    start = Barrier(2)

    def move(record, target):
        start.wait(timeout=10)
        return client.patch(f"{URL}/{record['id']}", headers=owner,
                            json={"wallet_id": target, "expected_version": record["version"]})

    with ThreadPoolExecutor(max_workers=2) as pool:
        outbound, inbound = pool.submit(move, first, right), pool.submit(move, second, left)
        assert outbound.result().status_code == inbound.result().status_code == 200

    assert balance(client, owner, left) == "11.52"
    assert balance(client, owner, right) == "8.03"
    credited = select(func.coalesce(func.sum(Income.amount), 0)).where(
        Income.user_id == Wallet.user_id, Income.wallet_id == Wallet.id, Income.deleted_at.is_(None),
    ).correlate(Wallet).scalar_subquery()
    with engine.connect() as conn:
        owner_id = conn.scalar(select(User.id).where(User.email == account["email"]))
        discrepancies = conn.scalar(select(func.count()).select_from(Wallet).where(
            Wallet.user_id == owner_id, Wallet.current_balance != Wallet.opening_balance + credited,
        ))
    assert discrepancies == 0
