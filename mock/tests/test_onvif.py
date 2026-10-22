import asyncio
import base64
import hashlib
import secrets
import socket
from datetime import UTC, datetime, timedelta
from xml.etree import ElementTree

import httpx
import pytest

from camera_mock_server.cli import _run_onvif, main
from camera_mock_server.config import RTSP_PATHS, Vendor
from camera_mock_server.onvif import NAMESPACES, create_onvif_app
from camera_mock_server.rtsp import RTSPConfiguration

CAMERA = RTSPConfiguration(RTSP_PATHS[Vendor.ONVIF])


def envelope(body: str, password: str | None = "meerkat", created: datetime | None = None) -> str:
    header = ""
    if password is not None:
        nonce = secrets.token_bytes(16)
        timestamp = (created or datetime.now(UTC)).strftime("%Y-%m-%dT%H:%M:%SZ")
        digest = hashlib.sha1(nonce + timestamp.encode() + password.encode()).digest()
        header = (
            f'<s:Header><wsse:Security xmlns:wsse="{NAMESPACES["wsse"]}" '
            f'xmlns:wsu="{NAMESPACES["wsu"]}"><wsse:UsernameToken>'
            "<wsse:Username>admin</wsse:Username>"
            f"<wsse:Password>{base64.b64encode(digest).decode()}</wsse:Password>"
            f"<wsse:Nonce>{base64.b64encode(nonce).decode()}</wsse:Nonce>"
            f"<wsu:Created>{timestamp}</wsu:Created>"
            "</wsse:UsernameToken></wsse:Security></s:Header>"
        )
    return f'<s:Envelope xmlns:s="{NAMESPACES["s"]}">{header}<s:Body>{body}</s:Body></s:Envelope>'


async def post(path: str, content: str) -> tuple[int, ElementTree.Element]:
    transport = httpx.ASGITransport(app=create_onvif_app(8556, CAMERA))
    async with httpx.AsyncClient(transport=transport, base_url="http://camera.test") as client:
        response = await client.post(path, content=content)
    return response.status_code, ElementTree.fromstring(response.content)


def texts(element: ElementTree.Element, name: str) -> list[str]:
    return [node.text or "" for node in element.iter() if node.tag.endswith(f"}}{name}")]


@pytest.mark.anyio
async def test_reports_clock_without_authentication() -> None:
    body = '<GetSystemDateAndTime xmlns="http://www.onvif.org/ver10/device/wsdl"/>'
    status, response = await post("/onvif/device_service", envelope(body, password=None))

    assert status == 200
    assert texts(response, "Year") == [str(datetime.now(UTC).year)]


@pytest.mark.anyio
@pytest.mark.parametrize(
    ("password", "created"),
    [(None, None), ("wrong", None), ("meerkat", datetime.now(UTC) - timedelta(hours=1))],
)
async def test_rejects_missing_wrong_or_stale_credentials(
    password: str | None, created: datetime | None
) -> None:
    body = '<GetCapabilities xmlns="http://www.onvif.org/ver10/device/wsdl"/>'
    status, response = await post("/onvif/device_service", envelope(body, password, created))

    assert status == 400
    assert texts(response, "Value")[-1] == "ter:NotAuthorized"


@pytest.mark.anyio
async def test_advertises_media_service_profiles_and_stream_uris() -> None:
    body = '<GetCapabilities xmlns="http://www.onvif.org/ver10/device/wsdl"/>'
    _, capabilities = await post("/onvif/device_service", envelope(body))
    assert texts(capabilities, "XAddr") == ["http://camera.test/onvif/media_service"]

    body = f'<GetProfiles xmlns="{NAMESPACES["trt"]}"/>'
    _, profiles = await post("/onvif/media_service", envelope(body))
    tokens = [node.get("token") for node in profiles.iter() if node.tag.endswith("}Profiles")]
    assert tokens == ["profile-1", "profile-2"]
    assert texts(profiles, "Encoding") == ["H264", "H264"]

    uris = []
    for token in tokens:
        body = (
            f'<GetStreamUri xmlns="{NAMESPACES["trt"]}"><ProfileToken>{token}</ProfileToken>'
            "</GetStreamUri>"
        )
        _, stream = await post("/onvif/media_service", envelope(body))
        uris += texts(stream, "Uri")
    assert uris == [
        "rtsp://camera.test:8556/Streaming/Channels/101",
        "rtsp://camera.test:8556/Streaming/Channels/102",
    ]


@pytest.mark.anyio
async def test_rejects_malformed_requests() -> None:
    status, response = await post("/onvif/device_service", "<not-soap")

    assert status == 400
    assert texts(response, "Value")[-1] == "ter:WellFormed"


@pytest.mark.anyio
async def test_busy_onvif_port_fails_like_other_cameras(monkeypatch: pytest.MonkeyPatch) -> None:
    async def run(*_: object) -> None:
        await asyncio.Event().wait()

    monkeypatch.setattr("camera_mock_server.cli._run_rtsp", run)
    with socket.socket() as busy:
        busy.bind(("127.0.0.1", 0))
        busy.listen()
        with pytest.raises(RuntimeError, match="could not listen"):
            await _run_onvif("127.0.0.1", 8556, busy.getsockname()[1], CAMERA)


def test_onvif_type_runs_rtsp_and_device_service(monkeypatch: pytest.MonkeyPatch) -> None:
    calls = []

    async def run(host: str, port: int, onvif_port: int, configuration: RTSPConfiguration) -> None:
        calls.append((host, port, onvif_port, configuration.paths))

    monkeypatch.setattr("camera_mock_server.cli._run_onvif", run)
    main(["onvif"])

    assert calls == [("127.0.0.1", 8556, 8080, RTSP_PATHS[Vendor.ONVIF])]
