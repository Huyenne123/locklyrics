#import "LRPreferences.h"

@implementation LRPreferences

+ (instancetype)sharedPreferences {
    static LRPreferences *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[LRPreferences alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self loadPreferences];
    }
    return self;
}

- (void)loadPreferences {
    CFPreferencesAppSynchronize(kLRPreferencesIdentifier);

    Boolean keyExistsAndHasValidFormat = false;

    // Enabled
    Boolean enabledVal = CFPreferencesGetAppBooleanValue((__bridge CFStringRef)@"enabled", kLRPreferencesIdentifier, &keyExistsAndHasValidFormat);
    self.enabled = keyExistsAndHasValidFormat ? enabledVal : YES;

    // Live Dragging
    Boolean dragVal = CFPreferencesGetAppBooleanValue((__bridge CFStringRef)@"enableLiveDrag", kLRPreferencesIdentifier, &keyExistsAndHasValidFormat);
    self.enableLiveDrag = keyExistsAndHasValidFormat ? dragVal : YES;

    // Lock position (disable drag when locked)
    Boolean lockVal = CFPreferencesGetAppBooleanValue((__bridge CFStringRef)@"lockPosition", kLRPreferencesIdentifier, &keyExistsAndHasValidFormat);
    self.lockPosition = keyExistsAndHasValidFormat ? lockVal : NO;

    // Alignment Preset
    CFPropertyListRef presetVal = CFPreferencesCopyAppValue((__bridge CFStringRef)@"alignmentPreset", kLRPreferencesIdentifier);
    if (presetVal && CFGetTypeID(presetVal) == CFNumberGetTypeID()) {
        self.alignmentPreset = [(__bridge NSNumber *)presetVal integerValue];
        CFRelease(presetVal);
    } else {
        self.alignmentPreset = LRLyricsAlignmentPresetCustom;
    }

    // Custom Center X
    CFPropertyListRef xVal = CFPreferencesCopyAppValue((__bridge CFStringRef)@"customCenterX", kLRPreferencesIdentifier);
    if (xVal && CFGetTypeID(xVal) == CFNumberGetTypeID()) {
        self.customCenterX = [(__bridge NSNumber *)xVal doubleValue];
        CFRelease(xVal);
    } else {
        self.customCenterX = -1.0; // Unset default
    }

    // Custom Center Y
    CFPropertyListRef yVal = CFPreferencesCopyAppValue((__bridge CFStringRef)@"customCenterY", kLRPreferencesIdentifier);
    if (yVal && CFGetTypeID(yVal) == CFNumberGetTypeID()) {
        self.customCenterY = [(__bridge NSNumber *)yVal doubleValue];
        CFRelease(yVal);
    } else {
        self.customCenterY = -1.0; // Unset default
    }

    // Visible lines count
    CFPropertyListRef linesVal = CFPreferencesCopyAppValue((__bridge CFStringRef)@"visibleLinesCount", kLRPreferencesIdentifier);
    if (linesVal && CFGetTypeID(linesVal) == CFNumberGetTypeID()) {
        self.visibleLinesCount = [(__bridge NSNumber *)linesVal integerValue];
        CFRelease(linesVal);
    } else {
        self.visibleLinesCount = 3;
    }

    // Font size
    CFPropertyListRef fontVal = CFPreferencesCopyAppValue((__bridge CFStringRef)@"fontSize", kLRPreferencesIdentifier);
    if (fontVal && CFGetTypeID(fontVal) == CFNumberGetTypeID()) {
        self.fontSize = [(__bridge NSNumber *)fontVal doubleValue];
        CFRelease(fontVal);
    } else {
        self.fontSize = 20.0;
    }

    // Auto Font Size
    Boolean autoFontVal = CFPreferencesGetAppBooleanValue((__bridge CFStringRef)@"autoFontSize", kLRPreferencesIdentifier, &keyExistsAndHasValidFormat);
    self.autoFontSize = keyExistsAndHasValidFormat ? autoFontVal : YES;

    // Blur
    Boolean blurVal = CFPreferencesGetAppBooleanValue((__bridge CFStringRef)@"enableBackgroundBlur", kLRPreferencesIdentifier, &keyExistsAndHasValidFormat);
    self.enableBackgroundBlur = keyExistsAndHasValidFormat ? blurVal : YES;

    // Background Alpha
    CFPropertyListRef alphaVal = CFPreferencesCopyAppValue((__bridge CFStringRef)@"backgroundAlpha", kLRPreferencesIdentifier);
    if (alphaVal && CFGetTypeID(alphaVal) == CFNumberGetTypeID()) {
        self.backgroundAlpha = [(__bridge NSNumber *)alphaVal doubleValue];
        CFRelease(alphaVal);
    } else {
        self.backgroundAlpha = 0.75;
    }

    // Show plain lyrics
    Boolean plainVal = CFPreferencesGetAppBooleanValue((__bridge CFStringRef)@"showPlainLyricsIfNoSynced", kLRPreferencesIdentifier, &keyExistsAndHasValidFormat);
    self.showPlainLyricsIfNoSynced = keyExistsAndHasValidFormat ? plainVal : YES;

    // Highlight current line
    Boolean highlightVal = CFPreferencesGetAppBooleanValue((__bridge CFStringRef)@"highlightCurrentLine", kLRPreferencesIdentifier, &keyExistsAndHasValidFormat);
    self.highlightCurrentLine = keyExistsAndHasValidFormat ? highlightVal : YES;

    // Lyrics Provider
    CFPropertyListRef provVal = CFPreferencesCopyAppValue((__bridge CFStringRef)@"lyricsProvider", kLRPreferencesIdentifier);
    if (provVal && CFGetTypeID(provVal) == CFNumberGetTypeID()) {
        self.lyricsProvider = (LRLyricsProvider)[(__bridge NSNumber *)provVal integerValue];
        CFRelease(provVal);
    } else {
        self.lyricsProvider = LRLyricsProviderLRCLIB;
    }

    // Musixmatch User Token
    CFPropertyListRef tokenVal = CFPreferencesCopyAppValue((__bridge CFStringRef)@"musixmatchUserToken", kLRPreferencesIdentifier);
    if (tokenVal && CFGetTypeID(tokenVal) == CFStringGetTypeID()) {
        self.musixmatchUserToken = [(__bridge NSString *)tokenVal copy];
        CFRelease(tokenVal);
    } else {
        self.musixmatchUserToken = @"";
    }

    // SpicyLyrics API Key
    CFPropertyListRef spicyKeyVal = CFPreferencesCopyAppValue((__bridge CFStringRef)@"spicyLyricsApiKey", kLRPreferencesIdentifier);
    if (spicyKeyVal && CFGetTypeID(spicyKeyVal) == CFStringGetTypeID()) {
        self.spicyLyricsApiKey = [(__bridge NSString *)spicyKeyVal copy];
        CFRelease(spicyKeyVal);
    } else {
        self.spicyLyricsApiKey = @"";
    }

    // App Filter Mode (default 0: Whitelist, 1: Blacklist)
    CFPropertyListRef filterModeVal = CFPreferencesCopyAppValue((__bridge CFStringRef)@"appFilterMode", kLRPreferencesIdentifier);
    if (filterModeVal && CFGetTypeID(filterModeVal) == CFNumberGetTypeID()) {
        self.appFilterMode = (LRAppFilterMode)[(__bridge NSNumber *)filterModeVal integerValue];
        CFRelease(filterModeVal);
    } else {
        self.appFilterMode = LRAppFilterModeWhitelist;
    }

    // AltList Custom Whitelist Apps
    CFPropertyListRef wlAppsVal = CFPreferencesCopyAppValue((__bridge CFStringRef)@"customWhitelistApps", kLRPreferencesIdentifier);
    if (wlAppsVal && CFGetTypeID(wlAppsVal) == CFArrayGetTypeID()) {
        self.customWhitelistApps = [(__bridge NSArray *)wlAppsVal copy];
        CFRelease(wlAppsVal);
    } else {
        self.customWhitelistApps = @[];
    }

    // AltList Custom Blacklist Apps
    CFPropertyListRef blAppsVal = CFPreferencesCopyAppValue((__bridge CFStringRef)@"customBlacklistApps", kLRPreferencesIdentifier);
    if (blAppsVal && CFGetTypeID(blAppsVal) == CFArrayGetTypeID()) {
        self.customBlacklistApps = [(__bridge NSArray *)blAppsVal copy];
        CFRelease(blAppsVal);
    } else {
        self.customBlacklistApps = @[];
    }
}

static BOOL isDefaultMusicApp(NSString *bundleID) {
    if (!bundleID || bundleID.length == 0) return NO;
    NSString *b = bundleID.lowercaseString;

    static NSArray<NSString *> *musicApps = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        musicApps = @[
            @"com.apple.music",
            @"com.spotify.client",
            @"com.google.ios.youtubemusic",
            @"com.soundcloud.touchapp",
            @"com.vng.zingmp3",
            @"com.vng.zingmp33",
            @"com.nct.nhaccuatui",
            @"com.aspiro.tidal",
            @"com.deezer.deezer",
            @"com.amazon.mp3.ios",
            @"com.musi.musi",
            @"com.pandora",
            @"com.audiomack.iphone",
            @"com.qobuz.music",
            @"com.coppertino.vox",
            @"com.apple.podcasts",
            @"fm.overcast.overcast",
            @"org.videolan.vlc-ios",
            @"org.foobar2000.foobar2000",
            @"com.audioflow.evermusic",
            @"co.brushedtype.doppler",
            @"com.shazam.shazam",
            @"com.tencent.qqmusic",
            @"com.netease.cloudmusic"
        ];
    });

    for (NSString *app in musicApps) {
        if ([b hasPrefix:app] || [b isEqualToString:app]) {
            return YES;
        }
    }
    return NO;
}

static BOOL isDefaultBlacklistedApp(NSString *bundleID) {
    if (!bundleID || bundleID.length == 0) return NO;
    NSString *b = bundleID.lowercaseString;

    // Calling / VoIP / In-Call services (Phone calls, FaceTime, etc.)
    if ([b isEqualToString:@"com.apple.mobilephone"] ||
        [b isEqualToString:@"com.apple.incallservice"] ||
        [b isEqualToString:@"com.apple.facetime"] ||
        [b containsString:@"telephonyutilities"] ||
        [b containsString:@"callaudio"]) {
        return YES;
    }

    // Explicit TikTok / ByteDance / Douyin apps
    if ([b containsString:@"zhiliaoapp"] ||
        [b containsString:@"musically"] ||
        [b containsString:@"tiktok"] ||
        [b containsString:@"ugc.aweme"] ||
        [b containsString:@"ugc.awen"]) {
        return YES;
    }

    // YouTube main app (NOT YouTube Music)
    if ([b isEqualToString:@"com.google.ios.youtube"] ||
        [b isEqualToString:@"com.google.ios.youtubeunplugged"]) {
        return YES;
    }

    // Social / video / shorts
    if ([b isEqualToString:@"com.burbn.instagram"] ||
        [b isEqualToString:@"com.facebook.facebook"] ||
        [b isEqualToString:@"com.atebits.tweetie2"] ||
        [b isEqualToString:@"com.reddit.reddit"] ||
        [b isEqualToString:@"tv.twitch"] ||
        [b isEqualToString:@"com.lemon.lvoverseas"] ||
        [b isEqualToString:@"com.netflix.netflix"] ||
        [b isEqualToString:@"com.apple.mobilesafari"]) {
        return YES;
    }

    return NO;
}

- (BOOL)isAppAllowed:(NSString *)bundleID {
    if (!self.enabled) return NO;
    if (!bundleID || bundleID.length == 0) return NO;

    NSString *b = bundleID.lowercaseString;

    // Always block in-call / telephony / FaceTime services
    if ([b isEqualToString:@"com.apple.mobilephone"] ||
        [b isEqualToString:@"com.apple.incallservice"] ||
        [b isEqualToString:@"com.apple.facetime"] ||
        [b containsString:@"telephonyutilities"] ||
        [b containsString:@"callaudio"]) {
        return NO;
    }

    if (self.appFilterMode == LRAppFilterModeWhitelist) {
        // Whitelist mode:
        // 1. Check user-selected whitelist apps from AltList
        if (self.customWhitelistApps && self.customWhitelistApps.count > 0) {
            for (NSString *app in self.customWhitelistApps) {
                if ([app isKindOfClass:[NSString class]]) {
                    if ([b isEqualToString:app.lowercaseString] || [b hasPrefix:app.lowercaseString]) {
                        return YES;
                    }
                }
            }
        }
        // 2. Allow default music apps (Apple Music, Spotify, YouTube Music, etc.)
        return isDefaultMusicApp(b);
    } else {
        // Blacklist mode:
        // 1. Check user-selected blacklist apps from AltList
        if (self.customBlacklistApps && self.customBlacklistApps.count > 0) {
            for (NSString *app in self.customBlacklistApps) {
                if ([app isKindOfClass:[NSString class]]) {
                    if ([b isEqualToString:app.lowercaseString] || [b hasPrefix:app.lowercaseString]) {
                        return NO;
                    }
                }
            }
        }
        // 2. Block known video / social apps by default in blacklist mode
        if (isDefaultBlacklistedApp(b)) {
            return NO;
        }
        return YES;
    }
}

- (void)saveCustomPosition:(CGPoint)center {
    self.customCenterX = center.x;
    self.customCenterY = center.y;
    self.alignmentPreset = LRLyricsAlignmentPresetCustom;

    CFPreferencesSetAppValue((__bridge CFStringRef)@"customCenterX", (__bridge CFNumberRef)@(center.x), kLRPreferencesIdentifier);
    CFPreferencesSetAppValue((__bridge CFStringRef)@"customCenterY", (__bridge CFNumberRef)@(center.y), kLRPreferencesIdentifier);
    CFPreferencesSetAppValue((__bridge CFStringRef)@"alignmentPreset", (__bridge CFNumberRef)@(LRLyricsAlignmentPresetCustom), kLRPreferencesIdentifier);
    CFPreferencesAppSynchronize(kLRPreferencesIdentifier);
}

@end
