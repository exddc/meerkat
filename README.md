# Meerkat

Meerkat is a macOS menu bar app that plays a live grid of Reolink camera streams. Click the icon to open the panel. Streams start when the panel opens and stop when it closes.

Requires macOS 26. Open `Meerkat.xcodeproj` in Xcode and run the Meerkat scheme.

## Stream URL

Each camera uses an HTTPS HTTP-FLV sub-stream:

```
https://<ip>/flv?port=1935&app=bcs&stream=channel0_sub.bcs&user=<user>&password=<password>
```

Add cameras in Settings.

- Use HTTPS. An HTTP request redirects to `https://<ip>/` and drops the `/flv` path.
- Reolink cameras present a self-signed TLS certificate. The player accepts it only for the configured `/flv` endpoint on a private or link-local IP address. Public hosts use normal certificate validation. Use the camera’s LAN IP for self-signed certificates.
- Do not percent-encode special characters in the password. A `!` sent as `%21` makes the camera drop the stream.

## Playback

Each tile takes an HTTPS HTTP-FLV URL carrying H.264 (AVC). URLSession reads the stream, the FLV parser extracts video tags, and Core Media packs AVC frames for `AVSampleBufferDisplayLayer`. Audio tags are ignored. HLS demo URLs and RTSP are unsupported; add a real camera in Settings.

Tiles retry failed connections after two seconds, including failures before the first frame. A ten-second video stall also triggers reconnection. Closing the panel cancels requests and retries, discards buffered bytes, and removes the display layers. The player buffers 300 milliseconds, presents frames by their FLV timestamps, and waits for an IDR frame after each connection. It rejects HTTP redirects to preserve the endpoint and keep credentials on the configured camera.

Run camera-independent tests with:

```sh
xcodebuild -project Meerkat.xcodeproj -scheme Meerkat -only-testing:MeerkatTests test
```

## License

MIT. See `LICENSE`.
