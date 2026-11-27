from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.api.v1.router import router
from app.core.config import Settings


def create_app(settings: Settings) -> FastAPI:
    application = FastAPI(title=settings.app_name, version=settings.app_version)
    application.include_router(router)
    if settings.cors_origins:
        application.add_middleware(
            CORSMiddleware,
            allow_origins=settings.cors_origins,
            allow_methods=["GET"],
        )
    return application


app = create_app(Settings())
