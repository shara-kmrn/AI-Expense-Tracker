from fastapi import HTTPException


class AuthError(HTTPException):
    def __init__(self, status: int, detail: str):
        headers = {"Cache-Control": "no-store"}
        if status == 401:
            headers["WWW-Authenticate"] = "Bearer"
        super().__init__(status_code=status, detail=detail, headers=headers)


class InvalidCredentials(AuthError):
    def __init__(self):
        super().__init__(401, "Invalid authentication credentials")
