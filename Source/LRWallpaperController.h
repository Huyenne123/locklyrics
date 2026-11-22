#pragma once
#import <UIKit/UIKit.h>
#import "LRLyricsManager.h"

@interface LRWallpaperController : NSObject <LRLyricsObserver>

+ (instancetype)sharedController;

- (void)attachToPosterLockViewController:(UIViewController *)vc;
- (void)attachToPosterHomeViewController:(UIViewController *)vc;
- (void)attachToFallbackWallpaperViewController:(UIViewController *)vc;
- (void)setCoverSheetViewController:(UIViewController *)vc;
- (void)setLockScreenVisible:(BOOL)visible;
- (void)setHomeScreenVisible:(BOOL)visible;
- (void)frontDisplayDidChange:(id)newDisplay;
- (void)setScreenOn:(BOOL)screenOn;
- (void)layoutViews;
- (void)refreshPreferences;

@end
