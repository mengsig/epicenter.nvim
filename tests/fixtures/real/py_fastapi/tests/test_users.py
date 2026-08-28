"""Tests for the user service and routes."""

from app.services.user_service import UserService


def test_get_user():
    svc = UserService()
    created = svc.create("Ada", "ADA@example.com")
    fetched = svc.fetch(created.id)
    assert fetched is not None
    assert fetched.id == created.id
