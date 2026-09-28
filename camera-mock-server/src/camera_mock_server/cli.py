import argparse
import asyncio
from collections.abc import Sequence
from contextlib import suppress

import uvicorn

from camera_mock_server.app import create_app
from camera_mock_server.config import DEFAULT_PASSWORD, DEFAULT_USERNAME, RTSP_PATHS, Vendor
from camera_mock_server.rtsp import RTSPConfiguration, run_rtsp_server


def build_parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description="Run a mock home camera")
    result.add_argument("vendor", choices=[vendor.value for vendor in Vendor])
    result.add_argument("--host", default="127.0.0.1")
    result.add_argument("--port", type=int)
    result.add_argument("--username", default=DEFAULT_USERNAME)
    result.add_argument("--password", default=DEFAULT_PASSWORD)
    result.add_argument("--no-auth", action="store_true")
    result.add_argument("--ssl-certfile")
    result.add_argument("--ssl-keyfile")
    return result


def main(argv: Sequence[str] | None = None) -> None:
    parser = build_parser()
    args = parser.parse_args(argv)
    if bool(args.ssl_certfile) != bool(args.ssl_keyfile):
        parser.error("--ssl-certfile and --ssl-keyfile must be used together")
    vendor = Vendor(args.vendor)
    if vendor in RTSP_PATHS:
        if args.ssl_certfile:
            parser.error("TLS certificate options do not apply to RTSP profiles")
        configuration = RTSPConfiguration(
            RTSP_PATHS[vendor],
            username=args.username,
            password=args.password,
            require_auth=not args.no_auth,
        )
        with suppress(KeyboardInterrupt):
            asyncio.run(run_rtsp_server(args.host, args.port or 8554, configuration))
        return

    app = create_app(
        username=args.username,
        password=args.password,
        require_auth=not args.no_auth,
    )
    uvicorn.run(
        app,
        host=args.host,
        port=args.port or 8000,
        ssl_certfile=args.ssl_certfile,
        ssl_keyfile=args.ssl_keyfile,
    )
