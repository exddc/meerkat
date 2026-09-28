# Camera Mock Server

Local stand-ins for home cameras. Each command runs one camera.

```sh
cd camera-mock-server
uv sync
uv run camera-mock-server reolink
```

The default username is `admin` and the default password is `meerkat`. Pass `--no-auth` to skip the check.

| Profile | Address | Authentication |
| --- | --- | --- |
| `reolink` | `http://127.0.0.1:8000/flv` | `user` and `password` query parameters |
| `tapo` | `rtsp://127.0.0.1:8554/stream1` and `/stream2` | Basic |
| `eufy` | `rtsp://127.0.0.1:8554/live0` and `/live1` | Basic |

Reolink follows the vendor's [HTTP-FLV URL](https://support.reolink.com/articles/28256840140441-Introduction-to-FLV-Stream/). Tapo's third-party stream is [RTSP `/stream1` and `/stream2`](https://www.tp-link.com/us/support/faq/2680/). eufy cameras that enable NAS storage publish an [RTSP address](https://service.eufy.com/article-description/Device-NAS-RTSP-Configuration-Guide) such as `/live0`. Tapo and eufy here accept only TCP interleaved RTP. The mock listens on 8554 so it does not need a privileged port.

Meerkat opens Reolink as HTTPS on a private LAN address, and it rejects `127.0.0.1`. For that check:

```sh
mkdir -p .certs
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout .certs/key.pem -out .certs/cert.pem -days 1 \
  -subj "/CN=camera-mock"
uv run camera-mock-server reolink --host 0.0.0.0 --port 8443 \
  --ssl-keyfile .certs/key.pem --ssl-certfile .certs/cert.pem
```

Enter `https://<your-lan-ip>:8443` as the camera address. Keep the server on a trusted network. The media and credentials are fixtures.

Ring, Nest, Arlo, and Wyze are omitted. Their live video is a cloud or WebRTC session, not a local URL.

## Check changes

```sh
uv run ruff format --check .
uv run ruff check .
uv run ty check
uv run pytest
```
