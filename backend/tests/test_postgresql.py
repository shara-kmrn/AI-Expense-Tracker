from argparse import Namespace
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from alembic.runtime.migration import MigrationContext
from fastapi.testclient import TestClient
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import sessionmaker

from app.core.config import Settings
from app.db.session import build_engine, session_scope
from app.main import create_app


@pytest.fixture(scope="module")
def test_url():
    settings = Settings()
    if settings.test_database_url is None:
        pytest.skip("TEST_DATABASE_URL is required for real PostgreSQL integration tests")
    return settings.test_database_url


@pytest.fixture
def connection(test_url):
    engine = build_engine(test_url)
    try:
        with engine.connect() as conn, conn.begin():
            identity = conn.execute(text("SELECT current_database(), current_user")).one()
            if tuple(identity) != ("expense_tracker_test", "expense_tracker_test_app"):
                pytest.fail("Refusing integration tests against an unexpected database or role")
            try:
                yield conn
            finally:
                conn.rollback()
    except SQLAlchemyError:
        pytest.fail("Test database operation failed. Check connectivity and test role permissions.", pytrace=False)
    finally:
        engine.dispose()


def test_postgres_connection_and_session_cleanup(connection):
    engine = connection.engine
    factory = sessionmaker(bind=engine)
    checked_out = engine.pool.checkedout()
    with session_scope(factory) as session:
        assert session.execute(text("SELECT 1")).scalar_one() == 1
    assert engine.pool.checkedout() == checked_out


def test_postgres_readiness(connection, test_url):
    settings = Settings(_env_file=None, DATABASE_URL=test_url, TEST_DATABASE_URL=None)
    with TestClient(create_app(settings)) as client:
        response = client.get("/api/v1/health/ready")
    assert response.status_code == 200
    assert response.json() == {"status": "ready"}


def test_postgres_migration_roundtrip(connection):
    config = Config(str(Path(__file__).resolve().parents[1] / "alembic.ini"))
    config.cmd_opts = Namespace(x=["target=test"])
    config.attributes["connection"] = connection

    def revisions():
        return MigrationContext.configure(connection).get_current_heads()

    assert revisions() in {(), ("0001",)}, "Unexpected migration history on test database"
    command.upgrade(config, "head")
    assert revisions() == ("0001",)
    command.downgrade(config, "base")
    assert revisions() == ()
    command.upgrade(config, "head")
    assert revisions() == ("0001",)


def test_database_role_isolation(connection):
    roles = connection.execute(text("""
        SELECT rolname, rolsuper OR rolcreatedb OR rolcreaterole
            OR rolreplication OR rolbypassrls,
            has_database_privilege(rolname, 'expense_tracker_dev', 'CONNECT'),
            has_database_privilege(rolname, 'expense_tracker_test', 'CONNECT')
        FROM pg_roles
        WHERE rolname IN ('expense_tracker_app', 'expense_tracker_test_app')
        ORDER BY rolname
    """)).all()
    assert [tuple(role) for role in roles] == [
        ("expense_tracker_app", False, True, False),
        ("expense_tracker_test_app", False, False, True),
    ]
    assert not connection.execute(text("""
        SELECT pg_has_role('expense_tracker_app', 'expense_tracker_test_app', 'MEMBER')
            OR pg_has_role('expense_tracker_test_app', 'expense_tracker_app', 'MEMBER')
    """)).scalar_one()
