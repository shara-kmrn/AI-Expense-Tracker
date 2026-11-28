from argparse import Namespace
from pathlib import Path
from uuid import uuid4

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import func, insert, select, text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.auth.models import User
from app.categories.defaults import DEFAULTS_V1
from app.categories.models import Category
from app.categories.repository import provision_defaults
from test_authentication import (
    account, assert_unauthorized, bearer, concurrently, context, login, register,
)

URL = "/api/v1/categories"
DEFAULT_CUSTOM = {"name": "University Expenses", "type": "EXPENSE", "icon": "graduation_cap", "color": "#d4af37"}


def authenticate(ctx, suffix="one"):
    data = account(ctx, suffix)
    client = ctx[0]
    assert register(client, data).status_code == 201
    return data, login(client, data).json()


def create(client, headers, **overrides):
    return client.post(URL, json={**DEFAULT_CUSTOM, **overrides}, headers=headers)


def test_registration_seeds_versioned_defaults_and_concurrent_provision_is_idempotent(context):
    client, _, engine, _ = context
    data, tokens = authenticate(context)
    headers = bearer(tokens["access_token"])
    listing = client.get(URL, headers=headers).json()
    assert len(listing["items"]) == len(DEFAULTS_V1)
    assert listing["next_offset"] is None
    assert all(item["is_default"] and item["is_active"] for item in listing["items"])
    assert create(client, headers).status_code == 201
    with engine.connect() as conn:
        owner = conn.execute(select(User.id).where(User.email == data["email"])).scalar_one()

    def provision():
        with Session(engine) as db, db.begin():
            provision_defaults(db, owner)

    concurrently(provision)
    with engine.connect() as conn:
        assert conn.execute(select(func.count()).select_from(Category).where(Category.user_id == owner)).scalar_one() == 17


def test_filter_search_pagination_and_stable_sort(context):
    client = context[0]
    _, tokens = authenticate(context)
    headers = bearer(tokens["access_token"])
    assert create(client, headers, name="Straße Study").status_code == 201
    assert create(client, headers, name="100% Supplies").status_code == 201
    query = lambda **params: client.get(URL, headers=headers, params=params)
    first = query(type="INCOME", limit=2).json()
    second = query(type="INCOME", limit=2, offset=first["next_offset"]).json()
    assert all(item["type"] == "INCOME" for item in first["items"] + second["items"])
    assert not ({i["id"] for i in first["items"]} & {i["id"] for i in second["items"]})
    assert query(type="INCOME", limit=2).json() == first
    assert [i["name"] for i in query(type="EXPENSE", q="STRASSE", default=False).json()["items"]] == ["Straße Study"]
    assert [i["name"] for i in query(q="%").json()["items"]] == ["100% Supplies"]
    assert not query(active=False).json()["items"]
    assert query(limit=101).status_code == 422
    assert query(offset=-1).status_code == 422


def test_custom_lifecycle_and_archived_names_remain_reserved(context):
    client = context[0]
    _, tokens = authenticate(context)
    headers = bearer(tokens["access_token"])
    created = create(client, headers)
    assert created.status_code == 201
    item = created.json()
    assert item["color"] == "#D4AF37"
    assert "user_id" not in item and "normalized_name" not in item
    route = f"{URL}/{item['id']}"
    assert client.get(route, headers=headers).json() == item
    edited = client.patch(route, headers=headers, json={"name": "  Ｕniversity　 Costs  ", "icon": "wallet"})
    assert edited.status_code == 200 and edited.json()["name"] == "University Costs"
    assert create(client, headers, name="university costs").status_code == 409
    for _ in range(2):
        assert client.delete(route, headers=headers).status_code == 204
    assert client.get(route, headers=headers).json()["is_active"] is False
    assert client.get(URL, headers=headers, params={"active": False, "default": False}).json()["items"][0]["id"] == item["id"]
    assert create(client, headers, name="University Costs").status_code == 409
    for _ in range(2):
        restored = client.post(route + "/restore", headers=headers)
        assert restored.status_code == 200
        assert restored.json()["id"] == item["id"] and restored.json()["is_active"] is True
    assert create(client, headers, name="University Costs", type="INCOME").status_code == 201


def test_protected_defaults_ownership_isolation_and_revocation(context):
    client = context[0]
    _, first = authenticate(context, "first")
    _, second = authenticate(context, "second")
    a, b = bearer(first["access_token"]), bearer(second["access_token"])
    first_default = client.get(URL, headers=a).json()["items"][0]
    defaults_a = {item["id"] for item in client.get(URL, headers=a).json()["items"]}
    defaults_b = {item["id"] for item in client.get(URL, headers=b).json()["items"]}
    assert not defaults_a & defaults_b
    route = f"{URL}/{first_default['id']}"
    for method, suffix, body in (("PATCH", "", {"name": "Renamed"}), ("DELETE", "", None), ("POST", "/restore", None)):
        args = {"json": body} if body is not None else {}
        assert client.request(method, route + suffix, headers=a, **args).status_code == 403
    custom = create(client, a).json()
    assert create(client, b).status_code == 201
    assert all(item["id"] != custom["id"] for item in client.get(URL, headers=b).json()["items"])
    foreign = f"{URL}/{custom['id']}"
    for method, suffix, body in (("GET", "", None), ("PATCH", "", {"name": "Changed"}), ("DELETE", "", None), ("POST", "/restore", None)):
        args = {"json": body} if body is not None else {}
        response = client.request(method, foreign + suffix, headers=b, **args)
        assert response.status_code == 404 and response.json() == {"detail": "Category not found"}
        assert_unauthorized(client.request(method, foreign + suffix, **args))
    assert_unauthorized(client.get(URL))
    assert_unauthorized(create(client, {}))
    assert client.post("/api/v1/auth/logout", headers=a).status_code == 204
    assert_unauthorized(client.get(URL, headers=a))


@pytest.mark.parametrize("override", [
    {"name": "  "}, {"name": "x" * 81}, {"name": "a\tname"}, {"name": "a\u202eb"},
    {"type": "expense"}, {"icon": "https://fixture.invalid/icon"}, {"color": "#FFF"},
    {"user_id": str(uuid4())}, {"is_default": True}, {"normalized_name": "fixture"},
])
def test_create_validation_and_mass_assignment(context, override):
    client = context[0]
    _, tokens = authenticate(context)
    headers = bearer(tokens["access_token"])
    response = create(client, headers, **override)
    assert response.status_code == 422 and response.json() == {"detail": "Invalid request"}
    assert client.get(URL, headers=headers, params={"default": False}).json()["items"] == []


def test_update_validation_and_concurrent_conflicts_roll_back(context):
    client = context[0]
    _, tokens = authenticate(context)
    headers = bearer(tokens["access_token"])
    statuses = concurrently(lambda: create(client, headers, name="  Straße   Study "))
    assert sorted(r.status_code for r in statuses) == [201, 409]
    record = next(r.json() for r in statuses if r.status_code == 201)
    route = f"{URL}/{record['id']}"
    for body in ({}, {"name": None}, {"type": "INCOME"}, {"user_id": str(uuid4())}, {"is_default": True}):
        assert client.patch(route, headers=headers, json=body).status_code == 422
    another = create(client, headers, name="Second").json()
    assert client.patch(f"{URL}/{another['id']}", headers=headers, json={"name": "STRASSE STUDY"}).status_code == 409
    assert client.get(f"{URL}/{another['id']}", headers=headers).json()["name"] == "Second"
    assert create(client, headers, name="Third").status_code == 201


def test_account_deletion_cascades_owned_categories(context):
    client, _, engine, _ = context
    data, tokens = authenticate(context)
    headers = bearer(tokens["access_token"])
    other_data, other = authenticate(context, "other")
    custom = create(client, headers).json()
    with engine.connect() as conn:
        owner = conn.execute(select(User.id).where(User.email == data["email"])).scalar_one()
    response = client.request("DELETE", "/api/v1/users/me", headers=headers,
                              json={"current_password": data["password"]})
    assert response.status_code == 204
    with engine.connect() as conn:
        assert conn.execute(select(Category.id).where(Category.user_id == owner)).first() is None
    assert_unauthorized(client.get(f"{URL}/{custom['id']}", headers=headers))
    assert len(client.get(URL, headers=bearer(other["access_token"])).json()["items"]) == 16


def test_migration_backfills_existing_accounts_and_database_constraints(context):
    engine = context[2]
    config = Config(str(Path(__file__).resolve().parents[1] / "alembic.ini"))
    config.cmd_opts = Namespace(x=["target=test"])
    owner = uuid4()
    with engine.connect() as conn, conn.begin():
        assert tuple(conn.execute(text("SELECT current_database(), current_user")).one()) == (
            "expense_tracker_test", "expense_tracker_test_app",
        )
        config.attributes["connection"] = conn
        try:
            command.downgrade(config, "0003")
            assert conn.execute(text("SELECT to_regclass('categories')")).scalar_one() is None
            conn.execute(insert(User).values(
                id=owner, full_name="Existing synthetic account",
                email=f"{context[3]}-migration@example.com", password_hash="fixture",
            ))
            command.upgrade(config, "0004")
            rows = conn.execute(select(Category.default_code).where(Category.user_id == owner)).scalars().all()
            assert set(rows) == {entry[0] for entry in DEFAULTS_V1}
            values = dict(id=uuid4(), user_id=owner, name="Constraint proof", normalized_name="constraint proof",
                          type="INVALID", icon="wallet", color="#D4AF37")
            with pytest.raises(IntegrityError), conn.begin_nested():
                conn.execute(insert(Category).values(**values))
            with pytest.raises(IntegrityError), conn.begin_nested():
                conn.execute(insert(Category).values(**{**values, "type": "INCOME", "user_id": uuid4()}))
            assert conn.execute(select(User.id).where(User.id == owner)).scalar_one() == owner
        finally:
            conn.rollback()
