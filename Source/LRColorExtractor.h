#pragma once
#import <UIKit/UIKit.h>

@interface LRColorExtractor : NSObject

/// Extracts a 8-color legibility-tuned vibrant palette from album artwork data.
+ (NSArray<UIColor *> *)extractPaletteFromImageData:(NSData *)imageData;

/// Returns a rich deep teal/indigo/ocean fallback palette when artwork is unavailable.
+ (NSArray<UIColor *> *)defaultPalette;

@end
