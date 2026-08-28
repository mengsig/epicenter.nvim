"""Domain models for the store API: users, items, money, and orders."""

from dataclasses import dataclass, field

from pydantic import BaseModel

from .config import SUPPORTED_CURRENCIES


class User:
    """A single user record: an id plus profile fields."""

    def __init__(self, id: int, name: str, email: str) -> None:
        self.id = id
        self.name = name
        self.email = email

    def __repr__(self) -> str:
        return f"User(id={self.id!r}, name={self.name!r})"

    def __eq__(self, other: object) -> bool:
        return isinstance(other, User) and other.id == self.id

    def __hash__(self) -> int:
        return hash(self.id)


def normalize_email(email: str) -> str:
    """Lower-case and trim a raw email string before storage."""
    return email.strip().lower()


@dataclass(order=True)
class Money:
    """A currency amount stored in minor units (e.g. cents)."""

    amount: int
    currency: str = "USD"

    def __post_init__(self) -> None:
        if self.currency not in SUPPORTED_CURRENCIES:
            raise ValueError(f"unsupported currency: {self.currency}")

    def __add__(self, other: "Money") -> "Money":
        if other.currency != self.currency:
            raise ValueError("currency mismatch")
        return Money(self.amount + other.amount, self.currency)

    def __str__(self) -> str:
        return f"{self.amount / 100:.2f} {self.currency}"


@dataclass
class Item:
    """A purchasable product with a stable id and a price."""

    id: int
    title: str
    price: Money
    tags: list = field(default_factory=list)

    def is_free(self) -> bool:
        """True when the item costs nothing."""
        return self.price.amount == 0


@dataclass
class OrderLine:
    """One item plus a quantity inside an order."""

    item: Item
    quantity: int

    def subtotal(self) -> Money:
        """Total cost for this line = price times quantity."""
        return Money(self.item.price.amount * self.quantity, self.item.price.currency)


@dataclass
class Order:
    """A customer order: an owner plus a list of lines."""

    id: int
    user_id: int
    lines: list = field(default_factory=list)

    def __len__(self) -> int:
        return len(self.lines)

    def total(self) -> Money:
        """Sum every line subtotal into a single Money value."""
        running = Money(0)
        for line in self.lines:
            running = running + line.subtotal()
        return running


class UserCreate(BaseModel):
    """Request body accepted when creating a user."""

    name: str
    email: str


class UserOut(BaseModel):
    """Response shape returned for a single user."""

    id: int
    name: str
    email: str


class ItemCreate(BaseModel):
    """Request body accepted when creating an item."""

    title: str
    price_cents: int
    currency: str = "USD"


# intentionally dead (fixture): no code constructs or references LegacyToken.
@dataclass
class LegacyToken:
    """Deprecated auth token kept only to exercise `unused` on a type."""

    value: str
    issued_at: int
