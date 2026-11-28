from argparse import Namespace
from pathlib import Path
from uuid import UUID, uuid4

import pytest
from alembic import command
from alembic.config import Config
from alembic.util import CommandError
from sqlalchemy import event, func, select, update
from sqlalchemy.exc import IntegrityError, SQLAlchemyError
from sqlalchemy.orm import Session

from app.auth.models import User
from app.financial import service as financial
from app.financial.reconciliation import wallet_discrepancies
from app.transfers.models import TransferReplay, WalletTransfer
from app.wallets.models import Wallet
from test_authentication import assert_unauthorized, context
from test_expenses import post as expense_post, race, setup as expense_setup
from test_incomes import balance, post as income_post
from test_wallets import create as create_wallet

URL = "/api/v1/transfers"


def setup(context, suffix="transfers", opening="100.00", destination="0"):
    account, headers, income, expense = expense_setup(context, suffix, opening)
    client = context[0]
    bank = create_wallet(client, headers, name="Bank", type="BANK", opening_balance=destination)
    digital = create_wallet(client, headers, name="Digital", type="DIGITAL")
    assert bank.status_code == digital.status_code == 201
    draft = dict(source_wallet_id=income["wallet_id"], destination_wallet_id=bank.json()["id"],
                 amount="10.02", currency="LKR", transfer_date="2024-02-29", note="Leap day 100%")
    return account, headers, income, expense, draft, digital.json()["id"]


def post(client, headers, draft, key=None):
    return client.post(URL, headers={**headers, "Idempotency-Key": str(key or uuid4())}, json=draft)


def reverse(client, headers, transfer_id, key=None, **body):
    return client.post(f"{URL}/{transfer_id}/reverse",
                       headers={**headers, "Idempotency-Key": str(key or uuid4())}, json=body)


def test_mixed_workflow_history_replay_and_account_deletion(context):
    client, _, engine, _ = context
    account, owner, income, expense, draft, digital = setup(context, destination="50")
    _, other, _, _, foreign, _ = setup(context, "foreign")
    cash, bank = draft["source_wallet_id"], draft["destination_wallet_id"]
    key = uuid4()
    assert income_post(client, owner, {**income, "wallet_id": bank, "amount": "20.02"}, key).status_code == 201
    assert expense_post(client, owner, {**expense, "wallet_id": bank, "amount": "5.03"}, key).status_code == 201
    summaries = ("/api/v1/incomes/summary?year=2024&month=2",
                 "/api/v1/expenses/summary?period=month&date=2024-02-29")
    before = [client.get(path, headers=owner).json() for path in summaries]
    assert balance(client, owner, bank) == "64.99"
    assert balance(client, owner, cash) == "100.00"
    bank_to_cash = dict(draft, source_wallet_id=bank, destination_wallet_id=cash)
    created = post(client, owner, bank_to_cash, key)
    assert created.status_code == 201
    original = created.json()
    assert (balance(client, owner, bank), balance(client, owner, cash)) == ("54.97", "110.02")
    assert post(client, owner, {**bank_to_cash, "amount": "010.02"}, key).json() == original
    assert post(client, owner, {**bank_to_cash, "amount": "10.03"}, key).status_code == 409
    assert post(client, owner, {**draft, "amount": "110.03"}).status_code == 409
    assert post(client, owner, {**draft, "destination_wallet_id": cash}).status_code == 422
    assert post(client, owner, {**draft, "destination_wallet_id": digital, "amount": "110.02"}).status_code == 201
    assert balance(client, owner, cash) == "0.00"
    assert balance(client, owner, digital) == "110.02"
    assert reverse(client, owner, original["id"]).status_code == 409
    assert post(client, owner, {**draft, "source_wallet_id": digital,
                               "destination_wallet_id": cash, "amount": "10.02"}).status_code == 201
    reversed_result = reverse(client, owner, original["id"], key, note="Correction")
    assert reversed_result.status_code == 201
    reversal = reversed_result.json()
    assert (reversal["source_wallet"]["id"], reversal["destination_wallet"]["id"]) == (cash, bank)
    assert reversal["reversal_of_id"] == original["id"]
    assert reversal["status"] == "reversal"
    detail_path = f"{URL}/{original['id']}"
    assert client.get(detail_path, headers=owner).json()["reversal_id"] == reversal["id"]
    assert client.get(detail_path, headers=owner).json()["status"] == "reversed"
    assert post(client, owner, bank_to_cash, key).json() == original
    assert reverse(client, owner, original["id"], key, note="Correction").json() == reversal
    assert reverse(client, owner, original["id"], key, note="Different").status_code == 409
    assert reverse(client, owner, original["id"]).status_code == 409
    assert reverse(client, owner, reversal["id"]).status_code == 409
    assert client.patch(detail_path, headers=owner, json={"amount": "5"}).status_code == 405
    assert client.delete(detail_path, headers=owner).status_code == 405
    assert (balance(client, owner, bank), balance(client, owner, cash), balance(client, owner, digital)) == (
        "64.99", "0.00", "100.00")
    assert [client.get(path, headers=owner).json() for path in summaries] == before
    first = client.get(URL, headers=owner, params={"limit": 1}).json()
    assert first["items"][0]["id"] == reversal["id"]
    assert first["next_offset"] == 1
    second = client.get(URL, headers=owner, params={"limit": 1, "offset": 1}).json()
    assert second["items"][0]["id"] != reversal["id"]
    for params in (
        {"wallet_id": bank, "q": "BANK"},
        {"source_wallet_id": bank, "destination_wallet_id": cash},
        {"date_from": "2024-02-29", "date_to": "2024-02-29", "q": "100%"},
        {"kind": "original"},
    ):
        assert original["id"] in [row["id"] for row in client.get(URL, headers=owner, params=params).json()["items"]]
    assert client.get(URL, headers=owner, params={"kind": "reversal"}).json()["items"] == [reversal]
    assert client.get(detail_path, headers=other).status_code == 404
    assert reverse(client, other, original["id"]).status_code == 404
    assert client.get(URL, headers=other).json()["items"] == []
    for field in ("source_wallet_id", "destination_wallet_id"):
        assert post(client, owner, {**draft, field: foreign[field]}).status_code == 404
    assert client.delete(f"/api/v1/wallets/{cash}", headers=owner).status_code == 204
    assert client.get(detail_path, headers=owner).json()["destination_wallet"]["is_active"] is False
    with engine.connect() as conn:
        owner_id = conn.scalar(select(User.id).where(User.email == account["email"]))
        assert wallet_discrepancies(conn) == 0
    assert client.request("DELETE", "/api/v1/users/me", headers=owner,
                          json={"current_password": account["password"]}).status_code == 204
    with engine.connect() as conn:
        for model in (WalletTransfer, TransferReplay):
            assert conn.scalar(select(func.count()).select_from(model).where(model.user_id == owner_id)) == 0
    assert_unauthorized(client.get(URL, headers=owner))


@pytest.mark.parametrize("overrides", [
    {"amount": "0"}, {"amount": "-1"}, {"amount": "1.001"}, {"amount": "NaN"}, {"amount": "Infinity"},
    {"amount": "1e2"}, {"amount": 2}, {"amount": "10000000000000000"}, {"currency": "USD"},
    {"transfer_date": "2024-02-30"}, {"transfer_date": "9999-01-01"}, {"note": "x" * 1001}, {"reversal_of_id": str(uuid4())},
])
def test_invalid_requests_leave_no_balance_change(context, overrides):
    client = context[0]
    _, owner, _, _, draft, _ = setup(context)
    assert post(client, owner, {**draft, **overrides}).status_code == 422
    assert balance(client, owner, draft["source_wallet_id"]) == "100.00"
    assert balance(client, owner, draft["destination_wallet_id"]) == "0.00"


def test_active_wallet_and_capacity_rules_for_both_directions(context):
    client = context[0]
    _, owner, income, _, draft, digital = setup(context, opening="10", destination="9999999999999999.99")
    source, dest = draft["source_wallet_id"], draft["destination_wallet_id"]
    assert post(client, owner, {**draft, "amount": "1"}).status_code == 409
    assert balance(client, owner, source) == "10.00"
    assert balance(client, owner, dest) == "9999999999999999.99"
    assert client.delete(f"/api/v1/wallets/{digital}", headers=owner).status_code == 204
    assert post(client, owner, {**draft, "destination_wallet_id": digital, "amount": "1"}).status_code == 409
    assert post(client, owner, {**draft, "source_wallet_id": digital, "amount": "1"}).status_code == 409
    assert client.post(f"/api/v1/wallets/{digital}/restore", headers=owner).status_code == 200
    original = post(client, owner, {**draft, "destination_wallet_id": digital, "amount": "10"}).json()
    assert client.delete(f"/api/v1/wallets/{source}", headers=owner).status_code == 204
    assert reverse(client, owner, original["id"]).status_code == 409
    assert reverse(client, owner, original["id"], amount="1").status_code == 422
    assert client.post(f"/api/v1/wallets/{source}/restore", headers=owner).status_code == 200
    assert income_post(client, owner, {**income, "amount": "9999999999999999.99"}).status_code == 201
    assert reverse(client, owner, original["id"]).status_code == 409
    assert balance(client, owner, digital) == "10.00"
    assert client.get(f"{URL}/{original['id']}", headers=owner).json()["status"] == "original"


def test_concurrent_replays_opposing_transfers_and_financial_limits(context):
    client, _, engine, _ = context
    _, owner, income, expense, draft, digital = setup(context, opening="5")
    source, dest = draft["source_wallet_id"], draft["destination_wallet_id"]
    request = {**draft, "amount": "4"}
    key = uuid4()
    first, repeat = race(lambda: post(client, owner, request, key), lambda: post(client, owner, request, key))
    assert first.status_code == repeat.status_code == 201
    assert first.json() == repeat.json()
    assert post(client, owner, request).status_code == 409
    assert balance(client, owner, source) == "1.00"
    left, right = race(lambda: reverse(client, owner, first.json()["id"]),
                       lambda: reverse(client, owner, first.json()["id"]))
    assert sorted([left.status_code, right.status_code]) == [201, 409]
    assert balance(client, owner, dest) == "0.00"
    assert balance(client, owner, source) == "5.00"
    split = race(lambda: post(client, owner, request), lambda: post(client, owner, {**request, "destination_wallet_id": digital}))
    assert sorted(row.status_code for row in split) == [201, 409]
    credit, debit = race(lambda: income_post(client, owner, {**income, "amount": "3"}),
                         lambda: post(client, owner, {**request, "amount": "1"}))
    assert credit.status_code == debit.status_code == 201
    spends = race(lambda: expense_post(client, owner, {**expense, "amount": "3"}),
                  lambda: post(client, owner, {**request, "amount": "3"}))
    assert sorted(row.status_code for row in spends) == [201, 409]
    funded = create_wallet(client, owner, name="Other", opening_balance="1").json()["id"]
    one, two = race(lambda: post(client, owner, {**request, "source_wallet_id": funded, "amount": "1"}),
                    lambda: post(client, owner, {**request, "source_wallet_id": dest,
                                                 "destination_wallet_id": funded, "amount": "1"}))
    assert one.status_code == two.status_code == 201
    with engine.connect() as conn:
        assert wallet_discrepancies(conn) == 0


def test_injected_failures_roll_back_creation_and_reversal(context, monkeypatch):
    client, _, engine, _ = context
    _, owner, _, _, draft, _ = setup(context)
    source, dest = draft["source_wallet_id"], draft["destination_wallet_id"]
    key = uuid4()

    def fail(*_):
        raise SQLAlchemyError("Synthetic failure after wallet changes")

    with monkeypatch.context() as patch:
        patch.setattr(financial, "persist_replay", fail)
        assert post(client, owner, draft, key).status_code == 503
    assert balance(client, owner, source) == "100.00"
    assert balance(client, owner, dest) == "0.00"
    assert client.get(URL, headers=owner).json()["items"] == []
    row = post(client, owner, draft, key).json()
    with monkeypatch.context() as patch:
        patch.setattr(financial, "persist_replay", fail)
        assert reverse(client, owner, row["id"], key).status_code == 503
    assert balance(client, owner, source) == "89.98"
    assert balance(client, owner, dest) == "10.02"
    assert client.get(f"{URL}/{row['id']}", headers=owner).json()["status"] == "original"
    assert reverse(client, owner, row["id"], key).status_code == 201
    with engine.connect() as conn:
        assert wallet_discrepancies(conn) == 0


def test_foreign_key_integrity_and_safe_migration_roundtrip(context):
    client, _, engine, _ = context
    _, owner, income, expense, draft, _ = setup(context)
    _, other, _, _, foreign, _ = setup(context, "foreign")
    assert income_post(client, owner, income).status_code == 201
    assert expense_post(client, owner, expense).status_code == 201
    key = uuid4()
    config = Config(str(Path(__file__).resolve().parents[1] / "alembic.ini"))
    config.cmd_opts = Namespace(x=["target=test"])
    with engine.connect() as conn, conn.begin():
        config.attributes["connection"] = conn
        command.downgrade(config, "0007")
        command.upgrade(config, "0008")
        assert wallet_discrepancies(conn) == 0
        conn.rollback()
    assert balance(client, owner, draft["source_wallet_id"]) == "100.00"
    row = post(client, owner, draft, key).json()
    foreign_row = post(client, other, foreign).json()
    with engine.connect() as conn, conn.begin():
        config.attributes["connection"] = conn
        for field, target in (("source_wallet_id", foreign["source_wallet_id"]),
                              ("destination_wallet_id", foreign["destination_wallet_id"]),
                              ("reversal_of_id", foreign_row["id"])):
            with pytest.raises(IntegrityError), conn.begin_nested():
                conn.execute(update(WalletTransfer).where(WalletTransfer.id == UUID(row["id"]))
                             .values(**{field: UUID(target)}))
                conn.exec_driver_sql("SET CONSTRAINTS ALL IMMEDIATE")
        with pytest.raises(CommandError, match="Financial reconciliation"):
            command.downgrade(config, "0007")
        conn.rollback()
    assert post(client, owner, draft, key).json() == row


@pytest.mark.parametrize("operation, failure", [
    ("create", "record"), ("create", "source"), ("create", "destination"),
    ("reverse", "record"), ("reverse", "source"), ("reverse", "destination"),
])
def test_constraint_failures_leave_both_wallets_and_history_unchanged(context, operation, failure):
    client, _, engine, _ = context
    _, owner, _, _, draft, _ = setup(context)
    source, dest = draft["source_wallet_id"], draft["destination_wallet_id"]
    key = uuid4()
    original = post(client, owner, draft).json() if operation == "reverse" else None
    expected = (balance(client, owner, source), balance(client, owner, dest))
    before = client.get(URL, headers=owner).json()

    def inject(session, *_):
        record = next((row for row in session.new if isinstance(row, WalletTransfer)), None)
        if record is None:
            return
        if failure == "record":
            record.amount = 0
            return
        target = record.source_wallet_id if failure == "source" else record.destination_wallet_id
        wallet = next(row for row in session.dirty if isinstance(row, Wallet) and row.id == target)
        wallet.current_balance = -1

    def submit():
        return post(client, owner, draft, key) if original is None else reverse(client, owner, original["id"], key)

    event.listen(Session, "before_flush", inject)
    try:
        assert submit().status_code == 503
    finally:
        event.remove(Session, "before_flush", inject)
    assert (balance(client, owner, source), balance(client, owner, dest)) == expected
    assert client.get(URL, headers=owner).json() == before
    with engine.connect() as conn:
        assert wallet_discrepancies(conn) == 0
    assert submit().status_code == 201


def test_concurrent_credits_archival_and_account_deletion(context):
    client, _, engine, _ = context
    account, owner, income, _, draft, digital = setup(
        context, opening="10", destination="9999999999999998.99",
    )
    source, dest = draft["source_wallet_id"], draft["destination_wallet_id"]
    statuses = sorted(result.status_code for result in race(
        lambda: post(client, owner, {**draft, "amount": "1"}),
        lambda: income_post(client, owner, {**income, "wallet_id": dest, "amount": "1"}),
    ))
    assert statuses == [201, 409]
    assert balance(client, owner, dest) == "9999999999999999.99"
    archive, transfer = race(
        lambda: client.delete(f"/api/v1/wallets/{digital}", headers=owner),
        lambda: post(client, owner, {**draft, "destination_wallet_id": digital, "amount": "1"}),
    )
    assert (archive.status_code, transfer.status_code) in {(204, 409), (409, 201)}
    if archive.status_code == 204:
        assert client.post(f"/api/v1/wallets/{digital}/restore", headers=owner).status_code == 200
    with engine.connect() as conn:
        assert wallet_discrepancies(conn) == 0
        owner_id = conn.scalar(select(User.id).where(User.email == account["email"]))
    deleted, written = race(
        lambda: client.request("DELETE", "/api/v1/users/me", headers=owner,
                               json={"current_password": account["password"]}),
        lambda: post(client, owner, {**draft, "destination_wallet_id": digital, "amount": "1"}),
    )
    assert deleted.status_code == 204
    assert written.status_code in {201, 401, 404}
    with engine.connect() as conn:
        for model in (Wallet, WalletTransfer, TransferReplay):
            assert conn.scalar(select(func.count()).select_from(model).where(model.user_id == owner_id)) == 0
        assert wallet_discrepancies(conn) == 0
