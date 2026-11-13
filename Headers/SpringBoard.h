#pragma once
#import <UIKit/UIKit.h>

@interface SpringBoard : UIApplication
- (void)applicationDidFinishLaunching:(id)application;
@end

@interface SBApplication : NSObject
- (NSString *)bundleIdentifier;
- (NSString *)displayName;
@end

@interface SBMediaController : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isPlaying;
- (BOOL)isPaused;
- (BOOL)hasTrack;
- (id)nowPlayingApplication;
- (NSString *)nowPlayingTitle;
- (NSString *)nowPlayingArtist;
- (NSString *)nowPlayingAlbum;
- (NSDictionary *)_nowPlayingInfo;
- (void)setNowPlayingInfo:(id)arg1;
- (void)_nowPlayingInfoChanged;
- (BOOL)_setNowPlayingApplication:(id)arg1;
@end
