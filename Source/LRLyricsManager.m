#import "LRLyricsManager.h"
#import "LRColorExtractor.h"
#import "LRPreferences.h"
#import "MediaRemote.h"
#import <CoreFoundation/CoreFoundation.h>
#import <math.h>
#import <sys/stat.h>
#import <unistd.h>
#import <dirent.h>
#import <stdlib.h>

@interface SBMediaController : NSObject
+ (instancetype)sharedInstance;
- (id)nowPlayingApplication;
@end

@interface SBApplication : NSObject
- (NSString *)bundleIdentifier;
@end

static const char *kOfflineLyricsDir = "/var/mobile/Library/LockLyrics/Lyrics";
static const char *kOfflineArtworkDir = "/var/mobile/Library/LockLyrics/Artwork";

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static NSString *urlEncodeParam(NSString *str) {
    if (!str || str.length == 0) return @"";
    CFStringRef legalChars = CFStringCreateWithCString(kCFAllocatorDefault, ":/?#[]@!$&'()*+,;=", kCFStringEncodingUTF8);
    CFStringRef escaped = CFURLCreateStringByAddingPercentEscapes(
        kCFAllocatorDefault,
        (__bridge CFStringRef)str,
        NULL,
        legalChars,
        kCFStringEncodingUTF8
    );
    if (legalChars) CFRelease(legalChars);
    if (escaped) {
        NSString *result = [(__bridge NSString *)escaped copy];
        CFRelease(escaped);
        return result;
    }
    return @"";
}
#pragma clang diagnostic pop

#pragma mark - Pure POSIX File Helpers (Avoids iOS 18 Swift Foundation PAC Crashes)

static void makeDirRecursive(const char *path) {
    char tmp[512];
    snprintf(tmp, sizeof(tmp), "%s", path);
    size_t len = strlen(tmp);
    if (len == 0) return;
    if (tmp[len - 1] == '/') tmp[len - 1] = 0;
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = 0;
            mkdir(tmp, 0755);
            *p = '/';
        }
    }
    mkdir(tmp, 0755);
}

static BOOL fileExists(const char *path) {
    return (access(path, F_OK) == 0);
}

static NSData *readDataFromFile(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return nil;
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (size <= 0) {
        fclose(f);
        return nil;
    }
    void *buf = malloc(size);
    if (!buf) {
        fclose(f);
        return nil;
    }
    size_t readBytes = fread(buf, 1, size, f);
    fclose(f);
    if (readBytes != (size_t)size) {
        free(buf);
        return nil;
    }
    return [NSData dataWithBytesNoCopy:buf length:size freeWhenDone:YES];
}

static BOOL writeDataToFile(const char *path, NSData *data) {
    if (!path || !data) return NO;
    FILE *f = fopen(path, "wb");
    if (!f) return NO;
    size_t written = fwrite([data bytes], 1, [data length], f);
    fclose(f);
    return (written == [data length]);
}

static BOOL writeStringToFile(const char *path, const char *str) {
    if (!path || !str) return NO;
    FILE *f = fopen(path, "w");
    if (!f) return NO;
    fputs(str, f);
    fclose(f);
    return YES;
}

static void ensureOfflineDir(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        makeDirRecursive(kOfflineLyricsDir);
    });
}

static void ensureOfflineArtworkDir(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        makeDirRecursive(kOfflineArtworkDir);
    });
}

static void offlineJsonPathForKeyInDir(const char *dirPath, const char *cacheKey, char *outPath, size_t outSize) {
    char clean[256];
    size_t j = 0;
    for (size_t i = 0; cacheKey && cacheKey[i] && j < sizeof(clean) - 6; i++) {
        char c = cacheKey[i];
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_') {
            clean[j++] = c;
        } else {
            int written = snprintf(&clean[j], sizeof(clean) - j, "_%02x", (unsigned char)c);
            if (written > 0) j += (size_t)written;
        }
    }
    clean[j] = '\0';
    snprintf(outPath, outSize, "%s/%s.json", dirPath, clean);
}

static void offlinePathForCacheKey(const char *cacheKey, char *outPath, size_t outSize) {
    offlineJsonPathForKeyInDir(kOfflineLyricsDir, cacheKey, outPath, outSize);
}

static void artworkPathForKey(const char *rawKey, char *outPath, size_t outSize) {
    offlineJsonPathForKeyInDir(kOfflineArtworkDir, rawKey, outPath, outSize);
}

static NSString *artworkKeyForTrackAndArtist(NSString *track, NSString *artist) {
    return [NSString stringWithFormat:@"%@||%@", (artist ?: @""), (track ?: @"")].lowercaseString;
}

static NSDictionary *serializePaletteDict(NSArray<UIColor *> *palette, NSString *track, NSString *artist) {
    NSMutableArray *colorArrays = [NSMutableArray arrayWithCapacity:palette.count];
    for (UIColor *color in palette) {
        CGFloat r = 0.0, g = 0.0, b = 0.0, a = 1.0;
        if (![color getRed:&r green:&g blue:&b alpha:&a]) {
            CGFloat w = 0.0;
            if ([color getWhite:&w alpha:&a]) {
                r = g = b = w;
            }
        }
        [colorArrays addObject:@[@(r), @(g), @(b), @(a)]];
    }
    return @{
        @"trackName": track ?: @"",
        @"artistName": artist ?: @"",
        @"colors": [colorArrays copy]
    };
}

static NSArray<UIColor *> *deserializePaletteDict(NSDictionary *dict) {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    NSArray *rawColors = dict[@"colors"];
    if (![rawColors isKindOfClass:[NSArray class]] || rawColors.count < 3) return nil;

    NSMutableArray<UIColor *> *colors = [NSMutableArray arrayWithCapacity:rawColors.count];
    for (id entry in rawColors) {
        if (![entry isKindOfClass:[NSArray class]]) continue;
        NSArray *comps = (NSArray *)entry;
        if (comps.count < 3) continue;
        if (![comps[0] isKindOfClass:[NSNumber class]] ||
            ![comps[1] isKindOfClass:[NSNumber class]] ||
            ![comps[2] isKindOfClass:[NSNumber class]]) {
            continue;
        }
        CGFloat r = MAX(0.0, MIN(1.0, [comps[0] doubleValue]));
        CGFloat g = MAX(0.0, MIN(1.0, [comps[1] doubleValue]));
        CGFloat b = MAX(0.0, MIN(1.0, [comps[2] doubleValue]));
        CGFloat a = (comps.count >= 4 && [comps[3] isKindOfClass:[NSNumber class]])
            ? MAX(0.0, MIN(1.0, [comps[3] doubleValue]))
            : 1.0;
        [colors addObject:[UIColor colorWithRed:r green:g blue:b alpha:a]];
    }
    return (colors.count >= 3) ? [colors copy] : nil;
}

static BOOL hasJsonExtension(const char *name) {
    if (!name) return NO;
    size_t len = strlen(name);
    return (len > 5 && strcmp(name + len - 5, ".json") == 0);
}

static NSArray<NSString *> *collectJsonFilesInDir(const char *dirPath) {
    if (!dirPath) return @[];
    DIR *dir = opendir(dirPath);
    if (!dir) return @[];

    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (!hasJsonExtension(entry->d_name)) continue;
        char fullPath[512];
        snprintf(fullPath, sizeof(fullPath), "%s/%s", dirPath, entry->d_name);
        NSString *pathStr = [NSString stringWithUTF8String:fullPath];
        if (pathStr) {
            [paths addObject:pathStr];
        }
    }
    closedir(dir);
    return paths;
}

static void shuffleMutableArray(NSMutableArray *arr) {
    NSUInteger count = arr.count;
    if (count < 2) return;
    for (NSUInteger i = count - 1; i > 0; i--) {
        NSUInteger j = (NSUInteger)arc4random_uniform((uint32_t)(i + 1));
        if (i != j) {
            [arr exchangeObjectAtIndex:i withObjectAtIndex:j];
        }
    }
}

@interface LRLyricsManager ()

@property (nonatomic, copy, readwrite) NSString *currentTitle;
@property (nonatomic, copy, readwrite) NSString *currentArtist;
@property (nonatomic, copy, readwrite) NSString *currentAlbum;
@property (nonatomic, assign, readwrite) NSTimeInterval duration;
@property (nonatomic, assign, readwrite) NSTimeInterval elapsedTime;
@property (nonatomic, assign, readwrite) float playbackRate;
@property (nonatomic, assign, readwrite) BOOL isPlaying;
@property (nonatomic, strong, readwrite) LRLyricsSong *currentSong;
@property (nonatomic, assign, readwrite) BOOL isLoading;
@property (nonatomic, strong) MRContentItem *currentContentItem;

@property (nonatomic, strong) NSDate *lastTimestamp;
@property (nonatomic, strong) NSCache<NSString *, LRLyricsSong *> *lyricsCache;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSHashTable<id<LRLyricsObserver>> *observers;
@property (nonatomic, assign) BOOL isMonitoring;
@property (nonatomic, assign) BOOL isFetchingNowPlayingScheduled;
@property (nonatomic, strong) dispatch_queue_t artworkQueue;
@property (nonatomic, copy) NSString *lastArtworkFingerprint;
@property (nonatomic, strong, readwrite) NSArray<UIColor *> *currentArtworkColors;
@property (nonatomic, strong, readwrite) NSArray<UIColor *> *idleArtworkColors;
@property (nonatomic, copy) NSString *lastIdleArtworkKey;
@property (nonatomic, assign) NSInteger lastFallbackPaletteIndex;
@property (nonatomic, assign) NSUInteger idleArtworkRequestId;

@end

@implementation LRLyricsManager

+ (instancetype)sharedManager {
    static LRLyricsManager *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _observers = [NSHashTable weakObjectsHashTable];
        _lyricsCache = [[NSCache alloc] init];
        _lyricsCache.countLimit = 100;

        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 8.0;
        config.timeoutIntervalForResource = 12.0;
        _session = [NSURLSession sessionWithConfiguration:config];

        _playbackRate = 1.0f;
        _isPlaying = NO;
        _artworkQueue = dispatch_queue_create("com.locklyrics.artwork", DISPATCH_QUEUE_SERIAL);
        _lastFallbackPaletteIndex = -1;
        _idleArtworkColors = [LRColorExtractor randomFallbackPaletteAvoidingIndex:-1 outIndex:&_lastFallbackPaletteIndex];
    }
    return self;
}

- (void)addObserver:(id<LRLyricsObserver>)observer {
    if (!observer) return;
    @synchronized (self.observers) {
        [self.observers addObject:observer];
    }
}

- (void)removeObserver:(id<LRLyricsObserver>)observer {
    if (!observer) return;
    @synchronized (self.observers) {
        [self.observers removeObject:observer];
    }
}

- (void)notifySongUpdated:(LRLyricsSong *)song {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray *allObservers;
        @synchronized (self.observers) {
            allObservers = self.observers.allObjects;
        }
        for (id<LRLyricsObserver> obs in allObservers) {
            if ([obs respondsToSelector:@selector(lyricsManagerDidUpdateSong:)]) {
                [obs lyricsManagerDidUpdateSong:song];
            }
        }
    });
}

- (void)notifyPlaybackStateChanged:(BOOL)isPlaying {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray *allObservers;
        @synchronized (self.observers) {
            allObservers = self.observers.allObjects;
        }
        for (id<LRLyricsObserver> obs in allObservers) {
            if ([obs respondsToSelector:@selector(lyricsManagerDidChangePlaybackState:)]) {
                [obs lyricsManagerDidChangePlaybackState:isPlaying];
            }
        }
    });
}

- (void)notifyArtworkColorsUpdated:(NSArray<UIColor *> *)colors {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray *allObservers;
        @synchronized (self.observers) {
            allObservers = self.observers.allObjects;
        }
        for (id<LRLyricsObserver> obs in allObservers) {
            if ([obs respondsToSelector:@selector(lyricsManagerDidUpdateArtworkColors:)]) {
                [obs lyricsManagerDidUpdateArtworkColors:colors];
            }
        }
    });
}

- (void)notifyIdleArtworkColorsUpdated:(NSArray<UIColor *> *)colors {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray *allObservers;
        @synchronized (self.observers) {
            allObservers = self.observers.allObjects;
        }
        for (id<LRLyricsObserver> obs in allObservers) {
            if ([obs respondsToSelector:@selector(lyricsManagerDidUpdateIdleArtworkColors:)]) {
                [obs lyricsManagerDidUpdateIdleArtworkColors:colors];
            }
        }
    });
}

- (NSString *)fingerprintForArtworkData:(NSData *)data identifier:(NSString *)ident {
    if (ident && [ident isKindOfClass:[NSString class]] && ident.length > 0) {
        return [NSString stringWithFormat:@"id:%@:%lu", ident, (unsigned long)data.length];
    }
    NSUInteger len = data.length;
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    uint32_t s0 = 0, s1 = 0, s2 = 0;
    if (bytes && len >= 4) {
        memcpy(&s0, bytes, 4);
        memcpy(&s1, bytes + (len / 2 - 2), 4);
        memcpy(&s2, bytes + (len - 4), 4);
    }
    char buf[96];
    snprintf(buf, sizeof(buf), "len:%lu:%08x:%08x:%08x", (unsigned long)len, s0, s1, s2);
    return [NSString stringWithUTF8String:buf];
}

#pragma mark - Offline Storage (Pure POSIX)

- (LRLyricsSong *)loadOfflineSongForCacheKey:(NSString *)cacheKey {
    if (!cacheKey || cacheKey.length == 0) return nil;
    char path[512];
    offlinePathForCacheKey([cacheKey UTF8String], path, sizeof(path));
    if (!fileExists(path)) return nil;

    NSData *data = readDataFromFile(path);
    if (!data) return nil;

    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([dict isKindOfClass:[NSDictionary class]]) {
        LRLyricsSong *song = [LRLyricsSong songFromLrclibResponse:dict];
        if (song && song.hasSyncedLyrics) {
            return song;
        }
    }
    return nil;
}

- (void)saveSongToOfflineStorage:(NSDictionary *)dict forCacheKey:(NSString *)cacheKey {
    if (!dict || !cacheKey) return;
    ensureOfflineDir();

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        char path[512];
        offlinePathForCacheKey([cacheKey UTF8String], path, sizeof(path));
        NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
        if (data) {
            writeDataToFile(path, data);
        }

        // Also save human-readable .lrc file in /var/mobile/Library/LockLyrics/Lyrics/
        NSString *syncedLyrics = dict[@"syncedLyrics"];
        if (syncedLyrics && [syncedLyrics isKindOfClass:[NSString class]] && syncedLyrics.length > 0) {
            NSString *artist = dict[@"artistName"] ?: @"";
            NSString *title = dict[@"trackName"] ?: dict[@"name"] ?: @"";
            NSString *lrcBase = [NSString stringWithFormat:@"%@ - %@", artist, title];
            char lrcPath[512];
            offlinePathForCacheKey([lrcBase.lowercaseString UTF8String], lrcPath, sizeof(lrcPath));
            size_t len = strlen(lrcPath);
            if (len > 5 && strcmp(lrcPath + len - 5, ".json") == 0) {
                strcpy(lrcPath + len - 5, ".lrc");
            }
            writeStringToFile(lrcPath, [syncedLyrics UTF8String]);
        }
    });
}

#pragma mark - Monitoring

- (void)handleMediaRemoteNotification:(NSNotification *)note {
    [self fetchLatestNowPlayingInfo];
}

- (void)startMonitoring {
    if (self.isMonitoring) return;
    self.isMonitoring = YES;

    MRMediaRemoteRegisterForNowPlayingNotifications(dispatch_get_main_queue());

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self
           selector:@selector(handleMediaRemoteNotification:)
               name:kMRMediaRemoteNowPlayingInfoDidChangeNotification
             object:nil];
    [nc addObserver:self
           selector:@selector(handleMediaRemoteNotification:)
               name:kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification
             object:nil];
    [nc addObserver:self
           selector:@selector(handleMediaRemoteNotification:)
               name:kMRMediaRemoteNowPlayingApplicationPlaybackStateDidChangeNotification
             object:nil];
    [nc addObserver:self
           selector:@selector(handleMediaRemoteNotification:)
               name:kMRMediaRemoteNowPlayingPlaybackQueueDidChangeNotification
             object:nil];

    [self refreshRandomIdleArtwork];
    [self fetchLatestNowPlayingInfo];
}

- (void)stopMonitoring {
    if (!self.isMonitoring) return;
    self.isMonitoring = NO;

    [[NSNotificationCenter defaultCenter] removeObserver:self];
    MRMediaRemoteUnregisterForNowPlayingNotifications();
}

@synthesize nowPlayingBundleID = _nowPlayingBundleID;

- (NSString *)effectiveNowPlayingBundleID {
    if (_nowPlayingBundleID && _nowPlayingBundleID.length > 0) {
        return _nowPlayingBundleID;
    }
    if ([NSThread isMainThread]) {
        Class sbClass = NSClassFromString(@"SBMediaController");
        if (sbClass && [sbClass respondsToSelector:@selector(sharedInstance)]) {
            SBMediaController *mc = [sbClass sharedInstance];
            if (mc && [mc respondsToSelector:@selector(nowPlayingApplication)]) {
                id app = [mc nowPlayingApplication];
                if (app && [app respondsToSelector:@selector(bundleIdentifier)]) {
                    _nowPlayingBundleID = [app bundleIdentifier];
                    return _nowPlayingBundleID;
                }
            }
        }
    }
    return nil;
}

- (BOOL)isCurrentAppAllowed {
    NSString *bundleID = [self effectiveNowPlayingBundleID];
    return [[LRPreferences sharedPreferences] isAppAllowed:bundleID];
}

- (void)clearDisallowedAppLyrics {
    self.currentTitle = nil;
    self.currentArtist = nil;
    self.currentAlbum = nil;
    self.currentSong = nil;
    self.currentContentItem = nil;
    self.lastArtworkFingerprint = nil;
    self.currentArtworkColors = nil;
    self.isLoading = NO;
    [self notifySongUpdated:nil];
    [self notifyArtworkColorsUpdated:nil];
}

- (void)checkAppAllowanceAndSync {
    if (![self isCurrentAppAllowed]) {
        [self clearDisallowedAppLyrics];
    }
}

- (void)setNowPlayingBundleID:(NSString *)bundleID {
    if ((!_nowPlayingBundleID && !bundleID) || [_nowPlayingBundleID isEqualToString:bundleID]) {
        return;
    }
    _nowPlayingBundleID = [bundleID copy];
    if (![self isCurrentAppAllowed]) {
        [self clearDisallowedAppLyrics];
    }
}

- (void)fetchLatestNowPlayingInfo {
    if (self.isFetchingNowPlayingScheduled) return;
    self.isFetchingNowPlayingScheduled = YES;

    dispatch_async(dispatch_get_main_queue(), ^{
        self.isFetchingNowPlayingScheduled = NO;
        [self _performFetchLatestNowPlayingInfo];
    });
}

- (void)_performFetchLatestNowPlayingInfo {
    MRMediaRemoteGetNowPlayingApplicationDisplayID(dispatch_get_main_queue(), ^(CFStringRef displayID) {
        if (displayID) {
            NSString *bID = (__bridge NSString *)displayID;
            if (![_nowPlayingBundleID isEqualToString:bID]) {
                _nowPlayingBundleID = [bID copy];
                if (![self isCurrentAppAllowed]) {
                    [self clearDisallowedAppLyrics];
                }
            }
        }
    });

    if (![self isCurrentAppAllowed]) {
        [self clearDisallowedAppLyrics];
        return;
    }

    MRMediaRemoteGetNowPlayingInfo(dispatch_get_main_queue(), ^(CFDictionaryRef information) {
        if (!information) {
            if (!self.isPlaying) {
                [self clearCurrentSong];
            }
            return;
        }
        NSDictionary *dict = (__bridge NSDictionary *)information;
        if (dict.count == 0 && !self.isPlaying) {
            [self clearCurrentSong];
            return;
        }
        [self updateWithInfoDictionary:dict];
    });

    MRMediaRemoteGetNowPlayingApplicationIsPlaying(dispatch_get_main_queue(), ^(Boolean isPlaying) {
        [self updatePlaybackState:(BOOL)isPlaying];
    });
}

- (void)updateWithInfoDictionary:(NSDictionary *)info {
    if (!info || ![info isKindOfClass:[NSDictionary class]]) {
        return;
    }

    if (![self isCurrentAppAllowed]) {
        [self clearDisallowedAppLyrics];
        return;
    }

    @try {
        Class itemClass = NSClassFromString(@"MRContentItem");
        if (itemClass && [itemClass instancesRespondToSelector:@selector(initWithNowPlayingInfo:)]) {
            self.currentContentItem = [[itemClass alloc] initWithNowPlayingInfo:info];
        }
    } @catch (NSException *e) {
        self.currentContentItem = nil;
    }

    NSString *title = info[kMRMediaRemoteNowPlayingInfoTitle];
    NSString *artist = info[kMRMediaRemoteNowPlayingInfoArtist];
    NSString *album = info[kMRMediaRemoteNowPlayingInfoAlbum];
    NSNumber *durationNum = info[kMRMediaRemoteNowPlayingInfoDuration];
    NSNumber *elapsedNum = info[kMRMediaRemoteNowPlayingInfoElapsedTime];
    NSNumber *rateNum = info[kMRMediaRemoteNowPlayingInfoPlaybackRate];
    NSDate *timestamp = info[kMRMediaRemoteNowPlayingInfoTimestamp];

    if (rateNum) {
        self.playbackRate = [rateNum floatValue];
        BOOL isPlaying = (self.playbackRate > 0.001f);
        [self updatePlaybackState:isPlaying];
    }

    if (durationNum) self.duration = [durationNum doubleValue];

    if (elapsedNum) {
        NSTimeInterval rawElapsed = [elapsedNum doubleValue];
        NSTimeInterval timeSinceSnapshot = 0.0;
        if (self.isPlaying && timestamp && [timestamp isKindOfClass:[NSDate class]]) {
            NSTimeInterval diff = [[NSDate date] timeIntervalSinceDate:timestamp];
            if (diff > 0.0 && diff < 7200.0) {
                timeSinceSnapshot = diff;
            }
        }
        float effectiveRate = (self.playbackRate > 0.001f) ? self.playbackRate : 1.0f;
        self.elapsedTime = rawElapsed + (timeSinceSnapshot * (NSTimeInterval)effectiveRate);
        self.lastTimestamp = [NSDate date];
    }

    NSData *artworkData = info[kMRMediaRemoteNowPlayingInfoArtworkData];
    NSString *artworkId = info[kMRMediaRemoteNowPlayingInfoArtworkIdentifier];
    BOOL hasValidArtworkData = (artworkData && [artworkData isKindOfClass:[NSData class]] && artworkData.length > 0);

    // Update track metadata before extracting artwork so saved palettes use the active track & artist
    if (title && [title isKindOfClass:[NSString class]] && title.length > 0) {
        if (artist && ![artist isKindOfClass:[NSString class]]) {
            artist = nil;
        }
        if (album && ![album isKindOfClass:[NSString class]]) {
            album = nil;
        }

        BOOL songChanged = ![title isEqualToString:self.currentTitle] ||
                           ((artist || self.currentArtist) && ![artist isEqualToString:self.currentArtist]);

        if (songChanged) {
            self.currentTitle = title;
            self.currentArtist = artist;
            self.currentAlbum = album;
            if (!hasValidArtworkData) {
                self.lastArtworkFingerprint = nil;
                if (!self.currentArtworkColors) {
                    self.currentArtworkColors = [LRColorExtractor defaultPalette];
                    [self notifyArtworkColorsUpdated:self.currentArtworkColors];
                }
            }
            // Clear current song immediately so old song lyrics never persist!
            self.currentSong = nil;
            [self fetchLyricsForTrack:title artist:artist album:album duration:self.duration];
        } else {
            [self notifyPlaybackStateChanged:self.isPlaying];
        }
    } else {
        // Metadata packet without title (e.g. play/pause/elapsed updates): keep currentSong!
        [self notifyPlaybackStateChanged:self.isPlaying];
    }

    // Process Now Playing Artwork for dynamic mesh gradient wallpaper & persistent idle cache
    if (hasValidArtworkData) {
        NSString *fp = [self fingerprintForArtworkData:artworkData identifier:artworkId];
        if (![fp isEqualToString:self.lastArtworkFingerprint]) {
            self.lastArtworkFingerprint = fp;
            NSData *dataCopy = [artworkData copy];
            NSString *saveTitle = [self.currentTitle copy];
            NSString *saveArtist = [self.currentArtist copy];
            __weak typeof(self) weakSelf = self;
            dispatch_async(self.artworkQueue, ^{
                NSArray<UIColor *> *palette = [LRColorExtractor extractPaletteFromImageData:dataCopy];
                if (saveTitle.length > 0 && palette.count > 0) {
                    ensureOfflineArtworkDir();
                    NSString *artKey = artworkKeyForTrackAndArtist(saveTitle, saveArtist);
                    char artPath[512];
                    artworkPathForKey([artKey UTF8String], artPath, sizeof(artPath));
                    NSDictionary *artDict = serializePaletteDict(palette, saveTitle, saveArtist);
                    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:artDict options:0 error:nil];
                    if (jsonData) {
                        writeDataToFile(artPath, jsonData);
                    }
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    if (!strongSelf || ![strongSelf.lastArtworkFingerprint isEqualToString:fp]) {
                        return;
                    }
                    strongSelf.currentArtworkColors = palette;
                    [strongSelf notifyArtworkColorsUpdated:palette];
                });
            });
        }
    }
}

#pragma mark - Idle Random Song Artwork Cache & Bootstrap

- (void)applyIdleFallbackAvoidingIndex:(NSInteger)avoidIdx forRequest:(NSUInteger)reqId {
    NSInteger newIdx = -1;
    NSArray<UIColor *> *fallback = [LRColorExtractor randomFallbackPaletteAvoidingIndex:avoidIdx outIndex:&newIdx];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.idleArtworkRequestId != reqId) return;
        strongSelf.lastFallbackPaletteIndex = newIdx;
        strongSelf.idleArtworkColors = fallback;
        [strongSelf notifyIdleArtworkColorsUpdated:fallback];
    });
}

- (void)fetchItunesArtworkAndCacheForTrack:(NSString *)track
                                    artist:(NSString *)artist
                                artworkKey:(NSString *)artKey
                               artworkPath:(NSString *)artPath
                                 requestId:(NSUInteger)reqId {
    if (!track || track.length == 0 || !artPath || artPath.length == 0) return;

    NSString *query = (artist && artist.length > 0)
        ? [NSString stringWithFormat:@"%@ %@", track, artist]
        : track;
    NSString *urlString = [NSString stringWithFormat:@"https://itunes.apple.com/search?term=%@&media=music&entity=song&limit=3", urlEncodeParam(query)];
    NSURL *searchUrl = [NSURL URLWithString:urlString];
    if (!searchUrl) return;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:searchUrl];
    [req setValue:@"LockLyrics-iOS/1.0" forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *searchTask = [self.session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
        if (error || !data || httpResp.statusCode != 200) return;

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![json isKindOfClass:[NSDictionary class]]) return;
        NSArray *results = json[@"results"];
        if (![results isKindOfClass:[NSArray class]] || results.count == 0) return;

        NSString *artworkUrlStr = nil;
        for (id item in results) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSString *candidateUrl = item[@"artworkUrl100"];
            if ([candidateUrl isKindOfClass:[NSString class]] && candidateUrl.length > 0) {
                artworkUrlStr = candidateUrl;
                break;
            }
        }
        if (!artworkUrlStr) return;

        NSURL *imgUrl = [NSURL URLWithString:artworkUrlStr];
        if (!imgUrl) return;

        NSURLSessionDataTask *imgTask = [weakSelf.session dataTaskWithURL:imgUrl completionHandler:^(NSData *imgData, NSURLResponse *imgResp, NSError *imgErr) {
            NSHTTPURLResponse *imgHttp = (NSHTTPURLResponse *)imgResp;
            if (imgErr || !imgData || imgData.length == 0 || imgHttp.statusCode != 200) return;

            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            dispatch_async(strongSelf.artworkQueue, ^{
                NSArray<UIColor *> *fetchedPalette = [LRColorExtractor extractPaletteFromImageData:imgData];
                if (fetchedPalette.count < 3) return;

                ensureOfflineArtworkDir();
                NSDictionary *artDict = serializePaletteDict(fetchedPalette, track, artist);
                NSData *jsonData = [NSJSONSerialization dataWithJSONObject:artDict options:0 error:nil];
                if (jsonData) {
                    writeDataToFile([artPath UTF8String], jsonData);
                }

                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) mainSelf = weakSelf;
                    if (!mainSelf || mainSelf.idleArtworkRequestId != reqId) return;
                    mainSelf.lastIdleArtworkKey = artKey;
                    mainSelf.idleArtworkColors = fetchedPalette;
                    [mainSelf notifyIdleArtworkColorsUpdated:fetchedPalette];
                });
            });
        }];
        [imgTask resume];
    }];
    [searchTask resume];
}

- (void)refreshRandomIdleArtwork {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshRandomIdleArtwork];
        });
        return;
    }

    NSUInteger reqId = ++self.idleArtworkRequestId;
    NSString *avoidKey = [self.lastIdleArtworkKey copy];
    NSInteger prevFallbackIdx = self.lastFallbackPaletteIndex;

    __weak typeof(self) weakSelf = self;
    dispatch_async(self.artworkQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        NSArray<NSString *> *artworkFiles = collectJsonFilesInDir(kOfflineArtworkDir);
        NSArray<NSString *> *lyricsFiles = collectJsonFilesInDir(kOfflineLyricsDir);
        NSMutableDictionary<NSString *, NSDictionary *> *candidatesByKey = [NSMutableDictionary dictionary];

        for (NSString *lrcPath in lyricsFiles) {
            NSData *data = readDataFromFile([lrcPath UTF8String]);
            if (!data) continue;
            NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![dict isKindOfClass:[NSDictionary class]]) continue;
            NSString *trackName = dict[@"trackName"] ?: dict[@"name"];
            if (![trackName isKindOfClass:[NSString class]] || trackName.length == 0) continue;
            NSString *artistName = [dict[@"artistName"] isKindOfClass:[NSString class]] ? dict[@"artistName"] : @"";
            NSString *key = artworkKeyForTrackAndArtist(trackName, artistName);
            char artPath[512];
            artworkPathForKey([key UTF8String], artPath, sizeof(artPath));
            NSString *artPathStr = [NSString stringWithUTF8String:artPath];
            if (!artPathStr) continue;
            candidatesByKey[key] = @{
                @"key": key,
                @"track": trackName,
                @"artist": artistName,
                @"artPath": artPathStr
            };
        }

        for (NSString *artJsonPath in artworkFiles) {
            NSData *data = readDataFromFile([artJsonPath UTF8String]);
            if (!data) continue;
            NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![dict isKindOfClass:[NSDictionary class]]) continue;
            NSString *trackName = [dict[@"trackName"] isKindOfClass:[NSString class]] ? dict[@"trackName"] : @"";
            NSString *artistName = [dict[@"artistName"] isKindOfClass:[NSString class]] ? dict[@"artistName"] : @"";
            NSString *key = (trackName.length > 0) ? artworkKeyForTrackAndArtist(trackName, artistName) : artJsonPath;
            candidatesByKey[key] = @{
                @"key": key,
                @"track": trackName,
                @"artist": artistName,
                @"artPath": artJsonPath
            };
        }

        NSMutableArray<NSDictionary *> *candidates = [candidatesByKey.allValues mutableCopy];
        if (candidates.count == 0) {
            [strongSelf applyIdleFallbackAvoidingIndex:prevFallbackIdx forRequest:reqId];
            return;
        }

        if (candidates.count > 1 && avoidKey.length > 0) {
            NSMutableArray<NSDictionary *> *filtered = [NSMutableArray arrayWithCapacity:candidates.count];
            for (NSDictionary *c in candidates) {
                if (![c[@"key"] isEqualToString:avoidKey]) {
                    [filtered addObject:c];
                }
            }
            if (filtered.count > 0) {
                candidates = filtered;
            }
        }
        shuffleMutableArray(candidates);

        NSDictionary *chosen = candidates[0];
        NSString *chosenArtPath = chosen[@"artPath"];
        if (chosenArtPath.length > 0 && fileExists([chosenArtPath UTF8String])) {
            NSData *data = readDataFromFile([chosenArtPath UTF8String]);
            NSDictionary *dict = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSArray<UIColor *> *palette = deserializePaletteDict(dict);
            if (palette.count >= 3) {
                NSString *chosenKey = chosen[@"key"];
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) mainSelf = weakSelf;
                    if (!mainSelf || mainSelf.idleArtworkRequestId != reqId) return;
                    mainSelf.lastIdleArtworkKey = chosenKey;
                    mainSelf.idleArtworkColors = palette;
                    [mainSelf notifyIdleArtworkColorsUpdated:palette];
                });
                return;
            }
        }

        // Chosen song lacks cached artwork palette yet: show any other cached song palette (or vibrant fallback) immediately
        BOOL appliedImmediate = NO;
        for (NSUInteger i = 1; i < candidates.count; i++) {
            NSDictionary *alt = candidates[i];
            NSString *altPath = alt[@"artPath"];
            if (altPath.length == 0 || !fileExists([altPath UTF8String])) continue;
            NSData *data = readDataFromFile([altPath UTF8String]);
            NSDictionary *dict = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSArray<UIColor *> *altPalette = deserializePaletteDict(dict);
            if (altPalette.count >= 3) {
                NSString *altKey = alt[@"key"];
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) mainSelf = weakSelf;
                    if (!mainSelf || mainSelf.idleArtworkRequestId != reqId) return;
                    mainSelf.lastIdleArtworkKey = altKey;
                    mainSelf.idleArtworkColors = altPalette;
                    [mainSelf notifyIdleArtworkColorsUpdated:altPalette];
                });
                appliedImmediate = YES;
                break;
            }
        }
        if (!appliedImmediate) {
            [strongSelf applyIdleFallbackAvoidingIndex:prevFallbackIdx forRequest:reqId];
        }

        [strongSelf fetchItunesArtworkAndCacheForTrack:chosen[@"track"]
                                                artist:chosen[@"artist"]
                                            artworkKey:chosen[@"key"]
                                           artworkPath:chosenArtPath
                                             requestId:reqId];
    });
}

- (void)clearCurrentSong {
    if (self.isPlaying) return;
    self.currentTitle = nil;
    self.currentArtist = nil;
    self.currentAlbum = nil;
    self.currentSong = nil;
    self.currentContentItem = nil;
    self.lastArtworkFingerprint = nil;
    self.currentArtworkColors = nil;
    [self notifySongUpdated:nil];
    [self notifyArtworkColorsUpdated:nil];
}

- (void)updatePlaybackState:(BOOL)isPlaying {
    if (self.isPlaying != isPlaying) {
        if (!isPlaying) {
            // Freezing playback: record elapsed time so far
            self.elapsedTime = [self currentEstimatedPlaybackTime];
        } else {
            if (self.playbackRate <= 0.001f) {
                self.playbackRate = 1.0f;
            }
        }
        self.isPlaying = isPlaying;
        self.lastTimestamp = [NSDate date];
        [self notifyPlaybackStateChanged:isPlaying];
    }
}

#pragma mark - LRCLIB API Request (Synced Lyrics Only + Offline Cache)

- (NSString *)cacheKeyForTrack:(NSString *)track artist:(NSString *)artist {
    NSInteger prov = (NSInteger)[LRPreferences sharedPreferences].lyricsProvider;
    return [NSString stringWithFormat:@"v2_%ld_%@||%@", (long)prov, (artist ?: @""), (track ?: @"")].lowercaseString;
}

- (void)fetchLyricsForTrack:(NSString *)track artist:(NSString *)artist album:(NSString *)album duration:(NSTimeInterval)duration {
    if (!track || track.length == 0 || ![self isCurrentAppAllowed]) {
        self.currentSong = nil;
        self.isLoading = NO;
        [self notifySongUpdated:nil];
        return;
    }

    NSString *cacheKey = [self cacheKeyForTrack:track artist:artist];

    // 1. Check fast in-memory cache
    LRLyricsSong *cached = [self.lyricsCache objectForKey:cacheKey];
    if (cached && cached.hasSyncedLyrics) {
        self.currentSong = cached;
        self.isLoading = NO;
        [self notifySongUpdated:self.currentSong];
        return;
    }

    // 2. Check offline persistent storage (0ms instant response)
    LRLyricsSong *offlineSong = [self loadOfflineSongForCacheKey:cacheKey];
    if (offlineSong && offlineSong.hasSyncedLyrics) {
        [self.lyricsCache setObject:offlineSong forKey:cacheKey];
        self.currentSong = offlineSong;
        self.isLoading = NO;
        [self notifySongUpdated:self.currentSong];
        return;
    }

    // 3. Not cached yet: fetch according to selected provider
    self.isLoading = YES;
    self.currentSong = nil;
    [self notifySongUpdated:nil];

    LRLyricsProvider provider = [LRPreferences sharedPreferences].lyricsProvider;
    if (provider == LRLyricsProviderSpicyLyrics) {
        [self fetchLyricsFromSpicyLyricsForTrack:track artist:artist album:album duration:duration cacheKey:cacheKey];
    } else if (provider == LRLyricsProviderLrcRed) {
        [self fetchLyricsFromLrcRedForTrack:track artist:artist album:album duration:duration cacheKey:cacheKey];
    } else if (provider == LRLyricsProviderMusixmatch) {
        [self fetchLyricsFromMusixmatchForTrack:track artist:artist album:album duration:duration cacheKey:cacheKey];
    } else {
        [self fetchLyricsFromLrclibForTrack:track artist:artist album:album duration:duration cacheKey:cacheKey];
    }
}

#pragma mark - SpicyLyrics API Request (With LRCLIB Fallback)

- (void)fetchLyricsFromSpicyLyricsForTrack:(NSString *)track artist:(NSString *)artist album:(NSString *)album duration:(NSTimeInterval)duration cacheKey:(NSString *)cacheKey {
    NSString *apiKey = [LRPreferences sharedPreferences].spicyLyricsApiKey;
    if (!apiKey) apiKey = @"";
    apiKey = [apiKey stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (apiKey.length == 0) {
        // No SpicyLyrics API key entered: gracefully fall back to LRCLIB
        [self fetchLyricsFromLrclibForTrack:track artist:artist album:album duration:duration cacheKey:cacheKey];
        return;
    }

    // Step 1: Search track to obtain track ID
    NSString *qTitle = urlEncodeParam(track);
    NSMutableString *searchUrlString = [NSMutableString stringWithFormat:@"https://api.spicylyrics.org/v1/tracks/search?title=%@", qTitle];
    if (artist && artist.length > 0) {
        [searchUrlString appendFormat:@"&artist=%@", urlEncodeParam(artist)];
    }
    if (album && album.length > 0) {
        [searchUrlString appendFormat:@"&album=%@", urlEncodeParam(album)];
    }
    if (duration > 0) {
        [searchUrlString appendFormat:@"&duration=%d", (int)duration];
    }
    [searchUrlString appendString:@"&limit=1"];

    NSURL *searchUrl = [NSURL URLWithString:searchUrlString];
    if (!searchUrl) {
        [self fetchLyricsFromLrclibForTrack:track artist:artist album:album duration:duration cacheKey:cacheKey];
        return;
    }

    NSMutableURLRequest *searchReq = [NSMutableURLRequest requestWithURL:searchUrl];
    [searchReq setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];
    [searchReq setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [searchReq setValue:@"LockLyrics-iOS/1.0" forHTTPHeaderField:@"User-Agent"];

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *searchTask = [self.session dataTaskWithRequest:searchReq completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (error || !data || httpResponse.statusCode != 200) {
            [weakSelf fetchLyricsFromLrclibForTrack:track artist:artist album:album duration:duration cacheKey:cacheKey];
            return;
        }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![json isKindOfClass:[NSDictionary class]]) {
            [weakSelf fetchLyricsFromLrclibForTrack:track artist:artist album:album duration:duration cacheKey:cacheKey];
            return;
        }

        NSArray *results = json[@"Body"][@"results"] ?: json[@"results"];
        if (![results isKindOfClass:[NSArray class]] || results.count == 0) {
            [weakSelf fetchLyricsFromLrclibForTrack:track artist:artist album:album duration:duration cacheKey:cacheKey];
            return;
        }

        NSDictionary *firstItem = results[0];
        NSString *trackId = firstItem[@"id"];
        if (!trackId || ![trackId isKindOfClass:[NSString class]] || trackId.length == 0) {
            [weakSelf fetchLyricsFromLrclibForTrack:track artist:artist album:album duration:duration cacheKey:cacheKey];
            return;
        }

        // Step 2: Fetch synced lyrics with trackId
        NSString *lyricsUrlString = [NSString stringWithFormat:@"https://api.spicylyrics.org/v1/lyrics/%@", urlEncodeParam(trackId)];
        NSURL *lyricsUrl = [NSURL URLWithString:lyricsUrlString];
        if (!lyricsUrl) {
            [weakSelf fetchLyricsFromLrclibForTrack:track artist:artist album:album duration:duration cacheKey:cacheKey];
            return;
        }

        NSMutableURLRequest *lyricsReq = [NSMutableURLRequest requestWithURL:lyricsUrl];
        [lyricsReq setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];
        [lyricsReq setValue:@"application/json" forHTTPHeaderField:@"Accept"];
        [lyricsReq setValue:@"LockLyrics-iOS/1.0" forHTTPHeaderField:@"User-Agent"];

        NSURLSessionDataTask *lyricsTask = [weakSelf.session dataTaskWithRequest:lyricsReq completionHandler:^(NSData *lData, NSURLResponse *lResp, NSError *lErr) {
            NSHTTPURLResponse *lHttp = (NSHTTPURLResponse *)lResp;
            if (lErr || !lData || lHttp.statusCode != 200) {
                [weakSelf fetchLyricsFromLrclibForTrack:track artist:artist album:album duration:duration cacheKey:cacheKey];
                return;
            }

            NSDictionary *lJson = [NSJSONSerialization JSONObjectWithData:lData options:0 error:nil];
            if (![lJson isKindOfClass:[NSDictionary class]]) {
                [weakSelf fetchLyricsFromLrclibForTrack:track artist:artist album:album duration:duration cacheKey:cacheKey];
                return;
            }

            NSDictionary *body = lJson[@"Body"] ?: lJson;
            NSString *type = body[@"Type"];
            NSArray *content = body[@"Content"];
            if (![content isKindOfClass:[NSArray class]] || content.count == 0) {
                [weakSelf fetchLyricsFromLrclibForTrack:track artist:artist album:album duration:duration cacheKey:cacheKey];
                return;
            }

            NSMutableArray<LRLyricLine *> *parsedLines = [NSMutableArray array];
            NSMutableString *lrcString = [NSMutableString string];

            if ([type isEqualToString:@"Line"]) {
                for (NSDictionary *lineDict in content) {
                    if (![lineDict isKindOfClass:[NSDictionary class]]) continue;
                    NSTimeInterval time = [lineDict[@"StartTime"] doubleValue];
                    NSString *lineText = lineDict[@"Text"];
                    if (lineText && [lineText isKindOfClass:[NSString class]]) {
                        lineText = [lineText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    } else {
                        lineText = @"";
                    }
                    if (lineText.length == 0) lineText = @"•••";
                    [parsedLines addObject:[[LRLyricLine alloc] initWithTime:time text:lineText]];
                    int lrcMin = (int)(time / 60.0);
                    double lrcSec = time - (lrcMin * 60.0);
                    [lrcString appendFormat:@"[%02d:%05.2f] %@\n", lrcMin, lrcSec, lineText];
                }
            } else if ([type isEqualToString:@"Syllable"]) {
                for (NSDictionary *lineDict in content) {
                    if (![lineDict isKindOfClass:[NSDictionary class]]) continue;
                    NSDictionary *lead = lineDict[@"Lead"];
                    if (![lead isKindOfClass:[NSDictionary class]]) continue;

                    NSTimeInterval time = [lead[@"StartTime"] doubleValue];
                    NSArray *syllables = lead[@"Syllables"];
                    NSMutableString *lineText = [NSMutableString string];
                    if ([syllables isKindOfClass:[NSArray class]]) {
                        for (NSDictionary *s in syllables) {
                            if (![s isKindOfClass:[NSDictionary class]]) continue;
                            NSString *st = s[@"Text"];
                            if (!st || ![st isKindOfClass:[NSString class]] || st.length == 0) continue;

                            [lineText appendString:st];

                            // Check IsPartOfWord flag:
                            // If YES, this syllable connects directly to the next syllable (e.g. "to" -> "gether").
                            // If NO (or missing), this syllable completes a word, so append a space.
                            BOOL isPartOfWord = NO;
                            id ipow = s[@"IsPartOfWord"];
                            if (ipow && [ipow isKindOfClass:[NSNumber class]]) {
                                isPartOfWord = [ipow boolValue];
                            }

                            if (!isPartOfWord && ![lineText hasSuffix:@" "]) {
                                [lineText appendString:@" "];
                            }
                        }
                    }
                    if (lineText.length == 0) {
                        NSString *t = lead[@"Text"] ?: lineDict[@"Text"];
                        if (t && [t isKindOfClass:[NSString class]]) {
                            [lineText appendString:t];
                        }
                    }
                    NSString *clean = [lineText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    // Clean up extraneous whitespace before punctuation
                    clean = [clean stringByReplacingOccurrencesOfString:@" ," withString:@","];
                    clean = [clean stringByReplacingOccurrencesOfString:@" ." withString:@"."];
                    clean = [clean stringByReplacingOccurrencesOfString:@" !" withString:@"!"];
                    clean = [clean stringByReplacingOccurrencesOfString:@" ?" withString:@"?"];
                    clean = [clean stringByReplacingOccurrencesOfString:@" ;" withString:@";"];
                    clean = [clean stringByReplacingOccurrencesOfString:@" :" withString:@":"];
                    clean = [clean stringByReplacingOccurrencesOfString:@" )" withString:@")"];
                    clean = [clean stringByReplacingOccurrencesOfString:@"( " withString:@"("];
                    clean = [clean stringByReplacingOccurrencesOfString:@" ’" withString:@"’"];
                    clean = [clean stringByReplacingOccurrencesOfString:@" '" withString:@"'"];
                    while ([clean containsString:@"  "]) {
                        clean = [clean stringByReplacingOccurrencesOfString:@"  " withString:@" "];
                    }
                    if (clean.length == 0) clean = @"•••";
                    [parsedLines addObject:[[LRLyricLine alloc] initWithTime:time text:clean]];
                    int lrcMin = (int)(time / 60.0);
                    double lrcSec = time - (lrcMin * 60.0);
                    [lrcString appendFormat:@"[%02d:%05.2f] %@\n", lrcMin, lrcSec, clean];
                }
            }

            if (parsedLines.count > 0) {
                [parsedLines sortUsingComparator:^NSComparisonResult(LRLyricLine *a, LRLyricLine *b) {
                    if (a.time < b.time) return NSOrderedAscending;
                    if (a.time > b.time) return NSOrderedDescending;
                    return NSOrderedSame;
                }];

                LRLyricsSong *song = [[LRLyricsSong alloc] init];
                song.trackName = [track copy];
                song.artistName = [artist copy];
                song.albumName = [album copy];
                song.duration = duration;
                song.lines = [parsedLines copy];
                song.hasSyncedLyrics = YES;
                song.plainLyrics = lrcString;

                NSDictionary *saveDict = @{
                    @"trackName": track ?: @"",
                    @"artistName": artist ?: @"",
                    @"albumName": album ?: @"",
                    @"duration": @(duration),
                    @"syncedLyrics": lrcString
                };
                [weakSelf handleLyricsSuccess:song rawDict:saveDict forCacheKey:cacheKey track:track artist:artist];
            } else {
                [weakSelf fetchLyricsFromLrclibForTrack:track artist:artist album:album duration:duration cacheKey:cacheKey];
            }
        }];
        [lyricsTask resume];
    }];
    [searchTask resume];
}

#pragma mark - lrc.red API Request (With LRCLIB Fallback)

- (void)fetchLyricsFromLrcRedForTrack:(NSString *)track artist:(NSString *)artist album:(NSString *)album duration:(NSTimeInterval)duration cacheKey:(NSString *)cacheKey {
    NSString *query = (artist && artist.length > 0) ? [NSString stringWithFormat:@"%@ %@", track, artist] : track;
    NSString *encodedQuery = urlEncodeParam(query);
    NSString *urlString = [NSString stringWithFormat:@"https://lrc.red/search.json?q=%@", encodedQuery];

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        [self fetchLyricsFromLrclibForTrack:track artist:artist album:album duration:duration cacheKey:cacheKey];
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15" forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *searchTask = [self.session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (error || !data || httpResponse.statusCode != 200) {
            [weakSelf fetchLyricsFromLrclibForTrack:track artist:artist album:album duration:duration cacheKey:cacheKey];
            return;
        }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![json isKindOfClass:[NSDictionary class]]) {
            [weakSelf fetchLyricsFromLrclibForTrack:track artist:artist album:album duration:duration cacheKey:cacheKey];
            return;
        }

        NSArray *hits = json[@"hits"];
        if (![hits isKindOfClass:[NSArray class]] || hits.count == 0) {
            [weakSelf fetchLyricsFromLrclibForTrack:track artist:artist album:album duration:duration cacheKey:cacheKey];
            return;
        }

        // Pick best matching hit: if duration > 0, find hit with closest duration
        NSDictionary *bestHit = hits[0];
        if (duration > 0 && hits.count > 1) {
            double bestDiff = 999999.0;
            for (NSDictionary *hit in hits) {
                if (![hit isKindOfClass:[NSDictionary class]]) continue;
                NSNumber *dNum = hit[@"duration"];
                if (dNum) {
                    double diff = fabs([dNum doubleValue] - duration);
                    if (diff < bestDiff) {
                        bestDiff = diff;
                        bestHit = hit;
                    }
                }
            }
        }

        NSString *isrc = bestHit[@"isrc"];
        if (!isrc || ![isrc isKindOfClass:[NSString class]] || isrc.length == 0) {
            [weakSelf fetchLyricsFromLrclibForTrack:track artist:artist album:album duration:duration cacheKey:cacheKey];
            return;
        }

        // Fetch .lrc directly
        NSString *lrcUrlString = [NSString stringWithFormat:@"https://lrc.red/s/%@.lrc", urlEncodeParam(isrc)];
        NSURL *lrcUrl = [NSURL URLWithString:lrcUrlString];
        if (!lrcUrl) {
            [weakSelf fetchLyricsFromLrclibForTrack:track artist:artist album:album duration:duration cacheKey:cacheKey];
            return;
        }

        NSMutableURLRequest *lrcReq = [NSMutableURLRequest requestWithURL:lrcUrl];
        [lrcReq setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15" forHTTPHeaderField:@"User-Agent"];

        NSURLSessionDataTask *lrcTask = [weakSelf.session dataTaskWithRequest:lrcReq completionHandler:^(NSData *lrcData, NSURLResponse *lrcResp, NSError *lrcErr) {
            NSHTTPURLResponse *lrcHttp = (NSHTTPURLResponse *)lrcResp;
            if (lrcErr || !lrcData || lrcHttp.statusCode != 200) {
                [weakSelf fetchLyricsFromLrclibForTrack:track artist:artist album:album duration:duration cacheKey:cacheKey];
                return;
            }

            NSString *lrcContent = [[NSString alloc] initWithData:lrcData encoding:NSUTF8StringEncoding];
            if (!lrcContent || lrcContent.length == 0) {
                [weakSelf fetchLyricsFromLrclibForTrack:track artist:artist album:album duration:duration cacheKey:cacheKey];
                return;
            }

            LRLyricsSong *song = [LRLyricsSong songFromLrcString:lrcContent track:track artist:artist album:album duration:duration];
            if (song && song.hasSyncedLyrics) {
                NSDictionary *saveDict = @{
                    @"trackName": track ?: @"",
                    @"artistName": artist ?: @"",
                    @"albumName": album ?: @"",
                    @"duration": @(duration),
                    @"syncedLyrics": lrcContent
                };
                [weakSelf handleLyricsSuccess:song rawDict:saveDict forCacheKey:cacheKey track:track artist:artist];
            } else {
                [weakSelf fetchLyricsFromLrclibForTrack:track artist:artist album:album duration:duration cacheKey:cacheKey];
            }
        }];
        [lrcTask resume];
    }];
    [searchTask resume];
}

#pragma mark - Musixmatch API Request (With LRCLIB Fallback)

static void parseMusixmatchToken(NSString *rawInput, NSString **outUserToken, NSString **outAppId, NSString **outCookieHeader) {
    if (!rawInput || rawInput.length == 0) {
        if (outUserToken) *outUserToken = @"";
        if (outAppId) *outAppId = @"web-desktop-app-v1.0";
        if (outCookieHeader) *outCookieHeader = nil;
        return;
    }

    NSString *s = [rawInput stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (s.length >= 2 && (([s hasPrefix:@"\""] && [s hasSuffix:@"\""]) || ([s hasPrefix:@"'"] && [s hasSuffix:@"'"]))) {
        s = [s substringWithRange:NSMakeRange(1, s.length - 2)];
        s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }

    NSString *cookieHeader = nil;
    if ([s containsString:@"musixmatchUserToken="] || [s containsString:@"aws-waf-token="]) {
        cookieHeader = s;
    }

    NSString *jsonStr = s;
    if ([s containsString:@"musixmatchUserToken="]) {
        NSRange range = [s rangeOfString:@"musixmatchUserToken="];
        NSString *after = [s substringFromIndex:range.location + range.length];
        NSRange semiRange = [after rangeOfString:@";"];
        NSString *tokenPart = (semiRange.location != NSNotFound) ? [after substringToIndex:semiRange.location] : after;
        tokenPart = [tokenPart stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        jsonStr = [tokenPart stringByRemovingPercentEncoding] ?: tokenPart;
    } else if ([s hasPrefix:@"%7B"] || [s hasPrefix:@"%7b"]) {
        jsonStr = [s stringByRemovingPercentEncoding] ?: s;
    }

    NSString *extractedToken = nil;
    NSString *extractedAppId = @"community-app-v1.0";

    NSData *data = [jsonStr dataUsingEncoding:NSUTF8StringEncoding];
    if (data) {
        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([dict isKindOfClass:[NSDictionary class]]) {
            NSDictionary *tokens = dict[@"tokens"];
            if ([tokens isKindOfClass:[NSDictionary class]]) {
                if (tokens[@"community-app-v1.0"]) {
                    extractedToken = tokens[@"community-app-v1.0"];
                    extractedAppId = @"community-app-v1.0";
                } else if (tokens[@"mxm-com-v1.0"]) {
                    extractedToken = tokens[@"mxm-com-v1.0"];
                    extractedAppId = @"web-desktop-app-v1.0";
                } else if (tokens[@"mxm-pro-web-v1.0"]) {
                    extractedToken = tokens[@"mxm-pro-web-v1.0"];
                    extractedAppId = @"web-desktop-app-v1.0";
                } else if (tokens[@"mxm-pro-ios-v1.0"]) {
                    extractedToken = tokens[@"mxm-pro-ios-v1.0"];
                    extractedAppId = @"web-desktop-app-v1.0";
                } else {
                    for (NSString *k in tokens) {
                        id v = tokens[k];
                        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 10) {
                            extractedToken = (NSString *)v;
                            extractedAppId = [k containsString:@"app"] ? k : @"web-desktop-app-v1.0";
                            break;
                        }
                    }
                }
            }
        }
    }

    if (!extractedToken || extractedToken.length == 0) {
        if ([s hasPrefix:@"usertoken="]) {
            s = [s substringFromIndex:10];
        } else if ([s hasPrefix:@"user_token="]) {
            s = [s substringFromIndex:11];
        }
        extractedToken = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        extractedAppId = @"web-desktop-app-v1.0";
    }

    if (outUserToken) *outUserToken = extractedToken ?: @"";
    if (outAppId) *outAppId = extractedAppId ?: @"web-desktop-app-v1.0";
    if (outCookieHeader) *outCookieHeader = cookieHeader;
}

- (void)fetchLyricsFromMusixmatchForTrack:(NSString *)track artist:(NSString *)artist album:(NSString *)album duration:(NSTimeInterval)duration cacheKey:(NSString *)cacheKey {
    NSString *rawInput = [LRPreferences sharedPreferences].musixmatchUserToken;
    NSString *token = nil;
    NSString *appId = nil;
    NSString *cookieHeader = nil;
    parseMusixmatchToken(rawInput, &token, &appId, &cookieHeader);

    NSString *qTrack = urlEncodeParam(track);
    NSString *qArtist = urlEncodeParam(artist ?: @"");
    NSMutableString *urlString = [NSMutableString stringWithFormat:@"https://apic-desktop.musixmatch.com/ws/1.1/macro.subtitles.get?app_id=%@&format=json&q_track=%@&q_artist=%@", urlEncodeParam(appId), qTrack, qArtist];
    if (token.length > 0) {
        [urlString appendFormat:@"&usertoken=%@", urlEncodeParam(token)];
    }

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        [self fetchLyricsFromLrclibForTrack:track artist:artist album:album duration:duration cacheKey:cacheKey];
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    if (cookieHeader && cookieHeader.length > 0) {
        [request setValue:cookieHeader forHTTPHeaderField:@"Cookie"];
    }

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (!error && httpResponse.statusCode == 200 && data) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:[NSDictionary class]]) {
                NSDictionary *body = json[@"message"][@"body"];
                NSDictionary *macroCalls = body[@"macro_calls"];
                if ([macroCalls isKindOfClass:[NSDictionary class]]) {
                    NSDictionary *subCall = macroCalls[@"track.subtitles.get"];
                    NSDictionary *subBody = subCall[@"message"][@"body"];
                    NSString *lrcBody = nil;
                    if ([subBody isKindOfClass:[NSDictionary class]]) {
                        NSArray *subList = subBody[@"subtitle_list"];
                        if ([subList isKindOfClass:[NSArray class]] && subList.count > 0) {
                            lrcBody = subList[0][@"subtitle"][@"subtitle_body"];
                        }
                        if (!lrcBody && [subBody[@"subtitle"] isKindOfClass:[NSDictionary class]]) {
                            lrcBody = subBody[@"subtitle"][@"subtitle_body"];
                        }
                    }

                    // Check for Musixmatch honeypot decoy text
                    if (lrcBody && [lrcBody isKindOfClass:[NSString class]] && lrcBody.length > 0) {
                        if (![lrcBody.lowercaseString containsString:@"wob gopini"]) {
                            LRLyricsSong *song = [LRLyricsSong songFromLrcString:lrcBody track:track artist:artist album:album duration:duration];
                            if (song && song.hasSyncedLyrics) {
                                NSDictionary *saveDict = @{
                                    @"trackName": track ?: @"",
                                    @"artistName": artist ?: @"",
                                    @"albumName": album ?: @"",
                                    @"duration": @(duration),
                                    @"syncedLyrics": lrcBody
                                };
                                [weakSelf handleLyricsSuccess:song rawDict:saveDict forCacheKey:cacheKey track:track artist:artist];
                                return;
                            }
                        }
                    }
                }
            }
        }

        // Musixmatch didn't have valid synced lyrics or served decoy: fall back to LRCLIB!
        [weakSelf fetchLyricsFromLrclibForTrack:track artist:artist album:album duration:duration cacheKey:cacheKey];
    }];
    [task resume];
}

#pragma mark - LRCLIB API Request (Synced Lyrics Only + Offline Cache)

- (void)fetchLyricsFromLrclibForTrack:(NSString *)track artist:(NSString *)artist album:(NSString *)album duration:(NSTimeInterval)duration cacheKey:(NSString *)cacheKey {
    // If artist is present, try /api/get first
    if (artist && artist.length > 0) {
        NSString *qTrack = urlEncodeParam(track);
        NSString *qArtist = urlEncodeParam(artist);
        NSMutableString *urlString = [NSMutableString stringWithFormat:@"https://lrclib.net/api/get?track_name=%@&artist_name=%@", qTrack, qArtist];
        if (album && album.length > 0) {
            [urlString appendFormat:@"&album_name=%@", urlEncodeParam(album)];
        }
        if (duration > 0) {
            [urlString appendFormat:@"&duration=%d", (int)duration];
        }

        NSURL *url = [NSURL URLWithString:urlString];
        if (url) {
            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
            [request setValue:@"LockLyrics-iOS/1.0 (iOS Lockscreen Lyrics Tweak)" forHTTPHeaderField:@"User-Agent"];
            [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];

            __weak typeof(self) weakSelf = self;
            NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
                if (!error && httpResponse.statusCode == 200 && data) {
                    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                    if ([json isKindOfClass:[NSDictionary class]]) {
                        LRLyricsSong *song = [LRLyricsSong songFromLrclibResponse:json];
                        // ONLY accept if it actually has synced lyrics!
                        if (song && song.hasSyncedLyrics) {
                            [weakSelf handleLyricsSuccess:song rawDict:json forCacheKey:cacheKey track:track artist:artist];
                            return;
                        }
                    }
                }

                // If /api/get didn't return synced lyrics, fallback to /api/search
                [weakSelf searchLyricsFallbackForTrack:track artist:artist album:album duration:duration cacheKey:cacheKey];
            }];
            [task resume];
            return;
        }
    }

    // Direct fallback to search
    [self searchLyricsFallbackForTrack:track artist:artist album:album duration:duration cacheKey:cacheKey];
}

- (NSString *)cleanTrackName:(NSString *)track {
    if (!track) return @"";
    NSMutableString *clean = [track mutableCopy];
    NSArray *prefixes = @[@"(feat.", @"(ft.", @"[feat.", @"[ft.", @"(cùng với", @"(cung voi"];
    for (NSString *prefix in prefixes) {
        NSRange range = [clean rangeOfString:prefix options:NSCaseInsensitiveSearch];
        if (range.location != NSNotFound) {
            NSRange closeParen = [clean rangeOfString:@")" options:0 range:NSMakeRange(range.location, clean.length - range.location)];
            if (closeParen.location == NSNotFound) {
                closeParen = [clean rangeOfString:@"]" options:0 range:NSMakeRange(range.location, clean.length - range.location)];
            }
            if (closeParen.location != NSNotFound) {
                NSRange totalRange = NSMakeRange(range.location, (closeParen.location + closeParen.length) - range.location);
                [clean deleteCharactersInRange:totalRange];
            } else {
                [clean deleteCharactersInRange:NSMakeRange(range.location, clean.length - range.location)];
            }
            break;
        }
    }
    return [clean stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

- (void)searchLyricsFallbackForTrack:(NSString *)track artist:(NSString *)artist album:(NSString *)album duration:(NSTimeInterval)duration cacheKey:(NSString *)cacheKey {
    NSString *query = artist.length > 0 ? [NSString stringWithFormat:@"%@ %@", track, artist] : track;
    __weak typeof(self) weakSelf = self;
    [self performSearchWithQuery:query duration:duration completion:^(LRLyricsSong *song, NSDictionary *rawDict) {
        if (song && song.hasSyncedLyrics) {
            [weakSelf handleLyricsSuccess:song rawDict:rawDict forCacheKey:cacheKey track:track artist:artist];
            return;
        }

        // Secondary search: stripped featured artists
        NSString *cleanedTrack = [weakSelf cleanTrackName:track];
        if (![cleanedTrack isEqualToString:track] && cleanedTrack.length > 0) {
            NSString *secondQuery = artist.length > 0 ? [NSString stringWithFormat:@"%@ %@", cleanedTrack, artist] : cleanedTrack;
            [weakSelf performSearchWithQuery:secondQuery duration:duration completion:^(LRLyricsSong *song2, NSDictionary *rawDict2) {
                if (song2 && song2.hasSyncedLyrics) {
                    [weakSelf handleLyricsSuccess:song2 rawDict:rawDict2 forCacheKey:cacheKey track:track artist:artist];
                } else {
                    [weakSelf handleLyricsNotFoundForTrack:track artist:artist];
                }
            }];
            return;
        }

        [weakSelf handleLyricsNotFoundForTrack:track artist:artist];
    }];
}

- (void)performSearchWithQuery:(NSString *)query duration:(NSTimeInterval)duration completion:(void (^)(LRLyricsSong *song, NSDictionary *rawDict))completion {
    NSString *qParam = urlEncodeParam(query);
    NSString *urlString = [NSString stringWithFormat:@"https://lrclib.net/api/search?q=%@", qParam];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (completion) completion(nil, nil);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"LockLyrics-iOS/1.0 (iOS Lockscreen Lyrics Tweak)" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (!error && httpResponse.statusCode == 200 && data) {
            NSArray *results = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([results isKindOfClass:[NSArray class]] && results.count > 0) {
                NSDictionary *bestItem = nil;
                double bestDurationDiff = 999999.0;

                for (NSDictionary *item in results) {
                    if (![item isKindOfClass:[NSDictionary class]]) continue;
                    NSString *synced = item[@"syncedLyrics"];
                    if (!synced || ![synced isKindOfClass:[NSString class]] || synced.length == 0) {
                        continue; // Strictly skip items without synced lyrics!
                    }

                    double itemDuration = [item[@"duration"] doubleValue];
                    if (duration > 0 && itemDuration > 0) {
                        double diff = fabs(itemDuration - duration);
                        if (diff < bestDurationDiff) {
                            bestDurationDiff = diff;
                            bestItem = item;
                            if (diff < 3.0) {
                                break; // Very close match
                            }
                        }
                    } else if (!bestItem) {
                        bestItem = item;
                    }
                }

                if (bestItem) {
                    LRLyricsSong *song = [LRLyricsSong songFromLrclibResponse:bestItem];
                    if (song && song.hasSyncedLyrics) {
                        if (completion) completion(song, bestItem);
                        return;
                    }
                }
            }
        }
        if (completion) completion(nil, nil);
    }];
    [task resume];
}

- (void)handleLyricsSuccess:(LRLyricsSong *)song rawDict:(NSDictionary *)dict forCacheKey:(NSString *)cacheKey track:(NSString *)track artist:(NSString *)artist {
    [self.lyricsCache setObject:song forKey:cacheKey];
    if (dict) {
        [self saveSongToOfflineStorage:dict forCacheKey:cacheKey];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.currentTitle && [self.currentTitle caseInsensitiveCompare:track] == NSOrderedSame) {
            self.currentSong = song;
            self.isLoading = NO;
            [self notifySongUpdated:song];
        }
    });
}

- (void)handleLyricsNotFoundForTrack:(NSString *)track artist:(NSString *)artist {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.currentTitle && [self.currentTitle caseInsensitiveCompare:track] == NSOrderedSame) {
            self.isLoading = NO;
            self.currentSong = nil;
            [self notifySongUpdated:nil];
        }
    });
}

#pragma mark - Time calculation (100% Elapsed Time via MediaRemote)

- (NSTimeInterval)currentEstimatedPlaybackTime {
    if (self.currentContentItem) {
        MRContentItemMetadata *meta = self.currentContentItem.metadata;
        if (meta && [meta respondsToSelector:@selector(calculatedPlaybackPosition)]) {
            CGFloat pos = meta.calculatedPlaybackPosition;
            if (!isnan(pos) && !isinf(pos) && pos >= 0.0) {
                return (NSTimeInterval)pos;
            }
        }
    }

    NSTimeInterval base = self.elapsedTime;
    if (self.isPlaying && self.lastTimestamp) {
        NSTimeInterval delta = [[NSDate date] timeIntervalSinceDate:self.lastTimestamp];
        if (delta > 0.0 && delta < 3600.0) {
            float rate = (self.playbackRate > 0.001f) ? self.playbackRate : 1.0f;
            base += (delta * (NSTimeInterval)rate);
        }
    }
    return MAX(0.0, base);
}

- (NSInteger)currentLyricIndex {
    if (!self.currentSong) return -1;
    NSTimeInterval current = [self currentEstimatedPlaybackTime];
    return [self.currentSong lineIndexForTime:current];
}

@end
