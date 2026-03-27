# Threek

> Because it's funny.

A macOS menu bar app that intercepts the ⏯ key and lets you choose **which app** receives the command when multiple apps are fighting over Now Playing.

---

## What it does

macOS hands play/pause to whichever app most recently claimed the Now Playing session. If you have Spotify, Apple Music, YouTube Music, and a podcast app all paused at the same time, pressing ⏯ is a lottery.

Threek intercepts the key, looks up all apps with active Now Playing sessions, and shows you a HUD:

| # of apps | Behavior |
|---|---|
| 0–1 | Transparent pass-through. You'd never know Threek exists. |
| 2 | HUD shows two icons. ⏮ sends to the left, ⏭ sends to the right. |
| 3 | HUD shows three icons. ⏮ / ⏯ / ⏭ each send to one app. |
| 4+ | Scrollable icon row. ⏮/⏭ move a selection ring, ⏯ confirms. |

⏮/⏭ (Previous/Next) always pass through — only ⏯ (Play/Pause) is intercepted.

---

## Requirements

- macOS 13 Ventura or later
- **Accessibility permission** — Threek prompts on first launch and explains why

---

## Installation

### Pre-built (recommended)

Download the latest `.dmg` from [Releases](https://github.com/LPFchan/Threek/releases), drag `Threek.app` to `/Applications`, and launch it.

macOS will ask for Accessibility permission the first time — that's expected and required for media key interception.

### Build from source

**Prerequisites:** Xcode 15+, [XcodeGen](https://github.com/yonaskolb/XcodeGen)

```bash
git clone https://github.com/LPFchan/Threek.git
cd Threek
brew install xcodegen   # if not already installed
xcodegen generate
open Threek.xcodeproj
```

Set your Development Team in Xcode's Signing & Capabilities, then ⌘R.

---

## Why direct distribution (no App Store)?

Threek uses two private macOS APIs:

1. **MediaRemote.framework** — `MRMediaRemoteGetNowPlayingApplications` and `MRMediaRemoteSendCommandToApp` for discovering and targeting specific Now Playing apps. There is no public equivalent that lets you enumerate *all* apps or send to a *specific* one.
2. **CGEvent tap** at `cghidEventTap` level — required to intercept hardware media keys before they reach other apps. This also requires Accessibility permission.

Neither is permitted in App Store submissions. Threek is distributed directly and notarized via Apple's notarytool — Gatekeeper will clear it on first launch.

---

## Project structure

```
Threek/
├── project.yml                      # XcodeGen — no .pbxproj committed
├── Threek.entitlements              # Hardened runtime (no sandbox)
├── Threek-Bridging-Header.h         # ObjC → Swift bridge
├── App/
│   ├── ThreekApp.swift              # @main
│   └── AppDelegate.swift            # Event tap lifecycle, menu bar, routing
├── MediaKeys/
│   ├── MediaKeyInterceptor.swift    # CGEvent tap, key classification
│   └── MediaKeyEvent.swift          # Enum: .previous .playPause .next
├── NowPlaying/
│   ├── MediaRemoteBridge.h          # Private framework typedefs
│   ├── NowPlayingService.swift      # MediaRemote wrapper, app discovery
│   └── NowPlayingApp.swift          # Model: bundleID, icon, lastActive
├── Popup/
│   ├── PopupController.swift        # NSPanel lifecycle
│   ├── SelectorViewModel.swift      # State machine
│   ├── SelectorPopup.swift          # SwiftUI HUD root view
│   └── AppIconView.swift            # Icon + label component
├── Preferences/
│   └── LaunchAtLogin.swift          # SMAppService wrapper
└── Resources/
    └── Assets.xcassets
```

---

## Privacy

- Threek does **not** log, store, or transmit any media metadata or usage data.
- The only sensitive permission is **Accessibility**, used solely to intercept hardware media key events.
- No network access. No analytics. No telemetry.

---

## Known limitations

- Only apps using the macOS Now Playing API are discoverable and targetable — anything not registering with `MPNowPlayingInfoCenter` can't be reached (browser tabs using the HTML5 Media Session API are usually fine; custom audio engines may not be).
- `MRMediaRemoteGetNowPlayingApplications` is a private API. Its behavior may change across macOS versions. Threek targets macOS 13+ and is tested on current releases.

---

## License

MIT — see [LICENSE](LICENSE).
