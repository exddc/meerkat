import asyncio
import json
import os
import shutil
import socket
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from dataclasses import dataclass
from pathlib import Path
from tempfile import TemporaryDirectory

from camera_mock_server.config import DEFAULT_PASSWORD, DEFAULT_USERNAME


@dataclass(frozen=True)
class RTSPConfiguration:
    paths: tuple[str, ...]
    username: str = DEFAULT_USERNAME
    password: str = DEFAULT_PASSWORD
    require_auth: bool = True
    auth_method: str = "basic"

    def __post_init__(self) -> None:
        if self.auth_method not in {"basic", "digest"}:
            raise ValueError("Authentication must be basic or digest")
        if not self.paths or any(not path.startswith("/") for path in self.paths):
            raise ValueError("Stream paths must start with /")
        if self.require_auth and (not self.username or self.username == "any" or not self.password):
            raise ValueError("Authentication requires a username (other than 'any') and password")


def server_config(host: str, port: int, camera: RTSPConfiguration) -> dict:
    if not 1 <= port <= 65535:
        raise ValueError("Port must be between 1 and 65535")
    address = f"[{host}]" if ":" in host else host
    paths = [path.lstrip("/") for path in camera.paths]
    return {
        "logLevel": "warn",
        "rtspAddress": f"{address}:{port}",
        "rtspTransports": ["tcp"],
        "rtspAuthMethods": [camera.auth_method],
        "rtmp": False,
        "hls": False,
        "webrtc": False,
        "srt": False,
        "moq": False,
        "authInternalUsers": [
            {
                "user": "any",
                "ips": ["127.0.0.1", "::1"],
                "permissions": [{"action": "publish", "path": path} for path in paths],
            },
            {
                "user": camera.username if camera.require_auth else "any",
                "pass": camera.password if camera.require_auth else "",
                "permissions": [{"action": "read", "path": path} for path in paths],
            },
        ],
        "paths": {path: {"source": "publisher"} for path in paths},
    }


def publisher_command(ffmpeg: str, url: str) -> list[str]:
    return [
        ffmpeg,
        "-nostdin",
        "-hide_banner",
        "-loglevel",
        "error",
        "-re",
        "-f",
        "lavfi",
        "-i",
        "testsrc2=size=640x360:rate=10",
        "-an",
        "-c:v",
        "libx264",
        "-preset",
        "ultrafast",
        "-tune",
        "zerolatency",
        "-pix_fmt",
        "yuv420p",
        "-profile:v",
        "baseline",
        "-g",
        "10",
        "-f",
        "rtsp",
        "-rtsp_transport",
        "tcp",
        url,
    ]


async def _stop(process: asyncio.subprocess.Process) -> None:
    if process.returncode is not None:
        return
    try:
        process.terminate()
    except ProcessLookupError:
        return
    try:
        await asyncio.wait_for(process.wait(), timeout=3)
    except TimeoutError:
        process.kill()
        await process.wait()


async def _wait_for_listener(host: str, port: int, process: asyncio.subprocess.Process) -> None:
    async with asyncio.timeout(10):
        while True:
            if process.returncode is not None:
                raise RuntimeError(f"MediaMTX exited with status {process.returncode}")
            try:
                _, writer = await asyncio.open_connection(host, port)
            except OSError:
                await asyncio.sleep(0.05)
            else:
                writer.close()
                await writer.wait_closed()
                return


@asynccontextmanager
async def camera_server(
    host: str,
    port: int,
    camera: RTSPConfiguration,
) -> AsyncIterator[tuple[asyncio.subprocess.Process, ...]]:
    binaries = {name: shutil.which(name) for name in ("mediamtx", "ffmpeg")}
    missing = [name for name, binary in binaries.items() if binary is None]
    if missing:
        raise RuntimeError(f"Missing executable(s): {', '.join(missing)}. See mock/README.md.")
    config = server_config(host, port, camera)
    for family, kind, protocol, _, address in socket.getaddrinfo(
        host, port, type=socket.SOCK_STREAM
    ):
        with socket.socket(family, kind, protocol) as reservation:
            reservation.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            reservation.bind(address)
    connect_host = {"0.0.0.0": "127.0.0.1", "::": "::1"}.get(host, host)
    publisher = config["authInternalUsers"][0]
    publisher["ips"] = list({entry[4][0] for entry in socket.getaddrinfo(connect_host, port)})
    address = f"[{connect_host}]" if ":" in connect_host else connect_host
    processes: list[asyncio.subprocess.Process] = []
    with TemporaryDirectory(prefix="meerkat-camera-") as directory:
        config_path = Path(directory) / "mediamtx.yml"
        config_path.write_text(json.dumps(config))
        config_path.chmod(0o600)
        environment = {
            key: value for key, value in os.environ.items() if not key.startswith("MTX_")
        }
        try:
            server = await asyncio.create_subprocess_exec(
                str(binaries["mediamtx"]),
                str(config_path),
                env=environment,
            )
            processes.append(server)
            await _wait_for_listener(connect_host, port, server)
            for path in camera.paths:
                publisher = await asyncio.create_subprocess_exec(
                    *publisher_command(str(binaries["ffmpeg"]), f"rtsp://{address}:{port}{path}")
                )
                processes.append(publisher)
            yield tuple(processes)
        finally:
            for process in reversed(processes):
                await _stop(process)


async def run_rtsp_server(host: str, port: int, configuration: RTSPConfiguration) -> None:
    async with camera_server(host, port, configuration) as processes:
        print(
            f"RTSP camera starting on {host}:{port}: {', '.join(configuration.paths)}", flush=True
        )
        waiters = [asyncio.create_task(process.wait()) for process in processes]
        try:
            done, _ = await asyncio.wait(waiters, return_when=asyncio.FIRST_COMPLETED)
            raise RuntimeError(f"Camera process exited with status {next(iter(done)).result()}")
        finally:
            for waiter in waiters:
                waiter.cancel()
            await asyncio.gather(*waiters, return_exceptions=True)
