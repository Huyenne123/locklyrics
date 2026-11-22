#import "Tweak.h"
#import <notify.h>

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;

    // Initialize wallpaper coordinator and start playback monitoring
    [LRWallpaperController sharedController];
    [[LRLyricsManager sharedManager] startMonitoring];
}

- (void)frontDisplayDidChange:(id)newDisplay {
    %orig;
    [[LRWallpaperController sharedController] frontDisplayDidChange:newDisplay];
}

%end

%hook PBUIPosterLockViewController

- (void)viewDidLoad {
    %orig;
    [[LRWallpaperController sharedController] attachToPosterLockViewController:self];
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    [[LRWallpaperController sharedController] attachToPosterLockViewController:self];
}

- (void)viewDidLayoutSubviews {
    %orig;
    [[LRWallpaperController sharedController] attachToPosterLockViewController:self];
}

%end

%hook PBUIPosterHomeViewController

- (void)viewDidLoad {
    %orig;
    [[LRWallpaperController sharedController] attachToPosterHomeViewController:self];
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    [[LRWallpaperController sharedController] attachToPosterHomeViewController:self];
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    [[LRWallpaperController sharedController] attachToPosterHomeViewController:self];
}

- (void)viewDidLayoutSubviews {
    %orig;
    [[LRWallpaperController sharedController] attachToPosterHomeViewController:self];
}

%end

%hook SBHomeScreenViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    [[LRWallpaperController sharedController] setHomeScreenVisible:YES];
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    [[LRWallpaperController sharedController] setHomeScreenVisible:YES];
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    [[LRWallpaperController sharedController] setHomeScreenVisible:NO];
}

%end

%hook SBRootFolderController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    [[LRWallpaperController sharedController] setHomeScreenVisible:YES];
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    [[LRWallpaperController sharedController] setHomeScreenVisible:NO];
}

%end

%hook PBUIWallpaperViewController

- (void)viewDidLoad {
    %orig;
    [[LRWallpaperController sharedController] attachToFallbackWallpaperViewController:self];
}

- (void)viewDidLayoutSubviews {
    %orig;
    [[LRWallpaperController sharedController] attachToFallbackWallpaperViewController:self];
}

- (void)_updateWallpaperForLocations:(long long)locations options:(unsigned long long)options wallpaperMode:(long long)mode withCompletion:(id)completion {
    %orig;
    [[LRWallpaperController sharedController] attachToFallbackWallpaperViewController:self];
}

%end

%hook SBBacklightController

- (void)turnOnScreenFullyWithBacklightSource:(long long)source {
    %orig;
    [[LRWallpaperController sharedController] setScreenOn:YES];
}

- (void)_notifyObserversWillAnimateToFactor:(float)factor source:(long long)source {
    %orig;
    [[LRWallpaperController sharedController] setScreenOn:(factor > 0.01f)];
}

- (void)_notifyObserversDidAnimateToFactor:(float)factor source:(long long)source {
    %orig;
    [[LRWallpaperController sharedController] setScreenOn:(factor > 0.01f)];
}

%end

%hook CSCoverSheetViewController

- (void)viewDidLoad {
    %orig;
    [[LRWallpaperController sharedController] setCoverSheetViewController:self];
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;

    LRWallpaperController *wc = [LRWallpaperController sharedController];
    [wc setCoverSheetViewController:self];
    [wc setLockScreenVisible:YES];

    // Fetch latest now playing info to update lyrics & artwork on lock screen reveal
    [[LRLyricsManager sharedManager] fetchLatestNowPlayingInfo];
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    [[LRWallpaperController sharedController] setLockScreenVisible:YES];
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    [[LRWallpaperController sharedController] setLockScreenVisible:NO];
}

- (void)viewDidLayoutSubviews {
    %orig;
    [[LRWallpaperController sharedController] layoutViews];
}

%end

%hook SBMediaController

- (void)setNowPlayingInfo:(id)arg1 {
    %orig;

    NSString *bundleID = nil;
    if ([self respondsToSelector:@selector(nowPlayingApplication)]) {
        id app = [self nowPlayingApplication];
        if (app && [app respondsToSelector:@selector(bundleIdentifier)]) {
            bundleID = [app bundleIdentifier];
        }
    }
    if (bundleID) {
        [[LRLyricsManager sharedManager] setNowPlayingBundleID:bundleID];
    }

    if (![[LRLyricsManager sharedManager] isCurrentAppAllowed]) {
        [[LRLyricsManager sharedManager] checkAppAllowanceAndSync];
        return;
    }

    if (arg1 && [arg1 isKindOfClass:[NSDictionary class]]) {
        [[LRLyricsManager sharedManager] updateWithInfoDictionary:(NSDictionary *)arg1];
    } else {
        [[LRLyricsManager sharedManager] fetchLatestNowPlayingInfo];
    }
    if ([self respondsToSelector:@selector(isPlaying)]) {
        [[LRLyricsManager sharedManager] updatePlaybackState:[self isPlaying]];
    }
}

- (void)_nowPlayingInfoChanged {
    %orig;

    NSString *bundleID = nil;
    if ([self respondsToSelector:@selector(nowPlayingApplication)]) {
        id app = [self nowPlayingApplication];
        if (app && [app respondsToSelector:@selector(bundleIdentifier)]) {
            bundleID = [app bundleIdentifier];
        }
    }
    if (bundleID) {
        [[LRLyricsManager sharedManager] setNowPlayingBundleID:bundleID];
    }

    if (![[LRLyricsManager sharedManager] isCurrentAppAllowed]) {
        [[LRLyricsManager sharedManager] checkAppAllowanceAndSync];
        return;
    }

    [[LRLyricsManager sharedManager] fetchLatestNowPlayingInfo];
    if ([self respondsToSelector:@selector(isPlaying)]) {
        [[LRLyricsManager sharedManager] updatePlaybackState:[self isPlaying]];
    }
}

- (BOOL)_setNowPlayingApplication:(id)arg1 {
    BOOL ret = %orig;

    NSString *bundleID = nil;
    if (arg1 && [arg1 respondsToSelector:@selector(bundleIdentifier)]) {
        bundleID = [arg1 bundleIdentifier];
    }
    [[LRLyricsManager sharedManager] setNowPlayingBundleID:bundleID];

    if (!arg1 || ![[LRLyricsManager sharedManager] isCurrentAppAllowed]) {
        [[LRLyricsManager sharedManager] checkAppAllowanceAndSync];
    } else {
        [[LRLyricsManager sharedManager] fetchLatestNowPlayingInfo];
        if ([self respondsToSelector:@selector(isPlaying)]) {
            [[LRLyricsManager sharedManager] updatePlaybackState:[self isPlaying]];
        }
    }
    return ret;
}

- (void)_nowPlayingAppIsPlayingDidChange {
    %orig;

    if (![[LRLyricsManager sharedManager] isCurrentAppAllowed]) {
        [[LRLyricsManager sharedManager] checkAppAllowanceAndSync];
        return;
    }

    if ([self respondsToSelector:@selector(isPlaying)]) {
        [[LRLyricsManager sharedManager] updatePlaybackState:[self isPlaying]];
    } else {
        [[LRLyricsManager sharedManager] fetchLatestNowPlayingInfo];
    }
}

%end

%ctor {
    %init;

    // Pure BSD notify_register_dispatch for live preference updates on iOS 16-18
    int token = 0;
    notify_register_dispatch(kLRPreferencesChangedNotification, &token, dispatch_get_main_queue(), ^(int t) {
        [[LRPreferences sharedPreferences] loadPreferences];
        [[LRLyricsManager sharedManager] checkAppAllowanceAndSync];
        [[LRWallpaperController sharedController] refreshPreferences];
    });
}
