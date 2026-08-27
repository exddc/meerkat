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
- Reolink cameras present a self-signed TLS certificate. The player skips certificate verification.
- Do not percent-encode special characters in the password. A `!` sent as `%21` makes the camera drop the stream.

## License

MIT. See `LICENSE`.
