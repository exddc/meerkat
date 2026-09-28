import pytest

from camera_mock_server.cli import main


@pytest.mark.parametrize(
    ("argv", "message"),
    [
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

    assert exit_info.value.code == 2
    assert message in capsys.readouterr().err
