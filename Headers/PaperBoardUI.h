#pragma once
#import <UIKit/UIKit.h>

@interface PBUIPosterVariantViewController : UIViewController
@end

@interface PBUIPosterLockViewController : PBUIPosterVariantViewController
@end

@interface PBUIPosterHomeViewController : PBUIPosterVariantViewController
@property (nonatomic, readonly) BOOL reflectsLock;
@end

@interface PBUIWallpaperViewController : UIViewController
- (void)_updateWallpaperForLocations:(long long)locations options:(unsigned long long)options wallpaperMode:(long long)mode withCompletion:(id)completion;
@end
