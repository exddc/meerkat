import asyncio
import base64
from collections.abc import AsyncGenerator

FLV_FIXTURE = base64.b64decode(
    "RkxWAQEAAAAJAAAAABIAALcAAAAAAAAAAgAKb25NZXRhRGF0YQgAAAAIAAhkdXJhdGlvbgA/8AAAAAAAAAAFd2lk"
    "dGgAQIQAAAAAAAAABmhlaWdodABAdoAAAAAAAAANdmlkZW9kYXRhcmF0ZQAAAAAAAAAAAAAJZnJhbWVyYXRlAEAk"
    "AAAAAAAAAAx2aWRlb2NvZGVjaWQAQBwAAAAAAAAAB2VuY29kZXICAAxMYXZmNjMuMS4xMDEACGZpbGVzaXplAECe"
    "WAAAAAAAAAAJAAAAwgkAAC4AAAAAAAAAFwAAAAABQsAW/+EAGWdCwBbZAKAv+XARAAADAAEAAAMAFA8WLkgBAAVo"
    "y4PLIAAAADkJAAVLAAAAAAAAABcBAAAAAAACcAYF//9s3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NSBy"
    "MzIyMiBiMzU2MDVhIC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6"
    "Ly93d3cudmlkZW9sYW4ub3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTAgcmVmPTMgZGVibG9jaz0xOjA6"
    "MCBhbmFseXNlPTB4MToweDExMSBtZT1oZXggc3VibWU9NyBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3Jl"
    "Zj0xIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MSA4eDhkY3Q9MCBjcW09MCBkZWFkem9uZT0yMSwx"
    "MSBmYXN0X3Bza2lwPTEgY2hyb21hX3FwX29mZnNldD0tMiB0aHJlYWRzPTExIGxvb2thaGVhZF90aHJlYWRzPTEg"
    "c2xpY2VkX3RocmVhZHM9MCBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJheV9jb21wYXQ9MCBjb25z"
    "dHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MCB3ZWlnaHRwPTAga2V5aW50PTEwIGtleWludF9taW49MSBzY2VuZWN1"
    "dD00MCBpbnRyYV9yZWZyZXNoPTAgcmNfbG9va2FoZWFkPTEwIHJjPWNyZiBtYnRyZWU9MSBjcmY9MjMuMCBxY29t"
    "cD0wLjYwIHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBhcT0xOjEuMDAAgAAAAs5liIQP"
    "8RigAC0jHAAFXKOAAIYMnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJyddddddddddddddddd"
    "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddeAAAFVgkAABAAAGQA"
    "AAAAJwEAAAAAAAAHQZo4H+AOZgAAABsJAAARAADIAAAAACcBAAAAAAAACEGaVAf4A5mAAAAAHAkAABAAASwAAAAA"
    "JwEAAAAAAAAHQZpgP8AczAAAABsJAAAQAAGQAAAAACcBAAAAAAAAB0GagD/AHMwAAAAbCQAAEAAB9AAAAAAnAQAA"
    "AAAAAAdBmqA/wBzMAAAAGwkAABAAAlgAAAAAJwEAAAAAAAAHQZrAP8AczAAAABsJAAAQAAK8AAAAACcBAAAAAAAA"
    "B0Ga4D/AHMwAAAAbCQAAEAADIAAAAAAnAQAAAAAAAAdBmwA7wBzMAAAAGwkAABAAA4QAAAAAJwEAAAAAAAAHQZsg"
    "N8AczAAAABsJAAAFAAOEAAAAABcCAAAAAAAAEA=="
)
JPEG_FIXTURE = base64.b64decode(
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////"
    "2wBDAf//////////////////////////////////////////////////////////////////////////////////////"
    "wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAX/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oA"
    "DAMBAAIQAxAAAAF//8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABBQJ//8QAFBEBAAAAAAAAAAAAAAAAAAAA"
    "AP/aAAgBAwEBPwF//8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAgBAgEBPwF//8QAFBABAAAAAAAAAAAAAAAAAAAA"
    "AP/aAAgBAQAGPwJ//8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPyF//9oADAMBAAIAAwAAABB//8QAFBEBA"
    "AAAAAAAAAAAAAAAAAAAAP/aAAgBAwEBPxB//8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAgBAgEBPxB//8QAFBABAA"
    "AAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxB//9k="
)


def _video_tags() -> tuple[list[tuple[int, bytes]], int]:
    tags: list[tuple[int, bytes]] = []
    offset = 13
    while offset + 15 <= len(FLV_FIXTURE):
        size = int.from_bytes(FLV_FIXTURE[offset + 1 : offset + 4])
        end = offset + 11 + size + 4
        if end > len(FLV_FIXTURE):
            break
        timestamp = int.from_bytes(FLV_FIXTURE[offset + 4 : offset + 7])
        timestamp |= FLV_FIXTURE[offset + 7] << 24
        payload = FLV_FIXTURE[offset + 11 : offset + 11 + size]
        if FLV_FIXTURE[offset] == 9 and len(payload) > 1 and payload[1] == 1:
            tags.append((timestamp, FLV_FIXTURE[offset:end]))
        offset = end
    timestamps = [timestamp for timestamp, _ in tags]
    step = max(40, (timestamps[-1] - timestamps[-2]) if len(timestamps) > 1 else 200)
    return tags, step


def _timestamped(tag: bytes, timestamp: int) -> bytes:
    result = bytearray(tag)
    result[4:7] = (timestamp & 0xFFFFFF).to_bytes(3)
    result[7] = (timestamp >> 24) & 0xFF
    return bytes(result)


async def flv_stream() -> AsyncGenerator[bytes]:
    yield FLV_FIXTURE
    tags, step = _video_tags()
    last_timestamp = tags[-1][0]
    offset = last_timestamp + step
    while True:
        previous = last_timestamp
        for timestamp, tag in tags:
            current = offset + timestamp
            await asyncio.sleep(max(step, current - previous) / 1000)
            yield _timestamped(tag, current)
            previous = current
        last_timestamp = previous
        offset += tags[-1][0] + step


async def mjpeg_stream(fps: int = 5) -> AsyncGenerator[bytes]:
    frame = (
        b"--meerkat\r\nContent-Type: image/jpeg\r\nContent-Length: "
        + str(len(JPEG_FIXTURE)).encode()
        + b"\r\n\r\n"
        + JPEG_FIXTURE
        + b"\r\n"
    )
    while True:
        yield frame
        await asyncio.sleep(1 / max(1, min(fps, 30)))
