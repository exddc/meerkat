import asyncio
from collections.abc import MutableMapping
from contextlib import suppress
from typing import Any

import httpx
import pytest
from fastapi import FastAPI

from camera_mock_server import create_app
from camera_mock_server.media import flv_stream


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


@pytest.mark.anyio
async def test_reolink_flv_uses_query_credentials() -> None:
    app = create_app()
    path = "/flv?port=1935&app=bcs&stream=channel0_sub.bcs&user=admin&password=meerkat"

    assert (await flv_prefix(app, "/flv"))[0] == 401
    status, prefix = await flv_prefix(app, path)

    assert status == 200
    assert prefix == b"FLV"


@pytest.mark.anyio
async def test_reolink_reports_device_info() -> None:
    app = create_app()

    assert (await get(app, "/api.cgi?cmd=GetDevInfo")).status_code == 401
    response = await get(app, "/api.cgi?cmd=GetDevInfo&user=admin&password=meerkat")

    assert response.status_code == 200
    assert response.json()[0]["value"]["DevInfo"]["model"] == "RLC-520A"


@pytest.mark.anyio
async def test_reolink_rejects_non_ascii_credentials() -> None:
    response = await get(create_app(), "/api.cgi?user=admin&password=m%C3%A9erkat")

    assert response.status_code == 401


@pytest.mark.anyio
async def test_reolink_without_auth_accepts_any_request() -> None:
    response = await get(create_app(require_auth=False), "/api.cgi?cmd=Snap")

    assert response.status_code == 200
    assert response.content.startswith(b"\xff\xd8")


@pytest.mark.anyio
async def test_flv_stream_starts_with_valid_signature() -> None:
    stream = flv_stream()
    chunk = await anext(stream)
    await stream.aclose()

    assert chunk.startswith(b"FLV")
