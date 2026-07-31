// Copyright (c) 2026 LPFchan
// This file is licensed under the BSD 3-Clause License.
//
// Adds a `metadata` command to the MediaRemote Adapter that returns, for EVERY
// registered Now Playing app, its current now-playing metadata and album
// artwork — the data the single-active-app `get` command cannot provide.
//
// This runs inside the entitled perl shim (see bin/mediaremote-adapter.pl), so
// the MediaRemote per-player calls return real data here even on macOS 15.4+.
//
// The call chain (verified in RSH-20260731-002) is one-shot and needs no
// persistent subscription:
//   MRMediaRemoteGetNowPlayingClients            -> [MRClient]
//   MRMediaRemoteGetNowPlayingPlayerForClient    -> MRPlayer        (per client)
//   MRPlayerPath initWithOrigin:client:player:   -> MRPlayerPath    (per client)
//   MRMediaRemoteGetNowPlayingInfoForPlayer      -> NSDictionary    (per client)

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#import "MediaRemoteAdapter.h"
#import "utility/helpers.h"

typedef void (*MRGetNowPlayingClients_t)(dispatch_queue_t queue,
                                         void (^completion)(id clients));
typedef void (*MRGetPlayerForClient_t)(id client, id origin,
                                       dispatch_queue_t queue,
                                       void (^completion)(id player));
typedef void (*MRGetInfoForPlayer_t)(id playerPath, BOOL includeArtwork,
                                     dispatch_queue_t queue,
                                     void (^completion)(NSDictionary *info));

// Reads one ObjC property off an object via the runtime.
static id objectProperty(id obj, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (![obj respondsToSelector:selector]) {
        return nil;
    }
    return ((id(*)(id, SEL))objc_msgSend)(obj, selector);
}

// Maps the MediaRemote now-playing-info keys we care about onto compact,
// stable JSON keys. Artwork bytes are left as NSData so the JSON sanitizer
// base64-encodes them.
static NSDictionary *extractMetadata(NSDictionary *info) {
    if (![info isKindOfClass:[NSDictionary class]]) {
        return @{};
    }
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    void (^copy)(NSString *, NSString *) = ^(NSString *jsonKey, NSString *mrKey) {
        id value = info[mrKey];
        if (value != nil) {
            out[jsonKey] = value;
        }
    };
    copy(@"title", @"kMRMediaRemoteNowPlayingInfoTitle");
    copy(@"artist", @"kMRMediaRemoteNowPlayingInfoArtist");
    copy(@"album", @"kMRMediaRemoteNowPlayingInfoAlbum");
    copy(@"duration", @"kMRMediaRemoteNowPlayingInfoDuration");
    copy(@"elapsedTime", @"kMRMediaRemoteNowPlayingInfoElapsedTime");
    copy(@"playbackRate", @"kMRMediaRemoteNowPlayingInfoPlaybackRate");
    copy(@"artworkData", @"kMRMediaRemoteNowPlayingInfoArtworkData");
    copy(@"artworkMimeType", @"kMRMediaRemoteNowPlayingInfoArtworkMIMEType");
    return out;
}

void adapter_metadata() {
    // Resolve the per-player symbols. MediaRemote is already loaded by this
    // framework's constructor (globals.m), so dlsym against RTLD_DEFAULT.
    MRGetNowPlayingClients_t getClients = (MRGetNowPlayingClients_t)dlsym(
        RTLD_DEFAULT, "MRMediaRemoteGetNowPlayingClients");
    MRGetPlayerForClient_t getPlayerForClient =
        (MRGetPlayerForClient_t)dlsym(RTLD_DEFAULT,
                                      "MRMediaRemoteGetNowPlayingPlayerForClient");
    MRGetInfoForPlayer_t getInfoForPlayer = (MRGetInfoForPlayer_t)dlsym(
        RTLD_DEFAULT, "MRMediaRemoteGetNowPlayingInfoForPlayer");
    if (!getClients || !getPlayerForClient || !getInfoForPlayer) {
        fail(@"per-player MediaRemote symbols not found");
        return;
    }
    Class playerPathClass = NSClassFromString(@"MRPlayerPath");
    if (!playerPathClass) {
        fail(@"MRPlayerPath class not found");
        return;
    }

    CFRunLoopRef runLoop = CFRunLoopGetCurrent();
    dispatch_queue_t queue = dispatch_get_main_queue();

    // Brief settle so the XPC connection is up before querying (same rationale
    // as clients.m).
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   queue, ^{
        getClients(queue, ^(id clients) {
            NSArray *all = [clients isKindOfClass:[NSArray class]]
                               ? (NSArray *)clients
                               : @[];
            // Collapse helper processes into their parent app, matching
            // clients.m. Keyed by effective bundle ID.
            NSMutableArray *entries = [NSMutableArray arrayWithCapacity:all.count];

            // Track how many clients still need their metadata resolved so we
            // know when to print and stop.
            __block NSInteger pending = (NSInteger)all.count;
            __block BOOL finished = NO;
            void (^finishIfDone)(void) = ^{
                if (finished) {
                    return;
                }
                if (pending > 0) {
                    return;
                }
                finished = YES;
                NSDictionary *result = @{
                    @"type" : @"metadata",
                    @"count" : @(entries.count),
                    @"apps" : entries,
                };
                NSString *json = serializeJsonDictionarySafe(result, NO);
                printOut(json ? json : @"{\"type\":\"metadata\",\"count\":0,\"apps\":[]}");
                CFRunLoopStop(runLoop);
            };

            if (all.count == 0) {
                finishIfDone();
                return;
            }

            for (id client in all) {
                NSMutableDictionary *entry = [NSMutableDictionary dictionary];
                id bundleID = objectProperty(client, @"bundleIdentifier");
                id displayName = objectProperty(client, @"displayName");
                id parentBundleID =
                    objectProperty(client, @"parentApplicationBundleIdentifier");
                if (bundleID) entry[@"bundleIdentifier"] = bundleID;
                if (displayName) entry[@"displayName"] = displayName;
                if (parentBundleID) {
                    entry[@"parentApplicationBundleIdentifier"] = parentBundleID;
                }
                [entries addObject:entry];

                getPlayerForClient(client, nil, queue, ^(id player) {
                    if (!player) {
                        pending--;
                        finishIfDone();
                        return;
                    }
                    id playerPath = ((id(*)(id, SEL, id, id, id))objc_msgSend)(
                        [playerPathClass alloc],
                        NSSelectorFromString(@"initWithOrigin:client:player:"),
                        nil, client, player);
                    if (!playerPath) {
                        pending--;
                        finishIfDone();
                        return;
                    }
                    // Second arg is a boolean: when nonzero, the request sets an
                    // explicit artwork size, which is what makes mediaremoted
                    // return raw artwork bytes rather than a lightweight
                    // reference. Verified by disassembly (cbz w23 gate around
                    // setArtworkWidth:/setArtworkHeight:).
                    getInfoForPlayer(playerPath, YES, queue, ^(NSDictionary *info) {
                        NSDictionary *meta = extractMetadata(info);
                        if (meta.count > 0) {
                            entry[@"metadata"] = meta;
                        }
                        pending--;
                        finishIfDone();
                    });
                });
            }
        });
    });

    // Hard timeout so the shim never hangs waiting on mediaremoted.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)),
                   queue, ^{
        printOut(@"{\"type\":\"metadata\",\"count\":0,\"apps\":[]}");
        CFRunLoopStop(runLoop);
    });

    CFRunLoopRun();
}
