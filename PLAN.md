# Meerkat — MVP Plan

A minimal macOS menu bar app: small icon, click it, a panel expands with a live multi-view grid of the Reolink cameras. Nothing else.

**Name:** Meerkat — the sentry animal that pops up to keep watch, exactly the interaction of a menu bar camera viewer. Open source; suggested repo name `meerkat` (no competing project in the camera/macOS space; a meerkat head makes a natural menu bar icon).

**Inspiration:** [omarchy-unifi-protect](https://github.com/jankeesvw/omarchy-unifi-protect) — a Quickshell/QML bar widget (Linux/Omarchy) for UniFi Protect: one small icon in the bar, a panel behind it with camera views, streams only playing while the panel is open. This is the macOS equivalent of that idea, for Reolink first. Patterns worth borrowing from it later: motion-detection lighting up the bar icon, and its "one live stream + static thumbnails" layout as a cheaper alternative to an all-live grid.

## 1. Does this already exist?

No — not in polished form. Everything close is either window-based or abandoned:

| Option | Menu bar? | Multi-cam grid? | Verdict |
|---|---|---|---|
| [Reolink Client](https://apps.apple.com/us/app/reolink-client/id1086871235) (official, free) | No | Yes (up to 36) | Clunky windowed Qt app |
| [Reolens](https://github.com/jestatsio/reolens) (free, MIT, native SwiftUI) | No | Yes | Best code reference to borrow from, but windowed and needs macOS 26 |
| [ReoMac](https://reomac.app) ($1.99/mo) | No | Yes | Windowed; uses Reolink's native protocol |
| [GlanceCam](https://www.glancecam.app) (~$9/yr) | No | Yes ("GlanceGrids") | Closest polished commercial option, windowed |
| [CamBar](https://github.com/jellypapi/CamBar) (MIT) | **Yes** | No (tabs, one cam at a time) | Dormant hobby project, 9 commits |
| [camai](https://github.com/hrrcne/camai) (MIT) | **Yes** | **Yes** (2x2) | Electron + Python/YOLO contraption, 2 commits |

**Conclusion: building it is justified.** The exact combination (menu bar + live grid + native + minimal) doesn't exist. Reolens (MIT-licensed Swift) is a useful reference for the Reolink/decoding parts.

## 2. Scope

### MVP (v0.1)
- Menu bar icon (`LSUIElement` app — no Dock icon, no windows).
- Click → panel opens with a live grid (2x2 for up to 4 cams; adapt rows to camera count).
- Streams **start when the panel opens, stop when it closes** — zero CPU while idle.
- Camera config (name, IP, user, password, channel) — hardcoded struct or a simple JSON/plist first; credentials can move to Keychain later.
- Uses camera **sub-streams** (low-res, always H.264) — a glanceable grid doesn't need 4K, and 4 sub-streams cost almost no CPU.
- Quit menu item. That's all.

### Explicitly out of scope for MVP
Settings UI, click-to-fullscreen / main-stream switching, PTZ, two-way audio, motion events/notifications, recording/snapshots, auto-discovery, launch-at-login, App Store distribution.

### v0.2 candidates (only if MVP sticks)
Click a tile to enlarge, settings window for camera management, Keychain storage, launch at login, pinnable panel.

### Later scope: any camera, not just Reolink
Make the app camera-agnostic — any RTSP/ONVIF source (UniFi Protect, Amcrest, Hikvision, generic IP cams), not just Reolink. The MVP architecture already keeps this door open: VLCKit plays any RTSP/HTTP stream URL, so the core just needs the config format to hold a generic stream URL per camera instead of Reolink-specific fields. Vendor-specific parts (URL templates, motion events, battery-cam protocols) would live behind per-vendor adapters; the go2rtc escape hatch also generalizes, since go2rtc ingests nearly every camera protocol in existence.

## 3. Technical approach

### Recommended stack
**Swift + SwiftUI `MenuBarExtra(.window)` + VLCKit, playing each camera's HTTP-FLV sub-stream.**

- **Stream source — HTTP-FLV, not RTSP:**
  `http://<ip>/flv?port=1935&app=bcs&stream=channel0_sub.bcs&user=X&password=Y`
  Reolink's RTSP implementation is notoriously flaky on newer firmware (drops, corruption) — the Frigate project explicitly recommends HTTP-FLV for most Reolink models. RTSP (`rtsp://user:pass@ip:554/h264Preview_01_sub`) stays as fallback. Sub-streams are always H.264, which sidesteps all H.265/Duo-model quirks.
- **Playback — VLCKit** (via SPM, e.g. `tylerjonesio/vlckit-spm`): plays RTSP and HTTP-FLV natively with VideoToolbox hardware decode. One `VLCMediaPlayer` per tile wrapped in an `NSViewRepresentable`, laid out in a `LazyVGrid`. 2–4 sub-streams is trivial load. Tune `network-caching` (~300–500 ms) for latency.
  - Ruled out: **AVPlayer** (no RTSP/FLV support at all), **FFmpegKit** (retired Jan 2025, binaries pulled), GStreamer (overkill).
- **Shell — `MenuBarExtra` with `.menuBarExtraStyle(.window)`** (macOS 13+): video renders fine inside it; a 2x2 grid of ~640x360 tiles fits comfortably. Start/stop players in the content view's `onAppear`/`onDisappear`. Use `orchetect/MenuBarExtraAccess` if programmatic open/close is needed. If a pinnable/"stay open" panel is ever wanted, switch to `NSStatusItem` + `NSPopover`.
- **Distribution — personal build**: sign with own dev cert, no notarization, sandbox off (or sandbox + `com.apple.security.network.client`). macOS 15+ shows a one-time Local Network permission prompt on first connect.

### Escape hatch
If reliability problems appear (battery/WiFi-only cams have no RTSP/FLV at all, or sub-second latency is wanted): run a **go2rtc** sidecar (single Go binary, best-in-class Reolink support) and render its WebRTC/MSE output in a WKWebView grid. For battery cams specifically, **neolink** bridges Reolink's proprietary Baichuan protocol to RTSP. Not needed for wired PoE/mains cameras.

### Camera prerequisites (one-time, per camera in Reolink app/web UI)
- Create/verify a user account; enable RTSP/HTTP under network settings.
- Set sub-stream to CBR, "fluency first", interframe space 1x (Frigate-recommended for stability).

## 4. Build plan

1. **Verify streams first (no code):** open each camera's HTTP-FLV sub-stream URL in VLC.app; confirm all cams play. (~15 min)
2. **Project skeleton:** Xcode macOS app, `LSUIElement = YES`, `MenuBarExtra` with a placeholder grid. (~0.5 h)
3. **Video tile:** VLCKit via SPM, `NSViewRepresentable` around `VLCMediaPlayer`, play one hardcoded camera. (~1–2 h)
4. **Grid + lifecycle:** camera list from a small config file → `LazyVGrid`; start on `onAppear`, stop on `onDisappear`; per-tile name label and a basic "reconnecting…" state. (~1–2 h)
5. **Polish pass:** icon, Quit item, latency tuning. (~1 h)

Realistic total: **an afternoon to a day** for a working MVP.
