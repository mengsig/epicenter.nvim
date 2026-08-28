"""Application-wide configuration constants and settings."""

from dataclasses import dataclass, field

# Module-level constants used across the app.
API_PREFIX = "/api"
DEFAULT_PAGE_SIZE = 20
MAX_PAGE_SIZE = 100
MAX_ITEMS_PER_ORDER = 50
SUPPORTED_CURRENCIES = ("USD", "EUR", "GBP")
TOKEN_TTL_SECONDS = 3600


@dataclass(frozen=True)
class Settings:
    """Immutable runtime settings resolved once at startup."""

    title: str = "Store API"
    debug: bool = False
    currency: str = "USD"
    allowed_hosts: tuple = field(default_factory=lambda: ("localhost",))

    def describe(self) -> str:
        """Human-readable one-line summary for the health endpoint."""
        mode = "debug" if self.debug else "prod"
        return f"{self.title} [{mode}] ({self.currency})"


def load_settings() -> Settings:
    """Build the global Settings object (would read env in a real app)."""
    return Settings(debug=True)
