import asyncio
import shutil
import socket

import pytest

from camera_mock_server.config import RTSP_PATHS, Vendor
from camera_mock_server.rtsp import RTSPConfiguration, camera_server, server_config


def test_config_separates_publish_and_read_permissions() -> None:
    config = server_config("127.0.0.1", 8554, RTSPConfiguration(("/live0",), auth_method="digest"))
    assert config["rtspAuthMethods"] == ["digest"]
    publisher, reader = config["authInternalUsers"]
    assert publisher["ips"] == ["127.0.0.1", "::1"]
    assert publisher["permissions"] == [{"action": "publish", "path": "live0"}]
    assert reader["permissions"] == [{"action": "read", "path": "live0"}]
    assert config["paths"] == {"live0": {"source": "publisher"}}
    assert not any(config[key] for key in ("hls", "rtmp", "webrtc", "srt", "moq"))


def test_no_auth_and_ipv6_configuration() -> None:
    config = server_config("::1", 8555, RTSPConfiguration(("/stream1",), require_auth=False))
    assert config["rtspAddress"] == "[::1]:8555"
    assert config["authInternalUsers"][1]["user"] == "any"


@pytest.mark.parametrize("port", [0, -1, 65536])
def test_invalid_port(port: int) -> None:
    with pytest.raises(ValueError, match="Port"):
        server_config("127.0.0.1", port, RTSPConfiguration(("/live0",)))


@pytest.mark.anyio
async def test_missing_binary_is_actionable(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(shutil, "which", lambda name: None)
    with pytest.raises(RuntimeError, match="Missing executable.*mediamtx.*ffmpeg"):
        async with camera_server("127.0.0.1", 8554, RTSPConfiguration(("/live0",))):
            pytest.fail("Server must not start")


async def decode(url: str) -> int:
    process = await asyncio.create_subprocess_exec(
        "ffmpeg",
        "-nostdin",
        "-hide_banner",
        "-loglevel",
        "error",
        "-rtsp_transport",
        "tcp",
        "-i",
        url,
        "-frames:v",
        "2",
        "-f",
        "null",
        "-",
        stdout=asyncio.subprocess.DEVNULL,
        stderr=asyncio.subprocess.DEVNULL,
    )
    try:
        return await asyncio.wait_for(process.wait(), 8)
    finally:
        if process.returncode is None:
            process.kill()
            await process.wait()


@pytest.mark.skipif(
    not shutil.which("mediamtx") or not shutil.which("ffmpeg"),
    reason="Integration requires MediaMTX and FFmpeg on PATH",
)
@pytest.mark.parametrize("vendor", [Vendor.TAPO, Vendor.EUFY])
@pytest.mark.parametrize("auth_method", ["basic", "digest"])
@pytest.mark.anyio
async def test_real_streams_authentication_and_cleanup(vendor: Vendor, auth_method: str) -> None:
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    configuration = RTSPConfiguration(RTSP_PATHS[vendor], auth_method=auth_method)
    async with camera_server("127.0.0.1", port, configuration) as processes:
        for path in configuration.paths:
            async with asyncio.timeout(15):
                while await decode(f"rtsp://admin:meerkat@127.0.0.1:{port}{path}") != 0:
                    assert all(process.returncode is None for process in processes)
                    await asyncio.sleep(0.1)
        assert await decode(f"rtsp://admin:wrong@127.0.0.1:{port}{configuration.paths[0]}") != 0
        assert await decode(f"rtsp://admin:meerkat@127.0.0.1:{port}/unknown") != 0
    assert all(process.returncode is not None for process in processes)


@pytest.mark.skipif(
    not shutil.which("mediamtx") or not shutil.which("ffmpeg"),
    reason="Integration requires MediaMTX and FFmpeg on PATH",
)
@pytest.mark.anyio
async def test_startup_failure_does_not_leave_children() -> None:
    with socket.socket() as occupied:
        occupied.bind(("127.0.0.1", 0))
        port = occupied.getsockname()[1]
        occupied.listen()
        with pytest.raises(OSError):
            async with camera_server("127.0.0.1", port, RTSPConfiguration(("/live0",))):
                pytest.fail("Occupied port must fail startup")


@pytest.mark.skipif(
    not shutil.which("mediamtx") or not shutil.which("ffmpeg"),
    reason="Integration requires MediaMTX and FFmpeg on PATH",
)
@pytest.mark.anyio
async def test_cancellation_stops_every_child() -> None:
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    started = asyncio.Event()
    children: list[asyncio.subprocess.Process] = []

    async def run() -> None:
        async with camera_server(
            "127.0.0.1", port, RTSPConfiguration(("/live0",), require_auth=False)
        ) as processes:
            children.extend(processes)
            started.set()
            await asyncio.Event().wait()

    task = asyncio.create_task(run())
    try:
        await asyncio.wait_for(started.wait(), 10)
    finally:
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
    assert children
    assert all(child.returncode is not None for child in children)
