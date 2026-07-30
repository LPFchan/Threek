// Copyright (c) 2026 LPFchan
// This file is licensed under the BSD 3-Clause License.
//
// Adds a `clients` command to the MediaRemote Adapter that enumerates ALL
// currently-registered Now Playing applications (playing and paused), which is
// what the stock single-active-app `get`/`stream` commands cannot provide.
//
// This runs inside the entitled perl shim (see bin/mediaremote-adapter.pl), so
// MRMediaRemoteGetNowPlayingClients returns real data here even on macOS 15.4+.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#import "MediaRemoteAdapter.h"
#import "utility/helpers.h"

typedef void (*MRGetNowPlayingClients_t)(dispatch_queue_t queue,
                                         void (^completion)(id clients));

// Reads one ObjC property off an MRClient via the runtime, returning nil when
// the selector is unavailable or returns nothing.
static id clientProperty(id client, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (![client respondsToSelector:selector]) {
        return nil;
    }
    return ((id(*)(id, SEL))objc_msgSend)(client, selector);
}

// Reads a scalar integer property (e.g. processIdentifier) off an MRClient.
// These are declared as `int`/`pid_t`, so the object-typed msgSend above would
// reinterpret a small integer as a pointer and crash on first use.
static long clientIntegerProperty(id client, NSString *selectorName,
                                  BOOL *present) {
    SEL selector = NSSelectorFromString(selectorName);
    if (![client respondsToSelector:selector]) {
        *present = NO;
        return 0;
    }
    *present = YES;
    return ((long(*)(id, SEL))objc_msgSend)(client, selector);
}

void adapter_clients() {
    // MediaRemote is already loaded by this framework's constructor
    // (globals.m / MediaRemote.m), so resolve the symbol directly rather than
    // re-creating the bundle, which double-loads the framework and crashes.
    MRGetNowPlayingClients_t getClients =
        (MRGetNowPlayingClients_t)dlsym(RTLD_DEFAULT,
                                        "MRMediaRemoteGetNowPlayingClients");
    if (!getClients) {
        fail(@"MRMediaRemoteGetNowPlayingClients symbol not found");
        return;
    }

    CFRunLoopRef runLoop = CFRunLoopGetCurrent();

    // Brief settle so the XPC connection is up before querying. Kept short so
    // the discovery round-trip stays fast — the app re-queries on demand and
    // any app that appears later is picked up on the next press.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        getClients(dispatch_get_main_queue(), ^(id clients) {
            NSArray *all = [clients isKindOfClass:[NSArray class]]
                               ? (NSArray *)clients
                               : @[];
            NSMutableArray *out = [NSMutableArray arrayWithCapacity:all.count];
            for (id client in all) {
                NSMutableDictionary *entry = [NSMutableDictionary dictionary];

                id bundleID = clientProperty(client, @"bundleIdentifier");
                id displayName = clientProperty(client, @"displayName");
                id parentBundleID =
                    clientProperty(client, @"parentApplicationBundleIdentifier");
                BOOL hasPid = NO;
                long pid = clientIntegerProperty(client, @"processIdentifier",
                                                 &hasPid);

                if (bundleID) entry[@"bundleIdentifier"] = bundleID;
                if (displayName) entry[@"displayName"] = displayName;
                if (parentBundleID) entry[@"parentApplicationBundleIdentifier"] = parentBundleID;
                if (hasPid) entry[@"processIdentifier"] = @(pid);

                [out addObject:entry];
            }

            NSDictionary *result = @{
                @"type" : @"clients",
                @"count" : @(all.count),
                @"clients" : out,
            };
            NSData *json = [NSJSONSerialization dataWithJSONObject:result
                                                           options:0
                                                             error:nil];
            if (json) {
                NSString *line =
                    [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
                printf("%s\n", line.UTF8String);
                fflush(stdout);
            } else {
                printf("{\"type\":\"clients\",\"count\":0,\"clients\":[]}\n");
                fflush(stdout);
            }
            CFRunLoopStop(runLoop);
        });
    });

    // Hard timeout so the shim never hangs waiting on mediaremoted.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        printf("{\"type\":\"clients\",\"count\":0,\"clients\":[]}\n");
        fflush(stdout);
        CFRunLoopStop(runLoop);
    });

    CFRunLoopRun();
}
