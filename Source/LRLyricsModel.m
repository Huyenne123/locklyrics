#import "LRLyricsModel.h"
#import <ctype.h>

@implementation LRLyricLine

- (instancetype)initWithTime:(NSTimeInterval)time text:(NSString *)text {
    self = [super init];
    if (self) {
        _time = time;
        _text = [text copy] ?: @"";
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"[%.2f] %@", _time, _text];
}

@end

@implementation LRLyricsSong

+ (instancetype)songFromLrclibResponse:(NSDictionary *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    LRLyricsSong *song = [[LRLyricsSong alloc] init];
    song.trackName = dict[@"trackName"] ?: dict[@"name"];
    song.artistName = dict[@"artistName"];
    song.albumName = dict[@"albumName"];
    song.duration = [dict[@"duration"] doubleValue];
    song.isInstrumental = [dict[@"instrumental"] boolValue];

    NSString *syncedLyrics = dict[@"syncedLyrics"];
    NSString *plainLyrics = dict[@"plainLyrics"];
    song.plainLyrics = plainLyrics;

    if (syncedLyrics && [syncedLyrics isKindOfClass:[NSString class]] && syncedLyrics.length > 0) {
        NSArray<LRLyricLine *> *parsedLines = [self parseLRC:syncedLyrics];
        if (parsedLines.count > 0) {
            song.lines = parsedLines;
            song.hasSyncedLyrics = YES;
        }
    }

    // Strict: never generate fake timestamps for plain lyrics.
    // Only synced lyrics will be presented.
    if (!song.hasSyncedLyrics) {
        song.lines = @[];
    }

    return song;
}

+ (instancetype)songFromLrcString:(NSString *)lrc track:(NSString *)track artist:(NSString *)artist album:(NSString *)album duration:(NSTimeInterval)duration {
    if (!lrc || ![lrc isKindOfClass:[NSString class]] || lrc.length == 0) {
        return nil;
    }

    LRLyricsSong *song = [[LRLyricsSong alloc] init];
    song.trackName = [track copy];
    song.artistName = [artist copy];
    song.albumName = [album copy];
    song.duration = duration;
    song.plainLyrics = lrc;

    NSArray<LRLyricLine *> *parsedLines = [self parseLRC:lrc];
    if (parsedLines.count > 0) {
        song.lines = parsedLines;
        song.hasSyncedLyrics = YES;
    } else {
        song.lines = @[];
        song.hasSyncedLyrics = NO;
    }

    return song;
}

+ (NSArray<LRLyricLine *> *)parseLRC:(NSString *)lrcContent {
    if (!lrcContent || ![lrcContent isKindOfClass:[NSString class]] || lrcContent.length == 0) {
        return @[];
    }

    NSMutableArray<LRLyricLine *> *parsedLines = [NSMutableArray array];
    NSArray<NSString *> *rawLines = [lrcContent componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];

    for (NSString *line in rawLines) {
        if (line.length == 0) continue;

        const char *cstr = [line UTF8String];
        if (!cstr) continue;

        NSMutableArray<NSNumber *> *timestamps = [NSMutableArray array];
        const char *ptr = cstr;

        while (*ptr) {
            const char *startBracket = strchr(ptr, '[');
            if (!startBracket) break;

            const char *endBracket = strchr(startBracket, ']');
            if (!endBracket) break;

            int min = 0;
            double sec = 0.0;
            // Matches [mm:ss] and [mm:ss.xx] or [mm:ss.xxx]
            int matched = sscanf(startBracket, "[%d:%lf]", &min, &sec);
            if (matched == 2) {
                NSTimeInterval total = (min * 60.0) + sec;
                [timestamps addObject:@(total)];
                ptr = endBracket + 1;
            } else if (endBracket > startBracket + 1 && isdigit((unsigned char)startBracket[1]) && sscanf(startBracket, "[%lf]", &sec) == 1) {
                [timestamps addObject:@(sec)];
                ptr = endBracket + 1;
            } else {
                ptr = endBracket + 1;
            }
        }

        if (timestamps.count > 0) {
            NSString *lyricText = [NSString stringWithUTF8String:ptr];
            if (lyricText) {
                if ([lyricText containsString:@"<"] && [lyricText containsString:@">"]) {
                    static NSRegularExpression *regex = nil;
                    static dispatch_once_t onceToken;
                    dispatch_once(&onceToken, ^{
                        regex = [NSRegularExpression regularExpressionWithPattern:@"<[^>]+>" options:0 error:nil];
                    });
                    if (regex) {
                        lyricText = [regex stringByReplacingMatchesInString:lyricText options:0 range:NSMakeRange(0, lyricText.length) withTemplate:@""];
                    }
                }
                lyricText = [lyricText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            } else {
                lyricText = @"";
            }
            if (lyricText.length == 0) {
                lyricText = @"•••";
            }

            for (NSNumber *timeNum in timestamps) {
                [parsedLines addObject:[[LRLyricLine alloc] initWithTime:[timeNum doubleValue] text:lyricText]];
            }
        }
    }

    [parsedLines sortUsingComparator:^NSComparisonResult(LRLyricLine *a, LRLyricLine *b) {
        if (a.time < b.time) return NSOrderedAscending;
        if (a.time > b.time) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    return [parsedLines copy];
}

- (NSInteger)lineIndexForTime:(NSTimeInterval)time {
    if (self.lines.count == 0) return -1;
    // Before the first lyric line starts (musical intro)
    if (time < self.lines.firstObject.time) return -1;

    NSInteger low = 0;
    NSInteger high = (NSInteger)self.lines.count - 1;
    NSInteger result = -1;

    while (low <= high) {
        NSInteger mid = low + (high - low) / 2;
        if (self.lines[mid].time <= time) {
            result = mid;
            low = mid + 1;
        } else {
            high = mid - 1;
        }
    }

    return result;
}

@end
