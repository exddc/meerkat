from collections.abc import Callable

from fastapi import Depends, FastAPI, Request, Response
from fastapi.responses import JSONResponse, StreamingResponse

from camera_mock_server.app_types import Vendor
from camera_mock_server.auth import camera_auth
from camera_mock_server.media import JPEG_FIXTURE, flv_stream


def create_app(
    vendor: Vendor,
    *,
    username: str = "admin",
    password: str = "meerkat",
    require_auth: bool = True,
) -> FastAPI:
    if vendor is not Vendor.REOLINK:
        raise ValueError(f"The {vendor.value} profile uses the RTSP server")
    app = FastAPI(title="Camera Mock Server", docs_url=None, redoc_url=None, openapi_url=None)
    authenticate = camera_auth(username, password, require_auth)

    @app.get("/__mock__/health")
    def health() -> dict[str, str]:
        return {"status": "ok", "vendor": vendor.value}

    _install_reolink(app, authenticate)
    return app


def _install_reolink(app: FastAPI, authenticate: Callable[[Request], None]) -> None:
    @app.get("/flv", dependencies=[Depends(authenticate)])
    async def stream() -> StreamingResponse:
        return StreamingResponse(flv_stream(), media_type="video/x-flv")

    @app.get("/cgi-bin/api.cgi", dependencies=[Depends(authenticate)])
    @app.get("/api.cgi", dependencies=[Depends(authenticate)])
    def api(cmd: str = "GetDevInfo") -> Response:
        if cmd == "Snap":
            return Response(JPEG_FIXTURE, media_type="image/jpeg")
        body = [{"cmd": cmd, "code": 0, "value": {"DevInfo": {"model": "RLC-520A"}}}]
        return JSONResponse(body)


__all__ = ["Vendor", "create_app"]
