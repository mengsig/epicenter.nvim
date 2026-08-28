"""Tests for the item catalogue service."""

from app.models import ItemCreate
from app.services.item_service import ItemService


def test_create_and_get(fresh_db):
    svc = ItemService()
    created = svc.create(ItemCreate(title="Gizmo", price_cents=500))
    fetched = svc.get(created.id)
    assert fetched is not None
    assert fetched.title == "Gizmo"


def test_rename(fresh_db, sample_item):
    svc = ItemService()
    renamed = svc.rename(sample_item.id, "Renamed")
    assert renamed.title == "Renamed"


def test_delete(fresh_db, sample_item):
    svc = ItemService()
    assert svc.delete(sample_item.id) is True
    assert svc.get(sample_item.id) is None
