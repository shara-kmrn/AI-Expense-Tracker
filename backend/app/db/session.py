import logging
from collections.abc import Iterator
from contextlib import contextmanager

import psycopg
from fastapi import Request
from pydantic import SecretStr
from sqlalchemy import create_engine, event
from sqlalchemy.engine import Engine, make_url
from sqlalchemy.exc import ArgumentError, OperationalError
from sqlalchemy.orm import Session, sessionmaker


class DatabaseNotConfigured(RuntimeError):
    pass


def build_engine(url: SecretStr) -> Engine:
    # DEBUG query logging may include returned rows even with hide_parameters.
    for name in ("sqlalchemy.engine.Engine.expense_tracker",
                 "sqlalchemy.pool.impl.QueuePool.expense_tracker"):
        logging.getLogger(name).setLevel(logging.WARNING)
    try:
        engine = create_engine(
            make_url(url.get_secret_value()),
            pool_pre_ping=True,
            pool_timeout=5,
            connect_args={"connect_timeout": 3},
            echo=False,
            echo_pool=False,
            logging_name="expense_tracker",
            pool_logging_name="expense_tracker",
            hide_parameters=True,
        )
    except (ArgumentError, ValueError):
        pass
    else:
        event.listen(engine, "do_connect", _connect)
        return engine
    raise DatabaseNotConfigured("Invalid PostgreSQL connection configuration.")


def _connect(dialect, _connection_record, args, kwargs):
    try:
        return dialect.connect(*args, **kwargs)
    except psycopg.Error as error:
        # Driver tracebacks can render the unredacted conninfo and kwargs.
        if isinstance(error, psycopg.errors.ConnectionTimeout):
            message = "PostgreSQL connection timed out."
        elif error.sqlstate == "28P01":
            message = "PostgreSQL authentication failed."
        else:
            message = "PostgreSQL connection failed. Check availability and role configuration."
    # Raise outside the handler so the raw driver exception isn't attached.
    raise OperationalError(None, None, RuntimeError(message), hide_parameters=True)


@contextmanager
def session_scope(factory: sessionmaker[Session]) -> Iterator[Session]:
    # Closing returns the connection to the pool and rolls back uncommitted work.
    # Callers own transaction boundaries and must commit explicitly.
    with factory() as session:
        yield session


@contextmanager
def request_session(request: Request) -> Iterator[Session]:
    factory = request.app.state.session_factory
    if factory is None:
        raise DatabaseNotConfigured
    with session_scope(factory) as session:
        yield session


def get_db(request: Request) -> Iterator[Session]:
    with request_session(request) as session:
        yield session
