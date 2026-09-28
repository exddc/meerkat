import asyncio
import base64
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

import pytest

from camera_mock_server import Vendor
from camera_mock_server.config import RTSP_PATHS
from camera_mock_server.rtsp import RTSPConfiguration, create_rtsp_server

AUTHORIZATION = "Basic " + base64.b64encode(b"admin:meerkat").decode()


@asynccontextmanager
async def rtsp_client(
    configuration: RTSPConfiguration,
) -> AsyncIterator[tuple[asyncio.StreamReader, asyncio.StreamWriter, str]]:
    server = await create_rtsp_server("127.0.0.1", 0, configuration)
    port = server.sockets[0].getsockname()[1]
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    try:
        yield reader, writer, f"rtsp://127.0.0.1:{port}"
    finally:
        writer.close()
        await writer.wait_closed()
        server.close()
        await server.wait_closed()


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


@pytest.mark.parametrize("vendor", [Vendor.TAPO, Vendor.EUFY])
@pytest.mark.anyio
async def test_home_rtsp_streams_on_negotiated_channel(vendor: Vendor) -> None:
    paths = RTSP_PATHS[vendor]
    async with rtsp_client(RTSPConfiguration(paths)) as (reader, writer, base):
        uri = f"{base}{paths[0]}"
        head, _ = await rtsp_request(reader, writer, "DESCRIBE", uri, 1)
        assert head.startswith("RTSP/1.0 401")

        head, body = await rtsp_request(
            reader, writer, "DESCRIBE", uri, 2, {"Authorization": AUTHORIZATION}
        )
        assert head.startswith("RTSP/1.0 200")
        assert b"H264/90000" in body
        assert b"profile-level-id=42C016" in body

        head, _ = await rtsp_request(
            reader,
            writer,
            "SETUP",
            f"{uri}/trackID=0",
            3,
            {"Authorization": AUTHORIZATION, "Transport": "RTP/AVP;unicast;client_port=5000-5001"},
        )
        assert head.startswith("RTSP/1.0 461")

        head, _ = await rtsp_request(
            reader,
            writer,
            "SETUP",
            f"{uri}/trackID=0",
            4,
            {"Authorization": AUTHORIZATION, "Transport": "RTP/AVP/TCP;unicast;interleaved=2-3"},
        )
        assert head.startswith("RTSP/1.0 200")
        assert "interleaved=2-3" in head

        head, _ = await rtsp_request(
            reader,
            writer,
            "PLAY",
            uri,
            5,
            {"Authorization": AUTHORIZATION, "Session": "meerkat"},
        )
        assert head.startswith("RTSP/1.0 200")
        frame = await reader.readexactly(4)
        packet = await reader.readexactly(int.from_bytes(frame[2:4]))

        assert frame[:2] == b"$\x02"
        assert packet[0] >> 6 == 2
        assert packet[1] & 0x7F == 96


@pytest.mark.anyio
async def test_setup_picks_tcp_from_transport_list() -> None:
    paths = RTSP_PATHS[Vendor.EUFY]
    async with rtsp_client(RTSPConfiguration(paths, require_auth=False)) as (reader, writer, base):
        transport = "RTP/AVP;unicast;client_port=5000-5001,RTP/AVP/TCP;unicast;interleaved=0-1"
        head, _ = await rtsp_request(
            reader, writer, "SETUP", f"{base}{paths[0]}/trackID=0", 1, {"Transport": transport}
        )

        assert head.startswith("RTSP/1.0 200")
        assert "Transport: RTP/AVP/TCP;unicast;interleaved=0-1" in head


@pytest.mark.anyio
async def test_tapo_rejects_eufy_path() -> None:
    configuration = RTSPConfiguration(RTSP_PATHS[Vendor.TAPO], require_auth=False)
    async with rtsp_client(configuration) as (reader, writer, base):
        head, _ = await rtsp_request(reader, writer, "DESCRIBE", f"{base}/live0", 1)
        assert head.startswith("RTSP/1.0 404")
        head, _ = await rtsp_request(reader, writer, "DESCRIBE", f"{base}/stream2", 2)
        assert head.startswith("RTSP/1.0 200")


@pytest.mark.anyio
async def test_rejects_non_ascii_credentials() -> None:
    paths = RTSP_PATHS[Vendor.EUFY]
    authorization = "Basic " + base64.b64encode("admin:mëërkat".encode()).decode()
    async with rtsp_client(RTSPConfiguration(paths)) as (reader, writer, base):
        head, _ = await rtsp_request(
            reader, writer, "DESCRIBE", f"{base}{paths[0]}", 1, {"Authorization": authorization}
        )

        assert head.startswith("RTSP/1.0 401")


@pytest.mark.anyio
async def test_rejects_invalid_content_length() -> None:
    paths = RTSP_PATHS[Vendor.EUFY]
    async with rtsp_client(RTSPConfiguration(paths, require_auth=False)) as (reader, writer, base):
        head, _ = await rtsp_request(
            reader, writer, "DESCRIBE", f"{base}{paths[0]}", 1, {"Content-Length": "abc"}
        )

        assert head.startswith("RTSP/1.0 400")
