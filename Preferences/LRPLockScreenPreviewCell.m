#import "LRPLockScreenPreviewCell.h"
#import <Preferences/PSSpecifier.h>
#import <QuartzCore/QuartzCore.h>
#import <ctype.h>
#import <dirent.h>
#import <notify.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <time.h>

static inline NSString *lrpStr(const char *s) {
    return s ? [NSString stringWithUTF8String:s] : [NSString string];
}

static const char * const kLRPPrefsChangedNotification = "com.locklyrics.preferences.changed";
static const char * const kLRPOfflineLyricsDir = "/var/mobile/Library/LockLyrics/Lyrics";

@interface LRPPreviewLine : NSObject
@property (nonatomic, assign) NSTimeInterval time;
@property (nonatomic, copy) NSString *text;
- (instancetype)initWithTime:(NSTimeInterval)time text:(NSString *)text;
@end

@implementation LRPPreviewLine
- (instancetype)initWithTime:(NSTimeInterval)time text:(NSString *)text {
    self = [super init];
    if (self) {
        _time = time;
        _text = text ? [text copy] : [NSString string];
    }
    return self;
}
@end

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

@property (nonatomic, strong) UILabel *mediaTitleLabel;
@property (nonatomic, strong) UILabel *mediaArtistLabel;
@property (nonatomic, strong) UIView *mediaProgressBg;
@property (nonatomic, strong) UIView *mediaProgressFill;
@property (nonatomic, strong) UILabel *mediaElapsedLabel;
@property (nonatomic, strong) UILabel *mediaRemainingLabel;

@property (nonatomic, strong) UIView *lyricsBoxView;
@property (nonatomic, strong) UIStackView *lyricsStackView;
@property (nonatomic, strong) NSMutableArray<UILabel *> *lyricsLabels;

@property (nonatomic, strong) NSArray<LRPPreviewLine *> *previewSongLines;
@property (nonatomic, assign) NSInteger previewLineIndex;
@property (nonatomic, copy) NSString *previewTrackName;
@property (nonatomic, copy) NSString *previewArtistName;
@property (nonatomic, assign) NSTimeInterval previewElapsedTime;
@property (nonatomic, assign) NSTimeInterval previewDuration;

@property (nonatomic, strong) UIButton *shuffleButton;
@property (nonatomic, strong) UILabel *titleLabelCustom;
@property (nonatomic, strong) UILabel *valueLabel;
@property (nonatomic, strong) UISlider *ySlider;
@property (nonatomic, strong) UISelectionFeedbackGenerator *hapticGenerator;
@property (nonatomic, assign) BOOL wasNearCenter;
@property (nonatomic, assign) BOOL isDraggingSlider;

@end

#pragma mark - Pure POSIX & C Cache Parsing Helpers

static NSData *lrpReadFileData(const char *path) {
    if (!path) return nil;
    FILE *f = fopen(path, "rb");
    if (!f) return nil;
    if (fseek(f, 0, SEEK_END) != 0) {
        fclose(f);
        return nil;
    }
    long size = ftell(f);
    if (size <= 0 || size > 4 * 1024 * 1024) {
        fclose(f);
        return nil;
    }
    rewind(f);
    void *buf = malloc((size_t)size);
    if (!buf) {
        fclose(f);
        return nil;
    }
    size_t readBytes = fread(buf, 1, (size_t)size, f);
    fclose(f);
    if (readBytes != (size_t)size) {
        free(buf);
        return nil;
    }
    return [NSData dataWithBytesNoCopy:buf length:(NSUInteger)size freeWhenDone:YES];
}

static void lrpShuffleMutableArray(NSMutableArray *arr) {
    NSUInteger count = arr.count;
    if (count < 2) return;
    for (NSUInteger i = count - 1; i > 0; i--) {
        NSUInteger j = (NSUInteger)arc4random_uniform((uint32_t)(i + 1));
        if (i != j) {
            [arr exchangeObjectAtIndex:i withObjectAtIndex:j];
        }
    }
}

static BOOL lrpHasSuffix(const char *str, const char *suffix) {
    if (!str || !suffix) return NO;
    size_t slen = strlen(str);
    size_t suflen = strlen(suffix);
    if (slen < suflen) return NO;
    return strcmp(str + (slen - suflen), suffix) == 0;
}

static NSArray<LRPPreviewLine *> *lrpParseLrcUTF8(const char *utf8) {
    if (!utf8 || utf8[0] == '\0') return @[];

    NSMutableArray<LRPPreviewLine *> *parsedLines = [NSMutableArray array];
    NSMutableArray<NSNumber *> *timestamps = [NSMutableArray array];
    NSString *dots = lrpStr("•••");

    const char *cursor = utf8;
    while (*cursor) {
        const char *lineStart = cursor;
        const char *lineEnd = cursor;
        while (*lineEnd && *lineEnd != '\n' && *lineEnd != '\r') {
            lineEnd++;
        }
        cursor = lineEnd;
        while (*cursor == '\n' || *cursor == '\r') {
            cursor++;
        }

        size_t lineLen = (size_t)(lineEnd - lineStart);
        if (lineLen == 0) continue;

        char *lineBuf = (char *)malloc(lineLen + 1);
        if (!lineBuf) continue;
        memcpy(lineBuf, lineStart, lineLen);
        lineBuf[lineLen] = '\0';

        [timestamps removeAllObjects];
        const char *ptr = lineBuf;
        while (*ptr) {
            const char *startBracket = strchr(ptr, '[');
            if (!startBracket) break;
            const char *endBracket = strchr(startBracket, ']');
            if (!endBracket) break;

            int min = 0;
            double sec = 0.0;
            if (sscanf(startBracket, "[%d:%lf]", &min, &sec) == 2) {
                [timestamps addObject:@((min * 60.0) + sec)];
                ptr = endBracket + 1;
            } else if (endBracket > startBracket + 1 &&
                       isdigit((unsigned char)startBracket[1]) &&
                       sscanf(startBracket, "[%lf]", &sec) == 1) {
                [timestamps addObject:@(sec)];
                ptr = endBracket + 1;
            } else {
                ptr = endBracket + 1;
            }
        }

        if (timestamps.count > 0) {
            size_t remLen = strlen(ptr);
            char *cleanBuf = (char *)malloc(remLen + 1);
            if (cleanBuf) {
                const char *src = ptr;
                char *dst = cleanBuf;
                while (*src) {
                    if (*src == '<') {
                        const char *close = strchr(src, '>');
                        if (close) {
                            src = close + 1;
                            continue;
                        }
                    }
                    *dst++ = *src++;
                }
                *dst = '\0';

                // Trim leading and trailing ASCII whitespace
                char *trimmed = cleanBuf;
                while (*trimmed == ' ' || *trimmed == '\t' || *trimmed == '\r' || *trimmed == '\n') {
                    trimmed++;
                }
                size_t tlen = strlen(trimmed);
                while (tlen > 0 && (trimmed[tlen - 1] == ' ' || trimmed[tlen - 1] == '\t' ||
                                    trimmed[tlen - 1] == '\r' || trimmed[tlen - 1] == '\n')) {
                    trimmed[--tlen] = '\0';
                }

                NSString *lyricText = (tlen > 0) ? lrpStr(trimmed) : dots;
                if (!lyricText || lyricText.length == 0) {
                    lyricText = dots;
                }

                for (NSNumber *timeNum in timestamps) {
                    [parsedLines addObject:[[LRPPreviewLine alloc] initWithTime:[timeNum doubleValue] text:lyricText]];
                }
                free(cleanBuf);
            }
        }
        free(lineBuf);
    }

    [parsedLines sortUsingComparator:^NSComparisonResult(LRPPreviewLine *a, LRPPreviewLine *b) {
        if (a.time < b.time) return NSOrderedAscending;
        if (a.time > b.time) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    return [parsedLines copy];
}

@implementation LRPLockScreenPreviewCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.textLabel.hidden = YES;
        self.detailTextLabel.hidden = YES;
        _lyricsLabels = [NSMutableArray array];
        _hapticGenerator = [[UISelectionFeedbackGenerator alloc] init];

        if (specifier && specifier.target && [specifier.target conformsToProtocol:@protocol(LRPLockScreenPreviewCellDelegate)]) {
            _delegate = specifier.target;
        }

        [self computeScreenMetrics];
        [self buildUI];
        [self loadRandomCachedSong];
        [self refreshFromPreferencesAnimated:NO];
    }
    return self;
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

    // Subtle Shuffle button to re-roll cached song & timestamp
    self.shuffleButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.shuffleButton.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *shufCfg = [UIImageSymbolConfiguration configurationWithPointSize:13.0 weight:UIImageSymbolWeightMedium];
    [self.shuffleButton setImage:[UIImage systemImageNamed:lrpStr("shuffle") withConfiguration:shufCfg] forState:UIControlStateNormal];
    self.shuffleButton.tintColor = [UIColor secondaryLabelColor];
    self.shuffleButton.accessibilityLabel = lrpStr("Shuffle preview song");
    [self.shuffleButton addTarget:self action:@selector(handleShuffleTap:) forControlEvents:UIControlEventTouchUpInside];
    [container addSubview:self.shuffleButton];

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
    self.titleLabelCustom.text = lrpStr("Y Position");
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
    self.ySlider.minimumValueImage = [[UIImage systemImageNamed:lrpStr("arrow.up.to.line") withConfiguration:symConfig] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    self.ySlider.maximumValueImage = [[UIImage systemImageNamed:lrpStr("arrow.down.to.line") withConfiguration:symConfig] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];

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

        [self.shuffleButton.topAnchor constraintEqualToAnchor:self.bezelView.topAnchor],
        [self.shuffleButton.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-14.0],
        [self.shuffleButton.widthAnchor constraintEqualToConstant:28.0],
        [self.shuffleButton.heightAnchor constraintEqualToConstant:28.0],

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

    // Pure C localtime_r + strftime to avoid iOS 18 Swift Foundation NSDateFormatter bridging
    time_t now = time(NULL);
    struct tm localTm;
    localtime_r(&now, &localTm);

    char dateBuf[64];
    dateBuf[0] = '\0';
    strftime(dateBuf, sizeof(dateBuf), "%A, %b %e", &localTm);

    UILabel *dateLabel = [[UILabel alloc] initWithFrame:CGRectMake(6.0, h * 0.10, w - 12.0, 11.0)];
    dateLabel.text = lrpStr(dateBuf);
    dateLabel.textAlignment = NSTextAlignmentCenter;
    dateLabel.font = [UIFont systemFontOfSize:7.5 weight:UIFontWeightMedium];
    dateLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.82];
    dateLabel.userInteractionEnabled = NO;
    [self.screenView addSubview:dateLabel];

    char timeBuf[16];
    timeBuf[0] = '\0';
    strftime(timeBuf, sizeof(timeBuf), "%H:%M", &localTm);

    UILabel *clockLabel = [[UILabel alloc] initWithFrame:CGRectMake(6.0, h * 0.132, w - 12.0, 38.0)];
    clockLabel.text = lrpStr(timeBuf);
    clockLabel.textAlignment = NSTextAlignmentCenter;
    UIFontDescriptor *desc = [[UIFont systemFontOfSize:32.0 weight:UIFontWeightBold] fontDescriptor];
    UIFontDescriptor *roundedDesc = [desc fontDescriptorWithDesign:UIFontDescriptorSystemDesignRounded];
    clockLabel.font = roundedDesc ? [UIFont fontWithDescriptor:roundedDesc size:32.0] : [UIFont systemFontOfSize:32.0 weight:UIFontWeightBold];
    clockLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.88];
    clockLabel.userInteractionEnabled = NO;
    [self.screenView addSubview:clockLabel];

    // Media Player Card (matches typical iOS 16-18 Lock Screen Now Playing card at ~64%-81.5% height)
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

    // Mini artwork square with subtle music note glyph
    UIView *artwork = [[UIView alloc] initWithFrame:CGRectMake(7.0, 6.0, 18.0, 18.0)];
    artwork.backgroundColor = [UIColor colorWithRed:0.30 green:0.52 blue:0.74 alpha:0.85];
    artwork.layer.cornerRadius = 4.0;
    UIImageSymbolConfiguration *artCfg = [UIImageSymbolConfiguration configurationWithPointSize:8.5 weight:UIImageSymbolWeightMedium];
    UIImageView *artIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:lrpStr("music.note") withConfiguration:artCfg]];
    artIcon.tintColor = [UIColor colorWithWhite:1.0 alpha:0.90];
    artIcon.contentMode = UIViewContentModeCenter;
    artIcon.frame = artwork.bounds;
    [artwork addSubview:artIcon];
    [mediaCard addSubview:artwork];

    // Song title & artist labels
    self.mediaTitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(29.0, 6.5, cardW - 36.0, 10.0)];
    self.mediaTitleLabel.font = [UIFont systemFontOfSize:7.5 weight:UIFontWeightSemibold];
    self.mediaTitleLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.90];
    self.mediaTitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [mediaCard addSubview:self.mediaTitleLabel];

    self.mediaArtistLabel = [[UILabel alloc] initWithFrame:CGRectMake(29.0, 16.5, cardW - 36.0, 8.0)];
    self.mediaArtistLabel.font = [UIFont systemFontOfSize:6.0 weight:UIFontWeightRegular];
    self.mediaArtistLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    self.mediaArtistLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [mediaCard addSubview:self.mediaArtistLabel];

    // Progress bar + elapsed/remaining labels
    CGFloat progW = cardW - 14.0;
    self.mediaProgressBg = [[UIView alloc] initWithFrame:CGRectMake(7.0, 29.0, progW, 2.5)];
    self.mediaProgressBg.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.20];
    self.mediaProgressBg.layer.cornerRadius = 1.25;
    [mediaCard addSubview:self.mediaProgressBg];

    self.mediaProgressFill = [[UIView alloc] initWithFrame:CGRectMake(0, 0, progW * 0.42, 2.5)];
    self.mediaProgressFill.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.78];
    self.mediaProgressFill.layer.cornerRadius = 1.25;
    [self.mediaProgressBg addSubview:self.mediaProgressFill];

    self.mediaElapsedLabel = [[UILabel alloc] initWithFrame:CGRectMake(7.0, 32.5, progW / 2.0, 7.0)];
    self.mediaElapsedLabel.font = [UIFont monospacedDigitSystemFontOfSize:5.5 weight:UIFontWeightRegular];
    self.mediaElapsedLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    self.mediaElapsedLabel.textAlignment = NSTextAlignmentLeft;
    [mediaCard addSubview:self.mediaElapsedLabel];

    self.mediaRemainingLabel = [[UILabel alloc] initWithFrame:CGRectMake(7.0 + progW / 2.0, 32.5, progW / 2.0, 7.0)];
    self.mediaRemainingLabel.font = [UIFont monospacedDigitSystemFontOfSize:5.5 weight:UIFontWeightRegular];
    self.mediaRemainingLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    self.mediaRemainingLabel.textAlignment = NSTextAlignmentRight;
    [mediaCard addSubview:self.mediaRemainingLabel];

    // Mini playback controls
    UIImageSymbolConfiguration *ctrlCfg = [UIImageSymbolConfiguration configurationWithPointSize:8.5 weight:UIImageSymbolWeightBold];
    NSArray<NSString *> *icons = @[lrpStr("backward.fill"), lrpStr("play.fill"), lrpStr("forward.fill")];
    CGFloat ctrlY = 42.0;
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
    UIImageView *flashIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:lrpStr("flashlight.off.fill") withConfiguration:qaCfg]];
    flashIcon.tintColor = [UIColor colorWithWhite:1.0 alpha:0.85];
    flashIcon.contentMode = UIViewContentModeCenter;
    flashIcon.frame = flashBtn.bounds;
    [flashBtn addSubview:flashIcon];
    [self.screenView addSubview:flashBtn];

    UIView *camBtn = [[UIView alloc] initWithFrame:CGRectMake(w - 18.0 - btnSize, btnY, btnSize, btnSize)];
    camBtn.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.35];
    camBtn.layer.cornerRadius = btnSize / 2.0;
    camBtn.userInteractionEnabled = NO;
    UIImageView *camIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:lrpStr("camera.fill") withConfiguration:qaCfg]];
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

#pragma mark - Cached Song Loader & Random Timestamp Picker

- (void)reloadRandomPreviewSong {
    [self loadRandomCachedSong];
    [self updateMediaCardMetadata];
    [self rebuildPreviewLyricsLabels];
}

- (void)populateFallbackSampleSong {
    self.previewTrackName = lrpStr("LockLyrics");
    self.previewArtistName = lrpStr("Preview Track");
    self.previewElapsedTime = 84.0;
    self.previewDuration = 205.0;
    self.previewLineIndex = 2;
    self.previewSongLines = @[
        [[LRPPreviewLine alloc] initWithTime:72.0 text:lrpStr("Waiting for the night to fall")],
        [[LRPPreviewLine alloc] initWithTime:78.0 text:lrpStr("Every step brings me closer")],
        [[LRPPreviewLine alloc] initWithTime:84.0 text:lrpStr("Dancing in the moonlight")],
        [[LRPPreviewLine alloc] initWithTime:90.0 text:lrpStr("Underneath the starlit sky")],
        [[LRPPreviewLine alloc] initWithTime:96.0 text:lrpStr("Never let this moment fade")]
    ];
}

- (BOOL)tryLoadPreviewSongFromFilename:(NSString *)filename isJSON:(BOOL)isJSON {
    if (!filename || filename.length == 0) return NO;
    char path[512];
    snprintf(path, sizeof(path), "%s/%s", kLRPOfflineLyricsDir, [filename UTF8String]);
    NSData *data = lrpReadFileData(path);
    if (!data || data.length == 0) return NO;

    NSString *track = nil;
    NSString *artist = nil;
    NSTimeInterval songDuration = 0.0;
    NSString *lrcText = nil;

    if (isJSON) {
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![obj isKindOfClass:[NSDictionary class]]) return NO;
        NSDictionary *dict = (NSDictionary *)obj;

        id syncedObj = dict[lrpStr("syncedLyrics")];
        if ([syncedObj isKindOfClass:[NSString class]]) {
            lrcText = (NSString *)syncedObj;
        }
        if (!lrcText || lrcText.length == 0) return NO;

        id trackObj = dict[lrpStr("trackName")];
        if (![trackObj isKindOfClass:[NSString class]] || [(NSString *)trackObj length] == 0) {
            trackObj = dict[lrpStr("name")];
        }
        if ([trackObj isKindOfClass:[NSString class]] && [(NSString *)trackObj length] > 0) {
            track = (NSString *)trackObj;
        }

        id artistObj = dict[lrpStr("artistName")];
        if ([artistObj isKindOfClass:[NSString class]] && [(NSString *)artistObj length] > 0) {
            artist = (NSString *)artistObj;
        }

        id durObj = dict[lrpStr("duration")];
        if ([durObj isKindOfClass:[NSNumber class]]) {
            songDuration = [(NSNumber *)durObj doubleValue];
        }
    } else {
        lrcText = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!lrcText || lrcText.length == 0) return NO;
    }

    NSArray<LRPPreviewLine *> *parsedLines = lrpParseLrcUTF8([lrcText UTF8String]);
    if (parsedLines.count == 0) return NO;

    // Pick a random timestamp that has real lyric text (not "•••")
    NSString *dots = lrpStr("•••");
    NSMutableArray<NSNumber *> *validIndices = [NSMutableArray arrayWithCapacity:parsedLines.count];
    for (NSUInteger i = 0; i < parsedLines.count; i++) {
        NSString *t = parsedLines[i].text;
        if (t.length >= 2 && ![t isEqualToString:dots]) {
            [validIndices addObject:@(i)];
        }
    }

    NSInteger pickedIdx = 0;
    if (validIndices.count > 0) {
        NSUInteger r = (NSUInteger)arc4random_uniform((uint32_t)validIndices.count);
        pickedIdx = [validIndices[r] integerValue];
    } else {
        pickedIdx = (NSInteger)arc4random_uniform((uint32_t)parsedLines.count);
    }

    self.previewSongLines = parsedLines;
    self.previewLineIndex = pickedIdx;
    self.previewElapsedTime = MAX(0.0, parsedLines[pickedIdx].time);

    NSTimeInterval lastTime = parsedLines.lastObject.time;
    if (songDuration > self.previewElapsedTime + 5.0) {
        self.previewDuration = songDuration;
    } else {
        self.previewDuration = MAX(lastTime + 15.0, self.previewElapsedTime + 30.0);
    }

    self.previewTrackName = (track && track.length > 0) ? track : lrpStr("LockLyrics");
    if (artist && artist.length > 0) {
        self.previewArtistName = artist;
    } else {
        self.previewArtistName = lrpStr(isJSON ? "Preview Track" : "Cached Track");
    }
    return YES;
}

- (void)loadRandomCachedSong {
    DIR *dir = opendir(kLRPOfflineLyricsDir);
    if (!dir) {
        [self populateFallbackSampleSong];
        return;
    }

    NSMutableArray<NSString *> *v2JsonFiles = [NSMutableArray array];
    NSMutableArray<NSString *> *otherJsonFiles = [NSMutableArray array];
    NSMutableArray<NSString *> *lrcFiles = [NSMutableArray array];

    struct dirent *ent;
    while ((ent = readdir(dir)) != NULL) {
        const char *name = ent->d_name;
        if (name[0] == '.') continue;
        if (lrpHasSuffix(name, ".json")) {
            NSString *fn = lrpStr(name);
            if (fn.length > 0) {
                if (strncmp(name, "v2_", 3) == 0) {
                    [v2JsonFiles addObject:fn];
                } else {
                    [otherJsonFiles addObject:fn];
                }
            }
        } else if (lrpHasSuffix(name, ".lrc")) {
            NSString *fn = lrpStr(name);
            if (fn.length > 0) {
                [lrcFiles addObject:fn];
            }
        }
    }
    closedir(dir);

    lrpShuffleMutableArray(v2JsonFiles);
    lrpShuffleMutableArray(otherJsonFiles);
    lrpShuffleMutableArray(lrcFiles);

    NSInteger attempts = 0;
    const NSInteger maxAttempts = 12;

    for (NSString *fn in v2JsonFiles) {
        if (attempts++ >= maxAttempts) break;
        if ([self tryLoadPreviewSongFromFilename:fn isJSON:YES]) return;
    }
    for (NSString *fn in otherJsonFiles) {
        if (attempts++ >= maxAttempts) break;
        if ([self tryLoadPreviewSongFromFilename:fn isJSON:YES]) return;
    }
    for (NSString *fn in lrcFiles) {
        if (attempts++ >= maxAttempts) break;
        if ([self tryLoadPreviewSongFromFilename:fn isJSON:NO]) return;
    }

    [self populateFallbackSampleSong];
}

- (void)updateMediaCardMetadata {
    self.mediaTitleLabel.text = self.previewTrackName ?: lrpStr("LockLyrics");
    self.mediaArtistLabel.text = self.previewArtistName ?: lrpStr("Preview Track");

    CGFloat ratio = (self.previewDuration > 0.0) ? (CGFloat)(self.previewElapsedTime / self.previewDuration) : 0.42;
    ratio = MAX(0.05, MIN(0.95, ratio));
    CGRect bgBounds = self.mediaProgressBg.bounds;
    self.mediaProgressFill.frame = CGRectMake(0, 0, bgBounds.size.width * ratio, bgBounds.size.height);

    int eSec = MAX(0, (int)llround(self.previewElapsedTime));
    int remSec = MAX(0, (int)llround(MAX(0.0, self.previewDuration - self.previewElapsedTime)));
    char eBuf[16];
    char rBuf[16];
    snprintf(eBuf, sizeof(eBuf), "%d:%02d", eSec / 60, eSec % 60);
    snprintf(rBuf, sizeof(rBuf), "-%d:%02d", remSec / 60, remSec % 60);
    self.mediaElapsedLabel.text = lrpStr(eBuf);
    self.mediaRemainingLabel.text = lrpStr(rBuf);
}

#pragma mark - Preferences & Preview Sync

- (CGFloat)fontSizeForText:(NSString *)text isCenterLine:(BOOL)isCenter {
    CGFloat baseSize = self.fontSize;
    if (baseSize < 12.0) baseSize = 20.0;

    if (!self.autoFontSize || !text || text.length == 0) {
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

- (void)refreshFromPreferencesAnimated:(BOOL)animated {
    NSString *domainStr = lrpStr("com.locklyrics.preferences");
    CFStringRef domain = (__bridge CFStringRef)domainStr;
    CFPreferencesAppSynchronize(domain);

    // Visible lines count (default 3)
    NSInteger linesCount = 3;
    NSString *linesKey = lrpStr("visibleLinesCount");
    CFPropertyListRef linesVal = CFPreferencesCopyAppValue((__bridge CFStringRef)linesKey, domain);
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
    NSString *fontKey = lrpStr("fontSize");
    CFPropertyListRef fontVal = CFPreferencesCopyAppValue((__bridge CFStringRef)fontKey, domain);
    if (fontVal && CFGetTypeID(fontVal) == CFNumberGetTypeID()) {
        fSize = [(__bridge NSNumber *)fontVal doubleValue];
        CFRelease(fontVal);
    } else if (fontVal) {
        CFRelease(fontVal);
    }
    if (fSize < 12.0) fSize = 20.0;
    self.fontSize = fSize;

    // Auto Font Size (default YES)
    Boolean autoKeyExists = false;
    NSString *autoFontKey = lrpStr("autoFontSize");
    Boolean autoVal = CFPreferencesGetAppBooleanValue((__bridge CFStringRef)autoFontKey, domain, &autoKeyExists);
    self.autoFontSize = autoKeyExists ? (BOOL)autoVal : YES;

    // Alignment preset (default 0 = Custom)
    NSInteger preset = 0;
    NSString *presetKey = lrpStr("alignmentPreset");
    CFPropertyListRef presetVal = CFPreferencesCopyAppValue((__bridge CFStringRef)presetKey, domain);
    if (presetVal && CFGetTypeID(presetVal) == CFNumberGetTypeID()) {
        preset = [(__bridge NSNumber *)presetVal integerValue];
        CFRelease(presetVal);
    } else if (presetVal) {
        CFRelease(presetVal);
    }
    self.alignmentPreset = preset;

    // Custom Center Y
    CGFloat savedY = -1.0;
    NSString *yKey = lrpStr("customCenterY");
    CFPropertyListRef yVal = CFPreferencesCopyAppValue((__bridge CFStringRef)yKey, domain);
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

    if (!self.previewSongLines || self.previewSongLines.count == 0) {
        [self loadRandomCachedSong];
    }

    [self updateMediaCardMetadata];
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

    NSInteger count = self.visibleLinesCount;
    if (count != 1 && count != 3 && count != 5) count = 3;
    NSInteger half = count / 2;

    UILabel *centerLabel = nil;
    UILabel *firstSideLabel = nil;
    NSInteger totalLines = (NSInteger)self.previewSongLines.count;
    NSInteger activeIdx = self.previewLineIndex;

    for (NSInteger offset = -half; offset <= half; offset++) {
        UILabel *label = [[UILabel alloc] init];
        label.textAlignment = NSTextAlignmentCenter;
        label.textColor = [UIColor whiteColor];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.adjustsFontSizeToFitWidth = YES;

        NSInteger targetIdx = activeIdx + offset;
        BOOL isCenter = (offset == 0);

        if (targetIdx >= 0 && targetIdx < totalLines) {
            NSString *text = self.previewSongLines[targetIdx].text;
            label.text = text;
            CGFloat rawFont = [self fontSizeForText:text isCenterLine:isCenter];

            if (isCenter) {
                CGFloat scaledFont = MAX(5.0, rawFont * self.previewScale);
                label.font = [UIFont systemFontOfSize:scaledFont weight:UIFontWeightBold];
                label.alpha = 1.0;
                label.numberOfLines = 2;
                label.minimumScaleFactor = 0.60;
                label.lineBreakMode = NSLineBreakByTruncatingTail;
                centerLabel = label;
            } else {
                CGFloat scaledFont = MAX(4.2, rawFont * self.previewScale);
                label.font = [UIFont systemFontOfSize:scaledFont weight:UIFontWeightMedium];
                label.alpha = (ABS(offset) == 1) ? 0.45 : 0.25;
                label.numberOfLines = 1;
                label.minimumScaleFactor = 0.70;
                label.lineBreakMode = NSLineBreakByTruncatingTail;
                if (!firstSideLabel) firstSideLabel = label;
            }
        } else {
            label.text = lrpStr(" ");
            label.alpha = 0.0;
            if (isCenter) {
                CGFloat scaledFont = MAX(5.0, self.fontSize * self.previewScale);
                label.font = [UIFont systemFontOfSize:scaledFont weight:UIFontWeightBold];
                label.numberOfLines = 2;
                centerLabel = label;
            } else {
                CGFloat scaledFont = MAX(4.2, MAX(self.fontSize - 4.0, 12.0) * self.previewScale);
                label.font = [UIFont systemFontOfSize:scaledFont weight:UIFontWeightMedium];
                label.numberOfLines = 1;
                if (!firstSideLabel) firstSideLabel = label;
            }
        }

        [self.lyricsStackView addArrangedSubview:label];
        [self.lyricsLabels addObject:label];
    }

    if (centerLabel && firstSideLabel) {
        NSLayoutConstraint *cCenter = [centerLabel.heightAnchor constraintEqualToAnchor:firstSideLabel.heightAnchor multiplier:2.0];
        cCenter.priority = (UILayoutPriority)999;
        cCenter.active = YES;

        NSInteger centerLabelIdx = half;
        for (NSInteger i = 0; i < (NSInteger)self.lyricsLabels.count; i++) {
            if (i != centerLabelIdx && self.lyricsLabels[i] != firstSideLabel) {
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
    char valBuf[32];
    snprintf(valBuf, sizeof(valBuf), "%d%% (%d pt)", percent, pts);
    self.valueLabel.text = lrpStr(valBuf);
}

#pragma mark - Slider, Tap & Shuffle Actions

- (void)handleShuffleTap:(UIButton *)sender {
    [self.hapticGenerator selectionChanged];
    [self.hapticGenerator prepare];

    [self loadRandomCachedSong];
    [self updateMediaCardMetadata];
    [UIView transitionWithView:self.lyricsStackView
                      duration:0.15
                       options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{
                        [self rebuildPreviewLyricsLabels];
                    }
                    completion:nil];
}

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
    NSString *domainStr = lrpStr("com.locklyrics.preferences");
    CFStringRef domain = (__bridge CFStringRef)domainStr;
    self.alignmentPreset = 0; // Custom / Draggable

    NSString *yKey = lrpStr("customCenterY");
    NSString *presetKey = lrpStr("alignmentPreset");
    CFPreferencesSetAppValue((__bridge CFStringRef)yKey, (__bridge CFNumberRef)@(self.currentCenterY), domain);
    CFPreferencesSetAppValue((__bridge CFStringRef)presetKey, (__bridge CFNumberRef)@(0), domain);
    CFPreferencesAppSynchronize(domain);

    notify_post(kLRPPrefsChangedNotification);

    id<LRPLockScreenPreviewCellDelegate> del = self.delegate;
    if (del && [del respondsToSelector:@selector(previewCellDidChangePosition:)]) {
        [del previewCellDidChangePosition:self];
    }
}

@end
