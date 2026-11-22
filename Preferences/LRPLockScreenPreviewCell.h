#import <Preferences/PSTableCell.h>

extern NSString * const LRPPreviewNeedsRefreshNotification;
extern NSString * const LRPPositionChangedBySliderNotification;

@interface LRPLockScreenPreviewCell : PSTableCell

- (void)refreshFromPreferencesAnimated:(BOOL)animated;

@end
