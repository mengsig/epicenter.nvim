"""HTTP routes for placing and reading orders."""

from fastapi import APIRouter

from ..services.order_service import OrderService

router = APIRouter(prefix="/api/orders", tags=["orders"])

_service = OrderService()


@router.post("")
async def place_order(user_id: int, cart: dict):
    """Place an order for a user from a {item_id: qty} cart."""
    order = await _service.place(user_id, cart)
    return {"id": order.id, "total": str(order.total())}


@router.get("/{order_id}")
async def read_order(order_id: int):
    """Return a previously placed order by id."""
    return _service.get(order_id)
