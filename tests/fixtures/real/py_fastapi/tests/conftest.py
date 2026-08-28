"""Shared pytest fixtures for the store test-suite."""

import pytest

from app import db
from app.main import create_app
from app.models import ItemCreate
from app.services.item_service import ItemService


def client():
    """Return a bare app instance the tests can drive."""
    return create_app()


@pytest.fixture()
def fresh_db():
    """Reset every in-memory table before a test runs."""
    db._reset()
    yield
    db._reset()


@pytest.fixture()
def item_service() -> ItemService:
    """Provide a service bound to the (reset) in-memory catalogue."""
    return ItemService()


@pytest.fixture()
def sample_item(item_service: ItemService):
    """Seed one catalogue item and hand it back to the test."""
    return item_service.create(ItemCreate(title="Widget", price_cents=999))
