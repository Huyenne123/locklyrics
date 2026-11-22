#pragma once
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// MediaRemote notification names
extern NSString *const kMRMediaRemoteNowPlayingInfoDidChangeNotification;
extern NSString *const kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification;
extern NSString *const kMRMediaRemoteNowPlayingApplicationPlaybackStateDidChangeNotification;
extern NSString *const kMRMediaRemoteNowPlayingPlaybackQueueDidChangeNotification;

// MediaRemote info keys
extern NSString *const kMRMediaRemoteNowPlayingInfoTitle;
extern NSString *const kMRMediaRemoteNowPlayingInfoArtist;
extern NSString *const kMRMediaRemoteNowPlayingInfoAlbum;
extern NSString *const kMRMediaRemoteNowPlayingInfoDuration;
extern NSString *const kMRMediaRemoteNowPlayingInfoElapsedTime;
extern NSString *const kMRMediaRemoteNowPlayingInfoPlaybackRate;
extern NSString *const kMRMediaRemoteNowPlayingInfoTimestamp;
extern NSString *const kMRMediaRemoteNowPlayingInfoUniqueIdentifier;
extern NSString *const kMRMediaRemoteNowPlayingInfoArtworkData;
extern NSString *const kMRMediaRemoteNowPlayingInfoArtworkIdentifier;

typedef void (^MRMediaRemoteGetNowPlayingInfoCompletion)(CFDictionaryRef information);
typedef void (^MRMediaRemoteGetNowPlayingApplicationIsPlayingCompletion)(Boolean isPlaying);

void MRMediaRemoteGetNowPlayingInfo(dispatch_queue_t queue, MRMediaRemoteGetNowPlayingInfoCompletion completion);
void MRMediaRemoteRegisterForNowPlayingNotifications(dispatch_queue_t queue);
void MRMediaRemoteUnregisterForNowPlayingNotifications(void);
void MRMediaRemoteGetNowPlayingApplicationIsPlaying(dispatch_queue_t queue, MRMediaRemoteGetNowPlayingApplicationIsPlayingCompletion completion);
void MRMediaRemoteGetNowPlayingApplicationDisplayID(dispatch_queue_t queue, void (^completion)(CFStringRef displayID));

#ifdef __cplusplus
}
#endif

@interface MRContentItemMetadata : NSObject
@property (nonatomic, assign) CGFloat calculatedPlaybackPosition;
@end

@interface MRContentItem : NSObject
@property (nonatomic, strong) MRContentItemMetadata *metadata;
- (instancetype)initWithNowPlayingInfo:(NSDictionary *)nowPlayingInfo;
@end
