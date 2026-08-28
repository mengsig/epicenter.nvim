"""HTTP routes for the users resource."""

from fastapi import APIRouter

from ..services.user_service import UserService

router = APIRouter(prefix="/api/users")


@router.get("")
def list_users():
    """List every user (empty-path collection route)."""
    svc = UserService()
    return svc.list_all()


@router.get("/{id}")
def get_user(id: int):
    """Fetch a single user by id."""
    svc = UserService()
    return svc.fetch(id)


@router.post("")
def create_user(name: str, email: str):
    """Create a new user from the submitted fields."""
    svc = UserService()
    return svc.create(name, email)


@router.put("/{id}")
def replace_user(id: int, name: str, email: str):
    """Fully replace an existing user record."""
    svc = UserService()
    return svc.replace(id, name, email)


@router.patch("/{id}")
def patch_user(id: int, email: str):
    """Partially update a user (email only)."""
    svc = UserService()
    return svc.update_email(id, email)


@router.delete("/{id}")
def delete_user(id: int):
    """Remove the user with the given id."""
    svc = UserService()
    return svc.remove(id)
