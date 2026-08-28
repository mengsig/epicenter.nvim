"""Business logic for placing and reading orders."""

from .. import db
from ..config import MAX_ITEMS_PER_ORDER
from ..models import Order, OrderLine
from .item_service import ItemService
from .user_service import UserService


class OrderService:
    """Assembles orders from catalogue items for a known user."""

    def __init__(self) -> None:
        self.items = ItemService()
        self.users = UserService()

    async def place(self, user_id: int, cart: dict) -> Order:
        """Create an order for `user_id` from a {item_id: qty} cart.

        Async to exercise `async def` on a service method; awaits the user
        lookup as if it hit a remote identity service.
        """
        owner = await self._resolve_owner(user_id)
        order_id = db.next_id("order")
        order = Order(order_id, owner.id if owner else user_id)
        for item_id, qty in cart.items():
            self._append_line(order, int(item_id), int(qty))
        db.put_order(order_id, self._serialize(order))
        return order

    def get(self, order_id: int):
        """Return a stored order record by id, or None."""
        return db.get_order(order_id)

    async def _resolve_owner(self, user_id: int):
        """Fetch the ordering user via the user service."""
        return self.users.fetch(user_id)

    def _append_line(self, order: Order, item_id: int, qty: int) -> None:
        """Look up an item and push a validated line onto the order."""
        if len(order) >= MAX_ITEMS_PER_ORDER:
            raise ValueError("order too large")
        item = self.items.get(item_id)
        if item is None:
            raise KeyError(item_id)
        order.lines.append(OrderLine(item, qty))

    def _serialize(self, order: Order) -> dict:
        """Flatten an Order into a raw record for storage."""
        return {
            "id": order.id,
            "user_id": order.user_id,
            "total_cents": order.total().amount,
            "line_count": len(order),
        }
