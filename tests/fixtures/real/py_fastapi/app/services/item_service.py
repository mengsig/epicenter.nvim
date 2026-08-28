"""Business logic for the item catalogue."""

from .. import db
from ..models import Item, ItemCreate, Money
from ..utils import audited, slugify


class ItemService:
    """CRUD operations over the in-memory item catalogue."""

    def list_items(self) -> list:
        """Return every item as a domain object."""
        return [self._hydrate(row) for row in db.all_items()]

    def get(self, item_id: int):
        """Return one item by id, or None when it does not exist."""
        row = db.get_item(item_id)
        if row is None:
            return None
        return self._hydrate(row)

    @audited
    def create(self, payload: ItemCreate) -> Item:
        """Persist a new item built from a validated payload."""
        item_id = db.next_id("item")
        price = Money(payload.price_cents, payload.currency)
        record = {
            "id": item_id,
            "title": payload.title,
            "slug": slugify(payload.title),
            "price_cents": price.amount,
            "currency": price.currency,
        }
        db.put_item(item_id, record)
        return self._hydrate(record)

    def update(self, item_id: int, payload: ItemCreate):
        """Replace an existing item's fields; None when absent."""
        if db.get_item(item_id) is None:
            return None
        record = {
            "id": item_id,
            "title": payload.title,
            "slug": slugify(payload.title),
            "price_cents": payload.price_cents,
            "currency": payload.currency,
        }
        db.put_item(item_id, record)
        return self._hydrate(record)

    def rename(self, item_id: int, title: str):
        """Patch only the title of an existing item."""
        record = db.get_item(item_id)
        if record is None:
            return None
        record["title"] = title
        record["slug"] = slugify(title)
        db.put_item(item_id, record)
        return self._hydrate(record)

    def delete(self, item_id: int) -> bool:
        """Remove an item; True when a row was deleted."""
        return db.drop_item(item_id)

    def _hydrate(self, record: dict) -> Item:
        """Build an Item domain object from a raw db record."""
        price = Money(record["price_cents"], record["currency"])
        return Item(record["id"], record["title"], price)
