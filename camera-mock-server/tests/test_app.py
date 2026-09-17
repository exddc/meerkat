import hashlib

import httpx
import pytest
from fastapi import FastAPI

from camera_mock_server import Vendor, create_app
from camera_mock_server.auth import NONCE, REALM
from camera_mock_server.media import flv_stream, mjpeg_stream


@pytest.fixture
def anyio_backend() -> str:
    return "asyncio"


async def get(
    app: FastAPI,
    path: str,
    auth: httpx.Auth | None = None,
    headers: dict[str, str] | None = None,
) -> httpx.Response:
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://camera.test") as client:
        return await client.get(path, auth=auth, headers=headers)


def digest_header(uri: str) -> str:
    username = "admin"
    password = "meerkat"
    nonce_count = "00000001"
    client_nonce = "test-client"

    def digest(value: str) -> str:
        return hashlib.md5(value.encode(), usedforsecurity=False).hexdigest()

    ha1 = digest(f"{username}:{REALM}:{password}")
    ha2 = digest(f"GET:{uri}")
    response = digest(f"{ha1}:{NONCE}:{nonce_count}:{client_nonce}:auth:{ha2}")
    return (
        f'Digest username="{username}", realm="{REALM}", nonce="{NONCE}", uri="{uri}", '
        f'response="{response}", qop=auth, nc={nonce_count}, cnonce="{client_nonce}"'
    )


@pytest.mark.parametrize("vendor", list(Vendor))
@pytest.mark.anyio
async def test_reports_active_vendor(vendor: Vendor) -> None:
    response = await get(create_app(vendor), "/__mock__/health")

    assert response.json() == {"status": "ok", "vendor": vendor.value}


@pytest.mark.parametrize(
    ("vendor", "path", "marker"),
    [
        (Vendor.AXIS, "/axis-cgi/param.cgi?action=list", "AXIS"),
        (Vendor.HIKVISION, "/ISAPI/System/deviceInfo", "Hikvision"),
        (Vendor.DAHUA, "/cgi-bin/magicBox.cgi?action=getSystemInfo", "Dahua"),
    ],
)
@pytest.mark.anyio
async def test_digest_authenticated_identity(vendor: Vendor, path: str, marker: str) -> None:
    app = create_app(vendor)

    assert (await get(app, path)).status_code == 401
    response = await get(app, path, auth=httpx.DigestAuth("admin", "meerkat"))

    assert response.status_code == 200
    assert marker in response.text


@pytest.mark.anyio
async def test_digest_credentials_cannot_be_replayed_for_another_path() -> None:
    app = create_app(Vendor.AXIS)
    header = digest_header("/axis-cgi/param.cgi")

    response = await get(
        app,
        "/axis-cgi/jpg/image.cgi",
        headers={"Authorization": header},
    )

    assert response.status_code == 401


@pytest.mark.anyio
async def test_reolink_uses_query_credentials() -> None:
    app = create_app(Vendor.REOLINK)

    assert (await get(app, "/api.cgi?cmd=GetDevInfo")).status_code == 401
    response = await get(app, "/api.cgi?cmd=GetDevInfo&user=admin&password=meerkat")

    assert response.status_code == 200
    assert response.json()[0]["value"]["DevInfo"]["model"] == "RLC-520A"


@pytest.mark.anyio
async def test_profiles_only_expose_their_own_routes() -> None:
    app = create_app(Vendor.AXIS, require_auth=False)

    assert (await get(app, "/axis-cgi/param.cgi")).status_code == 200
    assert (await get(app, "/api.cgi")).status_code == 404


@pytest.mark.anyio
async def test_flv_stream_starts_with_valid_signature() -> None:
    stream = flv_stream()
    chunk = await anext(stream)
    await stream.aclose()

    assert chunk.startswith(b"FLV")


@pytest.mark.anyio
async def test_mjpeg_stream_contains_jpeg_frame() -> None:
    stream = mjpeg_stream()
    chunk = await anext(stream)
    await stream.aclose()
    assert chunk.startswith(b"--meerkat\r\n")
    assert b"\xff\xd8\xff" in chunk
