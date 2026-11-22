#pragma once
#import <UIKit/UIKit.h>

@interface SpringBoard : UIApplication
- (void)applicationDidFinishLaunching:(id)application;
- (void)frontDisplayDidChange:(id)newDisplay;
- (id)_accessibilityFrontMostApplication;
@end

@interface SBHomeScreenViewController : UIViewController
@end

@interface SBRootFolderController : UIViewController
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

@interface SBBacklightController : NSObject
+ (instancetype)sharedInstance;
@property (nonatomic, readonly) BOOL screenIsOn;
- (void)turnOnScreenFullyWithBacklightSource:(long long)source;
- (void)_notifyObserversWillAnimateToFactor:(float)factor source:(long long)source;
- (void)_notifyObserversDidAnimateToFactor:(float)factor source:(long long)source;
@end
