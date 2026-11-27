from collections.abc import Iterator
from contextlib import contextmanager

from fastapi import Request
from pydantic import SecretStr
from sqlalchemy import create_engine
from sqlalchemy.engine import Engine, make_url
from sqlalchemy.orm import Session, sessionmaker


class DatabaseNotConfigured(RuntimeError):
    pass


def build_engine(url: SecretStr) -> Engine:
    return create_engine(
        make_url(url.get_secret_value()),
        pool_pre_ping=True,
        pool_timeout=5,
        connect_args={"connect_timeout": 3},
        hide_parameters=True,
    )


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
