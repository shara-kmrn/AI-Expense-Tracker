from alembic import context
from alembic.util import CommandError
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError

from app.core.config import Settings
from app.auth import models  # noqa: F401 - register ORM metadata
from app.db.base import Base
from app.db.session import build_engine


def migrate(connection, identity):
    context.configure(connection=connection, target_metadata=Base.metadata)
    with context.begin_transaction():
        actual = connection.execute(text("SELECT current_database(), current_user")).one()
        if tuple(actual) != identity:
            raise CommandError("Connected database or role does not match the migration target")
        context.run_migrations()


def run():
    target = context.get_x_argument(as_dictionary=True).get("target", "dev")
    if target not in {"dev", "test"}:
        raise CommandError("Migration target must be dev or test")
    if context.is_offline_mode():
        raise CommandError("Online migrations are required to verify the database identity")

    settings = Settings()
    if target == "test":
        url = settings.test_database_url
        identity = ("expense_tracker_test", "expense_tracker_test_app")
    else:
        url = settings.database_url
        identity = ("expense_tracker_dev", "expense_tracker_app")

    try:
        connection = context.config.attributes.get("connection")
        if connection is not None:
            migrate(connection, identity)
            return
        if url is None:
            raise CommandError("Configure the database URL for the selected migration target")
        engine = build_engine(url)
        try:
            with engine.connect() as connection:
                migrate(connection, identity)
        finally:
            engine.dispose()
    except SQLAlchemyError:
        raise CommandError(
            "Database migration failed. Check the target configuration and privileges."
        ) from None


run()
