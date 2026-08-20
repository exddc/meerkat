# Meerkat

A minimal macOS menu bar app for glancing at your home cameras: one small icon, click it, a live multi-view grid pops up.

Status: early skeleton

## Stream URL

Reolink HTTP-FLV sub-stream:

```
https://<ip>/flv?port=1935&app=bcs&stream=channel0_sub.bcs&user=<user>&password=<password>
```

Notes:

- Use **HTTPS**. HTTP 302s to `https://<ip>/` and drops the `/flv` path.
- Camera TLS is **self-signed**, so the player must skip certificate verification.
- Do **not** percent-encode special characters in the password (a `!` sent as `%21` makes the camera drop the stream).

