"""A tiny in-memory data store shared by the service layer."""

from typing import Optional

# Module-level tables. Real code would use a database session here.
_ITEMS: dict = {}
_ORDERS: dict = {}
_SEQUENCE: dict = {"item": 0, "order": 0}


def next_id(kind: str) -> int:
    """Hand out a monotonically increasing id for the given table."""
    _SEQUENCE[kind] += 1
    return _SEQUENCE[kind]


def put_item(item_id: int, record: dict) -> None:
    """Insert or overwrite an item record by id."""
    _ITEMS[item_id] = record


def get_item(item_id: int) -> Optional[dict]:
    """Return the raw item record, or None when missing."""
    return _ITEMS.get(item_id)


def all_items() -> list:
    """Return every stored item record."""
    return list(_ITEMS.values())


def drop_item(item_id: int) -> bool:
    """Delete an item record; True when a row was removed."""
    if item_id in _ITEMS:
        del _ITEMS[item_id]
        return True
    return False


def put_order(order_id: int, record: dict) -> None:
    """Insert or overwrite an order record by id."""
    _ORDERS[order_id] = record


def get_order(order_id: int) -> Optional[dict]:
    """Return the raw order record, or None when missing."""
    return _ORDERS.get(order_id)


def _reset() -> None:
    """Clear every table. Used only by test fixtures."""
    _ITEMS.clear()
    _ORDERS.clear()
    _SEQUENCE.update({"item": 0, "order": 0})


# intentionally dead (fixture): nothing calls this private compaction helper.
def _compact_sequences() -> None:
    """Would renumber ids to close gaps; never wired up."""
    for key in list(_SEQUENCE):
        _SEQUENCE[key] = 0
