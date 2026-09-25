import asyncio
import base64
from collections.abc import MutableMapping
from contextlib import suppress
from typing import Any

import httpx
import pytest
from fastapi import FastAPI

from camera_mock_server import Vendor, create_app
from camera_mock_server.app_types import RTSP_PATHS
from camera_mock_server.media import flv_stream
from camera_mock_server.rtsp import create_rtsp_server


@pytest.fixture
def anyio_backend() -> str:
    return "asyncio"


async def get(app: FastAPI, path: str) -> httpx.Response:
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://camera.test") as client:
        return await client.get(path)


async def flv_prefix(app: FastAPI, path: str) -> tuple[int, bytes]:
    path, _, query = path.partition("?")
    started = False
    opened: asyncio.Future[tuple[int, bytes]] = asyncio.get_running_loop().create_future()

    async def receive() -> MutableMapping[str, Any]:
        nonlocal started
        if not started:
            started = True
            return {"type": "http.request", "body": b"", "more_body": False}
        await opened
        return {"type": "http.disconnect"}

    async def send(message: MutableMapping[str, Any]) -> None:
        if opened.done():
            return
        if message["type"] == "http.response.start":
            status = message["status"]
            assert isinstance(status, int)
            if status != 200:
                opened.set_result((status, b""))
        elif message["type"] == "http.response.body":
            body = message.get("body", b"")
            assert isinstance(body, bytes)
            if body:
                opened.set_result((200, body[:3]))

    scope = {
        "type": "http",
        "asgi": {"version": "3.0"},
        "http_version": "1.1",
        "method": "GET",
        "scheme": "http",
        "path": path,
        "raw_path": path.encode(),
        "query_string": query.encode(),
        "headers": [],
        "client": ("127.0.0.1", 123),
        "server": ("camera.test", 80),
    }
    task = asyncio.create_task(app(scope, receive, send))
    try:
        return await asyncio.wait_for(opened, timeout=2)
    finally:
        task.cancel()
        with suppress(asyncio.CancelledError):
            await task


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


@pytest.mark.anyio
async def test_reolink_flv_uses_query_credentials() -> None:
    app = create_app(Vendor.REOLINK)
    path = "/flv?port=1935&app=bcs&stream=channel0_sub.bcs&user=admin&password=meerkat"

    assert (await flv_prefix(app, "/flv"))[0] == 401
    status, prefix = await flv_prefix(app, path)

    assert status == 200
    assert prefix == b"FLV"


@pytest.mark.anyio
async def test_reolink_reports_device_info() -> None:
    app = create_app(Vendor.REOLINK)

    assert (await get(app, "/api.cgi?cmd=GetDevInfo")).status_code == 401
    response = await get(app, "/api.cgi?cmd=GetDevInfo&user=admin&password=meerkat")

    assert response.status_code == 200
    assert response.json()[0]["value"]["DevInfo"]["model"] == "RLC-520A"


@pytest.mark.anyio
async def test_flv_stream_starts_with_valid_signature() -> None:
    stream = flv_stream()
    chunk = await anext(stream)
    await stream.aclose()

    assert chunk.startswith(b"FLV")


@pytest.mark.parametrize("vendor", [Vendor.TAPO, Vendor.EUFY])
@pytest.mark.anyio
async def test_home_rtsp_requires_tcp_interleaved(vendor: Vendor) -> None:
    paths = RTSP_PATHS[vendor]
    server = await create_rtsp_server("127.0.0.1", 0, paths)
    socket = server.sockets[0]
    address = socket.getsockname()
    assert isinstance(address, tuple)
    port = address[1]
    assert isinstance(port, int)
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    uri = f"rtsp://127.0.0.1:{port}{paths[0]}"
    authorization = "Basic " + base64.b64encode(b"admin:meerkat").decode()

    try:
        head, _ = await rtsp_request(reader, writer, "DESCRIBE", uri, 1)
        assert head.startswith("RTSP/1.0 401")

        head, body = await rtsp_request(
            reader, writer, "DESCRIBE", uri, 2, {"Authorization": authorization}
        )
        assert head.startswith("RTSP/1.0 200")
        assert b"H264/90000" in body

        head, _ = await rtsp_request(
            reader,
            writer,
            "SETUP",
            f"{uri}/trackID=0",
            3,
            {"Authorization": authorization, "Transport": "RTP/AVP;unicast;client_port=5000-5001"},
        )
        assert head.startswith("RTSP/1.0 461")

        head, _ = await rtsp_request(
            reader,
            writer,
            "SETUP",
            f"{uri}/trackID=0",
            4,
            {
                "Authorization": authorization,
                "Transport": "RTP/AVP/TCP;unicast;interleaved=0-1",
            },
        )
        assert head.startswith("RTSP/1.0 200")
        assert "interleaved=0-1" in head

        head, _ = await rtsp_request(
            reader,
            writer,
            "PLAY",
            uri,
            5,
            {"Authorization": authorization, "Session": "meerkat"},
        )
        assert head.startswith("RTSP/1.0 200")
        interleaved = await reader.readexactly(4)
        assert interleaved[:2] == b"$\x00"
    finally:
        writer.close()
        await writer.wait_closed()
        server.close()
        await server.wait_closed()


@pytest.mark.anyio
async def test_tapo_rejects_eufy_path() -> None:
    server = await create_rtsp_server("127.0.0.1", 0, RTSP_PATHS[Vendor.TAPO], require_auth=False)
    socket = server.sockets[0]
    address = socket.getsockname()
    assert isinstance(address, tuple)
    port = address[1]
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    try:
        head, _ = await rtsp_request(
            reader, writer, "DESCRIBE", f"rtsp://127.0.0.1:{port}/live0", 1
        )
        assert head.startswith("RTSP/1.0 404")
        head, _ = await rtsp_request(
            reader, writer, "DESCRIBE", f"rtsp://127.0.0.1:{port}/stream2", 2
        )
        assert head.startswith("RTSP/1.0 200")
    finally:
        writer.close()
        await writer.wait_closed()
        server.close()
        await server.wait_closed()
