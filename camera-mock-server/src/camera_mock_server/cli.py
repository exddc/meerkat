import argparse
import asyncio
from collections.abc import Sequence
from contextlib import suppress

import uvicorn

from camera_mock_server.app import create_app
from camera_mock_server.app_types import RTSP_PATHS, Vendor
from camera_mock_server.rtsp import run_rtsp_server


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description="Run a mock home camera")
    result.add_argument("vendor", choices=[vendor.value for vendor in Vendor])
    result.add_argument("--host", default="127.0.0.1")
    result.add_argument("--port", type=int)
    result.add_argument("--username", default="admin")
    result.add_argument("--password", default="meerkat")
    result.add_argument("--no-auth", action="store_true")
    result.add_argument("--ssl-certfile")
    result.add_argument("--ssl-keyfile")
    return result


def main(argv: Sequence[str] | None = None) -> None:
    args = parser().parse_args(argv)
    if bool(args.ssl_certfile) != bool(args.ssl_keyfile):
        parser().error("--ssl-certfile and --ssl-keyfile must be used together")
    vendor = Vendor(args.vendor)
    if vendor in RTSP_PATHS:
        if args.ssl_certfile or args.ssl_keyfile:
            parser().error("TLS certificate options do not apply to RTSP profiles")
        with suppress(KeyboardInterrupt):
            asyncio.run(
                run_rtsp_server(
                    args.host,
                    args.port or 8554,
                    paths=RTSP_PATHS[vendor],
                    username=args.username,
                    password=args.password,
                    require_auth=not args.no_auth,
                )
            )
        return

    app = create_app(
        vendor,
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
