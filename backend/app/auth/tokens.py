from hashlib import sha256
from secrets import token_urlsafe
from uuid import UUID, uuid4

import jwt

from app.auth.errors import AuthError, InvalidCredentials
from app.core.config import Settings

ALGORITHM = "HS256"


def signing_key(settings: Settings) -> str:
    key = settings.jwt_secret.get_secret_value() if settings.jwt_secret else ""
    if len(key.encode("utf-8")) < 32 or len(set(key)) < 16:
        raise AuthError(503, "Authentication is unavailable")
    return key


def digest_token(token: str) -> str:
    return sha256(token.encode("utf-8")).hexdigest()


def new_refresh_token() -> tuple[str, str]:
    token = token_urlsafe(32)
    return token, digest_token(token)


def issue_access(settings: Settings, user_id: UUID, family_id: UUID, now, expires) -> str:
    return jwt.encode(
        {
            "sub": str(user_id), "sid": str(family_id), "jti": str(uuid4()),
            "iat": int(now.timestamp()), "exp": int(expires.timestamp()),
            "type": "access", "iss": settings.jwt_issuer, "aud": settings.jwt_audience,
        },
        signing_key(settings),
        algorithm=ALGORITHM,
    )


def decode_access(settings: Settings, token: str | None) -> tuple[UUID, UUID]:
    if not token or len(token) > 4096:
        raise InvalidCredentials
    try:
        claims = jwt.decode(
            token,
            signing_key(settings),
            algorithms=[ALGORITHM],
            issuer=settings.jwt_issuer,
            audience=settings.jwt_audience,
            options={
                "require": ["sub", "sid", "jti", "iat", "exp", "type", "iss", "aud"],
                "strict_aud": True,
            },
        )
        if claims["type"] != "access" or any(
            type(claims[field]) is not int for field in ("iat", "exp")
        ) or claims["iat"] >= claims["exp"]:
            raise ValueError
        UUID(claims["jti"])
        return UUID(claims["sub"]), UUID(claims["sid"])
    except (jwt.InvalidTokenError, ValueError, TypeError, AttributeError, OverflowError):
        raise InvalidCredentials from None
