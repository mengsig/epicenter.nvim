"""Token minting and verification for the store API."""

import hashlib

from app.config import TOKEN_TTL_SECONDS
from app.models import normalize_email


class AuthService:
    """Issues opaque tokens and validates them on later requests."""

    def __init__(self, secret: str = "dev-secret") -> None:
        self.secret = secret
        self._issued: dict = {}

    def issue(self, email: str) -> str:
        """Mint a token for a (normalised) email address."""
        who = normalize_email(email)
        token = self._sign(who)
        self._issued[token] = who
        return token

    def verify(self, token: str) -> bool:
        """True when the token was issued by this service."""
        return token in self._issued

    def whoami(self, token: str):
        """Return the email behind a token, or None."""
        return self._issued.get(token)

    def _sign(self, payload: str) -> str:
        """Derive a stable token from payload, secret, and TTL."""
        material = f"{payload}:{self.secret}:{TOKEN_TTL_SECONDS}"
        return hashlib.sha256(material.encode()).hexdigest()[:16]

    def __call__(self, token: str) -> bool:
        """Allow the service to act as a FastAPI dependency callable."""
        return self.verify(token)


# A single shared instance used as a dependency by the auth router.
auth = AuthService()
