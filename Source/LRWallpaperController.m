#import "LRWallpaperController.h"
#import "LRColorExtractor.h"
#import "LRDynamicWallpaperView.h"
#import "LRLyricsView.h"
#import "LRPreferences.h"
#import "SpringBoard.h"

static BOOL LRIsViewVisiblyAttached(UIView *view) {
    if (!view || !view.window || CGRectIsEmpty(view.bounds)) {
        return NO;
    }
    UIView *curr = view;
    while (curr) {
        if (curr.hidden || curr.alpha <= 0.01) {
            return NO;
        }
        curr = curr.superview;
    }
    return YES;
}

static BOOL LRIsViewAboveView(UIView *viewA, UIView *viewB) {
    if (!viewA || !viewB || viewA == viewB) {
        return NO;
    }

    NSMutableArray<UIView *> *chainA = [NSMutableArray array];
    for (UIView *v = viewA; v != nil; v = v.superview) {
        [chainA addObject:v];
    }

    UIView *childB = nil;
    UIView *currB = viewB;
    while (currB) {
        NSUInteger idxA = [chainA indexOfObjectIdenticalTo:currB];
        if (idxA != NSNotFound) {
            if (!childB) {
                // viewB is an ancestor of viewA; subviews paint above superview
                return (idxA > 0);
            }
            if (idxA == 0) {
                // viewA is an ancestor of viewB; subviews paint above superview
                return NO;
            }
            UIView *childA = chainA[idxA - 1];
            NSUInteger indexA = [currB.subviews indexOfObjectIdenticalTo:childA];
            NSUInteger indexB = [currB.subviews indexOfObjectIdenticalTo:childB];
            return (indexA != NSNotFound && indexB != NSNotFound && indexA > indexB);
        }
        childB = currB;
        currB = currB.superview;
    }
    return NO;
}

@interface LRWallpaperController ()

@property (nonatomic, strong) UIView *wallpaperHostView;
@property (nonatomic, strong) LRDynamicWallpaperView *dynamicWallpaperView;
@property (nonatomic, strong) UIView *homeWallpaperHostView;
@property (nonatomic, strong) LRDynamicWallpaperView *homeDynamicWallpaperView;
@property (nonatomic, strong) LRLyricsView *lyricsView;

@property (nonatomic, weak) UIViewController *posterLockVC;
@property (nonatomic, weak) UIViewController *posterHomeVC;
@property (nonatomic, weak) UIViewController *fallbackWallpaperVC;
@property (nonatomic, weak) UIViewController *coverSheetVC;

@property (nonatomic, assign) BOOL isScreenOn;
@property (nonatomic, assign) BOOL isLockScreenVisible;
@property (nonatomic, assign) BOOL isHomeScreenVisible;
@property (nonatomic, assign) BOOL isForegroundAppActive;
@property (nonatomic, assign) BOOL isInLowPowerMode;
@property (nonatomic, assign) BOOL isInIdleWallpaperMode;
@property (nonatomic, assign) BOOL pauseDebounceScheduled;
@property (nonatomic, assign) NSUInteger pauseDebounceToken;
@property (nonatomic, strong) NSArray<UIColor *> *lastLockColors;
@property (nonatomic, strong) NSArray<UIColor *> *lastHomeColors;
@property (nonatomic, assign) BOOL desiredLockVisible;
@property (nonatomic, assign) BOOL desiredHomeVisible;

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

        _homeWallpaperHostView = [[UIView alloc] initWithFrame:CGRectZero];
        _homeWallpaperHostView.backgroundColor = [UIColor clearColor];
        _homeWallpaperHostView.userInteractionEnabled = NO;
        _homeWallpaperHostView.clipsToBounds = YES;
        _homeWallpaperHostView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        _homeDynamicWallpaperView = [[LRDynamicWallpaperView alloc] initWithFrame:CGRectZero];
        _homeDynamicWallpaperView.hidden = YES;
        _homeDynamicWallpaperView.alpha = 0.0;
        _homeDynamicWallpaperView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [_homeWallpaperHostView addSubview:_homeDynamicWallpaperView];

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
        _isHomeScreenVisible = NO;
        _isForegroundAppActive = [self queryHasForegroundApp];
        _isInIdleWallpaperMode = YES;
        _pauseDebounceScheduled = NO;
        _pauseDebounceToken = 0;

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

- (BOOL)queryHasForegroundApp {
    UIApplication *app = [UIApplication sharedApplication];
    if (app && [app respondsToSelector:@selector(_accessibilityFrontMostApplication)]) {
        id frontApp = [(SpringBoard *)app _accessibilityFrontMostApplication];
        return (frontApp != nil);
    }
    return NO;
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

- (void)attachToPosterHomeViewController:(UIViewController *)vc {
    if (!vc) return;
    self.posterHomeVC = vc;
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
    if (!visible) {
        BOOL hasFrontApp = [self queryHasForegroundApp];
        self.isForegroundAppActive = hasFrontApp;
        self.isHomeScreenVisible = !hasFrontApp;
    }
    [self syncMountHierarchyAndPowerState];
    if (visible && (changed || self.isScreenOn)) {
        [self.lyricsView reloadData];
    }
}

- (void)setHomeScreenVisible:(BOOL)visible {
    self.isHomeScreenVisible = visible;
    if (visible) {
        self.isForegroundAppActive = NO;
    }
    [self syncMountHierarchyAndPowerState];
}

- (void)frontDisplayDidChange:(id)newDisplay {
    Class sbAppClass = NSClassFromString(@"SBApplication");
    if (newDisplay && sbAppClass && [newDisplay isKindOfClass:sbAppClass]) {
        self.isForegroundAppActive = YES;
        self.isHomeScreenVisible = NO;
    } else {
        self.isForegroundAppActive = NO;
        if (!self.isLockScreenVisible) {
            self.isHomeScreenVisible = YES;
        }
    }
    [self syncMountHierarchyAndPowerState];
}

- (void)setScreenOn:(BOOL)screenOn {
    BOOL wasOn = self.isScreenOn;
    self.isScreenOn = screenOn;
    if (screenOn && !wasOn && !self.isLockScreenVisible) {
        BOOL hasFrontApp = [self queryHasForegroundApp];
        self.isForegroundAppActive = hasFrontApp;
        self.isHomeScreenVisible = !hasFrontApp;
    }
    [self syncMountHierarchyAndPowerState];
    if (screenOn && !wasOn) {
        LRLyricsManager *mgr = [LRLyricsManager sharedManager];
        LRPreferences *prefs = [LRPreferences sharedPreferences];
        if (self.isLockScreenVisible) {
            [mgr fetchLatestNowPlayingInfo];
            [self.lyricsView reloadData];
        } else if (self.isHomeScreenVisible) {
            [mgr fetchLatestNowPlayingInfo];
        }
        if (self.isInIdleWallpaperMode && prefs.enabled && prefs.enableDynamicWallpaper && prefs.idleRandomWallpaper) {
            [mgr refreshRandomIdleArtwork];
        }
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

- (void)applyWallpaperStateToView:(LRDynamicWallpaperView *)view
                             isHome:(BOOL)isHome
                         shouldShow:(BOOL)shouldShow
                      shouldAnimate:(BOOL)shouldAnimate
                        sizeChanged:(BOOL)sizeChanged
                      immediateHide:(BOOL)immediateHide
                            palette:(NSArray<UIColor *> *)targetPalette
                            opacity:(CGFloat)targetOpacity
                                fps:(NSInteger)fps
                              speed:(CGFloat)speed {
    view.renderScale = 0.25;
    view.frameLimit = fps;
    view.speed = speed;

    if (isHome) {
        self.desiredHomeVisible = shouldShow;
    } else {
        self.desiredLockVisible = shouldShow;
    }

    if (shouldShow) {
        NSArray<UIColor *> *lastColors = isHome ? self.lastHomeColors : self.lastLockColors;
        BOOL wasHidden = view.hidden;

        if (!lastColors || lastColors != targetPalette) {
            if (isHome) {
                self.lastHomeColors = targetPalette;
            } else {
                self.lastLockColors = targetPalette;
            }
            [view setColors:targetPalette animated:(!wasHidden && shouldAnimate)];
        }

        if (wasHidden) {
            view.alpha = 0.0;
            view.hidden = NO;
            [view setNeedsLayout];
            [view layoutIfNeeded];
            [view renderSingleFrame];
        }

        view.animating = shouldAnimate;
        if (!shouldAnimate || sizeChanged) {
            if (sizeChanged && !wasHidden) {
                [view setNeedsLayout];
                [view layoutIfNeeded];
            }
            [view renderSingleFrame];
        }

        if (fabs(view.alpha - targetOpacity) > 0.01) {
            [UIView animateWithDuration:0.30
                                  delay:0.0
                                options:(UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction)
                             animations:^{
                                 view.alpha = targetOpacity;
                             }
                             completion:nil];
        }
    } else {
        view.animating = NO;

        if (immediateHide) {
            [view.layer removeAllAnimations];
            view.alpha = 0.0;
            view.hidden = YES;
        } else if (!view.hidden) {
            [UIView animateWithDuration:0.30
                                  delay:0.0
                                options:(UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction)
                             animations:^{
                                 view.alpha = 0.0;
                             }
                             completion:^(BOOL finished) {
                                 BOOL stillWanted = isHome ? self.desiredHomeVisible : self.desiredLockVisible;
                                 if (!stillWanted) {
                                     view.hidden = YES;
                                 }
                             }];
        }
    }
}

- (void)syncMountHierarchyAndPowerState {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self syncMountHierarchyAndPowerState];
        });
        return;
    }

    LRPreferences *prefs = [LRPreferences sharedPreferences];
    LRLyricsManager *mgr = [LRLyricsManager sharedManager];

    // 1. Lock Wallpaper Host Mounting (prefer PosterLockVC on iOS 16-18, fallback to PBUIWallpaperVC)
    UIViewController *targetLockVC = self.posterLockVC ?: self.fallbackWallpaperVC;
    UIView *lockTargetView = nil;
    BOOL lockSizeChanged = NO;
    if (targetLockVC && targetLockVC.isViewLoaded && targetLockVC.view) {
        lockTargetView = targetLockVC.view;
        if (self.wallpaperHostView.superview != lockTargetView) {
            [self.wallpaperHostView removeFromSuperview];
            self.wallpaperHostView.frame = lockTargetView.bounds;
            [lockTargetView addSubview:self.wallpaperHostView];
            lockSizeChanged = YES;
        } else if (!CGRectEqualToRect(self.wallpaperHostView.frame, lockTargetView.bounds)) {
            self.wallpaperHostView.frame = lockTargetView.bounds;
            lockSizeChanged = YES;
        }
        [lockTargetView bringSubviewToFront:self.wallpaperHostView];

        if (!CGRectEqualToRect(self.dynamicWallpaperView.frame, self.wallpaperHostView.bounds)) {
            self.dynamicWallpaperView.frame = self.wallpaperHostView.bounds;
            lockSizeChanged = YES;
        }
    }

    // 2. Home Wallpaper Host Mounting (PBUIPosterHomeViewController.view ONLY; never mounts lyricsView)
    UIView *homeTargetView = nil;
    BOOL homeSizeChanged = NO;
    if (self.posterHomeVC && self.posterHomeVC.isViewLoaded && self.posterHomeVC.view) {
        homeTargetView = self.posterHomeVC.view;
        if (self.homeWallpaperHostView.superview != homeTargetView) {
            [self.homeWallpaperHostView removeFromSuperview];
            self.homeWallpaperHostView.frame = homeTargetView.bounds;
            [homeTargetView addSubview:self.homeWallpaperHostView];
            homeSizeChanged = YES;
        } else if (!CGRectEqualToRect(self.homeWallpaperHostView.frame, homeTargetView.bounds)) {
            self.homeWallpaperHostView.frame = homeTargetView.bounds;
            homeSizeChanged = YES;
        }
        [homeTargetView bringSubviewToFront:self.homeWallpaperHostView];

        if (!CGRectEqualToRect(self.homeDynamicWallpaperView.frame, self.homeWallpaperHostView.bounds)) {
            self.homeDynamicWallpaperView.frame = self.homeWallpaperHostView.bounds;
            homeSizeChanged = YES;
        }
    }

    // 3. Playback vs Idle Mode State (with 0.8s debounce when pausing to avoid flicker during skips)
    BOOL hasActiveMusic = mgr.isCurrentAppAllowed && (mgr.currentTitle.length > 0);
    BOOL rawMusicPlaying = mgr.isPlaying && hasActiveMusic;

    if (rawMusicPlaying) {
        self.pauseDebounceToken++;
        self.pauseDebounceScheduled = NO;
        self.isInIdleWallpaperMode = NO;
    } else if (!hasActiveMusic) {
        self.pauseDebounceToken++;
        self.pauseDebounceScheduled = NO;
        if (!self.isInIdleWallpaperMode) {
            self.isInIdleWallpaperMode = YES;
            [mgr refreshRandomIdleArtwork];
        }
    } else {
        if (!self.isInIdleWallpaperMode && !self.pauseDebounceScheduled) {
            self.pauseDebounceScheduled = YES;
            NSUInteger token = ++self.pauseDebounceToken;
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf || strongSelf.pauseDebounceToken != token) return;
                strongSelf.pauseDebounceScheduled = NO;
                LRLyricsManager *m = [LRLyricsManager sharedManager];
                BOOL stillPaused = !(m.isPlaying && m.isCurrentAppAllowed && m.currentTitle.length > 0);
                if (stillPaused && !strongSelf.isInIdleWallpaperMode) {
                    strongSelf.isInIdleWallpaperMode = YES;
                    [m refreshRandomIdleArtwork];
                    [strongSelf syncMountHierarchyAndPowerState];
                    [strongSelf.lyricsView reloadData];
                }
            });
        }
    }

    BOOL showIdleRandomArt = self.isInIdleWallpaperMode && prefs.idleRandomWallpaper;
    BOOL showActiveMusicArt = !showIdleRandomArt && hasActiveMusic;

    // 4. Lyrics View Mounting (Lock Screen ONLY when playing active music; strictly hidden when idle or unlocked)
    BOOL lockMounted = (self.wallpaperHostView.superview != nil);
    BOOL homeMounted = (self.homeWallpaperHostView.superview != nil);
    if (prefs.lyricsInWallpaperLayer && lockMounted) {
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

    BOOL lyricsActive = self.isLockScreenVisible && self.isScreenOn && !showIdleRandomArt && hasActiveMusic;
    BOOL lyricsBecameActive = (lyricsActive && !self.lyricsView.isLockscreenActive);
    if (self.lyricsView.isLockscreenActive != lyricsActive) {
        self.lyricsView.isLockscreenActive = lyricsActive;
    }
    if (!lyricsActive) {
        [self.lyricsView stopSyncTimer];
        [self.lyricsView.layer removeAllAnimations];
        self.lyricsView.hidden = YES;
        self.lyricsView.alpha = 0.0;
    } else if (lyricsBecameActive) {
        [self.lyricsView reloadData];
    }

    // 5. Dual Lock vs Home Dynamic Wallpaper State Machine (zero double-blending / zero simultaneous animation)
    BOOL baseDynamic = prefs.enabled && prefs.enableDynamicWallpaper && self.isScreenOn && (showActiveMusicArt || showIdleRandomArt);
    BOOL freezeForLowPower = prefs.dynamicWallpaperPowerSaver && self.isInLowPowerMode;
    BOOL shouldFlow = showActiveMusicArt ? mgr.isPlaying : showIdleRandomArt;
    BOOL canAnimate = shouldFlow && !freezeForLowPower && (prefs.dynamicWallpaperSpeed > 0.01);

    BOOL homeVis = homeMounted && LRIsViewVisiblyAttached(homeTargetView);
    BOOL lockVis = lockMounted && LRIsViewVisiblyAttached(lockTargetView);
    BOOL homeViewIsTop = homeVis && (!lockVis || !LRIsViewAboveView(lockTargetView, homeTargetView));

    BOOL shouldShowLock = NO;
    BOOL shouldAnimateLock = NO;
    BOOL shouldShowHome = NO;
    BOOL shouldAnimateHome = NO;

    if (self.isLockScreenVisible) {
        shouldShowLock = baseDynamic && lockMounted;
        shouldAnimateLock = shouldShowLock && canAnimate;
        shouldShowHome = NO;
        shouldAnimateHome = NO;
    } else if (prefs.enableHomeScreenWallpaper && baseDynamic) {
        if (homeViewIsTop) {
            shouldShowHome = YES;
            // Freeze GPU animation while inside an app, but keep static frame ready for zero-flash swipe home
            shouldAnimateHome = self.isHomeScreenVisible && canAnimate;
            shouldShowLock = NO;
            shouldAnimateLock = NO;
        } else if (lockMounted) {
            // Paired Lock+Home wallpaper or legacy PBUIWallpaperViewController shares lockTargetView; lyrics stay strictly hidden
            shouldShowLock = YES;
            shouldAnimateLock = self.isHomeScreenVisible && canAnimate;
            shouldShowHome = NO;
            shouldAnimateHome = NO;
        }
    }

    NSArray<UIColor *> *targetPalette = showActiveMusicArt
        ? (mgr.currentArtworkColors ?: [LRColorExtractor defaultPalette])
        : (mgr.idleArtworkColors ?: [LRColorExtractor defaultPalette]);
    BOOL immediateHideLock = !self.isScreenOn || (!self.isLockScreenVisible && homeViewIsTop);
    BOOL immediateHideHome = !self.isScreenOn || self.isLockScreenVisible;

    [self applyWallpaperStateToView:self.dynamicWallpaperView
                             isHome:NO
                         shouldShow:shouldShowLock
                      shouldAnimate:shouldAnimateLock
                        sizeChanged:lockSizeChanged
                      immediateHide:immediateHideLock
                            palette:targetPalette
                            opacity:prefs.dynamicWallpaperOpacity
                                fps:prefs.dynamicWallpaperFPS
                              speed:prefs.dynamicWallpaperSpeed];

    [self applyWallpaperStateToView:self.homeDynamicWallpaperView
                             isHome:YES
                         shouldShow:shouldShowHome
                      shouldAnimate:shouldAnimateHome
                        sizeChanged:homeSizeChanged
                      immediateHide:immediateHideHome
                            palette:targetPalette
                            opacity:prefs.dynamicWallpaperOpacity
                                fps:prefs.dynamicWallpaperFPS
                              speed:prefs.dynamicWallpaperSpeed];
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
        if (!self.isInIdleWallpaperMode && colors.count > 0) {
            self.lastLockColors = colors;
            self.lastHomeColors = colors;

            BOOL animateLock = self.isScreenOn && !self.dynamicWallpaperView.hidden && self.dynamicWallpaperView.animating;
            [self.dynamicWallpaperView setColors:colors animated:animateLock];

            BOOL animateHome = self.isScreenOn && !self.homeDynamicWallpaperView.hidden && self.homeDynamicWallpaperView.animating;
            [self.homeDynamicWallpaperView setColors:colors animated:animateHome];
        }
        [self syncMountHierarchyAndPowerState];
    });
}

- (void)lyricsManagerDidUpdateIdleArtworkColors:(NSArray<UIColor *> *)colors {
    dispatch_async(dispatch_get_main_queue(), ^{
        LRPreferences *prefs = [LRPreferences sharedPreferences];
        if (self.isInIdleWallpaperMode && prefs.idleRandomWallpaper && colors.count > 0) {
            self.lastLockColors = colors;
            self.lastHomeColors = colors;

            BOOL animateLock = self.isScreenOn && !self.dynamicWallpaperView.hidden && self.dynamicWallpaperView.animating;
            [self.dynamicWallpaperView setColors:colors animated:animateLock];

            BOOL animateHome = self.isScreenOn && !self.homeDynamicWallpaperView.hidden && self.homeDynamicWallpaperView.animating;
            [self.homeDynamicWallpaperView setColors:colors animated:animateHome];

            [self syncMountHierarchyAndPowerState];
        }
    });
}

@end
