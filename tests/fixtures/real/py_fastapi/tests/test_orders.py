"""Tests for the order placement service."""

import pytest

from app.models import ItemCreate
from app.services.item_service import ItemService
from app.services.order_service import OrderService


@pytest.mark.asyncio
async def test_place_order(fresh_db):
    items = ItemService()
    widget = items.create(ItemCreate(title="Widget", price_cents=250))
    orders = OrderService()
    order = await orders.place(1, {widget.id: 2})
    assert order.total().amount == 500
    assert len(order) == 1
