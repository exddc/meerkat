import secrets
from collections.abc import Callable

from fastapi import HTTPException, Request, status


def camera_auth(username: str, password: str, require_auth: bool) -> Callable[[Request], None]:
    def authenticate(request: Request) -> None:
        if not require_auth:
            return
        supplied_user = request.query_params.get("user", "")
        supplied_password = request.query_params.get("password", "")
        if secrets.compare_digest(supplied_user, username) and secrets.compare_digest(
            supplied_password, password
        ):
            return
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid camera credentials",
        )

    return authenticate
