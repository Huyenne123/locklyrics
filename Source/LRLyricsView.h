#pragma once
#import <UIKit/UIKit.h>
#import "LRLyricsModel.h"
#import "LRLyricsManager.h"

@interface LRLyricsView : UIView <UIGestureRecognizerDelegate, LRLyricsObserver>

@property (nonatomic, assign) BOOL isLockscreenActive;
@property (nonatomic, assign, readonly) BOOL isDragging;

- (instancetype)initWithFrame:(CGRect)frame;
- (void)updateLayoutForParentBounds:(CGRect)parentBounds;
- (void)refreshPreferences;
- (void)startSyncTimer;
- (void)stopSyncTimer;
- (void)reloadData;

@end
