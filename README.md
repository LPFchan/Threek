# Threek

> Because it's funny.

A macOS menu bar app that intercepts the ⏯ key and lets you choose **which app**
receives the command when several apps are registered with Now Playing at the
same time — playing *or paused*.

---

## What it does

macOS hands play/pause to whichever app most recently claimed the Now Playing
session. With Spotify, Music, and a browser tab all paused at once, pressing ⏯
is a lottery. Threek intercepts the key, enumerates **every** app in the Now
Playing registry, and pops up a HUD so you pick the target.

| # of apps | Behavior |
|---|---|
| 0 | Re-injects the key so the system handles it normally. |
| 1 | Sends play/pause directly to that app. |
| 2 | HUD shows two icons. ⏮ sends left, ⏭ sends right. |
| 3 | HUD shows three icons. ⏮ / ⏯ / ⏭ map to the three apps. |
| 4+ | HUD shows a scrollable row. ⏮/⏭ move a selection ring, ⏯ confirms. |

⏮/⏭ (Previous/Next) always pass through — only ⏯ is intercepted.

---

## How it works (macOS 15.4+)

Since **macOS 15.4**, the `mediaremoted` daemon refuses to hand Now Playing data
to third-party processes — `MRMediaRemoteGetNowPlayingClient(s)` returns empty
from any unsigned context. This is why the original implementation broke.

Threek v2 works around the entitlement wall using the bundled
[**MediaRemote Adapter**](https://github.com/ungive/mediaremote-adapter)
(vendored in `Vendor/`): it spawns `/usr/bin/perl` — a system binary that *is*
entitled — and loads a small helper framework that talks to MediaRemote and
reports back as JSON.

On top of the stock adapter, Threek adds a **`clients`** command
(`Vendor/mediaremote-adapter/src/adapter/clients.m`) that enumerates **all**
registered Now Playing apps, including paused ones — the data the stock
single-active-app `get`/`stream` commands can't provide.

| Concern | Mechanism |
|---|---|
| **Discovery** (which apps, incl. paused) | `mediaremote-adapter.pl … clients` inside the perl shim |
| **Identity** | bundleID, displayName, PID, parent bundleID (collapses WebKit/browser helpers) |
| **Send play/pause** | AppleScript (`osascript`) to the picked app; falls back to the adapter's `MRMediaRemoteSendCommand` (current now-playing app) when AppleScript isn't possible |

The framework is **built from source** by `Scripts/build-adapter.sh` (a Xcode
pre-build phase) — no committed binaries.

---

## Requirements

- macOS 15 (Sequoia) or later
- **Accessibility** permission — to intercept media keys
- **Automation** permission — one prompt per media app, to send play/pause

---

## Build from source

**Prerequisites:** Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen), CMake

```bash
git clone https://github.com/LPFchan/Threek.git
cd Threek
brew install xcodegen cmake   # if needed
xcodegen generate
open Threek.xcodeproj
```

Set your Development Team in `project.yml` (or Xcode → Signing & Capabilities),
then ⌘R. The adapter framework builds automatically as a pre-build phase.

---

## Project structure

```
Threek/
├── project.yml                 # XcodeGen — no .pbxproj committed
├── Scripts/
│   └── build-adapter.sh        # Builds MediaRemoteAdapter.framework from source
├── Vendor/
│   └── mediaremote-adapter/    # Vendored adapter (BSD-3) + our `clients` command
├── App/
│   ├── ThreekApp.swift         # @main
│   └── AppDelegate.swift       # Event tap lifecycle, menu bar, routing
├── MediaKeys/
│   ├── MediaKeyInterceptor.swift
│   └── MediaKeyEvent.swift
├── NowPlaying/
│   ├── NowPlayingService.swift # Perl-shim discovery + AppleScript dispatch
│   └── NowPlayingApp.swift     # Model
├── Popup/
│   ├── PopupController.swift   # NSPanel + SwiftUI HUD
│   └── SelectorViewModel.swift # State machine
├── Preferences/
│   └── LaunchAtLogin.swift
└── Resources/Assets.xcassets
```

---

## Privacy

- No network access. No analytics. No telemetry.
- Now Playing metadata stays in-process.
- Accessibility is used only to intercept hardware media-key events.

---

## Known limitations

- Only apps that register with macOS Now Playing are discoverable.
- The adapter relies on a private-API workaround Apple could close in a future
  macOS release. `mediaremote-adapter.pl … test` detects this at runtime.

---

## Credits

- [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) by Jonas
  van den Berg (BSD 3-Clause) — the entitlement workaround that makes v2
  possible. License in `Vendor/mediaremote-adapter/LICENSE`.

---

## License

MIT — see [LICENSE](LICENSE).
