"""Business logic for reading and writing users."""

from ..models import User, normalize_email

_USERS: dict = {}


class UserService:
    """In-memory user store used by the routes layer."""

    def fetch(self, id: int):
        """Return the user with `id`, or None when absent."""
        row = self._query(id)
        if row is None:
            return None
        return User(id, row["name"], row["email"])

    def _query(self, id: int):
        """Look up the raw record backing a user id."""
        return _USERS.get(id)

    def create(self, name: str, email: str) -> User:
        """Persist and return a freshly created user."""
        clean = normalize_email(email)
        user = User(len(_USERS) + 1, name, clean)
        _USERS[user.id] = {"name": name, "email": clean}
        return user

    def remove(self, id: int) -> bool:
        """Delete a user by id; True when a row was removed."""
        if id in _USERS:
            del _USERS[id]
            return True
        return False

    def list_all(self) -> list:
        """Return every stored user as a domain object."""
        return [User(uid, row["name"], row["email"]) for uid, row in _USERS.items()]

    def replace(self, id: int, name: str, email: str):
        """Overwrite a user's fields; None when the id is unknown."""
        if id not in _USERS:
            return None
        clean = normalize_email(email)
        _USERS[id] = {"name": name, "email": clean}
        return User(id, name, clean)

    def update_email(self, id: int, email: str):
        """Patch just the email of an existing user."""
        row = self._query(id)
        if row is None:
            return None
        row["email"] = normalize_email(email)
        return User(id, row["name"], row["email"])


def _seed_demo_data() -> None:
    """Populate the store with fixtures for local development."""
    _USERS[1] = {"name": "Ada", "email": "ada@example.com"}
