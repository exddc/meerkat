from collections.abc import Callable

from fastapi import Depends, FastAPI, Request, Response
from fastapi.responses import JSONResponse, StreamingResponse

from camera_mock_server.app_types import Vendor
from camera_mock_server.auth import camera_auth
from camera_mock_server.media import JPEG_FIXTURE, flv_stream, mjpeg_stream


def create_app(
    vendor: Vendor,
    *,
    username: str = "admin",
    password: str = "meerkat",
    require_auth: bool = True,
) -> FastAPI:
    app = FastAPI(title="Camera Mock Server", docs_url=None, redoc_url=None, openapi_url=None)
    authenticate = camera_auth(vendor, username, password, require_auth)

    @app.get("/__mock__/health")
    def health() -> dict[str, str]:
        return {"status": "ok", "vendor": vendor.value}

    installers: dict[Vendor, Callable[[FastAPI, Callable[[Request], None]], None]] = {
        Vendor.REOLINK: _install_reolink,
        Vendor.AXIS: _install_axis,
        Vendor.HIKVISION: _install_hikvision,
        Vendor.DAHUA: _install_dahua,
    }
    installers[vendor](app, authenticate)
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


def _install_axis(app: FastAPI, authenticate: Callable[[Request], None]) -> None:
    @app.get("/axis-cgi/param.cgi", dependencies=[Depends(authenticate)])
    def parameters() -> Response:
        body = (
            "root.Brand.Brand=AXIS\n"
            "root.Properties.System.ProductNumber=P3265-LV\n"
            "root.Properties.API.HTTP.Version=3\n"
            "root.Properties.Image.Format=jpeg,mjpeg,h264,h265\n"
        )
        return Response(body, media_type="text/plain")

    @app.get("/axis-cgi/jpg/image.cgi", dependencies=[Depends(authenticate)])
    def snapshot() -> Response:
        return Response(JPEG_FIXTURE, media_type="image/jpeg")

    @app.get("/axis-cgi/mjpg/video.cgi", dependencies=[Depends(authenticate)])
    async def stream(fps: int = 5) -> StreamingResponse:
        return StreamingResponse(
            mjpeg_stream(fps), media_type="multipart/x-mixed-replace; boundary=meerkat"
        )


def _install_hikvision(app: FastAPI, authenticate: Callable[[Request], None]) -> None:
    @app.get("/ISAPI/System/deviceInfo", dependencies=[Depends(authenticate)])
    def device_info() -> Response:
        body = (
            '<?xml version="1.0" encoding="UTF-8"?>'
            '<DeviceInfo xmlns="http://www.isapi.org/ver20/XMLSchema" version="2.0">'
            "<deviceName>Camera Mock Server</deviceName><deviceType>IPCamera</deviceType>"
            "<model>DS-2CD2143G2-I</model><manufacturer>Hikvision</manufacturer></DeviceInfo>"
        )
        return Response(body, media_type="application/xml")

    @app.get("/ISAPI/Streaming/channels/{channel}/picture", dependencies=[Depends(authenticate)])
    def snapshot(channel: int) -> Response:
        return Response(JPEG_FIXTURE, media_type="image/jpeg", headers={"X-Channel": str(channel)})


def _install_dahua(app: FastAPI, authenticate: Callable[[Request], None]) -> None:
    @app.get("/cgi-bin/magicBox.cgi", dependencies=[Depends(authenticate)])
    def system_info(action: str = "getSystemInfo") -> Response:
        body = (
            f"result={'true' if action == 'getSystemInfo' else 'false'}\n"
            "deviceType=IPC-HDW5442TM-AS\nmanufacturer=Dahua\n"
        )
        return Response(body, media_type="text/plain")

    @app.get("/cgi-bin/snapshot.cgi", dependencies=[Depends(authenticate)])
    def snapshot() -> Response:
        return Response(JPEG_FIXTURE, media_type="image/jpeg")

    @app.get("/cgi-bin/mjpg/video.cgi", dependencies=[Depends(authenticate)])
    async def stream() -> StreamingResponse:
        return StreamingResponse(
            mjpeg_stream(), media_type="multipart/x-mixed-replace; boundary=meerkat"
        )


__all__ = ["Vendor", "create_app"]
