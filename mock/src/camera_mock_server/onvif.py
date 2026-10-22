import base64
import binascii
import hashlib
import secrets
from datetime import UTC, datetime, timedelta
from xml.etree import ElementTree

from fastapi import FastAPI, Request, Response

from camera_mock_server.rtsp import RTSPConfiguration

NAMESPACES = {
    "s": "http://www.w3.org/2003/05/soap-envelope",
    "wsse": "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd",
    "wsu": "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd",
    "tds": "http://www.onvif.org/ver10/device/wsdl",
    "trt": "http://www.onvif.org/ver10/media/wsdl",
    "tt": "http://www.onvif.org/ver10/schema",
    "ter": "http://www.onvif.org/ver10/error",
}
MAX_CLOCK_SKEW = timedelta(minutes=5)


def create_onvif_app(rtsp_port: int, camera: RTSPConfiguration) -> FastAPI:
    app = FastAPI(title="ONVIF Camera Mock", docs_url=None, redoc_url=None, openapi_url=None)
    tokens = {f"profile-{index}": path for index, path in enumerate(camera.paths, start=1)}

    async def read(request: Request) -> tuple[str, ElementTree.Element | None]:
        try:
            envelope = ElementTree.fromstring(await request.body())
        except ElementTree.ParseError:
            return "", None
        body = envelope.find("s:Body", NAMESPACES)
        if body is None or len(body) == 0:
            return "", None
        operation = body[0].tag.rpartition("}")[2]
        if camera.require_auth and not _authorized(envelope, camera.username, camera.password):
            return operation, None
        return operation, body[0]

    @app.post("/onvif/device_service")
    async def device_service(request: Request) -> Response:
        operation, element = await read(request)
        if not operation:
            return _fault("ter:WellFormed")
        if operation == "GetSystemDateAndTime":
            return _envelope(_system_date_and_time(datetime.now(UTC)))
        if element is None:
            return _fault("ter:NotAuthorized")
        if operation == "GetCapabilities":
            return _envelope(
                "<tds:GetCapabilitiesResponse><tds:Capabilities><tt:Media>"
                f"<tt:XAddr>{request.base_url}onvif/media_service</tt:XAddr>"
                "</tt:Media></tds:Capabilities></tds:GetCapabilitiesResponse>"
            )
        return _fault("ter:ActionNotSupported")

    @app.post("/onvif/media_service")
    async def media_service(request: Request) -> Response:
        operation, element = await read(request)
        if not operation:
            return _fault("ter:WellFormed")
        if element is None:
            return _fault("ter:NotAuthorized")
        if operation == "GetProfiles":
            profiles = "".join(
                f'<trt:Profiles token="{token}"><tt:VideoEncoderConfiguration token="video">'
                "<tt:Encoding>H264</tt:Encoding></tt:VideoEncoderConfiguration></trt:Profiles>"
                for token in tokens
            )
            return _envelope(f"<trt:GetProfilesResponse>{profiles}</trt:GetProfilesResponse>")
        token = element.findtext("trt:ProfileToken", default="", namespaces=NAMESPACES)
        if operation == "GetStreamUri" and token in tokens:
            host = request.url.hostname or "127.0.0.1"
            host = f"[{host}]" if ":" in host else host
            uri = f"rtsp://{host}:{rtsp_port}{tokens[token]}"
            return _envelope(
                "<trt:GetStreamUriResponse><trt:MediaUri>"
                f"<tt:Uri>{uri}</tt:Uri>"
                "</trt:MediaUri></trt:GetStreamUriResponse>"
            )
        return _fault("ter:InvalidArgVal")

    return app


def _authorized(envelope: ElementTree.Element, username: str, password: str) -> bool:
    token = envelope.find(".//wsse:UsernameToken", NAMESPACES)
    if token is None:
        return False
    user = token.findtext("wsse:Username", default="", namespaces=NAMESPACES)
    digest = token.findtext("wsse:Password", default="", namespaces=NAMESPACES)
    nonce = token.findtext("wsse:Nonce", default="", namespaces=NAMESPACES)
    created = token.findtext("wsu:Created", default="", namespaces=NAMESPACES)
    try:
        nonce_bytes = base64.b64decode(nonce, validate=True)
        created_at = datetime.fromisoformat(created)
    except (binascii.Error, ValueError):
        return False
    if created_at.tzinfo is None or abs(datetime.now(UTC) - created_at) > MAX_CLOCK_SKEW:
        return False
    expected = hashlib.sha1(nonce_bytes + created.encode() + password.encode()).digest()
    return secrets.compare_digest(user.encode(), username.encode()) and secrets.compare_digest(
        digest.encode(), base64.b64encode(expected)
    )


def _system_date_and_time(now: datetime) -> str:
    return (
        "<tds:GetSystemDateAndTimeResponse><tds:SystemDateAndTime><tt:UTCDateTime>"
        f"<tt:Time><tt:Hour>{now.hour}</tt:Hour><tt:Minute>{now.minute}</tt:Minute>"
        f"<tt:Second>{now.second}</tt:Second></tt:Time>"
        f"<tt:Date><tt:Year>{now.year}</tt:Year><tt:Month>{now.month}</tt:Month>"
        f"<tt:Day>{now.day}</tt:Day></tt:Date>"
        "</tt:UTCDateTime></tds:SystemDateAndTime></tds:GetSystemDateAndTimeResponse>"
    )


def _fault(subcode: str) -> Response:
    return _envelope(
        "<s:Fault><s:Code><s:Value>s:Sender</s:Value>"
        f"<s:Subcode><s:Value>{subcode}</s:Value></s:Subcode></s:Code></s:Fault>",
        status_code=400,
    )


def _envelope(body: str, status_code: int = 200) -> Response:
    namespaces = " ".join(f'xmlns:{prefix}="{uri}"' for prefix, uri in NAMESPACES.items())
    content = (
        '<?xml version="1.0" encoding="UTF-8"?>'
        f"<s:Envelope {namespaces}><s:Body>{body}</s:Body></s:Envelope>"
    )
    return Response(content, status_code=status_code, media_type="application/soap+xml")
