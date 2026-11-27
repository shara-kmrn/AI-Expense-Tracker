from secrets import token_urlsafe
from threading import BoundedSemaphore

from pwdlib import PasswordHash

from app.auth.errors import AuthError

_hasher = PasswordHash.recommended()
_dummy_hash = _hasher.hash(token_urlsafe(32))
_slots = BoundedSemaphore(4)


def hash_password(password: str) -> str:
    if not _slots.acquire(blocking=False):
        raise AuthError(429, "Authentication temporarily busy")
    try:
        return _hasher.hash(password)
    finally:
        _slots.release()


def verify_password(password: str, stored_hash: str | None) -> tuple[bool, str | None]:
    if not _slots.acquire(blocking=False):
        raise AuthError(429, "Authentication temporarily busy")
    try:
        valid, replacement = _hasher.verify_and_update(password, stored_hash or _dummy_hash)
        return valid and stored_hash is not None, replacement
    finally:
        _slots.release()
