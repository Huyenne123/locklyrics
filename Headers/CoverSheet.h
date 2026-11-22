#pragma once
#import <UIKit/UIKit.h>

@interface CSCoverSheetView : UIView
@end

@interface CSCoverSheetViewController : UIViewController
@property (nonatomic, readonly) CSCoverSheetView *coverSheetView;
- (void)viewDidLoad;
- (void)viewWillAppear:(BOOL)animated;
- (void)viewDidDisappear:(BOOL)animated;
- (void)viewDidLayoutSubviews;
@end
