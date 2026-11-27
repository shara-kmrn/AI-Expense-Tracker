from typing import Literal

from fastapi import APIRouter, Request, Response
from pydantic import BaseModel
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError

from app.db.session import DatabaseNotConfigured, request_session

router = APIRouter(tags=["health"])


class HealthResponse(BaseModel):
    status: Literal["ok"]
    version: str


@router.get("/health")
async def health(request: Request) -> HealthResponse:
    return HealthResponse(status="ok", version=request.app.version)


class ReadinessResponse(BaseModel):
    status: Literal["ready", "unavailable"]


@router.get(
    "/health/ready",
    responses={503: {"model": ReadinessResponse, "description": "Database unavailable"}},
)
def readiness(request: Request, response: Response) -> ReadinessResponse:
    try:
        # The probe owns its session so acquisition and cleanup failures are sanitized.
        with request_session(request) as session:
            session.execute(text("SELECT 1")).scalar_one()
    except (DatabaseNotConfigured, SQLAlchemyError):
        response.status_code = 503
        return ReadinessResponse(status="unavailable")
    return ReadinessResponse(status="ready")
