#pragma once
#import <UIKit/UIKit.h>

@class CSCoverSheetView;
@class LRLyricsView;

@interface CSCoverSheetView : UIView
@end

@interface CSCoverSheetViewController : UIViewController
@property (nonatomic, readonly) CSCoverSheetView *coverSheetView;
@property (nonatomic, strong) LRLyricsView *lr_lyricsView;
- (void)viewDidLoad;
- (void)viewWillAppear:(BOOL)animated;
- (void)viewDidDisappear:(BOOL)animated;
- (void)viewDidLayoutSubviews;
- (void)lr_ensureLyricsView;
- (void)lr_updateLyricsPosition;
@end
