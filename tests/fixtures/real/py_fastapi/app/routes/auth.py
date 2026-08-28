"""HTTP routes for issuing and inspecting auth tokens."""

from fastapi import APIRouter

from ..services.auth_service import auth

router = APIRouter(prefix="/api/auth", tags=["auth"])


@router.post("/login")
def login(email: str):
    """Issue a fresh token for the given email address."""
    return {"token": auth.issue(email)}


@router.put("/token")
def refresh(email: str):
    """Re-issue a token, replacing whatever the client held."""
    return {"token": auth.issue(email)}


@router.get("/whoami")
def whoami(token: str):
    """Return the identity behind a bearer token."""
    if not auth.verify(token):
        return {"authenticated": False}
    return {"authenticated": True, "email": auth.whoami(token)}
