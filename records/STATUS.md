# Threek Status

This document tracks current operational truth.
Update it when the project's real state changes.

## Snapshot

- Last updated: 2026-09-26
- Overall posture: `active`
- Current focus: general availability — first public release (DMG, Sparkle
  updates, threek.lost.plus, 28 UI languages)
- Highest-priority blocker: none
- Next operator decision needed: none
- Related decisions: none yet

## Current State Summary

Threek v2 is functional: it intercepts ⏯, enumerates all Now Playing apps via
the perl-shim adapter, and dispatches to the chosen app. When exactly one
controllable app is actually playing, a media-key press routes straight to it
without opening the picker; the HUD only flashes that app over the pressed key. The HUD is now chrome-less — no realtime blurred
backdrop; content separation comes from a drop shadow and background-adaptive
glyph color (keyed off one-shot screenshots of the screen behind the panel,
re-taken every 250 ms while the HUD is up; this needs Screen Recording, which
the onboarding asks for up front along with Accessibility and Automation). Research on
2026-07-31 (RSH-20260731-001) established that per-app artwork is reachable
through a richer MediaRemote API, while targeted control of backgrounded apps
is an OS ceiling. The repo has just adopted the repo-template operating model
(`records/`, `skills/`, commit enforcement hooks).

## Active Phases Or Tracks

### Per-app album artwork in the HUD

- Goal: show each Now Playing app's current album artwork in the picker.
- Status: `done`
- Why this matters now: it is the operator's requested next feature.
- Current work: implemented — new `metadata` adapter command returns per-app
  metadata + base64 artwork one-shot; the picker renders artwork with the app
  icon badged in the corner and falls back to the icon when absent.
- Exit criteria: picker rows show each app's artwork (falling back to the app
  icon when no artwork), sourced from a one-shot per-player adapter command.
- Dependencies: a new per-player adapter command; Threek-side JSON decode +
  icon fallback.
- Risks: the richer MediaRemote API is private and could change; artwork
  presence varies per app (Spotify/web media may omit bytes), so the icon
  fallback is required.
- Related ids: RSH-20260731-001, RSH-20260731-002

## Recent Changes To Project Reality

- Date: 2026-09-26
  - Change: Threek is set up for public release: fork app icon, 28 UI
    languages, Sparkle auto-updates, a "Threek Self-Signed" release
    certificate (keeps the Accessibility grant across updates), a tag-driven
    GitHub Actions release that builds the DMG with DMGMaker, and a homepage
    plus update feed at threek.lost.plus. Now Playing discovery runs its
    three adapter calls concurrently (~0.4 s instead of ~0.7 s).
  - Why it matters: anyone can install and update Threek without building it.
  - Related ids: none

- Date: 2026-09-26
  - Change: Threek now reliably intercepts the real F7–F9 media keys; the
    Karabiner F17–F19 remap workaround and its code path are gone. Swallowed
    keys are swallowed whole (key-down and key-up), the rewind/fast-forward
    codes Apple keyboards send for F7/F9 map to ⏮/⏭, and the play-state
    snapshot is updated on each toggle so rapid presses don't hit a stale
    "X is playing".
  - Why it matters: Threek works out of the box for anyone, without a
    per-user Karabiner setup.
  - Related ids: none

- Date: 2026-08-02
  - Change: media keys route directly to the single playing app (bypassing
    the picker); the HUD's realtime blurred backdrop was removed in favor of
    a chrome-less panel that keeps the drop shadow and adaptive glyph color
    (now driven by a one-shot screenshot, which was expected to drop the
    Screen Recording permission need; superseded 2026-09-26: macOS still asks
    for Screen Recording, so the onboarding requests it).
  - Why it matters: removes the picker step for the common single-player
    case and simplifies the HUD rendering path.
  - Related ids: none

- Date: 2026-07-31
  - Change: per-app album artwork is implemented end-to-end (adapter
    `metadata` command + Swift rendering), committed in 20e3028 and 6d373c5.
  - Why it matters: the accepted artwork feature is now in the picker.
  - Related ids: RSH-20260731-001, RSH-20260731-002


- Date: 2026-07-31
  - Change: adopted the LPFchan repo-template operating model (records/,
    skills/, LOG-* commit enforcement).
  - Why it matters: establishes canonical truth/memory surfaces for the repo.
  - Related ids: none

- Date: 2026-07-31
  - Change: confirmed per-app artwork is viable and backgrounded targeted
    control is not.
  - Why it matters: scopes the artwork feature and closes the control debate.
  - Related ids: RSH-20260731-001

- Date: 2026-07-31
  - Change: confirmed per-app metadata + artwork is fetchable one-shot, no
    persistent subscription needed.
  - Why it matters: removes the artwork feature's main architectural risk and
    simplifies it to a bounded adapter command.
  - Related ids: RSH-20260731-002

## Active Blockers And Risks

- Blocker or risk: private MediaRemote API may change between macOS releases.
  - Effect: discovery or artwork could break on an OS update.
  - Owner: operator
  - Mitigation: the adapter's `test` command detects entitlement loss at
    runtime; pin and test on macOS betas.
  - Related ids: none

## Immediate Next Steps

- Next: design the subscription-based adapter command for per-app metadata +
  artwork.
  - Owner: orchestrator/worker
  - Trigger: operator approval to start the artwork feature
  - Related ids: RSH-20260731-001, RSH-20260731-002
