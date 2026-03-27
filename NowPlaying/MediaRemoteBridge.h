// MediaRemoteBridge.h
// ObjC header declaring the private MediaRemote function types loaded via dlopen/dlsym.
// Do NOT import this header directly; it is included via the bridging header.

@import Foundation;

// ---------------------------------------------------------------------------
// Command enum (matches MediaRemote's internal integer values)
// ---------------------------------------------------------------------------
typedef NS_ENUM(NSInteger, MRMediaRemoteCommand) {
    kMRPlay             = 0,
    kMRPause            = 1,
    kMRTogglePlayPause  = 2,
    kMRStop             = 3,
    kMRNextTrack        = 4,
    kMRPreviousTrack    = 5,
    kMRBeginFastForward = 6,
    kMREndFastForward   = 7,
    kMRBeginRewind      = 8,
    kMREndRewind        = 9,
};

// ---------------------------------------------------------------------------
// Function pointer typedefs
// ---------------------------------------------------------------------------

// MRMediaRemoteGetNowPlayingApplications
// Calls completion on the given queue with an array of bundle-ID strings.
typedef void (*MRMediaRemoteGetNowPlayingApplicationsFuncPtr)(
    dispatch_queue_t queue,
    void (^completion)(NSArray<NSString *> *bundleIDs)
);

// MRMediaRemoteGetNowPlayingInfo
// Calls completion on the given queue with a dictionary of now-playing metadata.
// Known keys: kMRMediaRemoteNowPlayingInfoTitle, kMRMediaRemoteNowPlayingInfoArtist,
//             kMRMediaRemoteNowPlayingInfoAlbum, kMRMediaRemoteNowPlayingInfoArtworkData,
//             kMRMediaRemoteNowPlayingInfoDuration, kMRMediaRemoteNowPlayingInfoElapsedTime,
//             kMRMediaRemoteNowPlayingInfoTimestamp, kMRMediaRemoteNowPlayingInfoPlaybackRate
typedef void (*MRMediaRemoteGetNowPlayingInfoFuncPtr)(
    dispatch_queue_t queue,
    void (^completion)(NSDictionary *info)
);

// MRMediaRemoteGetNowPlayingApplicationIsPlaying
// Calls completion with a BOOL indicating whether the app with the given bundle ID is playing.
typedef void (*MRMediaRemoteGetNowPlayingApplicationIsPlayingFuncPtr)(
    dispatch_queue_t queue,
    void (^completion)(BOOL isPlaying)
);

// MRMediaRemoteSendCommand
// Sends a command to the active Now Playing app (first responder).
typedef BOOL (*MRMediaRemoteSendCommandFuncPtr)(
    MRMediaRemoteCommand command,
    NSDictionary *options
);

// ---------------------------------------------------------------------------
// Well-known Now Playing info dictionary keys (string constants in the framework)
// ---------------------------------------------------------------------------
// We declare them as externs; the actual values are looked up at runtime via
// dlsym in NowPlayingService.swift. Declared as (void *) here, Swift side
// casts them to CFString / NSString as needed.
