# Threek Spec

This file is the canonical statement of what Threek is supposed to be.
Keep it durable. Do not use it as a changelog, inbox, or weekly narrative.

- Project: Threek
- Canonical repo: LPFchan/Threek
- Project id: threek
- Operator: yeowool
- Last updated: 2026-07-31
- Related decisions: none yet

## Project thesis

macOS hands play/pause to whichever app most recently claimed the Now Playing
session. With Spotify, Music, and a browser tab all paused at once, pressing ⏯
is a lottery. Threek intercepts the key, enumerates every app in the Now
Playing registry, and pops up a HUD so you pick the target.

## Core capabilities

- Intercept the hardware ⏯ key via a `CGEvent` tap (Accessibility permission).
- Discover **all** Now Playing registrants (playing and paused) through the
  vendored `mediaremote-adapter` perl shim, which is entitled where the host
  app is not (macOS 15.4+ restriction).
- Present a fixed-size selector HUD anchored above the F7–F9 keys; 2–3 apps
  map directly to ⏮/⏯/⏭, 4+ apps use a carousel with a selection ring.
- Dispatch play/pause to the chosen app: AppleScript for scriptable apps,
  MediaRemote fallback for the active app.

## Invariants

- ⏮/⏭ always pass through; only ⏯ is intercepted.
- No network access, analytics, or telemetry. Now Playing metadata stays
  in-process.
- `LSUIElement = true` (menu bar app, no dock icon).
- The adapter is built from source at build time; no committed binaries.
- Only apps registered with macOS Now Playing are discoverable.

## Non-goals

- Controlling backgrounded, paused apps that do not hold Now Playing focus.
  `mediaremoted` reroutes such commands to the active app; this is an OS
  ceiling, not a gap. See RSH-20260731-001.

## Main surfaces

- `NowPlaying/NowPlayingService.swift` — perl-shim discovery + dispatch.
- `Popup/PopupController.swift`, `Popup/SelectorViewModel.swift` — HUD.
- `Vendor/mediaremote-adapter/` — the entitlement workaround (adds a `clients`
  command on top of the upstream adapter).
