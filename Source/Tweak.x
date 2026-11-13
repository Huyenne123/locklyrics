#import "Tweak.h"
#import <notify.h>

static __weak CSCoverSheetViewController *gActiveCoverSheetVC = nil;

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;

    // Start playback monitoring once SpringBoard is fully initialized
    [[LRLyricsManager sharedManager] startMonitoring];
}

%end

%hook CSCoverSheetViewController

%property (nonatomic, strong) LRLyricsView *lr_lyricsView;

- (void)viewDidLoad {
    %orig;
    [self lr_ensureLyricsView];
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;

    gActiveCoverSheetVC = self;
    [self lr_ensureLyricsView];
    if (self.lr_lyricsView) {
        self.lr_lyricsView.isLockscreenActive = YES;
        [self.view bringSubviewToFront:self.lr_lyricsView];
        [self.lr_lyricsView refreshPreferences];
        [self.lr_lyricsView updateLayoutForParentBounds:self.view.bounds];

        // Fetch latest now playing info to update lyrics on lock screen reveal
        [[LRLyricsManager sharedManager] fetchLatestNowPlayingInfo];
        [self.lr_lyricsView reloadData];
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;

    if (gActiveCoverSheetVC == self) {
        gActiveCoverSheetVC = nil;
    }

    if (self.lr_lyricsView) {
        self.lr_lyricsView.isLockscreenActive = NO;
        [self.lr_lyricsView stopSyncTimer];
    }
}

- (void)viewDidLayoutSubviews {
    %orig;

    if (self.lr_lyricsView && self.lr_lyricsView.superview) {
        [self.lr_lyricsView updateLayoutForParentBounds:self.view.bounds];
    }
}

%new(v@:)
- (void)lr_ensureLyricsView {
    if (!self.lr_lyricsView) {
        self.lr_lyricsView = [[LRLyricsView alloc] initWithFrame:CGRectZero];
        [self.view addSubview:self.lr_lyricsView];
        [self.view bringSubviewToFront:self.lr_lyricsView];
        [self.lr_lyricsView updateLayoutForParentBounds:self.view.bounds];
    }
}

%new(v@:)
- (void)lr_updateLyricsPosition {
    if (self.lr_lyricsView) {
        [self.lr_lyricsView updateLayoutForParentBounds:self.view.bounds];
    }
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

    // Use pure BSD notify_register_dispatch to listen for live preference changes
    // Completely avoids CFNotificationCenter / Swift Foundation PAC issues on iOS 18
    int token = 0;
    notify_register_dispatch(kLRPreferencesChangedNotification, &token, dispatch_get_main_queue(), ^(int t) {
        [[LRPreferences sharedPreferences] loadPreferences];
        [[LRLyricsManager sharedManager] checkAppAllowanceAndSync];
        CSCoverSheetViewController *activeVC = gActiveCoverSheetVC;
        if (activeVC && activeVC.lr_lyricsView) {
            [activeVC.lr_lyricsView refreshPreferences];
            [activeVC.lr_lyricsView updateLayoutForParentBounds:activeVC.view.bounds];
            [activeVC.lr_lyricsView reloadData];
        }
    });
}
