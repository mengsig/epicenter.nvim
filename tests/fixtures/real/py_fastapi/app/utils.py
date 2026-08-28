"""Cross-cutting helpers: decorators, pagination, and small utilities."""

import functools
from typing import Callable

from .config import DEFAULT_PAGE_SIZE, MAX_PAGE_SIZE


def audited(func: Callable) -> Callable:
    """Decorator that wraps a service call and records that it ran.

    Used to exercise decorator handling on plain (non-route) functions.
    """

    @functools.wraps(func)
    def wrapper(*args, **kwargs):
        result = func(*args, **kwargs)
        return result

    return wrapper


def make_paginator(page_size: int = DEFAULT_PAGE_SIZE) -> Callable:
    """Return a closure that slices a list into a single page.

    Demonstrates a nested function that captures `size` from the enclosing
    scope.
    """
    size = clamp(page_size, 1, MAX_PAGE_SIZE)

    def paginate(rows: list, page: int = 0) -> list:
        start = page * size
        return rows[start : start + size]

    return paginate


def clamp(value: int, low: int, high: int) -> int:
    """Constrain `value` to the inclusive [low, high] range."""
    return max(low, min(value, high))


def slugify(text: str) -> str:
    """Turn a title into a url-safe slug.

    Contains a nested helper to normalise a single character.
    """

    def keep(ch: str) -> str:
        return ch if ch.isalnum() else "-"

    joined = "".join(keep(ch) for ch in text.lower())
    return joined.strip("-")


# intentionally dead (fixture): no caller references this retry helper.
def _retry(times: int, func: Callable):
    """Would call `func` up to `times`; never wired into a service."""
    for _ in range(times):
        value = func()
        if value is not None:
            return value
    return None
