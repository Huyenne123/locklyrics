#import "LRWallpaperController.h"
#import "LRColorExtractor.h"
#import "LRDynamicWallpaperView.h"
#import "LRLyricsView.h"
#import "LRPreferences.h"
#import "SpringBoard.h"

@interface LRWallpaperController ()

@property (nonatomic, strong) UIView *wallpaperHostView;
@property (nonatomic, strong) LRDynamicWallpaperView *dynamicWallpaperView;
@property (nonatomic, strong) LRLyricsView *lyricsView;

@property (nonatomic, weak) UIViewController *posterLockVC;
@property (nonatomic, weak) UIViewController *fallbackWallpaperVC;
@property (nonatomic, weak) UIViewController *coverSheetVC;

@property (nonatomic, assign) BOOL isScreenOn;
@property (nonatomic, assign) BOOL isLockScreenVisible;
@property (nonatomic, assign) BOOL isInLowPowerMode;
@property (nonatomic, strong) NSArray<UIColor *> *lastAppliedColors;
@property (nonatomic, assign) BOOL desiredVisible;

@end

@implementation LRWallpaperController

+ (instancetype)sharedController {
    static LRWallpaperController *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _wallpaperHostView = [[UIView alloc] initWithFrame:CGRectZero];
        _wallpaperHostView.backgroundColor = [UIColor clearColor];
        _wallpaperHostView.userInteractionEnabled = NO;
        _wallpaperHostView.clipsToBounds = YES;
        _wallpaperHostView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        _dynamicWallpaperView = [[LRDynamicWallpaperView alloc] initWithFrame:CGRectZero];
        _dynamicWallpaperView.hidden = YES;
        _dynamicWallpaperView.alpha = 0.0;
        _dynamicWallpaperView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [_wallpaperHostView addSubview:_dynamicWallpaperView];

        _lyricsView = [[LRLyricsView alloc] initWithFrame:CGRectZero];

        // Query initial screen & power states safely
        _isScreenOn = YES;
        Class backlightClass = NSClassFromString(@"SBBacklightController");
        if (backlightClass && [backlightClass respondsToSelector:@selector(sharedInstance)]) {
            SBBacklightController *bl = [backlightClass sharedInstance];
            if (bl && [bl respondsToSelector:@selector(screenIsOn)]) {
                _isScreenOn = bl.screenIsOn;
            }
        }
        _isInLowPowerMode = [NSProcessInfo processInfo].lowPowerModeEnabled;
        _isLockScreenVisible = NO;

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handlePowerStateChanged:)
                                                     name:NSProcessInfoPowerStateDidChangeNotification
                                                   object:nil];

        [[LRLyricsManager sharedManager] addObserver:self];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [[LRLyricsManager sharedManager] removeObserver:self];
}

- (void)handlePowerStateChanged:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.isInLowPowerMode = [NSProcessInfo processInfo].lowPowerModeEnabled;
        [self syncMountHierarchyAndPowerState];
    });
}

#pragma mark - Attachment & Lifecycle

- (void)attachToPosterLockViewController:(UIViewController *)vc {
    if (!vc) return;
    self.posterLockVC = vc;
    [self syncMountHierarchyAndPowerState];
}

- (void)attachToFallbackWallpaperViewController:(UIViewController *)vc {
    if (!vc) return;
    self.fallbackWallpaperVC = vc;
    [self syncMountHierarchyAndPowerState];
}

- (void)setCoverSheetViewController:(UIViewController *)vc {
    if (!vc) return;
    self.coverSheetVC = vc;
    [self syncMountHierarchyAndPowerState];
}

- (void)setLockScreenVisible:(BOOL)visible {
    BOOL changed = (self.isLockScreenVisible != visible);
    self.isLockScreenVisible = visible;
    [self syncMountHierarchyAndPowerState];
    if (visible && (changed || self.isScreenOn)) {
        [self.lyricsView reloadData];
    }
}

- (void)setScreenOn:(BOOL)screenOn {
    BOOL wasOn = self.isScreenOn;
    self.isScreenOn = screenOn;
    [self syncMountHierarchyAndPowerState];
    if (screenOn && !wasOn && self.isLockScreenVisible) {
        [[LRLyricsManager sharedManager] fetchLatestNowPlayingInfo];
        [self.lyricsView reloadData];
    }
}

- (void)layoutViews {
    [self syncMountHierarchyAndPowerState];
}

- (void)refreshPreferences {
    [self.lyricsView refreshPreferences];
    [self syncMountHierarchyAndPowerState];
    [self.lyricsView reloadData];
}

#pragma mark - Mount & Power State Machine

- (void)syncMountHierarchyAndPowerState {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self syncMountHierarchyAndPowerState];
        });
        return;
    }

    LRPreferences *prefs = [LRPreferences sharedPreferences];
    LRLyricsManager *mgr = [LRLyricsManager sharedManager];

    // 1. Wallpaper Host Mounting (prefer PosterLockVC on iOS 16-18, fallback to PBUIWallpaperVC)
    UIViewController *targetWallpaperVC = self.posterLockVC ?: self.fallbackWallpaperVC;
    if (targetWallpaperVC && targetWallpaperVC.isViewLoaded && targetWallpaperVC.view) {
        UIView *targetView = targetWallpaperVC.view;
        if (self.wallpaperHostView.superview != targetView) {
            [self.wallpaperHostView removeFromSuperview];
            self.wallpaperHostView.frame = targetView.bounds;
            [targetView addSubview:self.wallpaperHostView];
        } else if (!CGRectEqualToRect(self.wallpaperHostView.frame, targetView.bounds)) {
            self.wallpaperHostView.frame = targetView.bounds;
        }
        [targetView bringSubviewToFront:self.wallpaperHostView];

        if (!CGRectEqualToRect(self.dynamicWallpaperView.frame, self.wallpaperHostView.bounds)) {
            self.dynamicWallpaperView.frame = self.wallpaperHostView.bounds;
        }
    }

    // 2. Lyrics View Mounting (Wallpaper Layer Mode vs CoverSheet Overlay Mode)
    BOOL wallpaperMounted = (self.wallpaperHostView.superview != nil);
    if (prefs.lyricsInWallpaperLayer && wallpaperMounted) {
        if (self.lyricsView.superview != self.wallpaperHostView) {
            [self.lyricsView removeFromSuperview];
            [self.wallpaperHostView addSubview:self.lyricsView];
        }
        [self.wallpaperHostView bringSubviewToFront:self.lyricsView];
        [self.lyricsView updateLayoutForParentBounds:self.wallpaperHostView.bounds];
    } else if (self.coverSheetVC && self.coverSheetVC.isViewLoaded && self.coverSheetVC.view) {
        UIView *csView = self.coverSheetVC.view;
        if (self.lyricsView.superview != csView) {
            [self.lyricsView removeFromSuperview];
            [csView addSubview:self.lyricsView];
        }
        [csView bringSubviewToFront:self.lyricsView];
        [self.lyricsView updateLayoutForParentBounds:csView.bounds];
    }

    // Enable or pause lyrics sync timer cleanly when sleeping or unlocked
    BOOL lyricsActive = self.isLockScreenVisible && self.isScreenOn;
    if (self.lyricsView.isLockscreenActive != lyricsActive) {
        self.lyricsView.isLockscreenActive = lyricsActive;
        if (!lyricsActive) {
            [self.lyricsView stopSyncTimer];
        }
    }

    // 3. Dynamic Wallpaper Visibility & GPU Power Saver
    BOOL hasActiveMusic = mgr.isCurrentAppAllowed && (mgr.currentTitle.length > 0);
    BOOL shouldShow = prefs.enabled &&
                      prefs.enableDynamicWallpaper &&
                      self.isLockScreenVisible &&
                      self.isScreenOn &&
                      hasActiveMusic &&
                      wallpaperMounted;

    BOOL freezeForLowPower = prefs.dynamicWallpaperPowerSaver && self.isInLowPowerMode;
    BOOL shouldAnimate = shouldShow &&
                         mgr.isPlaying &&
                         !freezeForLowPower &&
                         (prefs.dynamicWallpaperSpeed > 0.01);

    self.dynamicWallpaperView.renderScale = 0.25;
    self.dynamicWallpaperView.frameLimit = prefs.dynamicWallpaperFPS;
    self.dynamicWallpaperView.speed = prefs.dynamicWallpaperSpeed;
    self.desiredVisible = shouldShow;

    if (shouldShow) {
        NSArray<UIColor *> *targetPalette = mgr.currentArtworkColors ?: [LRColorExtractor defaultPalette];
        BOOL wasHidden = self.dynamicWallpaperView.hidden;

        if (!self.lastAppliedColors || self.lastAppliedColors != targetPalette) {
            self.lastAppliedColors = targetPalette;
            [self.dynamicWallpaperView setColors:targetPalette animated:(!wasHidden && shouldAnimate)];
        }

        if (wasHidden) {
            self.dynamicWallpaperView.alpha = 0.0;
            self.dynamicWallpaperView.hidden = NO;
            [self.dynamicWallpaperView renderSingleFrame];
        }

        self.dynamicWallpaperView.animating = shouldAnimate;
        if (!shouldAnimate) {
            [self.dynamicWallpaperView renderSingleFrame];
        }

        CGFloat targetOpacity = prefs.dynamicWallpaperOpacity;
        if (fabs(self.dynamicWallpaperView.alpha - targetOpacity) > 0.01) {
            [UIView animateWithDuration:0.35
                                  delay:0.0
                                options:(UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction)
                             animations:^{
                                 self.dynamicWallpaperView.alpha = targetOpacity;
                             }
                             completion:nil];
        }
    } else {
        self.dynamicWallpaperView.animating = NO;

        if (!self.isScreenOn || !self.isLockScreenVisible) {
            self.dynamicWallpaperView.alpha = 0.0;
            self.dynamicWallpaperView.hidden = YES;
        } else if (!self.dynamicWallpaperView.hidden) {
            [UIView animateWithDuration:0.35
                                  delay:0.0
                                options:(UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction)
                             animations:^{
                                 self.dynamicWallpaperView.alpha = 0.0;
                             }
                             completion:^(BOOL finished) {
                                 if (!self.desiredVisible) {
                                     self.dynamicWallpaperView.hidden = YES;
                                 }
                             }];
        }
    }
}

#pragma mark - LRLyricsObserver

- (void)lyricsManagerDidUpdateSong:(LRLyricsSong *)song {
    [self syncMountHierarchyAndPowerState];
}

- (void)lyricsManagerDidChangePlaybackState:(BOOL)isPlaying {
    [self syncMountHierarchyAndPowerState];
}

- (void)lyricsManagerDidUpdateArtworkColors:(NSArray<UIColor *> *)colors {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray<UIColor *> *palette = colors ?: [LRColorExtractor defaultPalette];
        self.lastAppliedColors = palette;
        BOOL animateSwap = self.isLockScreenVisible && self.isScreenOn && !self.dynamicWallpaperView.hidden;
        [self.dynamicWallpaperView setColors:palette animated:animateSwap];
        [self syncMountHierarchyAndPowerState];
    });
}

@end
