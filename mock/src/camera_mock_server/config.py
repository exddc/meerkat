from enum import StrEnum

DEFAULT_USERNAME = "admin"
DEFAULT_PASSWORD = "meerkat"


class Vendor(StrEnum):
    REOLINK = "reolink"
    TAPO = "tapo"
    EUFY = "eufy"
    ONVIF = "onvif"


RTSP_PATHS: dict[Vendor, tuple[str, ...]] = {
    Vendor.TAPO: ("/stream1", "/stream2"),
    Vendor.EUFY: ("/live0", "/live1"),
    Vendor.ONVIF: ("/Streaming/Channels/101", "/Streaming/Channels/102"),
}

DEFAULT_PORTS: dict[Vendor, int] = {
    Vendor.REOLINK: 8000,
    Vendor.TAPO: 8554,
    Vendor.EUFY: 8555,
    Vendor.ONVIF: 8556,
}

DEFAULT_ONVIF_PORT = 8080
