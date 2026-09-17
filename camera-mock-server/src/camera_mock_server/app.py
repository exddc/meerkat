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
    token: str = "meerkat",
    require_auth: bool = True,
) -> FastAPI:
    if vendor is Vendor.EUFY:
        raise ValueError("The eufy profile uses the RTSP server")
    app = FastAPI(title="Camera Mock Server", docs_url=None, redoc_url=None, openapi_url=None)
    authenticate = camera_auth(vendor, username, password, token, require_auth)

    @app.get("/__mock__/health")
    def health() -> dict[str, str]:
        return {"status": "ok", "vendor": vendor.value}

    installers: dict[Vendor, Callable[[FastAPI, Callable[[Request], None]], None]] = {
        Vendor.REOLINK: _install_reolink,
        Vendor.AXIS: _install_axis,
        Vendor.HIKVISION: _install_hikvision,
        Vendor.DAHUA: _install_dahua,
        Vendor.RING: _install_ring,
        Vendor.UBIQUITI: _install_ubiquiti,
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


def _install_ring(app: FastAPI, authenticate: Callable[[Request], None]) -> None:
    device_id = "ava1.ring.device.meerkat"

    def device() -> dict[str, object]:
        return {
            "type": "devices",
            "id": device_id,
            "attributes": {"name": "Front Door Camera"},
            "relationships": {
                "status": {
                    "data": {"type": "device-status", "id": f"{device_id}.status"},
                    "links": {"related": f"/v1/devices/{device_id}/status"},
                },
                "capabilities": {
                    "data": {"type": "device-capabilities", "id": f"{device_id}.capabilities"},
                    "links": {"related": f"/v1/devices/{device_id}/capabilities"},
                },
            },
        }

    @app.get("/v1/devices", dependencies=[Depends(authenticate)])
    def devices() -> dict[str, object]:
        return {"meta": {"time": "2026-01-01T00:00:00Z"}, "data": [device()]}

    @app.get("/v1/devices/{requested_id}", dependencies=[Depends(authenticate)])
    def device_details(requested_id: str) -> Response:
        if requested_id != device_id:
            return JSONResponse({"errors": [{"status": "404"}]}, status_code=404)
        return JSONResponse({"data": device()})

    @app.get("/v1/devices/{requested_id}/status", dependencies=[Depends(authenticate)])
    def status(requested_id: str) -> Response:
        if requested_id != device_id:
            return JSONResponse({"errors": [{"status": "404"}]}, status_code=404)
        data = {
            "type": "device-status",
            "id": f"{device_id}.status",
            "attributes": {"online": True},
        }
        return JSONResponse({"data": data})

    @app.post(
        "/v1/devices/{requested_id}/media/image/download",
        dependencies=[Depends(authenticate)],
    )
    def snapshot(requested_id: str) -> Response:
        if requested_id != device_id:
            return JSONResponse({"errors": [{"status": "404"}]}, status_code=404)
        return Response(JPEG_FIXTURE, media_type="image/jpeg")


def _install_ubiquiti(app: FastAPI, authenticate: Callable[[Request], None]) -> None:
    camera_id = "66d025b301ebc903e80003ea"
    camera = {
        "id": camera_id,
        "modelKey": "camera",
        "state": "CONNECTED",
        "name": "Front Door",
        "type": "UVC G5 Bullet",
        "guid": "00000000-0000-0000-0000-000000000001",
        "mac": "24A43C3DFEB9",
    }

    @app.get("/v1/cameras", dependencies=[Depends(authenticate)])
    def cameras() -> list[dict[str, str]]:
        return [camera]

    @app.get("/v1/cameras/{requested_id}", dependencies=[Depends(authenticate)])
    def camera_details(requested_id: str) -> Response:
        if requested_id != camera_id:
            return JSONResponse({"error": "Camera not found"}, status_code=404)
        return JSONResponse(camera)

    @app.get("/v1/cameras/{requested_id}/snapshot", dependencies=[Depends(authenticate)])
    def snapshot(requested_id: str) -> Response:
        if requested_id != camera_id:
            return JSONResponse({"error": "Camera not found"}, status_code=404)
        return Response(JPEG_FIXTURE, media_type="image/jpeg")

    @app.get("/v1/cameras/{requested_id}/rtsps-stream", dependencies=[Depends(authenticate)])
    def streams(requested_id: str) -> Response:
        if requested_id != camera_id:
            return JSONResponse({"error": "Camera not found"}, status_code=404)
        return JSONResponse(
            {
                "high": "rtsps://127.0.0.1:7441/meerkat-high?enableSrtp",
                "medium": "rtsps://127.0.0.1:7441/meerkat-medium?enableSrtp",
                "low": None,
                "package": None,
            }
        )


__all__ = ["Vendor", "create_app"]
