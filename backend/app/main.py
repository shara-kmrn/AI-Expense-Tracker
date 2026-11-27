from contextlib import asynccontextmanager
from functools import partial
from threading import BoundedSemaphore

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy.orm import sessionmaker

from app.api.v1.router import router
from app.auth.dependencies import AuthLimiter
from app.auth.recovery import smtp_delivery
from app.core.config import Settings
from app.db.session import build_engine


def create_app(settings: Settings) -> FastAPI:
    engine = build_engine(settings.database_url) if settings.database_url else None

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        try:
            yield
        finally:
            if engine is not None:
                engine.dispose()

    application = FastAPI(
        title=settings.app_name, version=settings.app_version, lifespan=lifespan
    )
    application.state.session_factory = sessionmaker(bind=engine) if engine else None
    application.state.settings = settings
    application.state.auth_limiter = AuthLimiter()
    application.state.recovery_limiter = AuthLimiter(limit=3, window=900)
    application.state.recovery_slots = BoundedSemaphore(4)
    application.state.recovery_delivery = partial(smtp_delivery, settings)
    application.include_router(router)
    if settings.cors_origins:
        application.add_middleware(
            CORSMiddleware,
            allow_origins=settings.cors_origins,
            allow_methods=["GET", "POST", "PATCH", "DELETE"],
            allow_headers=["Authorization", "Content-Type"],
        )
    return application


app = create_app(Settings())
