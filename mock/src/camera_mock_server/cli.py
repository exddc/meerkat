import argparse
import asyncio
import signal
import socket
from collections.abc import Iterator, Sequence
from contextlib import contextmanager, suppress

import uvicorn

from camera_mock_server.app import create_app
from camera_mock_server.config import (
    DEFAULT_ONVIF_PORT,
    DEFAULT_PASSWORD,
    DEFAULT_PORTS,
    DEFAULT_USERNAME,
    RTSP_PATHS,
    Vendor,
)
from camera_mock_server.onvif import create_onvif_app
from camera_mock_server.rtsp import RTSPConfiguration, run_rtsp_server


def build_parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description="Run a mock home camera")
    result.add_argument("vendor", choices=[vendor.value for vendor in Vendor])
    result.add_argument("--host", default="127.0.0.1")
    result.add_argument(
        "--port", type=int, help="default: reolink=8000, tapo=8554, eufy=8555, onvif=8556"
    )
    result.add_argument(
        "--onvif-port", type=int, help=f"ONVIF device service port, default: {DEFAULT_ONVIF_PORT}"
    )
    result.add_argument("--username", default=DEFAULT_USERNAME)
    result.add_argument("--password", default=DEFAULT_PASSWORD)
    result.add_argument("--no-auth", action="store_true")
    result.add_argument("--auth-method", choices=["basic", "digest"], default="digest")
    result.add_argument("--ssl-certfile")
    result.add_argument("--ssl-keyfile")
    return result


async def _run_rtsp(host: str, port: int, configuration: RTSPConfiguration) -> None:
    loop = asyncio.get_running_loop()
    task = asyncio.current_task()
    assert task is not None
    loop.add_signal_handler(signal.SIGTERM, task.cancel)
    try:
        await run_rtsp_server(host, port, configuration)
    finally:
        loop.remove_signal_handler(signal.SIGTERM)


class _EmbeddedServer(uvicorn.Server):
    # Leave SIGTERM to the RTSP task so MediaMTX and FFmpeg are always stopped.
    @contextmanager
    def capture_signals(self) -> Iterator[None]:
        yield

    async def serve(self, sockets: list[socket.socket] | None = None) -> None:
        try:
            await super().serve(sockets)
        except SystemExit:
            raise RuntimeError(
                f"ONVIF service could not listen on port {self.config.port}"
            ) from None


async def _run_onvif(
    host: str, port: int, onvif_port: int, configuration: RTSPConfiguration
) -> None:
    app = create_onvif_app(port, configuration)
    server = _EmbeddedServer(
        uvicorn.Config(app, host=host, port=onvif_port, lifespan="off", access_log=False)
    )
    tasks = [
        asyncio.create_task(_run_rtsp(host, port, configuration)),
        asyncio.create_task(server.serve()),
    ]
    try:
        done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        for task in done:
            task.result()
    finally:
        server.should_exit = True
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)


def main(argv: Sequence[str] | None = None) -> None:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.onvif_port is not None and args.vendor != Vendor.ONVIF:
        parser.error("--onvif-port only applies to the onvif camera")
    onvif_port = args.onvif_port if args.onvif_port is not None else DEFAULT_ONVIF_PORT
    for name, value in (("--port", args.port), ("--onvif-port", onvif_port)):
        if value is not None and not 1 <= value <= 65535:
            parser.error(f"{name} must be between 1 and 65535")
    if bool(args.ssl_certfile) != bool(args.ssl_keyfile):
        parser.error("--ssl-certfile and --ssl-keyfile must be used together")
    vendor = Vendor(args.vendor)
    port = args.port if args.port is not None else DEFAULT_PORTS[vendor]
    if vendor in RTSP_PATHS:
        if args.ssl_certfile:
            parser.error("TLS certificate options do not apply to RTSP profiles")
        try:
            configuration = RTSPConfiguration(
                RTSP_PATHS[vendor],
                username=args.username,
                password=args.password,
                require_auth=not args.no_auth,
                auth_method=args.auth_method,
            )
            with suppress(KeyboardInterrupt, asyncio.CancelledError):
                if vendor == Vendor.ONVIF:
                    asyncio.run(_run_onvif(args.host, port, onvif_port, configuration))
                else:
                    asyncio.run(_run_rtsp(args.host, port, configuration))
        except (RuntimeError, ValueError, OSError, TimeoutError) as error:
            parser.exit(1, f"Camera failed: {error}\n")
        return

    app = create_app(
        username=args.username,
        password=args.password,
        require_auth=not args.no_auth,
    )
    uvicorn.run(
        app,
        host=args.host,
        port=port,
        ssl_certfile=args.ssl_certfile,
        ssl_keyfile=args.ssl_keyfile,
    )
