from collections import OrderedDict
from threading import Lock
from time import monotonic
from typing import Annotated

from fastapi import Depends, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.orm import Session

from app.auth import service
from app.auth.errors import AuthError
from app.auth.tokens import decode_access, signing_key
from app.core.config import Settings
from app.db.session import get_db

_bearer = HTTPBearer(auto_error=False)
Database = Annotated[Session, Depends(get_db)]
Bearer = Annotated[HTTPAuthorizationCredentials | None, Depends(_bearer)]


class AuthLimiter:
    def __init__(self, limit=20, window=60, capacity=4096):
        self.limit = limit
        self.window = window
        self.capacity = capacity
        self.entries = OrderedDict()
        self.lock = Lock()

    def allow(self, source: str) -> bool:
        with self.lock:
            now = monotonic()
            while self.entries and next(iter(self.entries.values()))[0] <= now:
                self.entries.popitem(last=False)
            entry = self.entries.get(source)
            if entry is None:
                if len(self.entries) >= self.capacity:
                    return False
                self.entries[source] = (now + self.window, 1)
                return True
            deadline, count = entry
            if count >= self.limit:
                return False
            self.entries[source] = (deadline, count + 1)
            return True


def guard_auth(request: Request) -> None:
    if not request.app.state.auth_limiter.allow(request.client.host if request.client else "unknown"):
        raise AuthError(429, "Too many authentication requests")
    signing_key(request.app.state.settings)


def settings_for(request: Request) -> Settings:
    return request.app.state.settings


def access_identity(request: Request, bearer: Bearer):
    return decode_access(settings_for(request), bearer.credentials if bearer else None)


def get_current_user(identity: Annotated[tuple, Depends(access_identity)], db: Database):
    return service.current_user(db, *identity)
