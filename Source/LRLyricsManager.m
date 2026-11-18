#import "LRLyricsManager.h"
#import "LRPreferences.h"
#import "MediaRemote.h"
#import <CoreFoundation/CoreFoundation.h>
#import <math.h>
#import <sys/stat.h>
#import <unistd.h>

@interface SBMediaController : NSObject
+ (instancetype)sharedInstance;
- (id)nowPlayingApplication;
@end

@interface SBApplication : NSObject
- (NSString *)bundleIdentifier;
@end

static const char *kOfflineLyricsDir = "/var/mobile/Library/LockLyrics/Lyrics";

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

static void offlinePathForCacheKey(const char *cacheKey, char *outPath, size_t outSize) {
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
    snprintf(outPath, outSize, "%s/%s.json", kOfflineLyricsDir, clean);
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
    self.isLoading = NO;
    [self notifySongUpdated:nil];
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

    // Only update track and fetch lyrics if a valid title is present in this dictionary
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
}

- (void)clearCurrentSong {
    if (self.isPlaying) return;
    self.currentTitle = nil;
    self.currentArtist = nil;
    self.currentAlbum = nil;
    self.currentSong = nil;
    self.currentContentItem = nil;
    [self notifySongUpdated:nil];
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
                    [lrcString appendFormat:@"[%.2f] %@\n", time, lineText];
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
                    [lrcString appendFormat:@"[%.2f] %@\n", time, clean];
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
