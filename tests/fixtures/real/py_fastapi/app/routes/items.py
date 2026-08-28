"""HTTP routes for the item catalogue resource."""

from fastapi import APIRouter

from ..config import DEFAULT_PAGE_SIZE
from ..models import ItemCreate
from ..services.item_service import ItemService
from ..utils import make_paginator

router = APIRouter(prefix="/api/items", tags=["items"])

_service = ItemService()


@router.get("")
async def list_items(page: int = 0):
    """List items, one page at a time (empty-path collection route)."""
    paginate = make_paginator(DEFAULT_PAGE_SIZE)
    rows = _service.list_items()

    def to_summary(item):
        return {"id": item.id, "title": item.title}

    return [to_summary(item) for item in paginate(rows, page)]


@router.get("/{item_id}")
async def get_item(item_id: int):
    """Fetch a single item by id."""
    return _service.get(item_id)


@router.post("")
def create_item(payload: ItemCreate):
    """Create a new catalogue item."""
    return _service.create(payload)


@router.put("/{item_id}")
def replace_item(item_id: int, payload: ItemCreate):
    """Fully replace an existing item."""
    return _service.update(item_id, payload)


@router.patch("/{item_id}")
def patch_item(item_id: int, title: str):
    """Partially update an item (its title only)."""
    return _service.rename(item_id, title)


@router.delete("/{item_id}")
def delete_item(item_id: int):
    """Remove an item from the catalogue."""
    return _service.delete(item_id)
