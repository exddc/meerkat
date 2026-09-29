import argparse
import asyncio
import signal
from collections.abc import Sequence
from contextlib import suppress

import uvicorn

from camera_mock_server.app import create_app
from camera_mock_server.config import (
    DEFAULT_PASSWORD,
    DEFAULT_PORTS,
    DEFAULT_USERNAME,
    RTSP_PATHS,
    Vendor,
)
from camera_mock_server.rtsp import RTSPConfiguration, run_rtsp_server


def build_parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description="Run a mock home camera")
    result.add_argument("vendor", choices=[vendor.value for vendor in Vendor])
    result.add_argument("--host", default="127.0.0.1")
    result.add_argument("--port", type=int, help="default: reolink=8000, tapo=8554, eufy=8555")
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


def main(argv: Sequence[str] | None = None) -> None:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.port is not None and not 1 <= args.port <= 65535:
        parser.error("--port must be between 1 and 65535")
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
