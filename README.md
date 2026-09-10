# Meerkat

Meerkat is a macOS menu bar app that plays a live grid of Reolink camera streams. Click the icon to open the panel. Each camera's HTTP-FLV connection stays open in the background so the panel can show a frame without waiting for the next keyframe.

Requires macOS 26. Open `Meerkat.xcodeproj` in Xcode and run the Meerkat scheme.

Official DMG builds update through Sparkle. Users can check manually from Settings, and release assets are hosted on GitHub Releases. See [`docs/updates.md`](docs/updates.md) for release setup.

## Stream URL

Each camera uses an HTTPS HTTP-FLV sub-stream:

```
https://<ip>/flv?port=1935&app=bcs&stream=channel0_sub.bcs&user=<user>&password=<password>
```

Add cameras in Settings.

- Use HTTPS. An HTTP request redirects to `https://<ip>/` and drops the `/flv` path.
- Reolink cameras present a self-signed TLS certificate. Meerkat accepts it only for the configured `/flv` endpoint on a private, link-local, or Tailscale (`100.64.0.0/10`) IP address. Public hosts use normal certificate validation. Use the camera’s LAN or Tailscale IP for self-signed certificates.
- Do not percent-encode special characters in the password. A `!` sent as `%21` makes the camera drop the stream.

## Playback

Each tile takes an HTTPS HTTP-FLV URL carrying H.264 (AVC). URLSession reads the stream, the FLV parser extracts video tags, and Core Media packs AVC frames for `AVSampleBufferDisplayLayer`. The parser ignores audio tags. HLS demo URLs and RTSP are unsupported; add a real camera in Settings.

The app starts one ingest session per configured camera and keeps the latest encoded Group of Pictures (GOP) in memory. Closing the panel flushes and removes every display layer, which stops decode, but the HTTP sessions continue to refill their GOP buffers. Opening the panel enqueues the stored GOP before live samples. The ingest retimes the stored timestamps to the host clock. Earlier frames decode as references and are dropped for display, and the newest frame displays immediately. Live samples continue on the same timeline.

Ingest retries dropped connections after two seconds, including failures before the first frame. Ten seconds without video also triggers reconnection. On 429 or 5xx, ingest waits two seconds and reconnects. The tile shows “Check credentials” for 401 or 403. An unsupported codec such as H.265, a redirect, or another non-FLV body maps to “Unsupported stream”. A rejected certificate maps to “Untrusted certificate”. Ingest retries these failures every 30 seconds. Reconnection clears stale encoded frames and waits for a new keyframe (IDR). The app rejects HTTP redirects to preserve the endpoint and keep credentials on the configured camera.

Run camera-independent tests with:

```sh
xcodebuild -project Meerkat.xcodeproj -scheme Meerkat -only-testing:MeerkatTests test
```

## License

MIT. See `LICENSE`.
