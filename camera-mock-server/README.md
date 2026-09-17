# Camera Mock Server

This CLI runs one mock network camera for local Meerkat development. It provides small,
continuous media fixtures and vendor-shaped HTTP endpoints without camera hardware.

## Run a Camera

Install the locked dependencies and start a Reolink camera:

```sh
cd camera-mock-server
uv sync
uv run camera-mock-server reolink
```

The server listens on `http://127.0.0.1:8000`. The default username is `admin`, and the
default password is `meerkat`. Use `--username`, `--password`, or `--no-auth` to change
authentication.

Choose one of these profiles as the positional argument:

| Profile | Identity endpoint | Media endpoints | Authentication |
| --- | --- | --- | --- |
| `reolink` | `/api.cgi` | `/flv`, `/cgi-bin/api.cgi?cmd=Snap` | Query parameters |
| `axis` | `/axis-cgi/param.cgi` | JPEG and Motion JPEG | Digest or Basic |
| `hikvision` | `/ISAPI/System/deviceInfo` | JPEG snapshot | Digest or Basic |
| `dahua` | `/cgi-bin/magicBox.cgi` | JPEG and Motion JPEG | Digest or Basic |

The Reolink stream follows the vendor's [HTTP-FLV URL format](https://support.reolink.com/articles/28256840140441-Introduction-to-FLV-Stream/).
The Axis routes follow the [VAPIX video streaming API](https://developer.axis.com/vapix/network-video/video-streaming/).
The profiles cover the endpoints needed for detection and playback tests, not complete camera
firmware.

## Use HTTPS

Meerkat accepts camera addresses over HTTPS. Create a temporary certificate, then expose the
server on your local network:

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
