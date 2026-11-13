#pragma once
#import <Foundation/Foundation.h>
#import "LRLyricsModel.h"

@protocol LRLyricsObserver <NSObject>
@optional
- (void)lyricsManagerDidUpdateSong:(LRLyricsSong *)song;
- (void)lyricsManagerDidChangePlaybackState:(BOOL)isPlaying;
@end

@interface LRLyricsManager : NSObject

@property (nonatomic, copy, readonly) NSString *currentTitle;
@property (nonatomic, copy, readonly) NSString *currentArtist;
@property (nonatomic, copy, readonly) NSString *currentAlbum;
@property (nonatomic, assign, readonly) NSTimeInterval duration;
@property (nonatomic, assign, readonly) NSTimeInterval elapsedTime;
@property (nonatomic, assign, readonly) float playbackRate;
@property (nonatomic, assign, readonly) BOOL isPlaying;
@property (nonatomic, strong, readonly) LRLyricsSong *currentSong;
@property (nonatomic, assign, readonly) BOOL isLoading;
@property (nonatomic, copy) NSString *nowPlayingBundleID;

+ (instancetype)sharedManager;

- (void)startMonitoring;
- (void)stopMonitoring;

- (void)addObserver:(id<LRLyricsObserver>)observer;
- (void)removeObserver:(id<LRLyricsObserver>)observer;

- (void)fetchLatestNowPlayingInfo;
- (void)clearCurrentSong;
- (void)updateWithInfoDictionary:(NSDictionary *)info;
- (void)updatePlaybackState:(BOOL)isPlaying;
- (BOOL)isCurrentAppAllowed;
- (void)checkAppAllowanceAndSync;

- (NSTimeInterval)currentEstimatedPlaybackTime;
- (NSInteger)currentLyricIndex;

@end
