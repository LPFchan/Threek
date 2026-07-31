# RSH-20260731-001: MediaRemote Per-App Metadata and Targeted Control

Opened: 2026-07-31 16-00-00 KST
Recorded by agent: codex

## Question

Can Threek show **per-app album artwork** in the picker HUD (every row, like
Sleeve/MediaMate), and can it send play/pause to a **specific paused,
backgrounded app** — including non-scriptable browsers — instead of only the
active Now Playing app?

Both questions probe the same private `MediaRemote.framework`, which is the
only path to Now Playing data on macOS 15.4+ and only reachable from Threek's
entitled perl shim (`Vendor/mediaremote-adapter`).

## Method

Drove `MediaRemote.framework` directly inside the entitled perl shim by
loading a probe `.dylib` via Perl `DynaLoader` (the shim strips
`DYLD_INSERT_LIBRARIES` because `/usr/bin/perl` is SIP-restricted, so
injection had to go through the same `dl_load_file` mechanism the adapter
itself uses). Enumerated ObjC classes/methods at runtime and dumped the
framework's exported symbols.

## Findings

### Per-app metadata exists (artwork is viable)

- The thin `MRClient` objects returned by
  `MRMediaRemoteGetNowPlayingClients` (what Threek's `clients` command uses)
  carry only identity: bundleID, displayName, PID, parent, app icon. No track
  metadata.
- A **richer API** exists and is present on macOS 15.x:
  `MRNowPlayingOriginClientManager` → `MRNowPlayingOriginClient` →
  `MRNowPlayingPlayerClient` → `nowPlayingInfo`, `nowPlayingContentItem`,
  `nowPlayingArtwork`, `playbackState`. `MRNowPlayingArtworkImage` carries the
  actual image data.
- This richer layer is built for **persistent, subscribed readers** (Sleeve,
  the stock panel). It returns empty from a stateless one-shot process unless
  the process registers for Now Playing notifications and stays connected long
  enough for `mediaremoted` to push player state. Threek's adapter is
  spawn-per-keypress, so reaching it requires a subscription-based command,
  not a one-shot query.
- Conclusion: **per-app artwork is achievable**, but it is an architectural
  change to the adapter (subscribe + collect + return JSON, with Threek-side
  caching between presses), not a new field on the existing `clients` payload.

### Targeted control of backgrounded apps is NOT possible

- `MRMediaRemoteSendCommandToClient` is exported. Its real signature (found in
  ChiChou/sploits) is 7-arg:
  `(int command, NSDictionary *options, id origin, id client, int flags, int reserved, id completion)`.
  A 3-arg guess segfaults; the working call uses
  `options = {kMRMediaRemoteOptionDisableImplicitAppLaunchBehaviors: YES}` and
  the **real** `MRClient` object (which carries the PID), and the process must
  stay alive briefly for `mediaremoted`'s answer.
- Verified behavior, across all call conventions (created-by-bundleID client,
  real registered client):
  - Target **is** the active / most-recent Now Playing app → command reaches
    it (Music toggled; Zen resumed when it was last-played).
  - Target is **paused and backgrounded** → the command is silently
    **rerouted to the active app**. Confirmed against Zen: Zen stayed paused,
    the active Spotify paused instead. Same reroute observed with Music.
- Conclusion: `mediaremoted` only forwards commands to the client that
  currently holds media-key focus. Backgrounded apps — scriptable or not — do
  not receive them. **Universal targeted control is an OS ceiling, not an
  engineering gap.** Threek's existing model (AppleScript for scriptable apps,
  active-only for the rest) is already the correct maximum.

## Rejected Paths

- Using `MRClient` (the `clients` command) for artwork: it has no metadata
  accessors.
- `MRMediaRemoteSendCommandToClient` as a way to make backgrounded browsers
  controllable: disproven by experiment.
- `MRMediaRemoteGetNowPlayingInfoForOriginator` for per-origin metadata: not
  exported on this OS.

## Follow-Up Routes

- Build the artwork feature: add a subscription-based adapter command that
  returns all players' content items + artwork as JSON; cache in Threek so the
  popup isn't empty on first open. See `records/PLANS.md`.
- Keep the control model unchanged. The `isControllable` grey-out for
  backgrounded non-scriptable apps should stay — it reflects how macOS works.
