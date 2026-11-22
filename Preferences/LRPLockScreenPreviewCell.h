#import <Preferences/PSTableCell.h>

@class LRPLockScreenPreviewCell;

@protocol LRPLockScreenPreviewCellDelegate <NSObject>
@optional
- (void)previewCellDidChangePosition:(LRPLockScreenPreviewCell *)cell;
@end

@interface LRPLockScreenPreviewCell : PSTableCell

@property (nonatomic, weak) id<LRPLockScreenPreviewCellDelegate> delegate;

- (void)refreshFromPreferencesAnimated:(BOOL)animated;

@end
