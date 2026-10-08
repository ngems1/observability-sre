"""Demo-grade identity: an X-API-Key header maps to a user and a role.
Keys are stored as SHA-256 hashes; the plain keys live in Secrets Manager / a K8s Secret."""

import hashlib

from fastapi import Depends, Header, HTTPException, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from opsdesk.db import get_session
from opsdesk.models import User


def hash_key(api_key: str) -> str:
    return hashlib.sha256(api_key.encode()).hexdigest()


def current_user(
    x_api_key: str | None = Header(default=None),
    session: Session = Depends(get_session),
) -> User:
    if not x_api_key:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "missing X-API-Key header")
    user = session.scalar(select(User).where(User.api_key_hash == hash_key(x_api_key)))
    if user is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "invalid API key")
    return user


def require_role(*roles: str):
    def checker(user: User = Depends(current_user)) -> User:
        if user.role not in roles:
            raise HTTPException(status.HTTP_403_FORBIDDEN, f"requires role: {', '.join(roles)}")
        return user

    return checker
