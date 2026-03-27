# Threek — Agent Handoff Document

## Name
**Threek** — because it's funny.

## One-liner
A macOS menu bar app that intercepts hardware media keys and lets you choose *which* app receives the command when multiple apps are fighting over Now Playing.

---

## Platform & Stack
- **OS:** macOS 13+ (Ventura minimum for current `MRMediaRemoteCommand` / `MPNowPlayingInfoCenter` APIs)
- **Language:** Swift
- **UI framework:** SwiftUI (for the popup) + AppKit (for global event tap and menu bar presence)
- **Distribution:** Menu bar app (no dock icon, `LSUIElement = true`)

---

## Core Concepts

### Media Key Interception
macOS media keys emit system-level events before any app sees them. Threek must register a **`CGEvent` tap** (via `CGEvent.tapCreate`) at the `cghidEventTap` or `annotatedSession` level to intercept `NX_KEYTYPE_PLAY`, `NX_KEYTYPE_NEXT`, and `NX_KEYTYPE_PREVIOUS` from the `NSSystemDefined` event subtype.

- This requires **Accessibility permissions** (`kAXTrustedCheckOptionPrompt`). Threek must prompt for this on first launch and show a clear onboarding screen.

### Now Playing Discovery
Use the **private `MediaRemote.framework`** (located at `/System/Library/PrivateFrameworks/MediaRemote.framework`) to enumerate all apps currently registered with Now Playing:

- `MRMediaRemoteGetNowPlayingApplications` — returns an array of all apps with active media sessions (not just the frontmost one).
- `MRMediaRemoteGetNowPlayingInfo` — gets metadata (title, artist, artwork) for a specific app.
- `MRMediaRemoteSendCommandToApp` — sends play/pause/next/prev to a **specific** bundle identifier.

> **Note:** This is a private API. It will not pass Mac App Store review. Plan for direct distribution (website + notarization) or explore whether the public `MPNowPlayingSession` observation APIs in newer macOS versions expose enough. If public APIs are insufficient, private framework is the only path.

---

## Behavior Specification

### Default Pass-through (Back / Forward)
| Key | Behavior |
|---|---|
| `⏮` (Previous) | Always passed through to macOS unmodified. Stock behavior. |
| `⏭` (Next) | Always passed through to macOS unmodified. Stock behavior. |

Threek does **not** intercept these in normal operation. It simply doesn't consume the event — lets it propagate.

### Play/Pause — Single App Playing
| Condition | Behavior |
|---|---|
| 0 or 1 app registered in Now Playing | Pass through to macOS unmodified. Completely transparent. User should never know Threek exists in this state. |

### Play/Pause — 2 Apps Playing
| Step | Detail |
|---|---|
| User presses `⏯` | Threek **consumes** the event (does not pass through). |
| Popup appears | Floating HUD-style panel (non-activating, `NSPanel` with `.nonactivatingPanel` style) centered on screen. |
| Layout | Two app icons side by side. Below left icon: `⏮` glyph. Below right icon: `⏭` glyph. |
| User presses `⏮` | Sends pause/play command to the left app via `MRMediaRemoteSendCommandToApp`. Popup dismisses. |
| User presses `⏭` | Sends pause/play command to the right app. Popup dismisses. |
| Timeout | Popup auto-dismisses after ~3 seconds with no action. No command sent. |
| Escape / click outside | Dismisses popup. No command sent. |

### Play/Pause — 3 Apps Playing
| Step | Detail |
|---|---|
| User presses `⏯` | Event consumed. Popup appears. |
| Layout | Three app icons in a row. Labels underneath: `⏮` / `⏯` / `⏭` |
| User presses `⏮` | Command → left app. |
| User presses `⏯` | Command → center app. |
| User presses `⏭` | Command → right app. |
| Timeout / escape | Dismiss, no action. |

### Play/Pause — 4+ Apps Playing (Selector Mode)
| Step | Detail |
|---|---|
| User presses `⏯` | Event consumed. Popup appears. |
| Layout | Horizontally scrollable row of app icons. One icon is **highlighted** (selection ring / glow). Starts on the first icon. Below the row: `⏮` = move selection left, `⏯` = confirm (send command), `⏭` = move selection right. |
| `⏮` press | Moves highlight one icon left (wraps around). |
| `⏭` press | Moves highlight one icon right (wraps around). |
| `⏯` press | Sends pause/play to highlighted app. Popup dismisses. |
| Timeout / escape | Dismiss, no action. |

---

## Popup Design Guidelines
- **Aesthetic:** Vibrancy material background (`.hudWindow` or similar), rounded corners, large app icons (~64pt), SF Symbol glyphs for `⏮ ⏯ ⏭` labels. Think macOS volume/brightness HUD.
- **Non-activating:** Must not steal focus from the current app. The user is pressing hardware keys, not clicking.
- **Icon source:** `NSRunningApplication.icon` or the app bundle's `CFBundleIconFile`. Fallback to generic app icon.
- **App ordering:** Sort by most-recently-active media session (the app that most recently started/changed playback first).
- **Animation:** Subtle fade in/out. Selection highlight animates smoothly between icons.

---

## Menu Bar Presence
- SF Symbol icon in menu bar (something minimal — a `3` with a play triangle, or three horizontal bars, or just the Threek logo).
- Menu items:
  - **Enabled** (toggle on/off — when off, all keys pass through)
  - **Currently Playing:** (submenu listing active Now Playing apps and their track info)
  - **Launch at Login** (toggle, uses `SMAppService` on macOS 13+)
  - **About Threek**
  - **Quit**

---

## Edge Cases to Handle
| Scenario | Handling |
|---|---|
| App quits while popup is showing | Refresh popup. If ≤1 app left, dismiss and pass through. |
| Bluetooth/headphone media buttons | These arrive as the same `NSSystemDefined` events. Threek handles them identically. |
| Touch Bar (older MacBooks) | Touch Bar media controls emit the same key events and should be intercepted the same way. |
| App is playing but not visible in Now Playing | Can't target it. Only apps using the Now Playing API are controllable. This is a macOS constraint, not a Threek bug. |
| Two instances of same app (e.g., two browser tabs) | Now Playing groups these under one bundle ID. Threek treats it as one app. |
| Accessibility permission revoked | Detect failure of event tap → show notification/alert guiding user to re-enable in System Settings. |

---

## Project Structure (Suggested)
```
Threek/
├── App/
│   ├── ThreekApp.swift              # @main, menu bar setup
│   └── AppDelegate.swift            # Event tap lifecycle
├── MediaKeys/
│   ├── MediaKeyInterceptor.swift    # CGEvent tap creation, key classification
│   └── MediaKeyEvent.swift          # Enum: .previous, .playPause, .next
├── NowPlaying/
│   ├── NowPlayingService.swift      # MediaRemote wrapper, app discovery
│   ├── NowPlayingApp.swift          # Model: bundleID, icon, trackInfo, lastActive
│   └── MediaRemoteBridge.h/.m       # ObjC bridging header for private framework
├── Popup/
│   ├── SelectorPopup.swift          # SwiftUI view for the HUD
│   ├── SelectorViewModel.swift      # State machine: idle → showing → selecting → dispatching
│   └── AppIconView.swift            # Single app icon + label component
├── Preferences/
│   ├── PreferencesView.swift        # Settings (if any beyond menu)
│   └── LaunchAtLogin.swift          # SMAppService wrapper
└── Resources/
    └── Assets.xcassets
```

---

## State Machine (Popup)

```
IDLE
  │
  ├── [play/pause pressed, ≤1 app] → pass through → IDLE
  │
  └── [play/pause pressed, ≥2 apps] → SHOWING
        │
        ├── [timeout / escape] → IDLE (no command)
        │
        ├── [2-3 apps: media key pressed] → DISPATCH command → IDLE
        │
        └── [4+ apps]
              ├── [prev/next pressed] → move selection → SHOWING
              └── [play/pause pressed] → DISPATCH command → IDLE
```

---

## Privacy & Security Notes
- **Accessibility access** is the only sensitive permission. Explain clearly *why* in the onboarding prompt.
- Do **not** log or transmit any Now Playing metadata. It stays in-process.
- The private `MediaRemote.framework` may change between macOS versions. Pin to specific macOS targets and test on betas.
- Notarize the app via `notarytool` for Gatekeeper. Hardened runtime is required but compatible with event taps as long as the entitlement is correct.

---

## Open Questions for Development
1. Should the popup also show the **track name / artist** next to each icon, or keep it icon-only for speed?
2. Should there be a "default app" preference (always send to Spotify unless popup is explicitly invoked)?
3. Should `⏮`/`⏭` get the same multi-app treatment, or is play/pause the only contested key?
4. What should the Threek icon/logo actually look like?

---

*End of handoff. Ship the funny name.*
