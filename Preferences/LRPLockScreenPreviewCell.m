#import "LRPLockScreenPreviewCell.h"
#import <QuartzCore/QuartzCore.h>
#import <notify.h>

NSString * const LRPPreviewNeedsRefreshNotification = @"LRPPreviewNeedsRefreshNotification";
NSString * const LRPPositionChangedBySliderNotification = @"LRPPositionChangedBySliderNotification";

static NSString * const kLRPPrefsDomain = @"com.locklyrics.preferences";
static const char * const kLRPPrefsChangedNotification = "com.locklyrics.preferences.changed";

@interface LRPLockScreenPreviewCell ()

@property (nonatomic, assign) CGFloat deviceScreenWidth;
@property (nonatomic, assign) CGFloat deviceScreenHeight;
@property (nonatomic, assign) CGFloat previewWidth;
@property (nonatomic, assign) CGFloat previewHeight;
@property (nonatomic, assign) CGFloat previewScale;

@property (nonatomic, assign) NSInteger visibleLinesCount;
@property (nonatomic, assign) CGFloat fontSize;
@property (nonatomic, assign) BOOL autoFontSize;
@property (nonatomic, assign) NSInteger alignmentPreset;
@property (nonatomic, assign) CGFloat currentCenterY;
@property (nonatomic, assign) CGFloat minY;
@property (nonatomic, assign) CGFloat maxY;

@property (nonatomic, strong) UIView *bezelView;
@property (nonatomic, strong) UIView *screenView;
@property (nonatomic, strong) CAGradientLayer *wallpaperGradient;
@property (nonatomic, strong) UIView *centerGuideLine;

@property (nonatomic, strong) UIView *lyricsBoxView;
@property (nonatomic, strong) UIStackView *lyricsStackView;
@property (nonatomic, strong) NSMutableArray<UILabel *> *lyricsLabels;

@property (nonatomic, strong) UILabel *titleLabelCustom;
@property (nonatomic, strong) UILabel *valueLabel;
@property (nonatomic, strong) UISlider *ySlider;
@property (nonatomic, strong) UISelectionFeedbackGenerator *hapticGenerator;
@property (nonatomic, assign) BOOL wasNearCenter;
@property (nonatomic, assign) BOOL isDraggingSlider;

@end

@implementation LRPLockScreenPreviewCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.textLabel.hidden = YES;
        self.detailTextLabel.hidden = YES;
        _lyricsLabels = [NSMutableArray array];
        _hapticGenerator = [[UISelectionFeedbackGenerator alloc] init];

        [self computeScreenMetrics];
        [self buildUI];
        [self refreshFromPreferencesAnimated:NO];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleRefreshNotification:)
                                                     name:LRPPreviewNeedsRefreshNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)handleRefreshNotification:(NSNotification *)note {
    BOOL animated = [note.userInfo[@"animated"] boolValue];
    [self refreshFromPreferencesAnimated:animated];
}

- (void)computeScreenMetrics {
    CGRect bounds = [UIScreen mainScreen].bounds;
    CGFloat w = MIN(bounds.size.width, bounds.size.height);
    CGFloat h = MAX(bounds.size.width, bounds.size.height);
    if (w <= 0 || h <= 0) {
        w = 390.0;
        h = 844.0;
    }
    self.deviceScreenWidth = w;
    self.deviceScreenHeight = h;

    self.previewHeight = 330.0;
    self.previewScale = self.previewHeight / self.deviceScreenHeight;
    self.previewWidth = round(self.deviceScreenWidth * self.previewScale);
}

#pragma mark - UI Construction

- (void)buildUI {
    UIView *container = self.contentView;

    // 1. Phone Bezel
    self.bezelView = [[UIView alloc] init];
    self.bezelView.translatesAutoresizingMaskIntoConstraints = NO;
    self.bezelView.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1.0];
    self.bezelView.layer.cornerRadius = 26.0;
    self.bezelView.layer.borderWidth = 1.5;
    self.bezelView.layer.borderColor = [UIColor colorWithWhite:0.35 alpha:0.75].CGColor;
    self.bezelView.layer.shadowColor = [UIColor blackColor].CGColor;
    self.bezelView.layer.shadowOpacity = 0.25;
    self.bezelView.layer.shadowRadius = 10.0;
    self.bezelView.layer.shadowOffset = CGSizeMake(0, 4);
    [container addSubview:self.bezelView];

    // 2. Inner Screen
    self.screenView = [[UIView alloc] init];
    self.screenView.translatesAutoresizingMaskIntoConstraints = NO;
    self.screenView.layer.cornerRadius = 23.0;
    self.screenView.clipsToBounds = YES;
    [self.bezelView addSubview:self.screenView];

    // Tap anywhere on the preview screen to jump lyrics to that Y position
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handlePreviewTap:)];
    [self.screenView addGestureRecognizer:tap];

    // Wallpaper gradient
    self.wallpaperGradient = [CAGradientLayer layer];
    self.wallpaperGradient.colors = @[
        (id)[UIColor colorWithRed:0.06 green:0.17 blue:0.22 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.06 green:0.27 blue:0.29 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.03 green:0.12 blue:0.16 alpha:1.0].CGColor
    ];
    self.wallpaperGradient.locations = @[@0.0, @0.55, @1.0];
    self.wallpaperGradient.startPoint = CGPointMake(0.2, 0.0);
    self.wallpaperGradient.endPoint = CGPointMake(0.8, 1.0);
    [self.screenView.layer addSublayer:self.wallpaperGradient];

    // Build mock Lock Screen elements
    [self buildMockLockScreenElements];

    // Center snap guide line (visible briefly when sliding near 50%)
    self.centerGuideLine = [[UIView alloc] init];
    self.centerGuideLine.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.45];
    self.centerGuideLine.alpha = 0.0;
    self.centerGuideLine.userInteractionEnabled = NO;
    [self.screenView addSubview:self.centerGuideLine];

    // 3. Lyrics Preview Box
    self.lyricsBoxView = [[UIView alloc] init];
    self.lyricsBoxView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
    self.lyricsBoxView.layer.cornerRadius = 8.0;
    self.lyricsBoxView.layer.borderWidth = 1.0;
    self.lyricsBoxView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.25].CGColor;
    self.lyricsBoxView.userInteractionEnabled = NO;
    [self.screenView addSubview:self.lyricsBoxView];

    self.lyricsStackView = [[UIStackView alloc] init];
    self.lyricsStackView.axis = UILayoutConstraintAxisVertical;
    self.lyricsStackView.alignment = UIStackViewAlignmentFill;
    self.lyricsStackView.distribution = UIStackViewDistributionFill;
    self.lyricsStackView.spacing = 1.0;
    self.lyricsStackView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.lyricsBoxView addSubview:self.lyricsStackView];

    [NSLayoutConstraint activateConstraints:@[
        [self.lyricsStackView.topAnchor constraintEqualToAnchor:self.lyricsBoxView.topAnchor constant:2.0],
        [self.lyricsStackView.bottomAnchor constraintEqualToAnchor:self.lyricsBoxView.bottomAnchor constant:-2.0],
        [self.lyricsStackView.leadingAnchor constraintEqualToAnchor:self.lyricsBoxView.leadingAnchor constant:4.0],
        [self.lyricsStackView.trailingAnchor constraintEqualToAnchor:self.lyricsBoxView.trailingAnchor constant:-4.0]
    ]];

    // 4. Slider Header Row ("Y Position" + live readout)
    self.titleLabelCustom = [[UILabel alloc] init];
    self.titleLabelCustom.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabelCustom.text = @"Y Position";
    self.titleLabelCustom.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    self.titleLabelCustom.textColor = [UIColor labelColor];
    [container addSubview:self.titleLabelCustom];

    self.valueLabel = [[UILabel alloc] init];
    self.valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:13.0 weight:UIFontWeightMedium];
    self.valueLabel.textColor = [UIColor secondaryLabelColor];
    self.valueLabel.textAlignment = NSTextAlignmentRight;
    [container addSubview:self.valueLabel];

    // 5. Y Position Slider
    self.ySlider = [[UISlider alloc] init];
    self.ySlider.translatesAutoresizingMaskIntoConstraints = NO;
    self.ySlider.continuous = YES;
    UIImageSymbolConfiguration *symConfig = [UIImageSymbolConfiguration configurationWithPointSize:13.0 weight:UIImageSymbolWeightMedium];
    self.ySlider.minimumValueImage = [[UIImage systemImageNamed:@"arrow.up.to.line" withConfiguration:symConfig] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    self.ySlider.maximumValueImage = [[UIImage systemImageNamed:@"arrow.down.to.line" withConfiguration:symConfig] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];

    [self.ySlider addTarget:self action:@selector(sliderTouchDown:) forControlEvents:UIControlEventTouchDown];
    [self.ySlider addTarget:self action:@selector(sliderValueChanged:) forControlEvents:UIControlEventValueChanged];
    [self.ySlider addTarget:self action:@selector(sliderTouchEnded:) forControlEvents:(UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel)];
    [container addSubview:self.ySlider];

    NSLayoutConstraint *sliderBottom = [self.ySlider.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-14.0];
    sliderBottom.priority = (UILayoutPriority)999;

    // Layout Constraints
    CGFloat bezelPad = 3.5;
    [NSLayoutConstraint activateConstraints:@[
        [self.bezelView.topAnchor constraintEqualToAnchor:container.topAnchor constant:16.0],
        [self.bezelView.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [self.bezelView.widthAnchor constraintEqualToConstant:self.previewWidth + bezelPad * 2.0],
        [self.bezelView.heightAnchor constraintEqualToConstant:self.previewHeight + bezelPad * 2.0],

        [self.screenView.topAnchor constraintEqualToAnchor:self.bezelView.topAnchor constant:bezelPad],
        [self.screenView.bottomAnchor constraintEqualToAnchor:self.bezelView.bottomAnchor constant:-bezelPad],
        [self.screenView.leadingAnchor constraintEqualToAnchor:self.bezelView.leadingAnchor constant:bezelPad],
        [self.screenView.trailingAnchor constraintEqualToAnchor:self.bezelView.trailingAnchor constant:-bezelPad],

        [self.titleLabelCustom.topAnchor constraintEqualToAnchor:self.bezelView.bottomAnchor constant:14.0],
        [self.titleLabelCustom.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:18.0],

        [self.valueLabel.centerYAnchor constraintEqualToAnchor:self.titleLabelCustom.centerYAnchor],
        [self.valueLabel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-18.0],
        [self.valueLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.titleLabelCustom.trailingAnchor constant:8.0],

        [self.ySlider.topAnchor constraintEqualToAnchor:self.titleLabelCustom.bottomAnchor constant:6.0],
        [self.ySlider.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16.0],
        [self.ySlider.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16.0],
        sliderBottom
    ]];
}

- (void)buildMockLockScreenElements {
    CGFloat w = self.previewWidth;
    CGFloat h = self.previewHeight;

    // Dynamic Island / Notch pill
    UIView *notch = [[UIView alloc] initWithFrame:CGRectMake((w - 42.0) / 2.0, 6.0, 42.0, 11.0)];
    notch.backgroundColor = [UIColor blackColor];
    notch.layer.cornerRadius = 5.5;
    notch.userInteractionEnabled = NO;
    [self.screenView addSubview:notch];

    // Mini status icons (top right battery pill)
    UIView *battery = [[UIView alloc] initWithFrame:CGRectMake(w - 22.0, 9.0, 11.0, 5.5)];
    battery.layer.cornerRadius = 1.5;
    battery.layer.borderWidth = 0.7;
    battery.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.7].CGColor;
    battery.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    battery.userInteractionEnabled = NO;
    [self.screenView addSubview:battery];

    // Date label
    NSDateFormatter *dateFmt = [[NSDateFormatter alloc] init];
    dateFmt.dateFormat = @"EEEE, MMM d";
    UILabel *dateLabel = [[UILabel alloc] initWithFrame:CGRectMake(6.0, h * 0.10, w - 12.0, 11.0)];
    dateLabel.text = [dateFmt stringFromDate:[NSDate date]];
    dateLabel.textAlignment = NSTextAlignmentCenter;
    dateLabel.font = [UIFont systemFontOfSize:7.5 weight:UIFontWeightMedium];
    dateLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.82];
    dateLabel.userInteractionEnabled = NO;
    [self.screenView addSubview:dateLabel];

    // Clock label
    NSDateFormatter *timeFmt = [[NSDateFormatter alloc] init];
    timeFmt.dateFormat = @"HH:mm";
    UILabel *clockLabel = [[UILabel alloc] initWithFrame:CGRectMake(6.0, h * 0.132, w - 12.0, 38.0)];
    clockLabel.text = [timeFmt stringFromDate:[NSDate date]];
    clockLabel.textAlignment = NSTextAlignmentCenter;
    UIFontDescriptor *desc = [[UIFont systemFontOfSize:32.0 weight:UIFontWeightBold] fontDescriptor];
    UIFontDescriptor *roundedDesc = [desc fontDescriptorWithDesign:UIFontDescriptorSystemDesignRounded];
    clockLabel.font = roundedDesc ? [UIFont fontWithDescriptor:roundedDesc size:32.0] : [UIFont systemFontOfSize:32.0 weight:UIFontWeightBold];
    clockLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.88];
    clockLabel.userInteractionEnabled = NO;
    [self.screenView addSubview:clockLabel];

    // Media Player Card (matches typical iOS 16-18 Lock Screen Now Playing card at ~64%-81% height)
    CGFloat cardMargin = 8.0;
    CGFloat cardW = w - (cardMargin * 2.0);
    CGFloat cardH = h * 0.175;
    CGFloat cardY = h * 0.64;
    UIView *mediaCard = [[UIView alloc] initWithFrame:CGRectMake(cardMargin, cardY, cardW, cardH)];
    mediaCard.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    mediaCard.layer.cornerRadius = 11.0;
    mediaCard.layer.borderWidth = 0.5;
    mediaCard.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.16].CGColor;
    mediaCard.userInteractionEnabled = NO;
    [self.screenView addSubview:mediaCard];

    // Mini artwork square
    UIView *artwork = [[UIView alloc] initWithFrame:CGRectMake(7.0, 7.0, 19.0, 19.0)];
    artwork.backgroundColor = [UIColor colorWithRed:0.35 green:0.55 blue:0.75 alpha:0.85];
    artwork.layer.cornerRadius = 4.0;
    [mediaCard addSubview:artwork];

    // Mini song title & artist bars
    UIView *titleBar = [[UIView alloc] initWithFrame:CGRectMake(31.0, 10.0, cardW * 0.45, 4.0)];
    titleBar.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.75];
    titleBar.layer.cornerRadius = 2.0;
    [mediaCard addSubview:titleBar];

    UIView *artistBar = [[UIView alloc] initWithFrame:CGRectMake(31.0, 17.5, cardW * 0.30, 3.0)];
    artistBar.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.40];
    artistBar.layer.cornerRadius = 1.5;
    [mediaCard addSubview:artistBar];

    // Mini progress bar
    CGFloat progY = cardH * 0.55;
    UIView *progBg = [[UIView alloc] initWithFrame:CGRectMake(8.0, progY, cardW - 16.0, 2.5)];
    progBg.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.20];
    progBg.layer.cornerRadius = 1.25;
    [mediaCard addSubview:progBg];

    UIView *progFill = [[UIView alloc] initWithFrame:CGRectMake(0, 0, (cardW - 16.0) * 0.42, 2.5)];
    progFill.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.75];
    progFill.layer.cornerRadius = 1.25;
    [progBg addSubview:progFill];

    // Mini playback controls
    UIImageSymbolConfiguration *ctrlCfg = [UIImageSymbolConfiguration configurationWithPointSize:8.5 weight:UIImageSymbolWeightBold];
    NSArray<NSString *> *icons = @[@"backward.fill", @"play.fill", @"forward.fill"];
    CGFloat ctrlY = cardH * 0.72;
    CGFloat spacing = cardW / 4.0;
    for (NSInteger i = 0; i < 3; i++) {
        UIImageView *iv = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:icons[i] withConfiguration:ctrlCfg]];
        iv.tintColor = [UIColor colorWithWhite:1.0 alpha:0.85];
        iv.contentMode = UIViewContentModeScaleAspectFit;
        iv.frame = CGRectMake(spacing * (i + 1) - 6.0, ctrlY, 12.0, 10.0);
        [mediaCard addSubview:iv];
    }

    // Bottom Flashlight & Camera circles
    CGFloat btnSize = 18.0;
    CGFloat btnY = h - 34.0;
    UIImageSymbolConfiguration *qaCfg = [UIImageSymbolConfiguration configurationWithPointSize:7.5 weight:UIImageSymbolWeightMedium];

    UIView *flashBtn = [[UIView alloc] initWithFrame:CGRectMake(18.0, btnY, btnSize, btnSize)];
    flashBtn.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.35];
    flashBtn.layer.cornerRadius = btnSize / 2.0;
    flashBtn.userInteractionEnabled = NO;
    UIImageView *flashIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"flashlight.off.fill" withConfiguration:qaCfg]];
    flashIcon.tintColor = [UIColor colorWithWhite:1.0 alpha:0.85];
    flashIcon.contentMode = UIViewContentModeCenter;
    flashIcon.frame = flashBtn.bounds;
    [flashBtn addSubview:flashIcon];
    [self.screenView addSubview:flashBtn];

    UIView *camBtn = [[UIView alloc] initWithFrame:CGRectMake(w - 18.0 - btnSize, btnY, btnSize, btnSize)];
    camBtn.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.35];
    camBtn.layer.cornerRadius = btnSize / 2.0;
    camBtn.userInteractionEnabled = NO;
    UIImageView *camIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"camera.fill" withConfiguration:qaCfg]];
    camIcon.tintColor = [UIColor colorWithWhite:1.0 alpha:0.85];
    camIcon.contentMode = UIViewContentModeCenter;
    camIcon.frame = camBtn.bounds;
    [camBtn addSubview:camIcon];
    [self.screenView addSubview:camBtn];

    // Home indicator bar
    CGFloat homeW = w * 0.36;
    UIView *homeBar = [[UIView alloc] initWithFrame:CGRectMake((w - homeW) / 2.0, h - 7.0, homeW, 2.5)];
    homeBar.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.75];
    homeBar.layer.cornerRadius = 1.25;
    homeBar.userInteractionEnabled = NO;
    [self.screenView addSubview:homeBar];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.wallpaperGradient.frame = self.screenView.bounds;
    self.centerGuideLine.frame = CGRectMake(0, self.previewHeight * 0.50, self.previewWidth, 0.75);
    [self updateLyricsBoxFrameAnimated:NO];
}

#pragma mark - Preferences & Preview Sync

- (void)refreshFromPreferencesAnimated:(BOOL)animated {
    CFStringRef domain = (__bridge CFStringRef)kLRPPrefsDomain;
    CFPreferencesAppSynchronize(domain);

    // Visible lines count (default 3)
    NSInteger linesCount = 3;
    CFPropertyListRef linesVal = CFPreferencesCopyAppValue((__bridge CFStringRef)@"visibleLinesCount", domain);
    if (linesVal && CFGetTypeID(linesVal) == CFNumberGetTypeID()) {
        linesCount = [(__bridge NSNumber *)linesVal integerValue];
        CFRelease(linesVal);
    } else if (linesVal) {
        CFRelease(linesVal);
    }
    if (linesCount != 1 && linesCount != 3 && linesCount != 5) linesCount = 3;
    self.visibleLinesCount = linesCount;

    // Font size (default 20.0)
    CGFloat fSize = 20.0;
    CFPropertyListRef fontVal = CFPreferencesCopyAppValue((__bridge CFStringRef)@"fontSize", domain);
    if (fontVal && CFGetTypeID(fontVal) == CFNumberGetTypeID()) {
        fSize = [(__bridge NSNumber *)fontVal doubleValue];
        CFRelease(fontVal);
    } else if (fontVal) {
        CFRelease(fontVal);
    }
    if (fSize < 12.0) fSize = 20.0;
    self.fontSize = fSize;

    // Alignment preset (default 0 = Custom)
    NSInteger preset = 0;
    CFPropertyListRef presetVal = CFPreferencesCopyAppValue((__bridge CFStringRef)@"alignmentPreset", domain);
    if (presetVal && CFGetTypeID(presetVal) == CFNumberGetTypeID()) {
        preset = [(__bridge NSNumber *)presetVal integerValue];
        CFRelease(presetVal);
    } else if (presetVal) {
        CFRelease(presetVal);
    }
    self.alignmentPreset = preset;

    // Custom Center Y
    CGFloat savedY = -1.0;
    CFPropertyListRef yVal = CFPreferencesCopyAppValue((__bridge CFStringRef)@"customCenterY", domain);
    if (yVal && CFGetTypeID(yVal) == CFNumberGetTypeID()) {
        savedY = [(__bridge NSNumber *)yVal doubleValue];
        CFRelease(yVal);
    } else if (yVal) {
        CFRelease(yVal);
    }

    // Match LRLyricsView.m exact height & clamping math
    CGFloat baseLineHeight = self.fontSize + 12.0;
    CGFloat actualHeight = (baseLineHeight * (self.visibleLinesCount + 1.2)) + 20.0;
    self.minY = (actualHeight / 2.0) + 40.0;
    self.maxY = self.deviceScreenHeight - (actualHeight / 2.0) - 40.0;
    if (self.maxY <= self.minY) {
        self.minY = self.deviceScreenHeight * 0.15;
        self.maxY = self.deviceScreenHeight * 0.85;
    }

    CGFloat targetY = savedY;
    if (targetY <= 0 || self.alignmentPreset != 0) {
        switch (self.alignmentPreset) {
            case 1: // Below Clock
                targetY = self.deviceScreenHeight * 0.28;
                break;
            case 2: // Screen Center
                targetY = self.deviceScreenHeight * 0.50;
                break;
            case 3: // Above Media Controls
                targetY = self.deviceScreenHeight * 0.65;
                break;
            case 0: // Custom
            default:
                targetY = (targetY > 0) ? targetY : (self.deviceScreenHeight * 0.30);
                break;
        }
    }
    targetY = MAX(self.minY, MIN(targetY, self.maxY));
    self.currentCenterY = targetY;

    // Rebuild sample lyric labels
    [self rebuildPreviewLyricsLabels];

    // Sync slider bounds & value
    self.ySlider.minimumValue = (float)self.minY;
    self.ySlider.maximumValue = (float)self.maxY;
    [self.ySlider setValue:(float)self.currentCenterY animated:animated];

    [self updateValueReadout];
    [self updateLyricsBoxFrameAnimated:animated];
}

- (void)rebuildPreviewLyricsLabels {
    for (UILabel *lbl in self.lyricsLabels) {
        [self.lyricsStackView removeArrangedSubview:lbl];
        [lbl removeFromSuperview];
    }
    [self.lyricsLabels removeAllObjects];

    NSArray<NSString *> *samples = nil;
    if (self.visibleLinesCount == 1) {
        samples = @[@"Dancing in the moonlight"];
    } else if (self.visibleLinesCount == 5) {
        samples = @[
            @"Waiting for the night to fall",
            @"Every step brings me closer",
            @"Dancing in the moonlight",
            @"Underneath the starlit sky",
            @"Never let this moment fade"
        ];
    } else {
        samples = @[
            @"Every step brings me closer",
            @"Dancing in the moonlight",
            @"Underneath the starlit sky"
        ];
    }

    NSInteger count = (NSInteger)samples.count;
    NSInteger centerIdx = count / 2;

    UILabel *centerLabel = nil;
    UILabel *firstSideLabel = nil;

    for (NSInteger i = 0; i < count; i++) {
        UILabel *label = [[UILabel alloc] init];
        label.text = samples[i];
        label.textAlignment = NSTextAlignmentCenter;
        label.textColor = [UIColor whiteColor];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.adjustsFontSizeToFitWidth = YES;
        label.minimumScaleFactor = 0.55;

        if (i == centerIdx) {
            CGFloat scaledFont = MAX(5.5, self.fontSize * self.previewScale);
            label.font = [UIFont systemFontOfSize:scaledFont weight:UIFontWeightBold];
            label.alpha = 1.0;
            label.numberOfLines = 2;
            centerLabel = label;
        } else {
            CGFloat sideFont = MAX(4.5, MAX(self.fontSize - 4.0, 12.0) * self.previewScale);
            label.font = [UIFont systemFontOfSize:sideFont weight:UIFontWeightMedium];
            label.alpha = (ABS(i - centerIdx) == 1) ? 0.45 : 0.25;
            label.numberOfLines = 1;
            if (!firstSideLabel) firstSideLabel = label;
        }

        [self.lyricsStackView addArrangedSubview:label];
        [self.lyricsLabels addObject:label];
    }

    if (centerLabel && firstSideLabel) {
        NSLayoutConstraint *cCenter = [centerLabel.heightAnchor constraintEqualToAnchor:firstSideLabel.heightAnchor multiplier:2.0];
        cCenter.priority = (UILayoutPriority)999;
        cCenter.active = YES;

        for (NSInteger i = 0; i < count; i++) {
            if (i != centerIdx && self.lyricsLabels[i] != firstSideLabel) {
                NSLayoutConstraint *cOther = [self.lyricsLabels[i].heightAnchor constraintEqualToAnchor:firstSideLabel.heightAnchor];
                cOther.priority = (UILayoutPriority)999;
                cOther.active = YES;
            }
        }
    }
}

- (void)updateLyricsBoxFrameAnimated:(BOOL)animated {
    CGFloat actualWidth = self.deviceScreenWidth - 32.0;
    CGFloat baseLineHeight = self.fontSize + 12.0;
    CGFloat actualHeight = (baseLineHeight * (self.visibleLinesCount + 1.2)) + 20.0;

    CGFloat scaledW = actualWidth * self.previewScale;
    CGFloat scaledH = actualHeight * self.previewScale;
    CGFloat scaledCenterY = self.currentCenterY * self.previewScale;

    void (^applyFrame)(void) = ^{
        self.lyricsBoxView.bounds = CGRectMake(0, 0, scaledW, scaledH);
        self.lyricsBoxView.center = CGPointMake(self.previewWidth / 2.0, scaledCenterY);
    };

    if (animated) {
        [UIView animateWithDuration:0.22
                              delay:0
             usingSpringWithDamping:0.85
              initialSpringVelocity:0.3
                            options:UIViewAnimationOptionBeginFromCurrentState
                         animations:applyFrame
                         completion:nil];
    } else {
        applyFrame();
    }
}

- (void)updateValueReadout {
    int percent = (int)llround((self.currentCenterY / self.deviceScreenHeight) * 100.0);
    int pts = (int)llround(self.currentCenterY);
    self.valueLabel.text = [NSString stringWithFormat:@"%d%% (%d pt)", percent, pts];
}

#pragma mark - Slider & Tap Actions

- (void)sliderTouchDown:(UISlider *)slider {
    self.isDraggingSlider = YES;
    [self.hapticGenerator prepare];
    [UIView animateWithDuration:0.15 animations:^{
        self.lyricsBoxView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.75].CGColor;
        self.lyricsBoxView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    }];
}

- (void)sliderValueChanged:(UISlider *)slider {
    CGFloat newY = (CGFloat)slider.value;
    CGFloat screenCenterY = self.deviceScreenHeight * 0.50;

    // Gentle haptic feedback and center guide when passing screen center (50%)
    BOOL nearCenter = (fabs(newY - screenCenterY) <= 6.0);
    if (nearCenter && !self.wasNearCenter) {
        [self.hapticGenerator selectionChanged];
        [self.hapticGenerator prepare];
    }
    self.wasNearCenter = nearCenter;

    [UIView animateWithDuration:0.12 animations:^{
        self.centerGuideLine.alpha = nearCenter ? 1.0 : 0.0;
    }];

    self.currentCenterY = MAX(self.minY, MIN(newY, self.maxY));
    [self updateValueReadout];
    [self updateLyricsBoxFrameAnimated:NO];
}

- (void)sliderTouchEnded:(UISlider *)slider {
    self.isDraggingSlider = NO;
    self.wasNearCenter = NO;
    [UIView animateWithDuration:0.2 animations:^{
        self.lyricsBoxView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.25].CGColor;
        self.lyricsBoxView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
        self.centerGuideLine.alpha = 0.0;
    }];

    [self saveCurrentYPosition];
}

- (void)handlePreviewTap:(UITapGestureRecognizer *)gesture {
    CGPoint pt = [gesture locationInView:self.screenView];
    CGFloat tappedY = pt.y / self.previewScale;
    self.currentCenterY = MAX(self.minY, MIN(tappedY, self.maxY));

    [self.hapticGenerator selectionChanged];
    [self.ySlider setValue:(float)self.currentCenterY animated:YES];
    [self updateValueReadout];
    [self updateLyricsBoxFrameAnimated:YES];
    [self saveCurrentYPosition];
}

- (void)saveCurrentYPosition {
    CFStringRef domain = (__bridge CFStringRef)kLRPPrefsDomain;
    self.alignmentPreset = 0; // Custom / Draggable

    CFPreferencesSetAppValue((__bridge CFStringRef)@"customCenterY", (__bridge CFNumberRef)@(self.currentCenterY), domain);
    CFPreferencesSetAppValue((__bridge CFStringRef)@"alignmentPreset", (__bridge CFNumberRef)@(0), domain);
    CFPreferencesAppSynchronize(domain);

    notify_post(kLRPPrefsChangedNotification);

    [[NSNotificationCenter defaultCenter] postNotificationName:LRPPositionChangedBySliderNotification object:nil];
}

@end
