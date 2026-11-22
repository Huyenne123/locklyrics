#import "LRLyricsView.h"
#import "LRPreferences.h"

@interface LRLyricsView ()

@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UIStackView *stackView;
@property (nonatomic, strong) NSMutableArray<UILabel *> *lineLabels;
@property (nonatomic, strong) NSTimer *syncTimer;
@property (nonatomic, assign) NSInteger lastLineIndex;
@property (nonatomic, strong) UIPanGestureRecognizer *panGesture;
@property (nonatomic, assign) CGPoint dragStartCenter;
@property (nonatomic, assign) NSTimeInterval lastNowPlayingCheckTime;

@end

@implementation LRLyricsView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _lastLineIndex = -999;
        _lineLabels = [NSMutableArray array];
        _isLockscreenActive = NO;

        [self setupUI];
        [self setupGestures];
        [self refreshPreferences];

        [[LRLyricsManager sharedManager] addObserver:self];
    }
    return self;
}

- (void)dealloc {
    [self stopSyncTimer];
    [[LRLyricsManager sharedManager] removeObserver:self];
}

#pragma mark - UI Setup

- (void)setupUI {
    self.backgroundColor = [UIColor clearColor];
    self.layer.masksToBounds = YES;
    self.layer.cornerRadius = 18.0;

    UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    _blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    _blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _blurView.frame = self.bounds;
    _blurView.userInteractionEnabled = NO;
    [self addSubview:_blurView];

    _stackView = [[UIStackView alloc] init];
    _stackView.axis = UILayoutConstraintAxisVertical;
    _stackView.distribution = UIStackViewDistributionFill;
    _stackView.alignment = UIStackViewAlignmentFill;
    _stackView.spacing = 4.0;
    _stackView.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_stackView];

    [NSLayoutConstraint activateConstraints:@[
        [_stackView.topAnchor constraintEqualToAnchor:self.topAnchor constant:8.0],
        [_stackView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-8.0],
        [_stackView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12.0],
        [_stackView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12.0]
    ]];

    [self setupLabels];
}

- (void)setupGestures {
    _panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self addGestureRecognizer:_panGesture];
}

- (CGFloat)fontSizeForText:(NSString *)text isCenterLine:(BOOL)isCenter {
    LRPreferences *prefs = [LRPreferences sharedPreferences];
    CGFloat baseSize = prefs.fontSize;
    if (baseSize < 12.0) baseSize = 20.0;

    if (!prefs.autoFontSize || !text || text.length == 0) {
        return isCenter ? baseSize : MAX(baseSize - 4.0, 12.0);
    }

    NSUInteger len = text.length;
    CGFloat size = baseSize;

    if (isCenter) {
        if (len <= 20) {
            size = baseSize + 3.0;
        } else if (len <= 35) {
            size = baseSize + 1.0;
        } else if (len <= 50) {
            size = baseSize - 1.0;
        } else if (len <= 75) {
            size = baseSize - 3.0;
        } else {
            size = baseSize - 5.0;
        }
        return MAX(14.0, MIN(size, 32.0));
    } else {
        if (len <= 30) {
            size = baseSize - 4.0;
        } else if (len <= 60) {
            size = baseSize - 5.0;
        } else {
            size = baseSize - 6.0;
        }
        return MAX(11.0, MIN(size, 24.0));
    }
}

- (void)setupLabels {
    for (UILabel *label in self.lineLabels) {
        [label removeFromSuperview];
    }
    [self.lineLabels removeAllObjects];

    LRPreferences *prefs = [LRPreferences sharedPreferences];
    NSInteger count = prefs.visibleLinesCount;
    if (count != 1 && count != 3 && count != 5) count = 3;

    NSInteger centerIndex = count / 2;

    UILabel *centerLabel = nil;
    UILabel *firstNonCenterLabel = nil;

    for (NSInteger i = 0; i < count; i++) {
        UILabel *label = [[UILabel alloc] init];
        label.textAlignment = NSTextAlignmentCenter;
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.textColor = [UIColor whiteColor];

        CGFloat initialSize = [self fontSizeForText:@"" isCenterLine:(i == centerIndex)];
        if (i == centerIndex) {
            label.numberOfLines = 2;
            label.adjustsFontSizeToFitWidth = YES;
            label.minimumScaleFactor = 0.60;
            label.lineBreakMode = NSLineBreakByTruncatingTail;
            label.font = [UIFont systemFontOfSize:initialSize weight:UIFontWeightBold];
            label.alpha = 1.0;
            centerLabel = label;
        } else {
            label.numberOfLines = 1;
            label.adjustsFontSizeToFitWidth = YES;
            label.minimumScaleFactor = 0.70;
            label.lineBreakMode = NSLineBreakByTruncatingTail;
            label.font = [UIFont systemFontOfSize:initialSize weight:UIFontWeightMedium];
            label.alpha = (ABS(i - centerIndex) == 1) ? 0.45 : 0.25;
            if (!firstNonCenterLabel) {
                firstNonCenterLabel = label;
            }
        }

        [self.stackView addArrangedSubview:label];
        [self.lineLabels addObject:label];
    }

    if (centerLabel && firstNonCenterLabel) {
        NSLayoutConstraint *cCenter = [centerLabel.heightAnchor constraintEqualToAnchor:firstNonCenterLabel.heightAnchor multiplier:2.0];
        cCenter.priority = (UILayoutPriority)999;
        cCenter.active = YES;

        for (NSInteger i = 0; i < count; i++) {
            if (i != centerIndex && self.lineLabels[i] != firstNonCenterLabel) {
                NSLayoutConstraint *cOther = [self.lineLabels[i].heightAnchor constraintEqualToAnchor:firstNonCenterLabel.heightAnchor];
                cOther.priority = (UILayoutPriority)999;
                cOther.active = YES;
            }
        }
    }
}

- (void)refreshPreferences {
    LRPreferences *prefs = [LRPreferences sharedPreferences];
    [prefs loadPreferences];

    self.blurView.hidden = prefs.enableDynamicWallpaper ? YES : !prefs.enableBackgroundBlur;
    self.blurView.alpha = prefs.backgroundAlpha;

    BOOL canInteract = prefs.enableLiveDrag && !prefs.lockPosition && !prefs.lyricsInWallpaperLayer;
    self.userInteractionEnabled = canInteract;
    self.panGesture.enabled = canInteract;

    [self setupLabels];
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    LRPreferences *prefs = [LRPreferences sharedPreferences];
    if (prefs.lockPosition || !prefs.enableLiveDrag || prefs.lyricsInWallpaperLayer) {
        // Completely pass touches through to views underneath when locked, in wallpaper layer, or dragging disabled
        return nil;
    }
    return [super hitTest:point withEvent:event];
}

#pragma mark - Timer & Sync

- (void)startSyncTimer {
    [self stopSyncTimer];
    if (!self.isLockscreenActive) return;

    __weak typeof(self) weakSelf = self;
    self.syncTimer = [NSTimer timerWithTimeInterval:0.05 repeats:YES block:^(NSTimer * _Nonnull timer) {
        [weakSelf checkAndUpdateCurrentLine];
    }];
    [[NSRunLoop currentRunLoop] addTimer:self.syncTimer forMode:NSRunLoopCommonModes];
}

- (void)stopSyncTimer {
    if (self.syncTimer) {
        [self.syncTimer invalidate];
        self.syncTimer = nil;
    }
}

- (void)checkAndUpdateCurrentLine {
    LRLyricsManager *mgr = [LRLyricsManager sharedManager];

    // Periodic check every 1.0s while lockscreen is active to immediately catch song skips
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - self.lastNowPlayingCheckTime >= 1.0) {
        self.lastNowPlayingCheckTime = now;
        [mgr fetchLatestNowPlayingInfo];
    }

    if (!mgr.currentSong || !mgr.currentSong.hasSyncedLyrics || mgr.currentSong.lines.count == 0) {
        return;
    }

    NSInteger currentIdx = [mgr currentLyricIndex];
    if (currentIdx != self.lastLineIndex) {
        self.lastLineIndex = currentIdx;
        [self renderLinesForCurrentIndex:currentIdx animated:YES];
    }
}

- (void)displayMessage:(NSString *)message {
    NSInteger totalLabels = self.lineLabels.count;
    NSInteger centerIndex = totalLabels / 2;
    for (NSInteger i = 0; i < totalLabels; i++) {
        UILabel *label = self.lineLabels[i];
        if (i == centerIndex) {
            label.text = message;
            label.alpha = 0.75;
            label.font = [UIFont systemFontOfSize:[LRPreferences sharedPreferences].fontSize weight:UIFontWeightBold];
        } else {
            label.text = @" ";
            label.alpha = 0.0;
        }
    }
}

#pragma mark - UI Rendering

- (void)reloadData {
    LRPreferences *prefs = [LRPreferences sharedPreferences];
    if (!prefs.enabled || !self.isLockscreenActive) {
        [self stopSyncTimer];
        [self.layer removeAllAnimations];
        self.hidden = YES;
        self.alpha = 0.0;
        return;
    }

    LRLyricsManager *mgr = [LRLyricsManager sharedManager];

    // While fetching new track lyrics, stay visible and show loading indicator
    if (mgr.isLoading && mgr.currentTitle) {
        [self.layer removeAllAnimations];
        self.hidden = NO;
        self.alpha = 1.0;
        if (self.superview) [self.superview bringSubviewToFront:self];
        [self displayMessage:@"•••"];
        return;
    }

    // Strict: If no song, or no synced lyrics -> hide immediately
    if (!mgr.currentSong || !mgr.currentSong.hasSyncedLyrics || mgr.currentSong.lines.count == 0) {
        [self stopSyncTimer];
        [self.layer removeAllAnimations];
        self.hidden = YES;
        self.alpha = 0.0;
        self.lastLineIndex = -999;
        for (UILabel *label in self.lineLabels) {
            label.text = @" ";
        }
        return;
    }

    // Has synced lyrics! Ensure visible and brought to front
    [self.layer removeAllAnimations];
    self.hidden = NO;
    self.alpha = 1.0;
    if (self.superview) [self.superview bringSubviewToFront:self];

    NSInteger currentIdx = [mgr currentLyricIndex];
    self.lastLineIndex = currentIdx;
    [self renderLinesForCurrentIndex:currentIdx animated:NO];

    if (self.isLockscreenActive && mgr.isPlaying) {
        [self startSyncTimer];
    } else {
        [self stopSyncTimer];
    }
}

- (void)renderLinesForCurrentIndex:(NSInteger)currentIdx animated:(BOOL)animated {
    LRLyricsSong *song = [LRLyricsManager sharedManager].currentSong;
    if (!song || song.lines.count == 0) return;

    NSInteger totalLabels = self.lineLabels.count;
    NSInteger centerIndex = totalLabels / 2;
    LRPreferences *prefs = [LRPreferences sharedPreferences];

    void (^updateText)(void) = ^{
        if (currentIdx < 0) {
            // Intro before first line: show "•••" in center, upcoming line faintly below it
            for (NSInteger i = 0; i < totalLabels; i++) {
                UILabel *label = self.lineLabels[i];
                if (i == centerIndex) {
                    label.text = @"•••";
                    label.alpha = 0.7;
                    label.font = [UIFont systemFontOfSize:prefs.fontSize weight:UIFontWeightBold];
                } else if (i == centerIndex + 1 && song.lines.count > 0) {
                    label.text = song.lines[0].text;
                    label.alpha = 0.35;
                    label.font = [UIFont systemFontOfSize:MAX(prefs.fontSize - 3.0, 11.0) weight:UIFontWeightMedium];
                } else {
                    label.text = @" ";
                    label.alpha = 0.0;
                }
            }
            return;
        }

        for (NSInteger offset = -centerIndex; offset <= centerIndex; offset++) {
            NSInteger labelIdx = centerIndex + offset;
            if (labelIdx < 0 || labelIdx >= totalLabels) continue;

            UILabel *label = self.lineLabels[labelIdx];
            NSInteger targetLineIdx = currentIdx + offset;

            if (targetLineIdx >= 0 && targetLineIdx < (NSInteger)song.lines.count) {
                NSString *text = song.lines[targetLineIdx].text;
                label.text = text;
                BOOL isCenter = (offset == 0);
                CGFloat fSize = [self fontSizeForText:text isCenterLine:isCenter];

                if (isCenter) {
                    label.alpha = 1.0;
                    label.font = [UIFont systemFontOfSize:fSize weight:UIFontWeightBold];
                } else {
                    label.alpha = (ABS(offset) == 1) ? 0.45 : 0.25;
                    label.font = [UIFont systemFontOfSize:fSize weight:UIFontWeightMedium];
                }
            } else {
                label.text = @" ";
                label.alpha = 0.0;
            }
        }
    };

    if (animated) {
        [UIView transitionWithView:self.stackView
                          duration:0.12
                           options:UIViewAnimationOptionTransitionCrossDissolve
                        animations:updateText
                        completion:nil];
    } else {
        updateText();
    }
}

#pragma mark - LRLyricsObserver

- (void)lyricsManagerDidUpdateSong:(LRLyricsSong *)song {
    [self reloadData];
}

- (void)lyricsManagerDidChangePlaybackState:(BOOL)isPlaying {
    if (isPlaying && self.isLockscreenActive) {
        [self startSyncTimer];
    } else {
        [self stopSyncTimer];
    }
    [self reloadData];
}

#pragma mark - Layout & Position

- (void)updateLayoutForParentBounds:(CGRect)parentBounds {
    if (CGRectIsEmpty(parentBounds)) return;

    LRPreferences *prefs = [LRPreferences sharedPreferences];
    CGFloat screenWidth = parentBounds.size.width;
    CGFloat screenHeight = parentBounds.size.height;

    CGFloat margin = 16.0;
    CGFloat width = screenWidth - (margin * 2);
    NSInteger linesCount = prefs.visibleLinesCount;
    CGFloat baseLineHeight = prefs.fontSize + 12.0;
    CGFloat height = (baseLineHeight * (linesCount + 1.2)) + 20.0;

    CGFloat targetCenterY = prefs.customCenterY;
    if (targetCenterY <= 0 || prefs.alignmentPreset != LRLyricsAlignmentPresetCustom) {
        switch (prefs.alignmentPreset) {
            case LRLyricsAlignmentPresetBelowClock:
                targetCenterY = screenHeight * 0.28;
                break;
            case LRLyricsAlignmentPresetCenter:
                targetCenterY = screenHeight * 0.50;
                break;
            case LRLyricsAlignmentPresetAboveMediaControls:
                targetCenterY = screenHeight * 0.65;
                break;
            case LRLyricsAlignmentPresetCustom:
            default:
                targetCenterY = (targetCenterY > 0) ? targetCenterY : (screenHeight * 0.30);
                break;
        }
    }

    CGFloat targetCenterX = (prefs.customCenterX > 0) ? prefs.customCenterX : (screenWidth / 2.0);
    targetCenterY = MAX(height / 2.0 + 40.0, MIN(targetCenterY, screenHeight - (height / 2.0) - 40.0));
    self.bounds = CGRectMake(0, 0, width, height);
    self.center = CGPointMake(targetCenterX, targetCenterY);
}

#pragma mark - Drag Gesture

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    LRPreferences *prefs = [LRPreferences sharedPreferences];
    if (prefs.lockPosition || !prefs.enableLiveDrag) return;

    UIView *superview = self.superview;
    if (!superview) return;

    CGPoint translation = [gesture translationInView:superview];

    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
            self.dragStartCenter = self.center;
            break;

        case UIGestureRecognizerStateChanged: {
            CGFloat newY = self.dragStartCenter.y + translation.y;
            CGFloat halfH = self.bounds.size.height / 2.0;
            CGFloat minY = halfH + 40.0;
            CGFloat maxY = superview.bounds.size.height - halfH - 40.0;
            newY = MAX(minY, MIN(newY, maxY));
            self.center = CGPointMake(self.dragStartCenter.x, newY);
            break;
        }

        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled: {
            prefs.alignmentPreset = LRLyricsAlignmentPresetCustom;
            [prefs saveCustomPosition:self.center];
            break;
        }

        default:
            break;
    }
}

@end
