# Threek Status

This document tracks current operational truth.
Update it when the project's real state changes.

## Snapshot

- Last updated: 2026-07-31
- Overall posture: `active`
- Current focus: per-app album artwork in the picker HUD
- Highest-priority blocker: none
- Next operator decision needed: none
- Related decisions: none yet

## Current State Summary

Threek v2 is functional: it intercepts ⏯, enumerates all Now Playing apps via
the perl-shim adapter, and dispatches to the chosen app. Research on
2026-07-31 (RSH-20260731-001) established that per-app artwork is reachable
through a richer MediaRemote API, while targeted control of backgrounded apps
is an OS ceiling. The repo has just adopted the repo-template operating model
(`records/`, `skills/`, commit enforcement hooks).

## Active Phases Or Tracks

### Per-app album artwork in the HUD

- Goal: show each Now Playing app's current album artwork in the picker.
- Status: `in progress`
- Why this matters now: it is the operator's requested next feature.
- Current work: research complete and de-risked — per-app metadata + artwork
  confirmed fetchable one-shot (RSH-20260731-002). Implementation not begun.
- Exit criteria: picker rows show each app's artwork (falling back to the app
  icon when no artwork), sourced from a one-shot per-player adapter command.
- Dependencies: a new per-player adapter command; Threek-side JSON decode +
  icon fallback.
- Risks: the richer MediaRemote API is private and could change; artwork
  presence varies per app (Spotify/web media may omit bytes), so the icon
  fallback is required.
- Related ids: RSH-20260731-001, RSH-20260731-002

## Recent Changes To Project Reality

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
