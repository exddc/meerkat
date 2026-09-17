import base64
import hashlib
import re
import secrets
from collections.abc import Callable

from fastapi import HTTPException, Request, status

from camera_mock_server.app_types import Vendor

REALM = "Camera Mock Server"
NONCE = hashlib.md5(b"camera-mock-server", usedforsecurity=False).hexdigest()
PAIR = re.compile(r'(\w+)=(?:"([^"]*)"|([^,\s]+))')


def _digest(value: str) -> str:
    return hashlib.md5(value.encode(), usedforsecurity=False).hexdigest()


def _unauthorized() -> HTTPException:
    challenge = f'Digest realm="{REALM}", nonce="{NONCE}", algorithm=MD5, qop="auth"'
    return HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Invalid camera credentials",
        headers={"WWW-Authenticate": challenge},
    )


def _valid_basic(value: str, username: str, password: str) -> bool:
    try:
        supplied = base64.b64decode(value, validate=True).decode()
    except (ValueError, UnicodeDecodeError):
        return False
    return secrets.compare_digest(supplied, f"{username}:{password}")


def _valid_digest(request: Request, value: str, username: str, password: str) -> bool:
    fields = {match[1]: match[2] or match[3] for match in PAIR.finditer(value)}
    required = {"username", "realm", "nonce", "uri", "response", "qop", "nc", "cnonce"}
    if fields.keys() < required:
        return False
    query = f"?{request.url.query}" if request.url.query else ""
    request_uri = f"{request.url.path}{query}"
    if not (
        secrets.compare_digest(fields["username"], username)
        and secrets.compare_digest(fields["realm"], REALM)
        and secrets.compare_digest(fields["nonce"], NONCE)
        and secrets.compare_digest(fields["uri"], request_uri)
        and fields["qop"] == "auth"
    ):
        return False
    ha1 = _digest(f"{username}:{REALM}:{password}")
    ha2 = _digest(f"{request.method}:{fields['uri']}")
    expected = _digest(f"{ha1}:{NONCE}:{fields['nc']}:{fields['cnonce']}:{fields['qop']}:{ha2}")
    return secrets.compare_digest(fields["response"], expected)


def camera_auth(
    vendor: Vendor, username: str, password: str, token: str, require_auth: bool
) -> Callable[[Request], None]:
    def authenticate(request: Request) -> None:
        if not require_auth:
            return
        if vendor is Vendor.REOLINK:
            supplied_user = request.query_params.get("user", "")
            supplied_password = request.query_params.get("password", "")
            if secrets.compare_digest(supplied_user, username) and secrets.compare_digest(
                supplied_password, password
            ):
                return
            raise _unauthorized()

        if vendor is Vendor.RING:
            supplied = request.headers.get("Authorization", "")
            if secrets.compare_digest(supplied, f"Bearer {token}"):
                return
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Invalid bearer token",
                headers={"WWW-Authenticate": "Bearer"},
            )

        if vendor is Vendor.UBIQUITI:
            if secrets.compare_digest(request.headers.get("X-API-Key", ""), token):
                return
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Invalid API key",
            )

        authorization = request.headers.get("Authorization", "")
        scheme, _, value = authorization.partition(" ")
        valid = (scheme.lower() == "basic" and _valid_basic(value, username, password)) or (
            scheme.lower() == "digest" and _valid_digest(request, value, username, password)
        )
        if not valid:
            raise _unauthorized()

    return authenticate
