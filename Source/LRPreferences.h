#pragma once
#import <UIKit/UIKit.h>

#define kLRPreferencesIdentifier (__bridge CFStringRef)@"com.locklyrics.preferences"
#define kLRPreferencesChangedNotification "com.locklyrics.preferences.changed"

typedef NS_ENUM(NSInteger, LRLyricsAlignmentPreset) {
    LRLyricsAlignmentPresetCustom = 0,
    LRLyricsAlignmentPresetBelowClock = 1,
    LRLyricsAlignmentPresetCenter = 2,
    LRLyricsAlignmentPresetAboveMediaControls = 3
};

typedef NS_ENUM(NSInteger, LRAppFilterMode) {
    LRAppFilterModeWhitelist = 0,   // Only selected apps + default music apps allow lyrics
    LRAppFilterModeBlacklist = 1    // All apps allow lyrics EXCEPT selected apps + default video/call apps
};

typedef NS_ENUM(NSInteger, LRLyricsProvider) {
    LRLyricsProviderLRCLIB = 0,
    LRLyricsProviderMusixmatch = 1,
    LRLyricsProviderLrcRed = 2
};

@interface LRPreferences : NSObject

@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) BOOL enableLiveDrag;
@property (nonatomic, assign) BOOL lockPosition;
@property (nonatomic, assign) LRLyricsAlignmentPreset alignmentPreset;
@property (nonatomic, assign) CGFloat customCenterX;
@property (nonatomic, assign) CGFloat customCenterY;
@property (nonatomic, assign) NSInteger visibleLinesCount; // 1, 3, or 5
@property (nonatomic, assign) CGFloat fontSize;
@property (nonatomic, assign) BOOL autoFontSize;
@property (nonatomic, assign) BOOL enableBackgroundBlur;
@property (nonatomic, assign) CGFloat backgroundAlpha;
@property (nonatomic, assign) BOOL showPlainLyricsIfNoSynced;
@property (nonatomic, assign) BOOL highlightCurrentLine;

// Lyrics Provider
@property (nonatomic, assign) LRLyricsProvider lyricsProvider;
@property (nonatomic, copy) NSString *musixmatchUserToken;

// App Filter Settings (2 options: Whitelist vs Blacklist mode + AltList selection)
@property (nonatomic, assign) LRAppFilterMode appFilterMode;
@property (nonatomic, strong) NSArray<NSString *> *customWhitelistApps;
@property (nonatomic, strong) NSArray<NSString *> *customBlacklistApps;

+ (instancetype)sharedPreferences;
- (void)loadPreferences;
- (void)saveCustomPosition:(CGPoint)center;
- (BOOL)isAppAllowed:(NSString *)bundleID;

@end
