#pragma once
#import <UIKit/UIKit.h>

@interface LRDynamicWallpaperView : UIView

@property (nonatomic, assign) CGFloat renderScale;      // Default: 0.25
@property (nonatomic, assign) NSInteger frameLimit;     // 15, 30, or 60 (Default: 30)
@property (nonatomic, assign) CGFloat speed;            // 0.0 .. 2.0 (Default: 0.60)
@property (nonatomic, assign) CGFloat transitionSpeed;  // Default: 2.5
@property (nonatomic, assign) CGFloat noiseAmount;      // Default: 12.0
@property (nonatomic, assign) BOOL animating;           // Starts/stops CADisplayLink

- (void)setColors:(NSArray<UIColor *> *)colors animated:(BOOL)animated;
- (void)renderSingleFrame;

@end
