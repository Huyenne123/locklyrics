#import "LRColorExtractor.h"
#import <CoreGraphics/CoreGraphics.h>
#import <math.h>
#import <stdlib.h>
#import <string.h>

typedef struct {
    double sumR;
    double sumG;
    double sumB;
    double sumSat;
    double totalWeight;
    NSInteger count;
} LRHueBucket;

static void lrRGBtoHSV(CGFloat r, CGFloat g, CGFloat b, CGFloat *outH, CGFloat *outS, CGFloat *outV) {
    CGFloat maxC = MAX(r, MAX(g, b));
    CGFloat minC = MIN(r, MIN(g, b));
    CGFloat delta = maxC - minC;

    *outV = maxC;
    *outS = (maxC > 1e-5) ? (delta / maxC) : 0.0;

    if (delta < 1e-5) {
        *outH = 0.0;
        return;
    }

    CGFloat h = 0.0;
    if (maxC == r) {
        h = (g - b) / delta + (g < b ? 6.0 : 0.0);
    } else if (maxC == g) {
        h = (b - r) / delta + 2.0;
    } else {
        h = (r - g) / delta + 4.0;
    }
    *outH = h / 6.0;
}

static UIColor *lrTunedForegroundColor(CGFloat r, CGFloat g, CGFloat b) {
    CGFloat h = 0.0, s = 0.0, v = 0.0;
    lrRGBtoHSV(r, g, b, &h, &s, &v);

    // Clamp brightness so white Lock Screen clock, lyrics & frosted media cards stay legible
    CGFloat tunedV = MAX(0.22, MIN(0.70, v));
    CGFloat tunedS = MAX(0.32, MIN(0.92, s * 1.12));
    return [UIColor colorWithHue:h saturation:tunedS brightness:tunedV alpha:1.0];
}

static UIColor *lrDeepAnchorColor(UIColor *baseColor, CGFloat brightness) {
    CGFloat h = 0.0, s = 0.0, v = 0.0, a = 1.0;
    if ([baseColor getHue:&h saturation:&s brightness:&v alpha:&a]) {
        return [UIColor colorWithHue:h
                          saturation:MAX(0.18, MIN(0.80, s * 0.90))
                          brightness:MAX(0.08, MIN(0.22, brightness))
                               alpha:1.0];
    }
    return [UIColor colorWithRed:0.06 green:0.11 blue:0.16 alpha:1.0];
}

static NSArray<UIColor *> *lrMonochromeAtmosphericPalette(CGFloat avgLum) {
    CGFloat baseV = MAX(0.12, MIN(0.38, avgLum * 0.65));
    return @[
        [UIColor colorWithRed:baseV * 0.70 green:baseV * 0.85 blue:baseV * 1.08 alpha:1.0],
        [UIColor colorWithRed:baseV * 0.90 green:baseV * 0.95 blue:baseV * 1.15 alpha:1.0],
        [UIColor colorWithRed:baseV * 0.55 green:baseV * 0.68 blue:baseV * 0.92 alpha:1.0],
        [UIColor colorWithRed:baseV * 1.05 green:baseV * 1.08 blue:baseV * 1.12 alpha:1.0],
        [UIColor colorWithRed:baseV * 0.42 green:baseV * 0.52 blue:baseV * 0.72 alpha:1.0],
        [UIColor colorWithRed:0.07 green:0.09 blue:0.14 alpha:1.0],
        [UIColor colorWithRed:0.11 green:0.13 blue:0.18 alpha:1.0],
        [UIColor colorWithRed:0.05 green:0.07 blue:0.11 alpha:1.0]
    ];
}

@implementation LRColorExtractor

+ (NSArray<UIColor *> *)defaultPalette {
    return @[
        [UIColor colorWithRed:0.06 green:0.25 blue:0.34 alpha:1.0],
        [UIColor colorWithRed:0.09 green:0.42 blue:0.46 alpha:1.0],
        [UIColor colorWithRed:0.14 green:0.21 blue:0.48 alpha:1.0],
        [UIColor colorWithRed:0.05 green:0.17 blue:0.28 alpha:1.0],
        [UIColor colorWithRed:0.18 green:0.34 blue:0.55 alpha:1.0],
        [UIColor colorWithRed:0.04 green:0.11 blue:0.18 alpha:1.0],
        [UIColor colorWithRed:0.08 green:0.13 blue:0.26 alpha:1.0],
        [UIColor colorWithRed:0.05 green:0.16 blue:0.20 alpha:1.0]
    ];
}

+ (NSArray<UIColor *> *)extractPaletteFromImageData:(NSData *)imageData {
    if (!imageData || imageData.length == 0) {
        return [self defaultPalette];
    }

    UIImage *image = [UIImage imageWithData:imageData];
    CGImageRef cgImage = image.CGImage;
    if (!cgImage) {
        return [self defaultPalette];
    }

    const size_t width = 32;
    const size_t height = 32;
    const size_t bytesPerRow = width * 4;
    uint8_t *pixels = (uint8_t *)calloc(height, bytesPerRow);
    if (!pixels) {
        return [self defaultPalette];
    }

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(
        pixels,
        width,
        height,
        8,
        bytesPerRow,
        colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
    );
    CGColorSpaceRelease(colorSpace);

    if (!ctx) {
        free(pixels);
        return [self defaultPalette];
    }

    CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
    CGContextDrawImage(ctx, CGRectMake(0, 0, width, height), cgImage);
    CGContextRelease(ctx);

    LRHueBucket buckets[12];
    memset(buckets, 0, sizeof(buckets));

    double neutralLumSum = 0.0;
    NSInteger neutralCount = 0;

    const size_t totalPixels = width * height;
    for (size_t i = 0; i < totalPixels; i++) {
        uint8_t *px = pixels + (i * 4);
        uint8_t a = px[3];
        if (a < 32) continue;

        CGFloat alphaF = (CGFloat)a / 255.0;
        CGFloat r = MIN(1.0, ((CGFloat)px[0] / 255.0) / alphaF);
        CGFloat g = MIN(1.0, ((CGFloat)px[1] / 255.0) / alphaF);
        CGFloat b = MIN(1.0, ((CGFloat)px[2] / 255.0) / alphaF);

        CGFloat h = 0.0, s = 0.0, v = 0.0;
        lrRGBtoHSV(r, g, b, &h, &s, &v);

        CGFloat lum = (0.2126 * r) + (0.7152 * g) + (0.0722 * b);
        neutralLumSum += lum;
        neutralCount++;

        // Skip near-gray/near-black/near-white pixels from chromatic hue buckets
        if (s < 0.14 || v < 0.08) {
            continue;
        }

        // Prefer vibrant midtones over blown-out whites or murky blacks
        CGFloat lumWeight = 1.0 - fabs(lum - 0.45) * 1.15;
        lumWeight = MAX(0.18, lumWeight);
        CGFloat weight = (0.25 + pow(s, 1.35)) * lumWeight;

        int bucketIdx = (int)(h * 12.0) % 12;
        if (bucketIdx < 0) bucketIdx = 0;

        buckets[bucketIdx].sumR += r * weight;
        buckets[bucketIdx].sumG += g * weight;
        buckets[bucketIdx].sumB += b * weight;
        buckets[bucketIdx].sumSat += s;
        buckets[bucketIdx].totalWeight += weight;
        buckets[bucketIdx].count++;
    }

    free(pixels);

    // Compute scores per hue bucket
    double scores[12];
    int order[12];
    for (int i = 0; i < 12; i++) {
        order[i] = i;
        if (buckets[i].count > 0 && buckets[i].totalWeight > 0.0) {
            double avgSat = buckets[i].sumSat / (double)buckets[i].count;
            double avgW = buckets[i].totalWeight / (double)buckets[i].count;
            scores[i] = (double)buckets[i].count * (0.25 + pow(avgSat, 1.5)) * avgW;
        } else {
            scores[i] = 0.0;
        }
    }

    // Sort bucket indices descending by score
    for (int i = 0; i < 11; i++) {
        for (int j = i + 1; j < 12; j++) {
            if (scores[order[j]] > scores[order[i]]) {
                int tmp = order[i];
                order[i] = order[j];
                order[j] = tmp;
            }
        }
    }

    // Monochrome / grayscale cover fallback
    if (scores[order[0]] <= 0.0) {
        CGFloat avgLum = (neutralCount > 0) ? (CGFloat)(neutralLumSum / (double)neutralCount) : 0.25;
        return lrMonochromeAtmosphericPalette(avgLum);
    }

    // Pick up to 5 distinct dominant hues (spaced at least ~30 deg / non-adjacent when possible)
    NSMutableArray<UIColor *> *dominant = [NSMutableArray array];
    NSMutableArray<NSNumber *> *selectedBuckets = [NSMutableArray array];

    for (int pass = 0; pass < 2 && dominant.count < 5; pass++) {
        for (int k = 0; k < 12 && dominant.count < 5; k++) {
            int bIdx = order[k];
            if (scores[bIdx] <= 0.0 || buckets[bIdx].totalWeight <= 0.0) continue;
            if ([selectedBuckets containsObject:@(bIdx)]) continue;

            BOOL tooClose = NO;
            if (pass == 0) {
                for (NSNumber *prevNum in selectedBuckets) {
                    int prev = [prevNum intValue];
                    int dist = abs(bIdx - prev);
                    dist = MIN(dist, 12 - dist);
                    if (dist < 2) {
                        tooClose = YES;
                        break;
                    }
                }
            }
            if (tooClose) continue;

            CGFloat avgR = (CGFloat)(buckets[bIdx].sumR / buckets[bIdx].totalWeight);
            CGFloat avgG = (CGFloat)(buckets[bIdx].sumG / buckets[bIdx].totalWeight);
            CGFloat avgB = (CGFloat)(buckets[bIdx].sumB / buckets[bIdx].totalWeight);
            UIColor *tuned = lrTunedForegroundColor(avgR, avgG, avgB);
            [dominant addObject:tuned];
            [selectedBuckets addObject:@(bIdx)];
        }
    }

    if (dominant.count == 0) {
        return [self defaultPalette];
    }

    // Build an 8-color array mixing vibrant dominant tones with 2-3 deep atmospheric anchors
    NSMutableArray<UIColor *> *result = [NSMutableArray arrayWithCapacity:8];
    NSInteger domCount = (NSInteger)dominant.count;

    // Fill 5 primary slots cycling over dominant colors with subtle tonal variation for 1-2 hue albums
    for (NSInteger i = 0; i < 5; i++) {
        UIColor *base = dominant[i % domCount];
        if (i >= domCount) {
            CGFloat h = 0.0, s = 0.0, v = 0.0, a = 1.0;
            if ([base getHue:&h saturation:&s brightness:&v alpha:&a]) {
                CGFloat shiftedV = (i % 2 == 0) ? MAX(0.20, v * 0.78) : MIN(0.68, v * 1.15);
                CGFloat shiftedH = fmod(h + (i == domCount ? 0.04 : -0.04) + 1.0, 1.0);
                base = [UIColor colorWithHue:shiftedH saturation:s brightness:shiftedV alpha:1.0];
            }
        }
        [result addObject:base];
    }

    // Append 3 deep shadow anchors derived from top hues for contrast & depth
    [result addObject:lrDeepAnchorColor(dominant[0], 0.14)];
    [result addObject:lrDeepAnchorColor(dominant[domCount > 1 ? 1 : 0], 0.17)];
    [result addObject:lrDeepAnchorColor(dominant[domCount > 2 ? 2 : 0], 0.12)];

    return [result copy];
}

@end
