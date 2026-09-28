from collections.abc import Callable

from fastapi import Depends, FastAPI, Request, Response
from fastapi.responses import JSONResponse, StreamingResponse

from camera_mock_server.auth import camera_auth
from camera_mock_server.config import DEFAULT_PASSWORD, DEFAULT_USERNAME, Vendor
from camera_mock_server.media import JPEG_FIXTURE, flv_stream


def create_app(
    *,
    username: str = DEFAULT_USERNAME,
    password: str = DEFAULT_PASSWORD,
    require_auth: bool = True,
) -> FastAPI:
    app = FastAPI(title="Camera Mock Server", docs_url=None, redoc_url=None, openapi_url=None)
    authenticate = camera_auth(username, password, require_auth)

    @app.get("/__mock__/health")
    def health() -> dict[str, str]:
        return {"status": "ok", "vendor": Vendor.REOLINK.value}

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
