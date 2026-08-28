"""Application entry point: build the FastAPI app and mount routers."""

from fastapi import FastAPI

from .config import load_settings
from .routes.auth import router as auth_router
from .routes.items import router as items_router
from .routes.orders import router as orders_router
from .routes.users import router as users_router

settings = load_settings()

app = FastAPI(title=settings.title)
app.include_router(users_router)
app.include_router(items_router)
app.include_router(orders_router)
app.include_router(auth_router)


@app.get("/health")
def health():
    """Liveness probe used by the load balancer."""
    return {"status": "ok", "app": settings.describe()}


def create_app() -> FastAPI:
    """Factory used by tests and the ASGI server."""
    return app
