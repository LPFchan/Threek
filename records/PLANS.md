# Threek Plans

This document contains accepted future direction only.
Do not put raw brainstorms or untriaged intake here.

## Approved Directions

### Per-app album artwork in the picker HUD

- Outcome: each row in the picker shows the app's current album artwork, with
  the app icon as fallback, so the HUD reads like the operator's reference
  mockup (artwork + app icon pairing).
- Why this is accepted: the operator requested it; research confirmed it is
  achievable via the richer MediaRemote per-player API.
- Expected value: a richer, more legible picker that identifies apps by what
  they are playing, not just their icon.
- Preconditions: a subscription-based adapter command that returns all
  players' content items + artwork as JSON; a Threek-side artwork cache so the
  popup is not empty on first open.
- Earliest likely start: immediate.
- Related ids: RSH-20260731-001

## Sequencing

### Near Term

- Initiative: subscription-based adapter metadata command.
  - Why now: it is the prerequisite for artwork and the riskiest unknown
    (adapting the stateless shim to receive pushed state).
  - Dependencies: none beyond the existing vendored adapter.
  - Related ids: RSH-20260731-001

- Initiative: Threek artwork cache + popup rendering.
  - Why now: follows directly once the adapter can supply artwork.
  - Dependencies: the adapter metadata command.
  - Related ids: RSH-20260731-001

### Deferred But Accepted

- Initiative: universal targeted control of backgrounded apps.
  - Why deferred: disproven — `mediaremoted` reroutes backgrounded commands to
    the active app (OS ceiling). Not pursued.
  - Revisit trigger: a future macOS release changing MediaRemote command
    routing.
  - Related ids: RSH-20260731-001
