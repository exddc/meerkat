import argparse
from collections.abc import Sequence

import uvicorn

from camera_mock_server.app import Vendor, create_app


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description="Run a mock network camera")
    result.add_argument("vendor", choices=[vendor.value for vendor in Vendor])
    result.add_argument("--host", default="127.0.0.1")
    result.add_argument("--port", default=8000, type=int)
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
    app = create_app(
        Vendor(args.vendor),
        username=args.username,
        password=args.password,
        require_auth=not args.no_auth,
    )
    uvicorn.run(
        app,
        host=args.host,
        port=args.port,
        ssl_certfile=args.ssl_certfile,
        ssl_keyfile=args.ssl_keyfile,
    )
