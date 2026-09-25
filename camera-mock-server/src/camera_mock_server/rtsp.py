import asyncio
import base64
import secrets
import struct
from contextlib import suppress
from dataclasses import dataclass

from camera_mock_server.media import h264_media


@dataclass(frozen=True)
class RTSPConfiguration:
    paths: tuple[str, ...]
    username: str
    password: str
    require_auth: bool


def _authorized(headers: dict[str, str], configuration: RTSPConfiguration) -> bool:
    if not configuration.require_auth:
        return True
    scheme, _, value = headers.get("authorization", "").partition(" ")
    if scheme.lower() != "basic":
        return False
    try:
        supplied = base64.b64decode(value, validate=True).decode()
    except (ValueError, UnicodeDecodeError):
        return False
    return secrets.compare_digest(
        supplied,
        f"{configuration.username}:{configuration.password}",
    )


def _response(
    code: int,
    cseq: str,
    *,
    headers: dict[str, str] | None = None,
    body: bytes = b"",
) -> bytes:
    reasons = {
        200: "OK",
        400: "Bad Request",
        401: "Unauthorized",
        404: "Not Found",
        405: "Method Not Allowed",
        455: "Method Not Valid in This State",
        461: "Unsupported Transport",
    }
    fields = {"CSeq": cseq, "Server": "Meerkat Camera Mock", **(headers or {})}
    if body:
        fields["Content-Length"] = str(len(body))
    head = [
        f"RTSP/1.0 {code} {reasons[code]}",
        *(f"{key}: {value}" for key, value in fields.items()),
    ]
    return "\r\n".join(head).encode() + b"\r\n\r\n" + body


def _sdp(host: str) -> bytes:
    sps, pps, _ = h264_media()
    sprop = f"{base64.b64encode(sps).decode()},{base64.b64encode(pps).decode()}"
    lines = [
        "v=0",
        f"o=- 0 0 IN IP4 {host}",
        "s=Camera",
        "t=0 0",
        "a=control:*",
        "m=video 0 RTP/AVP 96",
        "a=rtpmap:96 H264/90000",
        f"a=fmtp:96 packetization-mode=1;profile-level-id=42C016;sprop-parameter-sets={sprop}",
        "a=control:trackID=0",
    ]
    return ("\r\n".join(lines) + "\r\n").encode()


def _nal_packets(nal: bytes, maximum_size: int = 1200) -> tuple[bytes, ...]:
    if len(nal) <= maximum_size:
        return (nal,)
    indicator = bytes([(nal[0] & 0xE0) | 28])
    nal_type = nal[0] & 0x1F
    chunks = [
        nal[index : index + maximum_size - 2] for index in range(1, len(nal), maximum_size - 2)
    ]
    return tuple(
        indicator
        + bytes(
            [nal_type | (0x80 if index == 0 else 0) | (0x40 if index == len(chunks) - 1 else 0)]
        )
        + chunk
        for index, chunk in enumerate(chunks)
    )


def _request_path(uri: str) -> str:
    path = uri.split("?", 1)[0]
    if "://" in path:
        path = path.split("://", 1)[1]
        path = "/" + path.split("/", 1)[1] if "/" in path else "/"
    return path.rstrip("/") or "/"


def _known_stream(path: str, paths: tuple[str, ...]) -> bool:
    return any(path == allowed or path.startswith(f"{allowed}/") for allowed in paths)


def _interleaved_channel(transport: str) -> int | None:
    fields = [field.strip() for field in transport.split(";")]
    if not fields or fields[0].upper() != "RTP/AVP/TCP":
        return None
    for field in fields:
        name, separator, value = field.partition("=")
        if separator and name.lower() == "interleaved":
            start, _, _ = value.partition("-")
            if start.isdigit() and 0 <= int(start) <= 255:
                return int(start)
    return None


async def _stream_rtp(writer: asyncio.StreamWriter, channel: int) -> None:
    sps, pps, frames = h264_media()
    timestamps = [timestamp for timestamp, _ in frames]
    step = max(40, timestamps[-1] - timestamps[-2] if len(timestamps) > 1 else 200)
    sequence = 0
    timestamp_offset = 0
    ssrc = 0x4D454552
    try:
        while True:
            previous = frames[0][0]
            for index, (timestamp, nals) in enumerate(frames):
                if index:
                    await asyncio.sleep(max(0, timestamp - previous) / 1000)
                keyframe = any(nal[0] & 0x1F == 5 for nal in nals)
                frame_nals = (sps, pps, *nals) if keyframe else nals
                packets = tuple(packet for nal in frame_nals for packet in _nal_packets(nal))
                for packet_index, payload in enumerate(packets):
                    marker = packet_index == len(packets) - 1
                    header = struct.pack(
                        "!BBHII",
                        0x80,
                        96 | (0x80 if marker else 0),
                        sequence,
                        ((timestamp_offset + timestamp) * 90) & 0xFFFFFFFF,
                        ssrc,
                    )
                    sequence = (sequence + 1) & 0xFFFF
                    rtp = header + payload
                    writer.write(bytes((0x24, channel)) + len(rtp).to_bytes(2, "big") + rtp)
                await writer.drain()
                previous = timestamp
            await asyncio.sleep(step / 1000)
            timestamp_offset += timestamps[-1] + step
    except (BrokenPipeError, ConnectionResetError):
        return


async def _handle_client(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    configuration: RTSPConfiguration,
    host: str,
) -> None:
    stream_task: asyncio.Task[None] | None = None
    setup_channel: int | None = None
    try:
        while True:
            try:
                raw = await reader.readuntil(b"\r\n\r\n")
            except (asyncio.IncompleteReadError, asyncio.LimitOverrunError):
                break
            lines = raw.decode(errors="replace").split("\r\n")
            request = lines[0].split(" ", 2)
            if len(request) != 3:
                writer.write(_response(400, "0"))
                await writer.drain()
                break
            method, uri, _ = request
            headers = {
                key.lower(): value.strip()
                for line in lines[1:]
                if ":" in line
                for key, value in [line.split(":", 1)]
            }
            cseq = headers.get("cseq", "0")
            content_length = int(headers.get("content-length", "0"))
            if content_length:
                await reader.readexactly(content_length)

            if method != "OPTIONS" and not _authorized(headers, configuration):
                response = _response(
                    401,
                    cseq,
                    headers={"WWW-Authenticate": 'Basic realm="Camera Mock Server"'},
                )
            elif method == "OPTIONS":
                response = _response(
                    200,
                    cseq,
                    headers={"Public": "OPTIONS, DESCRIBE, SETUP, PLAY, GET_PARAMETER, TEARDOWN"},
                )
            elif not _known_stream(_request_path(uri), configuration.paths):
                response = _response(404, cseq)
            elif method == "DESCRIBE":
                response = _response(
                    200,
                    cseq,
                    headers={
                        "Content-Type": "application/sdp",
                        "Content-Base": f"{uri.rstrip('/')}/",
                    },
                    body=_sdp(host),
                )
            elif method == "SETUP":
                channel = _interleaved_channel(headers.get("transport", ""))
                if channel is None:
                    response = _response(461, cseq)
                else:
                    setup_channel = channel
                    response = _response(
                        200,
                        cseq,
                        headers={"Transport": headers["transport"], "Session": "meerkat"},
                    )
            elif method == "PLAY":
                if setup_channel is None:
                    response = _response(455, cseq)
                else:
                    response = _response(
                        200,
                        cseq,
                        headers={
                            "Session": "meerkat",
                            "RTP-Info": f"url={uri}/trackID=0;seq=0;rtptime=0",
                        },
                    )
            elif method == "GET_PARAMETER" or method == "TEARDOWN":
                response = _response(200, cseq, headers={"Session": "meerkat"})
            else:
                response = _response(405, cseq)

            writer.write(response)
            await writer.drain()
            if (
                method == "PLAY"
                and response.startswith(b"RTSP/1.0 200")
                and stream_task is None
                and setup_channel is not None
            ):
                stream_task = asyncio.create_task(_stream_rtp(writer, setup_channel))
            if method == "TEARDOWN":
                break
    finally:
        if stream_task is not None:
            stream_task.cancel()
            with suppress(asyncio.CancelledError):
                await stream_task
        writer.close()
        with suppress(ConnectionError):
            await writer.wait_closed()


async def create_rtsp_server(
    host: str,
    port: int,
    paths: tuple[str, ...],
    *,
    username: str = "admin",
    password: str = "meerkat",
    require_auth: bool = True,
) -> asyncio.Server:
    configuration = RTSPConfiguration(paths, username, password, require_auth)
    return await asyncio.start_server(
        lambda reader, writer: _handle_client(reader, writer, configuration, host),
        host,
        port,
    )


async def run_rtsp_server(
    host: str,
    port: int,
    paths: tuple[str, ...],
    *,
    username: str = "admin",
    password: str = "meerkat",
    require_auth: bool = True,
) -> None:
    server = await create_rtsp_server(
        host,
        port,
        paths,
        username=username,
        password=password,
        require_auth=require_auth,
    )
    addresses = ", ".join(f"rtsp://{host}:{port}{path}" for path in paths)
    print(f"RTSP camera running on {addresses}")
    async with server:
        await server.serve_forever()
