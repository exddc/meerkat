import pytest

from camera_mock_server.cli import main
from camera_mock_server.rtsp import RTSPConfiguration


@pytest.mark.parametrize(("vendor", "port"), [("tapo", 8554), ("eufy", 8555)])
def test_type_only_uses_distinct_ports_and_digest(
    vendor: str, port: int, monkeypatch: pytest.MonkeyPatch
) -> None:
    calls = []

    async def run(host: str, actual_port: int, configuration: RTSPConfiguration) -> None:
        calls.append((host, actual_port, configuration))

    monkeypatch.setattr("camera_mock_server.cli._run_rtsp", run)
    main([vendor])
    host, actual_port, configuration = calls[0]
    assert (host, actual_port) == ("127.0.0.1", port)
    assert configuration.auth_method == "digest"
    assert configuration.require_auth
    assert (configuration.username, configuration.password) == ("admin", "meerkat")


def test_rtsp_options_still_override_defaults(monkeypatch: pytest.MonkeyPatch) -> None:
    calls = []

    async def run(host: str, port: int, configuration: RTSPConfiguration) -> None:
        calls.append((host, port, configuration))

    monkeypatch.setattr("camera_mock_server.cli._run_rtsp", run)
    main(
        [
            "eufy",
            "--host",
            "0.0.0.0",
            "--port",
            "9554",
            "--auth-method",
            "basic",
            "--username",
            "viewer",
            "--password",
            "fixture",
            "--no-auth",
        ]
    )
    host, port, configuration = calls[0]
    assert (host, port) == ("0.0.0.0", 9554)
    assert configuration.auth_method == "basic"
    assert not configuration.require_auth
    assert (configuration.username, configuration.password) == ("viewer", "fixture")


def test_reolink_type_only_keeps_http_defaults(monkeypatch: pytest.MonkeyPatch) -> None:
    calls = []
    monkeypatch.setattr(
        "camera_mock_server.cli.uvicorn.run", lambda app, **kwargs: calls.append(kwargs)
    )
    main(["reolink"])
    assert calls[0]["host"] == "127.0.0.1"
    assert calls[0]["port"] == 8000


@pytest.mark.parametrize(
    ("argv", "message"),
    [
        (["tapo", "--port", "0"], "between 1 and 65535"),
        (["eufy", "--username", "any"], "other than 'any'"),
        (["reolink", "--ssl-certfile", "cert.pem"], "must be used together"),
        (
            ["eufy", "--ssl-certfile", "cert.pem", "--ssl-keyfile", "key.pem"],
            "do not apply to RTSP profiles",
        ),
    ],
)
def test_rejects_invalid_tls_options(
    argv: list[str], message: str, capsys: pytest.CaptureFixture[str]
) -> None:
    with pytest.raises(SystemExit) as exit_info:
        main(argv)

    assert exit_info.value.code in (1, 2)
    assert message in capsys.readouterr().err
