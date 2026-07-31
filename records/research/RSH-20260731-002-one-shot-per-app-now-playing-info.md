# RSH-20260731-002: One-Shot Per-App Now Playing Info (No Persistent Subscription)

Opened: 2026-07-31 16-20-00 KST
Recorded by agent: codex

## Question

Following RSH-20260731-001, which assumed per-app artwork required a
persistent subscribed reader: can the stateless perl shim fetch per-app
metadata + artwork **one-shot**, on demand, without holding a connection?

## Finding

**Yes.** The exported function `MRMediaRemoteGetNowPlayingInfoForPlayer`
returns a given app's full now-playing dictionary — including
`kMRMediaRemoteNowPlayingInfoArtworkData` (raw image bytes), title, artist,
album, playback rate — in a single asynchronous call, with no focus
requirement and no persistent subscription. Verified live against three
simultaneously-registered apps: Music returned real artwork data (54 KB JPEG +
166 KB PNG), Zen returned its X-tab metadata, Spotify returned its track.

This removes the main architectural risk flagged in RSH-20260731-001. The
artwork feature does **not** need a persistent helper.

## Working Call Chain (inside the entitled perl shim)

1. `MRMediaRemoteGetNowPlayingClients(queue, ^(id clients))`
   → array of `MRClient`.
2. `MRMediaRemoteGetNowPlayingPlayerForClient(client, nil, queue, ^(MRPlayer *))`
   → the app's `MRPlayer`. Second arg (origin) may be nil.
3. Build an `MRPlayerPath`:
   `[[MRPlayerPath alloc] initWithOrigin:nil client:client player:player]`.
4. `MRMediaRemoteGetNowPlayingInfoForPlayer(playerPath, nil, queue, ^(NSDictionary *))`
   → the now-playing info dictionary for that app.

Both getters are 4-argument C functions whose last argument is a completion
block. Argument order for the player getter is `(client, origin, queue,
completion)` — confirmed by disassembly (`mov x20, x0` = client, `mov x21, x1`
= origin) and by the `MROrigin`/`MRClient` type-mismatch errors when swapped.

## Caveats

- **Artwork presence is per-app.** Music ships `ArtworkData`; Spotify returned
  metadata but no artwork bytes in this run (transient — it had artwork
  earlier); Zen (web media) publishes no artwork. The HUD must fall back to the
  app icon when `ArtworkData` is absent.
- Signatures were recovered by disassembly, not headers; treat them as
  empirically verified on macOS 15.x but private and subject to change.
- The completion blocks fire on an arbitrary queue; the shim must pump the
  runloop briefly to receive results before exiting (as it already does for
  `clients`).

## Follow-Up Routes

- Add an adapter command (e.g. `artwork` / extend `clients`) that walks this
  chain for every registered client and emits JSON: per app, the metadata plus
  base64 artwork. This is a bounded addition to `Vendor/mediaremote-adapter`.
- Threek decodes the JSON and renders artwork in the popup, falling back to
  the app icon. Caching between keypresses becomes an optimization, not a
  correctness requirement, since the fetch is one-shot.
