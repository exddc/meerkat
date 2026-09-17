import asyncio
import base64
import hashlib

import httpx
import pytest
from fastapi import FastAPI

from camera_mock_server import Vendor, create_app
from camera_mock_server.auth import NONCE, REALM
from camera_mock_server.media import flv_stream, mjpeg_stream
from camera_mock_server.rtsp import create_rtsp_server


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


async def post(app: FastAPI, path: str, headers: dict[str, str]) -> httpx.Response:
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://camera.test") as client:
        return await client.post(path, headers=headers, json={})


async def rtsp_request(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    method: str,
    uri: str,
    cseq: int,
    headers: dict[str, str] | None = None,
) -> tuple[str, bytes]:
    fields = {"CSeq": str(cseq), **(headers or {})}
    request = [f"{method} {uri} RTSP/1.0", *(f"{key}: {value}" for key, value in fields.items())]
    writer.write(("\r\n".join(request) + "\r\n\r\n").encode())
    await writer.drain()
    head = (await reader.readuntil(b"\r\n\r\n")).decode()
    response_headers = {
        key.lower(): value.strip()
        for line in head.split("\r\n")[1:]
        if ":" in line
        for key, value in [line.split(":", 1)]
    }
    body = await reader.readexactly(int(response_headers.get("content-length", "0")))
    return head, body


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


@pytest.mark.parametrize("vendor", [vendor for vendor in Vendor if vendor is not Vendor.EUFY])
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


@pytest.mark.parametrize(
    ("vendor", "path", "headers", "marker"),
    [
        (Vendor.RING, "/v1/devices", {"Authorization": "Bearer meerkat"}, "ava1.ring"),
        (Vendor.UBIQUITI, "/v1/cameras", {"X-API-Key": "meerkat"}, "UVC G5 Bullet"),
    ],
)
@pytest.mark.anyio
async def test_token_authenticated_profiles(
    vendor: Vendor,
    path: str,
    headers: dict[str, str],
    marker: str,
) -> None:
    app = create_app(vendor)

    assert (await get(app, path)).status_code == 401
    response = await get(app, path, headers=headers)

    assert response.status_code == 200
    assert marker in response.text


@pytest.mark.anyio
async def test_ring_snapshot_download() -> None:
    app = create_app(Vendor.RING)
    path = "/v1/devices/ava1.ring.device.meerkat/media/image/download"

    response = await post(app, path, {"Authorization": "Bearer meerkat"})

    assert response.status_code == 200
    assert response.headers["content-type"] == "image/jpeg"
    assert response.content.startswith(b"\xff\xd8\xff")


@pytest.mark.anyio
async def test_ubiquiti_returns_rtsps_streams() -> None:
    app = create_app(Vendor.UBIQUITI)
    path = "/v1/cameras/66d025b301ebc903e80003ea/rtsps-stream"

    response = await get(app, path, headers={"X-API-Key": "meerkat"})

    assert response.status_code == 200
    assert response.json()["high"].startswith("rtsps://")


@pytest.mark.anyio
async def test_eufy_negotiates_rtsp_and_streams_h264() -> None:
    server = await create_rtsp_server("127.0.0.1", 0)
    socket = server.sockets[0]
    address = socket.getsockname()
    assert isinstance(address, tuple)
    port = address[1]
    assert isinstance(port, int)
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    uri = f"rtsp://127.0.0.1:{port}/live0"
    authorization = "Basic " + base64.b64encode(b"admin:meerkat").decode()

    try:
        head, _ = await rtsp_request(reader, writer, "DESCRIBE", uri, 1)
        assert head.startswith("RTSP/1.0 401")

        head, body = await rtsp_request(
            reader,
            writer,
            "DESCRIBE",
            uri,
            2,
            {"Authorization": authorization},
        )
        assert head.startswith("RTSP/1.0 200")
        assert b"H264/90000" in body

        setup_headers = {
            "Authorization": authorization,
            "Transport": "RTP/AVP/TCP;unicast;interleaved=0-1",
        }
        head, _ = await rtsp_request(reader, writer, "SETUP", f"{uri}/trackID=0", 3, setup_headers)
        assert head.startswith("RTSP/1.0 200")

        head, _ = await rtsp_request(
            reader,
            writer,
            "PLAY",
            uri,
            4,
            {"Authorization": authorization, "Session": "meerkat"},
        )
        assert head.startswith("RTSP/1.0 200")
        interleaved = await reader.readexactly(4)
        assert interleaved[:2] == b"$\x00"
        packet = await reader.readexactly(int.from_bytes(interleaved[2:]))
        assert packet[0] >> 6 == 2
    finally:
        writer.close()
        await writer.wait_closed()
        server.close()
        await server.wait_closed()


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
