# Camera Mock Server

This CLI runs one mock camera service for local Meerkat development. It provides small,
continuous media fixtures and vendor-shaped protocol endpoints without camera hardware.

## Run a Camera

Install the locked dependencies and start a Reolink camera:

```sh
cd camera-mock-server
uv sync
uv run camera-mock-server reolink
```

HTTP profiles listen on `http://127.0.0.1:8000`. The default username is `admin`, and the
default password is `meerkat`. Ring and Ubiquiti use the default token `meerkat`. Use
`--username`, `--password`, `--token`, or `--no-auth` to change authentication.

Choose one of these profiles as the positional argument:

| Profile | Identity endpoint | Media endpoints | Authentication |
| --- | --- | --- | --- |
| `reolink` | `/api.cgi` | `/flv`, `/cgi-bin/api.cgi?cmd=Snap` | Query parameters |
| `axis` | `/axis-cgi/param.cgi` | JPEG and Motion JPEG | Digest or Basic |
| `hikvision` | `/ISAPI/System/deviceInfo` | JPEG snapshot | Digest or Basic |
| `dahua` | `/cgi-bin/magicBox.cgi` | JPEG and Motion JPEG | Digest or Basic |
| `ring` | `/v1/devices` | JPEG snapshot download | Bearer token |
| `ubiquiti` | `/v1/cameras` | JPEG snapshot and RTSPS catalog | `X-API-Key` |
| `eufy` | RTSP `DESCRIBE` | H.264 over interleaved RTP | Basic |

The Reolink stream follows the vendor's [HTTP-FLV URL format](https://support.reolink.com/articles/28256840140441-Introduction-to-FLV-Stream/).
The Axis routes follow the [VAPIX video streaming API](https://developer.axis.com/vapix/network-video/video-streaming/).
Ring exposes cameras through its cloud [Partner API](https://developer.amazon.com/docs/ring/api-documentation.html),
which uses OAuth bearer tokens and device media endpoints. UniFi Protect exposes a local
[Protect API](https://developer.ui.com/protect) with API-key authentication and RTSPS stream
catalogs. Compatible eufy models can generate an authenticated
[RTSP address](https://service.eufy.com/article-description/Device-NAS-RTSP-Configuration-Guide),
although support and event-only behavior vary by model and configuration.

Start the eufy RTSP profile separately:

```sh
uv run camera-mock-server eufy
```

It listens on `rtsp://127.0.0.1:8554/live0`. The profiles cover the endpoints needed for
detection and media tests, not complete camera firmware or cloud account linking.

## Use HTTPS

Meerkat accepts camera addresses over HTTPS. For an HTTP profile, create a temporary certificate,
then expose the server on your local network:

```sh
mkdir -p .certs
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout .certs/key.pem -out .certs/cert.pem -days 1 \
  -subj "/CN=camera-mock"
uv run camera-mock-server reolink --host 0.0.0.0 --port 8443 \
  --ssl-keyfile .certs/key.pem --ssl-certfile .certs/cert.pem
```

Enter `https://<your-lan-ip>:8443` as the camera address in Meerkat. Keep this server on a
trusted development network because its media and credentials are test fixtures.

## Check Changes

```sh
uv run ruff format --check .
uv run ruff check .
uv run ty check
uv run pytest
```
