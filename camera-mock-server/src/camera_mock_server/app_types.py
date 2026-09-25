from enum import StrEnum


class Vendor(StrEnum):
    REOLINK = "reolink"
    TAPO = "tapo"
    EUFY = "eufy"


RTSP_PATHS: dict[Vendor, tuple[str, ...]] = {
    Vendor.TAPO: ("/stream1", "/stream2"),
    Vendor.EUFY: ("/live0", "/live1"),
}
