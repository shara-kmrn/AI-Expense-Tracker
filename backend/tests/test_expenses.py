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
from app.expenses.models import Expense, ExpenseCreation
from app.financial import service
from app.financial.reconciliation import wallet_discrepancies
from app.incomes.models import Income, IncomeCreation
from test_authentication import assert_unauthorized, context
from test_incomes import balance, post as income_post, setup as income_setup
from test_wallets import create as create_wallet

URL = "/api/v1/expenses"


def setup(context, suffix="expenses", opening="0"):
    account, headers, income = income_setup(context, suffix, opening)
    client = context[0]
    categories = client.get("/api/v1/categories", headers=headers, params={"type": "EXPENSE"}).json()["items"]
    assert len(categories) == 10
    expense = {**income, "category_id": categories[0]["id"]}
    expense["expense_date"] = expense.pop("income_date")
    expense.update(title="Food 100%", note="Leap day groceries", amount="5.02")
    return account, headers, income, expense


def post(client, headers, draft, key=None):
    return client.post(URL, headers={**headers, "Idempotency-Key": str(key or uuid4())}, json=draft)


def remove(client, headers, path, version):
    return client.delete(path, headers={**headers, "If-Match": str(version)})


def summary(client, headers, period, date="2024-02-29"):
    return client.get(f"{URL}/summary", headers=headers, params={"period": period, "date": date}).json()


def race(*actions):
    barrier = Barrier(len(actions))
    def call(action):
        barrier.wait(timeout=10)
        return action()
    with ThreadPoolExecutor(max_workers=len(actions)) as pool:
        return list(pool.map(call, actions))


def test_mixed_lifecycle_summary_and_account_cascade(context):
    client, _, engine, _ = context
    account, owner, income, draft = setup(context)
    _, other, _, foreign = setup(context, "foreign")
    left = draft["wallet_id"]
    right = create_wallet(client, owner, name="Second", opening_balance="7.01").json()["id"]
    key = uuid4()
    posted_income = income_post(client, owner, {**income, "amount": "15.03"}, key)
    assert posted_income.status_code == 201
    income_path = f"/api/v1/incomes/{posted_income.json()['id']}"
    assert balance(client, owner, left) == "15.03"
    created = post(client, owner, draft, key)
    assert created.status_code == 201
    original = created.json()
    path = f"{URL}/{original['id']}"
    assert balance(client, owner, left) == "10.01"
    assert post(client, owner, {**draft, "amount": "05.02"}, key).json() == original
    assert post(client, owner, {**draft, "amount": "5.03"}, key).status_code == 409
    assert post(client, owner, {**draft, "amount": "10.02"}).status_code == 409
    assert remove(client, owner, income_path, 1).status_code == 409
    assert client.patch(income_path, headers=owner, json={"amount": "5.01", "expected_version": 1}).status_code == 409
    for field in ("category_id", "wallet_id"):
        assert post(client, owner, {**draft, field: foreign[field]}).status_code == 404
    assert post(client, owner, {**draft, "category_id": income["category_id"]}).status_code == 409
    assert client.get(path, headers=other).status_code == 404
    assert client.patch(path, headers=other, json={"title": "Foreign", "expected_version": 1}).status_code == 404
    assert remove(client, other, path, 1).status_code == 404
    assert summary(client, other, "month")["total"] == "0.00"
    assert client.get(URL, headers=other).json()["items"] == []
    assert client.patch(path, headers=owner, json={"note": None, "expected_version": 1}).json()["version"] == 2
    assert balance(client, owner, left) == "10.01"
    assert client.patch(path, headers=owner, json={"amount": "6.12", "expected_version": 2}).json()["version"] == 3
    assert balance(client, owner, left) == "8.91"
    moved = client.patch(path, headers=owner, json={"wallet_id": right, "amount": "1.02", "expected_version": 3})
    assert moved.status_code == 200
    assert balance(client, owner, left) == "15.03"
    assert balance(client, owner, right) == "5.99"
    assert post(client, owner, draft, key).json() == original
    for period, start, end in [("day", "2024-02-29", "2024-02-29"),
                               ("week", "2024-02-26", "2024-03-03"),
                               ("month", "2024-02-01", "2024-02-29")]:
        totals = summary(client, owner, period)
        assert (totals["start_date"], totals["end_date"], totals["total"], totals["count"]) == (start, end, "1.02", 1)
        assert totals["categories"][0]["total"] == "1.02"
    response = client.get(URL, headers=owner, params={"q": "100%", "date_from": "2024-02-29",
                          "date_to": "2024-02-29", "category_id": draft["category_id"], "wallet_id": right})
    assert response.json()["items"] == [moved.json()]
    assert remove(client, owner, path, 3).status_code == 409
    for _ in range(2):
        assert remove(client, owner, path, 4).status_code == 204
        assert balance(client, owner, right) == "7.01"
    assert client.get(path, headers=owner).status_code == 404
    assert summary(client, owner, "month")["count"] == 0
    assert post(client, owner, draft, key).json() == original
    assert remove(client, owner, income_path, 1).status_code == 204
    assert balance(client, owner, left) == "0.00"
    with engine.connect() as conn:
        assert wallet_discrepancies(conn) == 0
        owner_id = conn.scalar(select(User.id).where(User.email == account["email"]))
    assert client.request("DELETE", "/api/v1/users/me", headers=owner,
                          json={"current_password": account["password"]}).status_code == 204
    with engine.connect() as conn:
        for model in (Expense, ExpenseCreation, Income, IncomeCreation):
            assert conn.scalar(select(func.count()).select_from(model).where(model.user_id == owner_id)) == 0
    assert_unauthorized(client.get(URL, headers=owner))


@pytest.mark.parametrize("overrides", [
    {"amount": "0"}, {"amount": "-1"}, {"amount": "1.001"}, {"amount": "NaN"}, {"amount": "Infinity"},
    {"amount": "1e2"}, {"amount": 2}, {"amount": "10000000000000000"}, {"currency": "USD"},
    {"expense_date": "2024-02-30"}, {"expense_date": "9999-01-01"}, {"title": " "},
    {"title": "x" * 121}, {"note": "x" * 1001}, {"version": 1},
])
def test_invalid_expense_leaves_wallet_unchanged(context, overrides):
    client = context[0]
    _, owner, _, draft = setup(context, opening="10")
    assert post(client, owner, {**draft, **overrides}).status_code == 422
    assert balance(client, owner, draft["wallet_id"]) == "10.00"
    assert client.get(URL, headers=owner).json()["items"] == []


def test_archived_references_and_oversized_refund(context):
    client = context[0]
    _, owner, income, draft = setup(context, opening="1")
    wallet = draft["wallet_id"]
    category = client.post("/api/v1/categories", headers=owner, json={
        "name": "Groceries", "type": "EXPENSE", "icon": "wallet", "color": "#D4AF37",
    }).json()["id"]
    draft = {**draft, "amount": "1", "category_id": category}
    row = post(client, owner, draft).json()
    path = f"{URL}/{row['id']}"
    assert balance(client, owner, wallet) == "0.00"
    assert client.delete(f"/api/v1/wallets/{wallet}", headers=owner).status_code == 204
    assert client.delete(f"/api/v1/categories/{category}", headers=owner).status_code == 204
    assert client.patch(path, headers=owner, json={"title": "Historical", "expected_version": 1}).status_code == 200
    assert summary(client, owner, "month")["total"] == "1.00"
    assert post(client, owner, draft).status_code == 409
    assert remove(client, owner, path, 2).status_code == 409
    assert client.get(path, headers=owner).json()["version"] == 2
    assert client.post(f"/api/v1/wallets/{wallet}/restore", headers=owner).status_code == 200
    assert income_post(client, owner, {**income, "amount": "9999999999999999.99"}).status_code == 201
    assert remove(client, owner, path, 2).status_code == 409
    assert client.patch(path, headers=owner, json={"amount": "0.50", "expected_version": 2}).status_code == 409
    assert balance(client, owner, wallet) == "9999999999999999.99"
    assert client.get(path, headers=owner).json()["amount"] == "1.00"


def test_concurrent_expenses_and_credits_are_serialized(context):
    client, _, engine, _ = context
    _, owner, income, draft = setup(context, opening="5")
    wallet = draft["wallet_id"]
    draft["amount"] = "4"
    key = uuid4()
    first, second = race(lambda: post(client, owner, draft, key), lambda: post(client, owner, draft, key))
    assert first.status_code == second.status_code == 201
    assert first.json() == second.json()
    assert balance(client, owner, wallet) == "1.00"
    funded = create_wallet(client, owner, name="Funded", opening_balance="5").json()["id"]
    spend = {**draft, "wallet_id": funded}
    result = race(lambda: post(client, owner, spend), lambda: post(client, owner, spend))
    assert sorted(row.status_code for row in result) == [201, 409]
    assert balance(client, owner, funded) == "1.00"
    credit, debit = race(lambda: income_post(client, owner, {**income, "amount": "3"}),
                         lambda: post(client, owner, {**draft, "amount": "1"}))
    assert credit.status_code == debit.status_code == 201
    assert balance(client, owner, wallet) == "3.00"
    path = f"{URL}/{first.json()['id']}"
    edit, deleted = race(lambda: client.patch(path, headers=owner, json={"amount": "2", "expected_version": 1}),
                         lambda: remove(client, owner, path, 1))
    assert (edit.status_code, deleted.status_code) in {(200, 409), (404, 204)}
    with engine.connect() as conn:
        assert wallet_discrepancies(conn) == 0


def test_atomic_failure_after_flush_and_large_exact_periods(context, monkeypatch):
    client, _, engine, _ = context
    _, owner, _, draft = setup(context, opening="9999999999999999.99")
    wallet = draft["wallet_id"]
    key = uuid4()
    def fail(*_):
        raise SQLAlchemyError("Synthetic failure after flush")
    with monkeypatch.context() as patch:
        patch.setattr(service, "update", fail)
        result = post(client, owner, draft, key)
        assert result.status_code == 503
        assert "Synthetic failure" not in result.text
    assert balance(client, owner, wallet) == "9999999999999999.99"
    target = create_wallet(client, owner, name="Second", opening_balance="9999999999999999.99").json()["id"]
    amount = "9999999999999999.99"
    assert post(client, owner, {**draft, "amount": amount}, key).status_code == 201
    assert post(client, owner, {**draft, "wallet_id": target, "amount": amount, "expense_date": "2024-03-01"}).status_code == 201
    assert summary(client, owner, "week")["total"] == "19999999999999999.98"
    assert summary(client, owner, "month")["total"] == amount
    assert summary(client, owner, "day", "2024-02-28")["count"] == 0
    first = client.get(URL, headers=owner, params={"limit": 1}).json()
    assert first["items"][0]["expense_date"] == "2024-03-01"
    assert first["next_offset"] == 1
    with engine.connect() as conn:
        assert wallet_discrepancies(conn) == 0


def test_migration_preserves_income_and_blocks_populated_expense_downgrade(context):
    client, _, engine, _ = context
    _, owner, income, draft = setup(context, opening="10")
    original = income_post(client, owner, income)
    assert original.status_code == 201
    config = Config(str(Path(__file__).resolve().parents[1] / "alembic.ini"))
    config.cmd_opts = Namespace(x=["target=test"])
    with engine.connect() as conn, conn.begin():
        config.attributes["connection"] = conn
        command.downgrade(config, "0006")
        command.upgrade(config, "0007")
        assert conn.scalar(select(func.count()).select_from(Income)) == 1
        assert conn.scalar(select(func.count()).select_from(IncomeCreation)) == 1
        assert wallet_discrepancies(conn) == 0
        conn.rollback()
    assert balance(client, owner, draft["wallet_id"]) == "15.02"
    assert post(client, owner, draft).status_code == 201
    with engine.connect() as conn, conn.begin():
        config.attributes["connection"] = conn
        with pytest.raises(CommandError, match="Financial reconciliation"):
            command.downgrade(config, "0006")
        conn.rollback()
    assert balance(client, owner, draft["wallet_id"]) == "10.00"


def test_concurrent_archival_and_database_ownership(context):
    client, _, engine, _ = context
    _, owner, _, draft = setup(context, opening="5")
    _, _, _, foreign = setup(context, "foreign")
    category = client.post("/api/v1/categories", headers=owner, json={
        "name": "Archived race", "type": "EXPENSE", "icon": "wallet", "color": "#D4AF37",
    }).json()["id"]
    wallet = draft["wallet_id"]
    archived, expense = race(
        lambda: client.delete(f"/api/v1/categories/{category}", headers=owner),
        lambda: post(client, owner, {**draft, "amount": "1.00", "category_id": category}),
    )
    assert archived.status_code == 204
    assert expense.status_code in {201, 409}
    assert balance(client, owner, wallet) == ("4.00" if expense.status_code == 201 else "5.00")
    empty = create_wallet(client, owner, name="Empty").json()["id"]
    archived, unfunded = race(
        lambda: client.delete(f"/api/v1/wallets/{empty}", headers=owner),
        lambda: post(client, owner, {**draft, "wallet_id": empty, "amount": "1.00"}),
    )
    assert (archived.status_code, unfunded.status_code) == (204, 409)
    item = post(client, owner, {**draft, "amount": "1.00"}).json()
    with engine.connect() as conn, conn.begin():
        for field in ("wallet_id", "category_id"):
            with pytest.raises(IntegrityError), conn.begin_nested():
                conn.execute(update(Expense).where(Expense.id == item["id"]).values(**{field: foreign[field]}))
                conn.exec_driver_sql("SET CONSTRAINTS ALL IMMEDIATE")
        assert wallet_discrepancies(conn) == 0
        conn.rollback()


def test_opposing_moves_and_insufficient_destination_rollback(context):
    client, _, engine, _ = context
    _, owner, _, draft = setup(context, opening="10")
    source = draft["wallet_id"]
    target = create_wallet(client, owner, name="Other", opening_balance="10").json()["id"]
    one = post(client, owner, {**draft, "amount": "2.00"}).json()
    two = post(client, owner, {**draft, "wallet_id": target, "amount": "3.00"}).json()

    def move(record, wallet_id, **extra):
        return client.patch(f"{URL}/{record['id']}", headers=owner,
                            json={"wallet_id": wallet_id, "expected_version": record["version"], **extra})

    assert move(one, target, amount="7.01").status_code == 409
    assert balance(client, owner, source) == "8.00"
    assert balance(client, owner, target) == "7.00"
    first, second = race(lambda: move(one, target), lambda: move(two, source))
    assert first.status_code == second.status_code == 200
    assert balance(client, owner, source) == "7.00"
    assert balance(client, owner, target) == "8.00"
    with engine.connect() as conn:
        assert wallet_discrepancies(conn) == 0
