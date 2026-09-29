# Camera Mock Server

## Setup

```sh
brew install mediamtx ffmpeg
cd mock
uv sync
```

## Run a camera

Only the camera type is required. Run each command in a separate terminal:

```sh
uv run meerkat-mock tapo
uv run meerkat-mock eufy
uv run meerkat-mock reolink
```

| Type | Default endpoints | Authentication |
| --- | --- | --- |
| `tapo` | `rtsp://127.0.0.1:8554/stream1`, `/stream2` | Digest |
| `eufy` | `rtsp://127.0.0.1:8555/live0`, `/live1` | Digest |
| `reolink` | `http://127.0.0.1:8000/flv` | Query parameters |

The username is `admin` and the password is `meerkat`.
For Tapo and Eufy, enter `127.0.0.1` in Meerkat and supply these credentials.
Meerkat probes known stream endpoints and saves one after validation.
Enter `127.0.0.1:8554` or `127.0.0.1:8555` to target one mock explicitly.

Stop a camera with Ctrl-C. Its child processes stop automatically.

## Optional overrides

All flags remain available through `uv run meerkat-mock --help`:

```sh
uv run meerkat-mock eufy --port 9554 --auth-method basic
uv run meerkat-mock tapo --no-auth
```

Reolink defaults to HTTP. Meerkat requires HTTPS, so testing Reolink in the app
requires a certificate and a private LAN address:

```sh
mkdir -p .certs
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout .certs/key.pem -out .certs/cert.pem -days 1 \
  -subj "/CN=camera-mock"
uv run meerkat-mock reolink --host 0.0.0.0 --port 8443 \
  --ssl-keyfile .certs/key.pem --ssl-certfile .certs/cert.pem
```

Enter `<your-lan-ip>:8443` in Meerkat. Keep this mock on a trusted network.

## Test

```sh
uv run python -m ruff format --check .
uv run python -m ruff check .
uv run python -m ty check
uv run python -m pytest
```

RTSP integration tests require MediaMTX and FFmpeg on `PATH`; otherwise they are skipped.
They decode video, check authentication, and verify process cleanup.

To run Meerkat's `RTSPMockIntegrationTests`, start the Tapo and Eufy mocks above.
Set `MEERKAT_RTSP_TEST_URLS` in the test process environment to:

```text
rtsp://admin:meerkat@127.0.0.1:8554/stream1,rtsp://admin:meerkat@127.0.0.1:8555/live0
```

If Xcode does not forward the variable, put the same list in `/tmp/meerkat-rtsp-test-urls`.
Remove that file after testing. Without either configuration, the suite is skipped.
