#pragma once
#import <Foundation/Foundation.h>

@interface LRLyricLine : NSObject
@property (nonatomic, assign) NSTimeInterval time;
@property (nonatomic, copy) NSString *text;

- (instancetype)initWithTime:(NSTimeInterval)time text:(NSString *)text;
@end

@interface LRLyricsSong : NSObject
@property (nonatomic, copy) NSString *trackName;
@property (nonatomic, copy) NSString *artistName;
@property (nonatomic, copy) NSString *albumName;
@property (nonatomic, assign) NSTimeInterval duration;
@property (nonatomic, assign) BOOL isInstrumental;
@property (nonatomic, assign) BOOL hasSyncedLyrics;
@property (nonatomic, copy) NSString *plainLyrics;
@property (nonatomic, copy) NSArray<LRLyricLine *> *lines;

+ (instancetype)songFromLrclibResponse:(NSDictionary *)dict;
+ (instancetype)songFromLrcString:(NSString *)lrc track:(NSString *)track artist:(NSString *)artist album:(NSString *)album duration:(NSTimeInterval)duration;
+ (NSArray<LRLyricLine *> *)parseLRC:(NSString *)lrcContent;
- (NSInteger)lineIndexForTime:(NSTimeInterval)time;

@end
