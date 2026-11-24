#pragma once
#import <UIKit/UIKit.h>

@interface LRColorExtractor : NSObject

/// Extracts a 8-color legibility-tuned vibrant palette from album artwork data.
+ (NSArray<UIColor *> *)extractPaletteFromImageData:(NSData *)imageData;

/// Returns a rich deep teal/indigo/ocean fallback palette when artwork is unavailable.
+ (NSArray<UIColor *> *)defaultPalette;

/// Returns one of several distinct legibility-tuned album-inspired palettes when no cached song artwork exists yet.
+ (NSArray<UIColor *> *)randomFallbackPaletteAvoidingIndex:(NSInteger)avoidIndex outIndex:(NSInteger *)outIndex;

@end
