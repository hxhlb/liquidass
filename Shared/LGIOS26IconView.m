#import "LGIOS26IconView.h"

#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <objc/message.h>
#import <stdint.h>
#import <stdlib.h>

@interface CALayer (LGIOS26PrivateFilters)
@property (nonatomic, copy) NSArray *filters;
@property (nonatomic, strong) id compositingFilter;
@end

static CGFloat LGIOS26Clamp(CGFloat value, CGFloat minimum, CGFloat maximum) {
    return MIN(MAX(value, minimum), maximum);
}

static CGFloat LGIOS26Smoothstep(CGFloat minimum,
                                 CGFloat maximum,
                                 CGFloat value) {
    CGFloat normalized = LGIOS26Clamp((value - minimum) / (maximum - minimum),
                                      0.0,
                                      1.0);
    return normalized * normalized * (3.0 - 2.0 * normalized);
}

static id LGIOS26NewFilter(NSString *type) {
    Class filterClass = NSClassFromString(@"CAFilter");
    SEL selector = NSSelectorFromString(@"initWithType:");
    if (!filterClass || ![filterClass instancesRespondToSelector:selector] || !type.length) return nil;
    id allocated = ((id (*)(id, SEL))objc_msgSend)(filterClass, @selector(alloc));
    return ((id (*)(id, SEL, id))objc_msgSend)(allocated, selector, type);
}

static void LGIOS26SetFilterValue(id filter, id value, NSString *key) {
    if (!filter || !value || !key.length) return;
    @try {
        [filter setValue:value forKey:key];
    } @catch (__unused NSException *exception) {
    }
}

static NSArray *LGIOS26RefractionFilters(void) {
    static NSArray *filters;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray *configured = [NSMutableArray arrayWithCapacity:2];
        id resize = LGIOS26NewFilter(@"lanczosResize");
        LGIOS26SetFilterValue(resize, @1.052, @"inputScale");
        LGIOS26SetFilterValue(resize, @1.0, @"inputAspectRatio");
        if (resize) [configured addObject:resize];
        id blur = LGIOS26NewFilter(@"gaussianBlur");
        LGIOS26SetFilterValue(blur, @0.80, @"inputRadius");
        LGIOS26SetFilterValue(blur, @YES, @"inputNormalizeEdges");
        if (blur) [configured addObject:blur];
        filters = [configured copy];
    });
    return filters;
}

static void LGIOS26SetLayerPrivateValue(CALayer *layer, id value, NSString *key) {
    if (!layer || !value || !key.length) return;
    @try {
        [layer setValue:value forKey:key];
    } @catch (__unused NSException *exception) {
    }
}

static void LGIOS26ReadPixel(const uint8_t *pixel,
                             CGFloat *red,
                             CGFloat *green,
                             CGFloat *blue,
                             CGFloat *alpha) {
    CGFloat a = pixel[3] / 255.0;
    if (alpha) *alpha = a;
    if (a <= 0.001) {
        if (red) *red = 0.0;
        if (green) *green = 0.0;
        if (blue) *blue = 0.0;
        return;
    }
    if (red) *red = LGIOS26Clamp(pixel[0] / 255.0 / a, 0.0, 1.0);
    if (green) *green = LGIOS26Clamp(pixel[1] / 255.0 / a, 0.0, 1.0);
    if (blue) *blue = LGIOS26Clamp(pixel[2] / 255.0 / a, 0.0, 1.0);
}

static CGFloat LGIOS26PixelDetail(const uint8_t *pixel,
                                  CGFloat backgroundR,
                                  CGFloat backgroundG,
                                  CGFloat backgroundB,
                                  CGFloat backgroundLuminance) {
    CGFloat red, green, blue, alpha;
    LGIOS26ReadPixel(pixel, &red, &green, &blue, &alpha);
    if (alpha < 0.02) return 0.0;
    CGFloat luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue;
    CGFloat colorDistance = sqrt((red - backgroundR) * (red - backgroundR)
        + (green - backgroundG) * (green - backgroundG)
        + (blue - backgroundB) * (blue - backgroundB)) / sqrt(3.0);
    return MAX(colorDistance, fabs(luminance - backgroundLuminance) * 1.25);
}

typedef struct {
    CGFloat red;
    CGFloat green;
    CGFloat blue;
    CGFloat variance;
    size_t count;
} LGIOS26ColorCluster;

static CGFloat LGIOS26ColorDistanceSquared(const CGFloat *first,
                                           const CGFloat *second) {
    CGFloat deltaR = first[0] - second[0];
    CGFloat deltaG = first[1] - second[1];
    CGFloat deltaB = first[2] - second[2];
    return (deltaR * deltaR + deltaG * deltaG + deltaB * deltaB) / 3.0;
}

static LGIOS26ColorCluster LGIOS26FindSampleCluster(const CGFloat *samples,
                                                    size_t sampleCount,
                                                    uint8_t *claimed) {
    LGIOS26ColorCluster cluster = {0};
    if (!samples || !sampleCount) return cluster;
    static const CGFloat radiusSquared = 0.13 * 0.13;
    size_t bestIndex = SIZE_MAX;
    size_t bestCount = 0;
    for (size_t index = 0; index < sampleCount; index++) {
        if (claimed && claimed[index]) continue;
        size_t neighbors = 0;
        const CGFloat *seed = samples + index * 3;
        for (size_t candidate = 0; candidate < sampleCount; candidate++) {
            if (claimed && claimed[candidate]) continue;
            if (LGIOS26ColorDistanceSquared(seed, samples + candidate * 3)
                <= radiusSquared) neighbors++;
        }
        if (neighbors > bestCount) {
            bestCount = neighbors;
            bestIndex = index;
        }
    }
    if (bestIndex == SIZE_MAX || !bestCount) return cluster;

    const CGFloat *seed = samples + bestIndex * 3;
    double red = 0.0, green = 0.0, blue = 0.0;
    double variance = 0.0;
    for (size_t index = 0; index < sampleCount; index++) {
        if (claimed && claimed[index]) continue;
        const CGFloat *sample = samples + index * 3;
        CGFloat distanceSquared = LGIOS26ColorDistanceSquared(seed, sample);
        if (distanceSquared > radiusSquared) continue;
        red += sample[0];
        green += sample[1];
        blue += sample[2];
        variance += distanceSquared;
        cluster.count++;
        if (claimed) claimed[index] = 1;
    }
    if (!cluster.count) return cluster;
    cluster.red = red / cluster.count;
    cluster.green = green / cluster.count;
    cluster.blue = blue / cluster.count;
    cluster.variance = variance / cluster.count;
    return cluster;
}

static CGFloat LGIOS26PixelDetailWithPalette(
    const uint8_t *pixel,
    CGFloat backgroundR,
    CGFloat backgroundG,
    CGFloat backgroundB,
    CGFloat backgroundLuminance,
    BOOL hasSecondaryBackground,
    CGFloat secondaryR,
    CGFloat secondaryG,
    CGFloat secondaryB,
    CGFloat secondaryLuminance) {
    CGFloat detail = LGIOS26PixelDetail(pixel,
                                         backgroundR,
                                         backgroundG,
                                         backgroundB,
                                         backgroundLuminance);
    if (!hasSecondaryBackground) return detail;
    return MIN(detail,
               LGIOS26PixelDetail(pixel,
                                  secondaryR,
                                  secondaryG,
                                  secondaryB,
                                  secondaryLuminance));
}

typedef struct {
    CGFloat primaryR;
    CGFloat primaryG;
    CGFloat primaryB;
    CGFloat primaryLuminance;
    CGFloat secondaryR;
    CGFloat secondaryG;
    CGFloat secondaryB;
    CGFloat secondaryLuminance;
    BOOL hasSecondary;
    BOOL coherentSamples;
    BOOL hasBackgroundPlane;
    CGFloat cornerColors[4][3];
} LGIOS26ReferencePalette;

static void LGIOS26BackgroundPlaneColor(const LGIOS26ReferencePalette *palette,
                                         CGFloat x, CGFloat y, CGFloat *color) {
    CGFloat u = (x - 0.16) / 0.68;
    CGFloat v = (y - 0.16) / 0.68;
    for (size_t channel = 0; channel < 3; channel++) {
        CGFloat top = palette->cornerColors[0][channel]
            + u * (palette->cornerColors[1][channel] - palette->cornerColors[0][channel]);
        CGFloat bottom = palette->cornerColors[2][channel]
            + u * (palette->cornerColors[3][channel] - palette->cornerColors[2][channel]);
        color[channel] = LGIOS26Clamp(top + v * (bottom - top), 0.0, 1.0);
    }
}

static LGIOS26ReferencePalette LGIOS26ReferencePaletteForPixels(
    const uint8_t *pixels,
    size_t width,
    size_t height,
    size_t rowBytes) {
    LGIOS26ReferencePalette palette = {0};
    static const CGFloat samplePoints[][2] = {
        {0.06, 0.25}, {0.06, 0.50}, {0.06, 0.75},
        {0.25, 0.06}, {0.50, 0.06}, {0.75, 0.06},
        {0.94, 0.25}, {0.94, 0.50}, {0.94, 0.75},
        {0.25, 0.94}, {0.50, 0.94}, {0.75, 0.94},
        {0.16, 0.16}, {0.50, 0.12}, {0.84, 0.16},
        {0.12, 0.50},                 {0.88, 0.50},
        {0.16, 0.84}, {0.50, 0.88}, {0.84, 0.84},
    };
    size_t sampleRadius = MIN((size_t)3,
                              MAX((size_t)1, MIN(width, height) / 60));
    size_t diameter = sampleRadius * 2 + 1;
    size_t maximumSampleCount =
        (sizeof(samplePoints) / sizeof(samplePoints[0])) * diameter * diameter;
    CGFloat *samples = calloc(maximumSampleCount * 3, sizeof(CGFloat));
    if (!samples) {
        palette.primaryR = palette.primaryG = palette.primaryB = 0.5;
        palette.primaryLuminance = 0.5;
        return palette;
    }

    double averageR = 0.0, averageG = 0.0, averageB = 0.0;
    size_t sampleCount = 0;
    for (size_t pointIndex = 0;
         pointIndex < sizeof(samplePoints) / sizeof(samplePoints[0]);
         pointIndex++) {
        size_t centerX = (size_t)llround((width - 1) * samplePoints[pointIndex][0]);
        size_t centerY = (size_t)llround((height - 1) * samplePoints[pointIndex][1]);
        size_t startX = centerX > sampleRadius ? centerX - sampleRadius : 0;
        size_t startY = centerY > sampleRadius ? centerY - sampleRadius : 0;
        size_t endX = MIN(width - 1, centerX + sampleRadius);
        size_t endY = MIN(height - 1, centerY + sampleRadius);
        for (size_t y = startY; y <= endY; y++) {
            for (size_t x = startX; x <= endX; x++) {
                CGFloat red, green, blue, alpha;
                LGIOS26ReadPixel(pixels + y * rowBytes + x * 4,
                                 &red, &green, &blue, &alpha);
                if (alpha < 0.5 || sampleCount >= maximumSampleCount) continue;
                samples[sampleCount * 3] = red;
                samples[sampleCount * 3 + 1] = green;
                samples[sampleCount * 3 + 2] = blue;
                averageR += red;
                averageG += green;
                averageB += blue;
                sampleCount++;
            }
        }
    }
    if (!sampleCount) {
        free(samples);
        palette.primaryR = palette.primaryG = palette.primaryB = 0.5;
        palette.primaryLuminance = 0.5;
        return palette;
    }

    uint8_t *claimed = calloc(sampleCount, sizeof(uint8_t));
    LGIOS26ColorCluster primary = LGIOS26FindSampleCluster(samples,
                                                           sampleCount,
                                                           claimed);
    LGIOS26ColorCluster secondary = {0};
    if (claimed) {
        secondary = LGIOS26FindSampleCluster(samples, sampleCount, claimed);
    }
    free(claimed);
    CGFloat primaryDominance = (CGFloat)primary.count / sampleCount;
    CGFloat secondaryDominance = (CGFloat)secondary.count / sampleCount;
    if (primaryDominance >= 0.28) {
        palette.primaryR = primary.red;
        palette.primaryG = primary.green;
        palette.primaryB = primary.blue;
    } else {
        palette.primaryR = averageR / sampleCount;
        palette.primaryG = averageG / sampleCount;
        palette.primaryB = averageB / sampleCount;
    }
    CGFloat primaryColor[3] = {primary.red, primary.green, primary.blue};
    CGFloat secondaryColor[3] = {secondary.red, secondary.green, secondary.blue};
    BOOL secondaryIsBackgroundShade = secondary.count
        && LGIOS26ColorDistanceSquared(primaryColor, secondaryColor) <= 0.22 * 0.22;
    palette.hasSecondary = primaryDominance >= 0.28
        && secondaryDominance >= 0.20
        && secondaryIsBackgroundShade
        && secondary.variance < 0.006;
    if (palette.hasSecondary) {
        palette.secondaryR = secondary.red;
        palette.secondaryG = secondary.green;
        palette.secondaryB = secondary.blue;
    }
    palette.primaryLuminance = 0.2126 * palette.primaryR
        + 0.7152 * palette.primaryG + 0.0722 * palette.primaryB;
    palette.secondaryLuminance = 0.2126 * palette.secondaryR
        + 0.7152 * palette.secondaryG + 0.0722 * palette.secondaryB;
    CGFloat backgroundCoverage = primaryDominance
        + (palette.hasSecondary ? secondaryDominance : 0.0);
    BOOL stronglyDominantPrimary = primaryDominance >= 0.62
        && primary.variance < 0.012;
    palette.coherentSamples = stronglyDominantPrimary
        || (primaryDominance >= 0.34
        && backgroundCoverage >= 0.58
        && primary.variance < 0.006
        && (!palette.hasSecondary || secondary.variance < 0.006));
    // A strong gradient can fail constant-color clustering (Settings is one
    // example). Validate the plane against the outer border instead of requiring
    // its bright and dark corners to belong to the same color cluster.
    palette.hasBackgroundPlane = YES;
    for (size_t corner = 0; corner < 4 && palette.hasBackgroundPlane; corner++) {
        size_t cx = (size_t)llround((width - 1) * ((corner & 1) ? 0.84 : 0.16));
        size_t cy = (size_t)llround((height - 1) * ((corner & 2) ? 0.84 : 0.16));
        CGFloat alpha;
        LGIOS26ReadPixel(pixels + cy * rowBytes + cx * 4,
            &palette.cornerColors[corner][0], &palette.cornerColors[corner][1],
            &palette.cornerColors[corner][2], &alpha);
        if (alpha < 0.95) palette.hasBackgroundPlane = NO;
    }
    if (palette.hasBackgroundPlane) {
        static const CGFloat borderPoints[][2] = {
            {0.025, 0.25}, {0.025, 0.50}, {0.025, 0.75},
            {0.975, 0.25}, {0.975, 0.50}, {0.975, 0.75},
            {0.25, 0.025}, {0.50, 0.025}, {0.75, 0.025},
            {0.25, 0.975}, {0.50, 0.975}, {0.75, 0.975},
        };
        size_t valid = 0, matching = 0;
        for (size_t index = 0; index < sizeof(borderPoints) / sizeof(borderPoints[0]); index++) {
            CGFloat x = borderPoints[index][0], y = borderPoints[index][1];
            size_t px = (size_t)llround((width - 1) * x);
            size_t py = (size_t)llround((height - 1) * y);
            CGFloat color[3], expected[3], alpha;
            LGIOS26ReadPixel(pixels + py * rowBytes + px * 4,
                &color[0], &color[1], &color[2], &alpha);
            if (alpha < 0.95) continue;
            valid++;
            LGIOS26BackgroundPlaneColor(&palette, x, y, expected);
            if (LGIOS26ColorDistanceSquared(color, expected) <= 0.04 * 0.04) matching++;
        }
        palette.hasBackgroundPlane = valid >= 8 && matching * 4 >= valid * 3;
        if (palette.hasBackgroundPlane) palette.coherentSamples = YES;
    }
    free(samples);
    return palette;
}

UIImage *LGIOS26ProcessedIconImage(UIImage *image, LGIOS26IconMode mode) {
    if (!image.CGImage || mode == LGIOS26IconModeTinted) return image;

    static NSCache<NSValue *, UIImage *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSCache new];
        cache.countLimit = 256;
        cache.totalCostLimit = 24 * 1024 * 1024;
    });

    NSValue *cacheKey = [NSValue valueWithPointer:image.CGImage];
    UIImage *cached = [cache objectForKey:cacheKey];
    if (cached) return cached;

    size_t width = CGImageGetWidth(image.CGImage);
    size_t height = CGImageGetHeight(image.CGImage);
    if (!width || !height || width > SIZE_MAX / 4) return image;
    size_t rowBytes = width * 4;
    if (height > SIZE_MAX / rowBytes || width > SIZE_MAX / height) return image;
    size_t pixelCount = width * height;

    uint8_t *pixels = calloc(height, rowBytes);
    if (!pixels) return image;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels,
                                                  width,
                                                  height,
                                                  8,
                                                  rowBytes,
                                                  colorSpace,
                                                  kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (!context) {
        free(pixels);
        return image;
    }
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image.CGImage);

    static const CGFloat samplePoints[][2] = {
        {0.06, 0.25}, {0.06, 0.50}, {0.06, 0.75},
        {0.25, 0.06}, {0.50, 0.06}, {0.75, 0.06},
        {0.94, 0.25}, {0.94, 0.50}, {0.94, 0.75},
        {0.25, 0.94}, {0.50, 0.94}, {0.75, 0.94},
        {0.16, 0.16}, {0.50, 0.12}, {0.84, 0.16},
        {0.12, 0.50},                 {0.88, 0.50},
        {0.16, 0.84}, {0.50, 0.88}, {0.84, 0.84},
    };
    size_t sampleRadius = MIN((size_t)3,
                              MAX((size_t)1, MIN(width, height) / 60));
    size_t sampleDiameter = sampleRadius * 2 + 1;
    size_t maximumSampleCount =
        (sizeof(samplePoints) / sizeof(samplePoints[0]))
        * sampleDiameter * sampleDiameter;
    CGFloat *sampleColors = calloc(maximumSampleCount * 3, sizeof(CGFloat));
    double backgroundR = 0.0, backgroundG = 0.0, backgroundB = 0.0;
    double backgroundR2 = 0.0, backgroundG2 = 0.0, backgroundB2 = 0.0;
    size_t sampleCount = 0;
    for (size_t pointIndex = 0;
         pointIndex < sizeof(samplePoints) / sizeof(samplePoints[0]);
         pointIndex++) {
        size_t centerX = (size_t)llround((width - 1) * samplePoints[pointIndex][0]);
        size_t centerY = (size_t)llround((height - 1) * samplePoints[pointIndex][1]);
        size_t startX = centerX > sampleRadius ? centerX - sampleRadius : 0;
        size_t startY = centerY > sampleRadius ? centerY - sampleRadius : 0;
        size_t endX = MIN(width - 1, centerX + sampleRadius);
        size_t endY = MIN(height - 1, centerY + sampleRadius);
        for (size_t y = startY; y <= endY; y++) {
            for (size_t x = startX; x <= endX; x++) {
                CGFloat red, green, blue, alpha;
                LGIOS26ReadPixel(pixels + y * rowBytes + x * 4,
                                 &red, &green, &blue, &alpha);
                if (alpha < 0.5) continue;
                backgroundR += red;
                backgroundG += green;
                backgroundB += blue;
                backgroundR2 += red * red;
                backgroundG2 += green * green;
                backgroundB2 += blue * blue;
                if (sampleColors && sampleCount < maximumSampleCount) {
                    sampleColors[sampleCount * 3] = red;
                    sampleColors[sampleCount * 3 + 1] = green;
                    sampleColors[sampleCount * 3 + 2] = blue;
                }
                sampleCount++;
            }
        }
    }
    CGFloat primaryDominance = 0.0;
    CGFloat paletteCoverage = 0.0;
    CGFloat primaryVariance = 1.0;
    CGFloat secondaryVariance = 1.0;
    BOOL hasSecondaryBackground = NO;
    CGFloat secondaryR = 0.0, secondaryG = 0.0, secondaryB = 0.0;
    if (sampleCount && sampleColors) {
        uint8_t *claimed = calloc(sampleCount, sizeof(uint8_t));
        LGIOS26ColorCluster primary = LGIOS26FindSampleCluster(
            sampleColors, sampleCount, claimed);
        LGIOS26ColorCluster secondary = LGIOS26FindSampleCluster(
            sampleColors, sampleCount, claimed);
        free(claimed);
        primaryDominance = (CGFloat)primary.count / sampleCount;
        CGFloat secondaryDominance = (CGFloat)secondary.count / sampleCount;
        paletteCoverage = primaryDominance + secondaryDominance;
        primaryVariance = primary.variance;
        secondaryVariance = secondary.variance;
        if (primaryDominance >= 0.28) {
            backgroundR = primary.red;
            backgroundG = primary.green;
            backgroundB = primary.blue;
        } else {
            backgroundR /= sampleCount;
            backgroundG /= sampleCount;
            backgroundB /= sampleCount;
        }
        hasSecondaryBackground = primaryDominance >= 0.28
            && secondaryDominance >= 0.20
            && secondary.variance < 0.006;
        if (hasSecondaryBackground) {
            secondaryR = secondary.red;
            secondaryG = secondary.green;
            secondaryB = secondary.blue;
        }
    } else if (sampleCount) {
        backgroundR /= sampleCount;
        backgroundG /= sampleCount;
        backgroundB /= sampleCount;
    } else {
        backgroundR = backgroundG = backgroundB = 0.5;
    }
    free(sampleColors);
    CGFloat backgroundLuminance = 0.2126 * backgroundR
        + 0.7152 * backgroundG + 0.0722 * backgroundB;
    CGFloat secondaryLuminance = 0.2126 * secondaryR
        + 0.7152 * secondaryG + 0.0722 * secondaryB;
    CGFloat edgeVariance = 0.0;
    if (sampleCount) {
        edgeVariance = ((backgroundR2 / sampleCount - backgroundR * backgroundR)
            + (backgroundG2 / sampleCount - backgroundG * backgroundG)
            + (backgroundB2 / sampleCount - backgroundB * backgroundB)) / 3.0;
    }

    size_t opaqueCount = 0;
    size_t detailedCount = 0;
    for (size_t y = 0; y < height; y++) {
        for (size_t x = 0; x < width; x++) {
            uint8_t *pixel = pixels + y * rowBytes + x * 4;
            if (pixel[3] < 51) continue;
            opaqueCount++;
            if (LGIOS26PixelDetailWithPalette(pixel,
                                               backgroundR,
                                               backgroundG,
                                               backgroundB,
                                               backgroundLuminance,
                                               hasSecondaryBackground,
                                               secondaryR,
                                               secondaryG,
                                               secondaryB,
                                               secondaryLuminance) > 0.24) {
                detailedCount++;
            }
        }
    }
    CGFloat detailedFraction = opaqueCount ? (CGFloat)detailedCount / opaqueCount : 0.0;
    BOOL coherentBackground = primaryDominance >= 0.34
        && paletteCoverage >= 0.68
        && primaryVariance < 0.006
        && (!hasSecondaryBackground || secondaryVariance < 0.006)
        && detailedFraction < 0.52;
    BOOL complexIcon = !coherentBackground
        && (edgeVariance > 0.016 || detailedFraction > 0.56);

    for (size_t y = 0; y < height; y++) {
        for (size_t x = 0; x < width; x++) {
            uint8_t *pixel = pixels + y * rowBytes + x * 4;
            CGFloat red, green, blue, sourceAlpha;
            LGIOS26ReadPixel(pixel, &red, &green, &blue, &sourceAlpha);
            if (sourceAlpha < 0.02) {
                pixel[0] = pixel[1] = pixel[2] = pixel[3] = 0;
                continue;
            }

            CGFloat detail = LGIOS26PixelDetailWithPalette(
                pixel,
                backgroundR,
                backgroundG,
                backgroundB,
                backgroundLuminance,
                hasSecondaryBackground,
                secondaryR,
                secondaryG,
                secondaryB,
                secondaryLuminance);
            CGFloat glyph = LGIOS26Clamp((detail - 0.045) / 0.24, 0.0, 1.0);
            glyph = glyph * glyph * (3.0 - 2.0 * glyph);

            CGFloat outputAlpha, outputR, outputG, outputB;
            if (complexIcon) {
                outputAlpha = sourceAlpha * (0.26 + 0.28 * glyph);
                outputR = 0.20 + 0.80 * red;
                outputG = 0.20 + 0.80 * green;
                outputB = 0.20 + 0.80 * blue;
            } else {
                outputAlpha = sourceAlpha * (0.01 + 0.90 * glyph);
                outputR = outputG = outputB = 0.96;
            }
            pixel[0] = (uint8_t)llround(255.0 * outputR * outputAlpha);
            pixel[1] = (uint8_t)llround(255.0 * outputG * outputAlpha);
            pixel[2] = (uint8_t)llround(255.0 * outputB * outputAlpha);
            pixel[3] = (uint8_t)llround(255.0 * outputAlpha);
        }
    }

    CGImageRef processedCGImage = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    free(pixels);
    if (!processedCGImage) return image;
    UIImage *processed = [UIImage imageWithCGImage:processedCGImage
                                               scale:image.scale
                                         orientation:UIImageOrientationUp];
    CGImageRelease(processedCGImage);
    if (processed) [cache setObject:processed forKey:cacheKey cost:pixelCount * 4];
    return processed ?: image;
}

UIImage *LGIOS26AppleMitigatedIconImage(UIImage *image,
                                       BOOL darkAppearance,
                                       BOOL preservesSubjectColor) {
    if (!image.CGImage) return image;
    static NSCache<NSString *, NSDictionary<NSString *, UIImage *> *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSCache new];
        cache.countLimit = 256;
        cache.totalCostLimit = 24 * 1024 * 1024;
    });

    NSString *cacheKey = [NSString stringWithFormat:@"%p-%d-%d",
                          image.CGImage,
                          darkAppearance,
                          preservesSubjectColor];
    NSDictionary<NSString *, UIImage *> *cachedEntry = [cache objectForKey:cacheKey];
    UIImage *cachedSource = cachedEntry[@"source"];
    UIImage *cachedProcessed = cachedEntry[@"processed"];
    if (cachedSource.CGImage == image.CGImage && cachedProcessed.CGImage) {
        return cachedProcessed;
    }
    if (cachedEntry) [cache removeObjectForKey:cacheKey];

    size_t width = CGImageGetWidth(image.CGImage);
    size_t height = CGImageGetHeight(image.CGImage);
    if (!width || !height || width > SIZE_MAX / 4) return image;
    size_t rowBytes = width * 4;
    if (height > SIZE_MAX / rowBytes || width > SIZE_MAX / height) return image;
    size_t pixelCount = width * height;
    uint8_t *sourcePixels = calloc(height, rowBytes);
    uint8_t *outputPixels = calloc(height, rowBytes);
    if (!sourcePixels || !outputPixels) {
        free(sourcePixels);
        free(outputPixels);
        return image;
    }

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef sourceContext = CGBitmapContextCreate(
        sourcePixels, width, height, 8, rowBytes, colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGContextRef outputContext = CGBitmapContextCreate(
        outputPixels, width, height, 8, rowBytes, colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (!sourceContext || !outputContext) {
        if (sourceContext) CGContextRelease(sourceContext);
        if (outputContext) CGContextRelease(outputContext);
        free(sourcePixels);
        free(outputPixels);
        return image;
    }
    CGContextSetBlendMode(sourceContext, kCGBlendModeCopy);
    CGContextDrawImage(sourceContext, CGRectMake(0, 0, width, height), image.CGImage);

    LGIOS26ReferencePalette reference = LGIOS26ReferencePaletteForPixels(
        sourcePixels, width, height, rowBytes);
    BOOL drawByReference = reference.coherentSamples;
    // Relief is a fine surface cue, not a second outline around the bitmap.
    size_t edgeRadius = 1;
    size_t interiorRadius = MAX((size_t)1, MIN(width, height) / 24);

    for (size_t y = 0; y < height; y++) {
        size_t upperY = y > edgeRadius ? y - edgeRadius : 0;
        size_t lowerY = MIN(y + edgeRadius, height - 1);
        for (size_t x = 0; x < width; x++) {
            size_t leftX = x > edgeRadius ? x - edgeRadius : 0;
            size_t rightX = MIN(x + edgeRadius, width - 1);
            const uint8_t *center = sourcePixels + y * rowBytes + x * 4;
            CGFloat red, green, blue, sourceAlpha;
            LGIOS26ReadPixel(center, &red, &green, &blue, &sourceAlpha);
            if (sourceAlpha < 0.02) continue;

            CGFloat leftR, leftG, leftB, leftA;
            CGFloat rightR, rightG, rightB, rightA;
            CGFloat upperR, upperG, upperB, upperA;
            CGFloat lowerR, lowerG, lowerB, lowerA;
            LGIOS26ReadPixel(sourcePixels + y * rowBytes + leftX * 4,
                             &leftR, &leftG, &leftB, &leftA);
            LGIOS26ReadPixel(sourcePixels + y * rowBytes + rightX * 4,
                             &rightR, &rightG, &rightB, &rightA);
            LGIOS26ReadPixel(sourcePixels + upperY * rowBytes + x * 4,
                             &upperR, &upperG, &upperB, &upperA);
            LGIOS26ReadPixel(sourcePixels + lowerY * rowBytes + x * 4,
                             &lowerR, &lowerG, &lowerB, &lowerA);

            CGFloat luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue;
            CGFloat leftLuminance = 0.2126 * leftR + 0.7152 * leftG + 0.0722 * leftB;
            CGFloat rightLuminance = 0.2126 * rightR + 0.7152 * rightG
                + 0.0722 * rightB;
            CGFloat upperLuminance = 0.2126 * upperR + 0.7152 * upperG
                + 0.0722 * upperB;
            CGFloat lowerLuminance = 0.2126 * lowerR + 0.7152 * lowerG
                + 0.0722 * lowerB;
            CGFloat horizontal = rightLuminance - leftLuminance;
            CGFloat vertical = lowerLuminance - upperLuminance;
            CGFloat alphaEdge = MAX(fabs(rightA - leftA), fabs(lowerA - upperA));
            CGFloat edge = sqrt(horizontal * horizontal + vertical * vertical);
            edge = MAX(edge, alphaEdge * 0.78);
            edge = LGIOS26Smoothstep(0.018, 0.18, edge);

            CGFloat referenceDetail = LGIOS26PixelDetailWithPalette(
                center,
                reference.primaryR,
                reference.primaryG,
                reference.primaryB,
                reference.primaryLuminance,
                reference.hasSecondary,
                reference.secondaryR,
                reference.secondaryG,
                reference.secondaryB,
                reference.secondaryLuminance);
            if (reference.hasBackgroundPlane && width > 1 && height > 1) {
                CGFloat background[3];
                LGIOS26BackgroundPlaneColor(&reference, (CGFloat)x / (width - 1),
                    (CGFloat)y / (height - 1), background);
                CGFloat backgroundLuminance = 0.2126 * background[0]
                    + 0.7152 * background[1] + 0.0722 * background[2];
                referenceDetail = LGIOS26PixelDetail(center, background[0],
                    background[1], background[2], backgroundLuminance);
            }
            CGFloat referenceSubject = LGIOS26Smoothstep(0.02,
                                                          0.22,
                                                          referenceDetail);
            CGFloat neighborLuminance = (leftLuminance + rightLuminance
                + upperLuminance + lowerLuminance) * 0.25;
            CGFloat localSubject = LGIOS26Smoothstep(
                0.02, 0.14, MAX(fabs(luminance - neighborLuminance), edge * 0.12));
            // A flat glyph interior has no local edge. Even when the border
            // palette is uncertain, retain its broad contrast with that palette.
            CGFloat subject = referenceSubject;
            if (!drawByReference) {
                // In a textured/multicolor bitmap, border color distance alone
                // also selects the background. Admit broad fills only where a
                // larger neighborhood supports a coherent interior.
                size_t sampleX[] = {x > interiorRadius ? x - interiorRadius : 0,
                    MIN(x + interiorRadius, width - 1), x, x};
                size_t sampleY[] = {y, y,
                    y > interiorRadius ? y - interiorRadius : 0,
                    MIN(y + interiorRadius, height - 1)};
                CGFloat centerColor[] = {red, green, blue};
                CGFloat variation = 0.0;
                for (size_t neighbor = 0; neighbor < 4; neighbor++) {
                    CGFloat color[3];
                    LGIOS26ReadPixel(sourcePixels + sampleY[neighbor] * rowBytes
                        + sampleX[neighbor] * 4, &color[0], &color[1], &color[2], NULL);
                    variation = MAX(variation,
                        LGIOS26ColorDistanceSquared(centerColor, color));
                }
                CGFloat interior = 1.0 - LGIOS26Smoothstep(0.045, 0.24,
                                                           sqrt(variation));
                subject = MAX(localSubject * 0.20, referenceSubject * 0.85 * interior);
            }
            if (!drawByReference) subject = MAX(subject, edge * 0.18);

            // This is a bitmap fallback for older systems, not an input to
            // Apple's clearIconBlendMode. Keep coverage separate from material
            // opacity; a second threshold used to erase low-contrast details.
            CGFloat subjectCoverage = sqrt(LGIOS26Clamp(subject, 0.0, 1.0));
            CGFloat substrateAlpha = darkAppearance ? 0.10 : 0.055;
            CGFloat glyphAlpha = preservesSubjectColor
                ? (darkAppearance ? 0.90 : 0.88) : 0.84;
            CGFloat resolvedAlpha;
            if (drawByReference) {
                resolvedAlpha = substrateAlpha
                    + (glyphAlpha - substrateAlpha) * subjectCoverage;
            } else {
                CGFloat fallbackAlpha = darkAppearance ? 0.26 : 0.22;
                resolvedAlpha = fallbackAlpha
                    + (glyphAlpha - fallbackAlpha) * subjectCoverage;
            }
            CGFloat outputAlpha = sourceAlpha
                * LGIOS26Clamp(resolvedAlpha, 0.0, 0.94);

            CGFloat sourceTone = darkAppearance
                ? 0.34 + 0.42 * pow(luminance, 0.82)
                : 0.44 + 0.36 * pow(luminance, 0.78);
            CGFloat directionalEdge = 0.0;
            CGFloat gradientLength = sqrt(horizontal * horizontal
                + vertical * vertical);
            if (gradientLength > 0.0001) {
                directionalEdge = LGIOS26Clamp(
                    -(horizontal + vertical) / (gradientLength * M_SQRT2),
                    -1.0,
                    1.0);
            }
            CGFloat highlight = edge * MAX(directionalEdge, 0.0);
            CGFloat darklight = edge * MAX(-directionalEdge, 0.0);
            CGFloat neutralTone = sourceTone;
            neutralTone = LGIOS26Clamp(neutralTone,
                                       darkAppearance ? 0.18 : 0.26,
                                       0.90);
            CGFloat subjectColorWeight = LGIOS26Smoothstep(0.28,
                                                            0.82,
                                                            subjectCoverage);
            CGFloat outputRed, outputGreen, outputBlue;
            if (preservesSubjectColor) {
                outputRed = neutralTone
                    + (red - neutralTone) * subjectColorWeight;
                outputGreen = neutralTone
                    + (green - neutralTone) * subjectColorWeight;
                outputBlue = neutralTone
                    + (blue - neutralTone) * subjectColorWeight;
            } else {
                // Retain the bitmap's internal tonal structure. A constant
                // white fill made dark markings identical to their white base.
                CGFloat softWhite = darkAppearance
                    ? 0.66 + 0.30 * pow(luminance, 0.75)
                    : 0.54 + 0.38 * pow(luminance, 0.75);
                CGFloat outputTone = neutralTone
                    + (softWhite - neutralTone) * subjectColorWeight;
                outputRed = outputGreen = outputBlue = outputTone;
            }
            // Shade after the subject fill so full-coverage pixels do not
            // overwrite their own bevel. Bake both sides into the image: the
            // iOS 15-17 lifecycle does not use the separate highlight layer.
            CGFloat relief = subjectCoverage * (0.025 * highlight - 0.055 * darklight);
            outputRed += relief;
            outputGreen += relief;
            outputBlue += relief;
            uint8_t *output = outputPixels + y * rowBytes + x * 4;
            output[0] = (uint8_t)llround(255.0
                * LGIOS26Clamp(outputRed, 0.0, 1.0) * outputAlpha);
            output[1] = (uint8_t)llround(255.0
                * LGIOS26Clamp(outputGreen, 0.0, 1.0) * outputAlpha);
            output[2] = (uint8_t)llround(255.0
                * LGIOS26Clamp(outputBlue, 0.0, 1.0) * outputAlpha);
            output[3] = (uint8_t)llround(255.0 * outputAlpha);
        }
    }

    CGImageRef processedCGImage = CGBitmapContextCreateImage(outputContext);
    CGContextRelease(sourceContext);
    CGContextRelease(outputContext);
    free(sourcePixels);
    free(outputPixels);
    if (!processedCGImage) return image;
    UIImage *processed = [UIImage imageWithCGImage:processedCGImage
                                               scale:image.scale
                                         orientation:UIImageOrientationUp];
    CGImageRelease(processedCGImage);
    if (processed) {
        [cache setObject:@{ @"source": image, @"processed": processed }
                  forKey:cacheKey
                    cost:pixelCount * 8];
    }
    return processed ?: image;
}

static UIImage *LGIOS26ContourHighlightImage(UIImage *image) {
    if (!image.CGImage) return nil;
    static NSCache<NSValue *, UIImage *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSCache new];
        cache.countLimit = 192;
        cache.totalCostLimit = 12 * 1024 * 1024;
    });

    NSValue *cacheKey = [NSValue valueWithPointer:image.CGImage];
    UIImage *cached = [cache objectForKey:cacheKey];
    if (cached) return cached;

    size_t width = CGImageGetWidth(image.CGImage);
    size_t height = CGImageGetHeight(image.CGImage);
    if (width < 3 || height < 3 || width > SIZE_MAX / 4) return nil;
    size_t rowBytes = width * 4;
    if (height > SIZE_MAX / rowBytes || width > SIZE_MAX / height) return nil;
    size_t pixelCount = width * height;
    uint8_t *sourcePixels = calloc(height, rowBytes);
    uint8_t *outputPixels = calloc(height, rowBytes);
    if (!sourcePixels || !outputPixels) {
        free(sourcePixels);
        free(outputPixels);
        return nil;
    }

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef sourceContext = CGBitmapContextCreate(
        sourcePixels, width, height, 8, rowBytes, colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGContextRef outputContext = CGBitmapContextCreate(
        outputPixels, width, height, 8, rowBytes, colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (!sourceContext || !outputContext) {
        if (sourceContext) CGContextRelease(sourceContext);
        if (outputContext) CGContextRelease(outputContext);
        free(sourcePixels);
        free(outputPixels);
        return nil;
    }
    CGContextSetBlendMode(sourceContext, kCGBlendModeCopy);
    CGContextDrawImage(sourceContext, CGRectMake(0, 0, width, height), image.CGImage);

    CGFloat inset = MIN(width, height) * 0.12;
    for (size_t y = 1; y + 1 < height; y++) {
        for (size_t x = 1; x + 1 < width; x++) {
            if (x < inset || y < inset || x >= width - inset || y >= height - inset) continue;
            const uint8_t *center = sourcePixels + y * rowBytes + x * 4;
            CGFloat centerA;
            LGIOS26ReadPixel(center, NULL, NULL, NULL, &centerA);
            if (centerA < 0.08) continue;

            CGFloat leftR, leftG, leftB, leftA;
            CGFloat rightR, rightG, rightB, rightA;
            CGFloat upR, upG, upB, upA;
            CGFloat downR, downG, downB, downA;
            LGIOS26ReadPixel(sourcePixels + y * rowBytes + (x - 1) * 4,
                             &leftR, &leftG, &leftB, &leftA);
            LGIOS26ReadPixel(sourcePixels + y * rowBytes + (x + 1) * 4,
                             &rightR, &rightG, &rightB, &rightA);
            LGIOS26ReadPixel(sourcePixels + (y - 1) * rowBytes + x * 4,
                             &upR, &upG, &upB, &upA);
            LGIOS26ReadPixel(sourcePixels + (y + 1) * rowBytes + x * 4,
                             &downR, &downG, &downB, &downA);

            CGFloat horizontal = sqrt((rightR - leftR) * (rightR - leftR)
                + (rightG - leftG) * (rightG - leftG)
                + (rightB - leftB) * (rightB - leftB)) / sqrt(3.0);
            CGFloat vertical = sqrt((downR - upR) * (downR - upR)
                + (downG - upG) * (downG - upG)
                + (downB - upB) * (downB - upB)) / sqrt(3.0);
            CGFloat alphaEdge = MAX(fabs(rightA - leftA), fabs(downA - upA));
            CGFloat edge = sqrt(horizontal * horizontal + vertical * vertical);
            edge = MAX(edge, alphaEdge * 0.72);
            edge = LGIOS26Clamp((edge - 0.025) / 0.19, 0.0, 1.0);
            edge = edge * edge * (3.0 - 2.0 * edge);

            CGFloat normalizedX = (CGFloat)x / MAX((CGFloat)width - 1.0, 1.0);
            CGFloat normalizedY = (CGFloat)y / MAX((CGFloat)height - 1.0, 1.0);
            CGFloat directionalLight = LGIOS26Clamp(1.20 - 0.52 * (normalizedX + normalizedY),
                                                     0.34, 1.0);
            CGFloat outputAlpha = centerA * edge * directionalLight * 0.86;
            uint8_t premultipliedWhite = (uint8_t)llround(255.0 * outputAlpha);
            uint8_t *output = outputPixels + y * rowBytes + x * 4;
            output[0] = output[1] = output[2] = premultipliedWhite;
            output[3] = (uint8_t)llround(255.0 * outputAlpha);
        }
    }

    CGImageRef contourCGImage = CGBitmapContextCreateImage(outputContext);
    CGContextRelease(sourceContext);
    CGContextRelease(outputContext);
    free(sourcePixels);
    free(outputPixels);
    if (!contourCGImage) return nil;
    UIImage *contourImage = [UIImage imageWithCGImage:contourCGImage
                                                  scale:image.scale
                                            orientation:UIImageOrientationUp];
    CGImageRelease(contourCGImage);
    if (contourImage) [cache setObject:contourImage forKey:cacheKey cost:pixelCount * 4];
    return contourImage;
}

UIImage *LGIOS26GrayscaleIconImage(UIImage *image) {
    if (!image.CGImage) return image;
    static NSCache<NSValue *, UIImage *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSCache new];
        cache.countLimit = 256;
        cache.totalCostLimit = 8 * 1024 * 1024;
    });

    NSValue *cacheKey = [NSValue valueWithPointer:image.CGImage];
    UIImage *cached = [cache objectForKey:cacheKey];
    if (cached) return cached;

    size_t width = CGImageGetWidth(image.CGImage);
    size_t height = CGImageGetHeight(image.CGImage);
    if (!width || !height || width > SIZE_MAX / 4) return image;
    size_t rowBytes = width * 4;
    if (height > SIZE_MAX / rowBytes || width > SIZE_MAX / height) return image;
    size_t pixelCount = width * height;
    uint8_t *pixels = calloc(height, rowBytes);
    if (!pixels) return image;

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(
        pixels, width, height, 8, rowBytes, colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (!context) {
        free(pixels);
        return image;
    }
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image.CGImage);

    for (size_t index = 0; index < pixelCount; index++) {
        uint8_t *pixel = pixels + index * 4;
        CGFloat red, green, blue, alpha;
        LGIOS26ReadPixel(pixel, &red, &green, &blue, &alpha);
        if (alpha < 0.002) {
            pixel[0] = pixel[1] = pixel[2] = pixel[3] = 0;
            continue;
        }
        CGFloat luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue;
        CGFloat tone = LGIOS26Clamp(0.06 + 0.76 * pow(luminance, 0.88), 0.0, 0.82);
        uint8_t premultipliedTone = (uint8_t)llround(255.0 * tone * alpha);
        pixel[0] = pixel[1] = pixel[2] = premultipliedTone;
        pixel[3] = (uint8_t)llround(255.0 * alpha);
    }

    CGImageRef grayscaleCGImage = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    free(pixels);
    if (!grayscaleCGImage) return image;
    UIImage *grayscaleImage = [UIImage imageWithCGImage:grayscaleCGImage
                                                    scale:image.scale
                                              orientation:UIImageOrientationUp];
    CGImageRelease(grayscaleCGImage);
    if (grayscaleImage) {
        [cache setObject:grayscaleImage forKey:cacheKey cost:pixelCount * 4];
    }
    return grayscaleImage ?: image;
}

UIImage *LGIOS26TintedIconImage(UIImage *image, CGFloat hue, CGFloat intensity) {
    if (!image.CGImage) return image;
    hue = hue - floor(hue);
    intensity = LGIOS26Clamp(intensity, 0.0, 1.0);
    static NSCache<NSString *, UIImage *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSCache new];
        cache.countLimit = 384;
        cache.totalCostLimit = 12 * 1024 * 1024;
    });

    NSString *cacheKey = [NSString stringWithFormat:@"%p-%.3f-%.3f",
                          image.CGImage, hue, intensity];
    UIImage *cached = [cache objectForKey:cacheKey];
    if (cached) return cached;

    size_t width = CGImageGetWidth(image.CGImage);
    size_t height = CGImageGetHeight(image.CGImage);
    if (!width || !height || width > SIZE_MAX / 4) return image;
    size_t rowBytes = width * 4;
    if (height > SIZE_MAX / rowBytes || width > SIZE_MAX / height) return image;
    size_t pixelCount = width * height;
    uint8_t *pixels = calloc(height, rowBytes);
    if (!pixels) return image;

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(
        pixels, width, height, 8, rowBytes, colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (!context) {
        free(pixels);
        return image;
    }
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image.CGImage);

    CGFloat tintR = 0.0, tintG = 0.0, tintB = 0.0;
    UIColor *tintColor = [UIColor colorWithHue:hue saturation:0.78 brightness:0.92 alpha:1.0];
    [tintColor getRed:&tintR green:&tintG blue:&tintB alpha:NULL];
    for (size_t index = 0; index < pixelCount; index++) {
        uint8_t *pixel = pixels + index * 4;
        CGFloat red, green, blue, alpha;
        LGIOS26ReadPixel(pixel, &red, &green, &blue, &alpha);
        if (alpha < 0.002) {
            pixel[0] = pixel[1] = pixel[2] = pixel[3] = 0;
            continue;
        }
        CGFloat luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue;
        CGFloat tone = LGIOS26Clamp(0.06 + 0.76 * pow(luminance, 0.88), 0.0, 0.82);
        CGFloat tintBase = 0.18 + 0.64 * tone;
        CGFloat tintedR = tintR * tintBase + tone * (1.0 - tintR) * 0.50;
        CGFloat tintedG = tintG * tintBase + tone * (1.0 - tintG) * 0.50;
        CGFloat tintedB = tintB * tintBase + tone * (1.0 - tintB) * 0.50;
        CGFloat outputR = tone + (tintedR - tone) * intensity;
        CGFloat outputG = tone + (tintedG - tone) * intensity;
        CGFloat outputB = tone + (tintedB - tone) * intensity;
        pixel[0] = (uint8_t)llround(255.0 * LGIOS26Clamp(outputR, 0.0, 1.0) * alpha);
        pixel[1] = (uint8_t)llround(255.0 * LGIOS26Clamp(outputG, 0.0, 1.0) * alpha);
        pixel[2] = (uint8_t)llround(255.0 * LGIOS26Clamp(outputB, 0.0, 1.0) * alpha);
        pixel[3] = (uint8_t)llround(255.0 * alpha);
    }

    CGImageRef tintedCGImage = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    free(pixels);
    if (!tintedCGImage) return image;
    UIImage *tintedImage = [UIImage imageWithCGImage:tintedCGImage
                                                 scale:image.scale
                                           orientation:UIImageOrientationUp];
    CGImageRelease(tintedCGImage);
    if (tintedImage) [cache setObject:tintedImage forKey:cacheKey cost:pixelCount * 4];
    return tintedImage ?: image;
}

@interface LGIOS26IconView ()
@property (nonatomic, strong) CALayer *backdropLayer;
@property (nonatomic, strong) CAShapeLayer *refractionMask;
@property (nonatomic, strong) CAGradientLayer *glassLayer;
@property (nonatomic, strong) CALayer *sourceLayer;
@property (nonatomic, strong) CALayer *glyphHighlightLayer;
@property (nonatomic, strong) UIImage *currentInputImage;
@property (nonatomic, strong) CAGradientLayer *rimBloomLayer;
@property (nonatomic, strong) CAShapeLayer *rimBloomMask;
@property (nonatomic, strong) CAGradientLayer *rimLayer;
@property (nonatomic, strong) CAShapeLayer *rimMask;
@property (nonatomic, strong) CAGradientLayer *glossLayer;
@property (nonatomic, strong) CAShapeLayer *glossMask;
@property (nonatomic) const void *currentImageIdentity;
@property (nonatomic) LGIOS26IconMode currentMode;
@property (nonatomic) LGIOS26IconAlgorithm currentAlgorithm;
@property (nonatomic) BOOL currentDarkAppearance;
@property (nonatomic) CGFloat currentTintHue;
@property (nonatomic) CGFloat currentTintIntensity;
@property (nonatomic) BOOL currentPreservesSubjectColor;
@property (nonatomic) BOOL hasConfiguration;
@property (nonatomic) BOOL hasMaterialConfiguration;
@property (nonatomic) CGRect laidOutBounds;
@property (nonatomic) CGFloat laidOutCornerRadius;
- (void)configureMaterial;
@end

@implementation LGIOS26IconView

@synthesize usesSharedBackdrop = _usesSharedBackdrop;

- (void)setUsesSharedBackdrop:(BOOL)usesSharedBackdrop {
    if (_usesSharedBackdrop == usesSharedBackdrop) return;
    _usesSharedBackdrop = usesSharedBackdrop;
    self.hasConfiguration = NO;
    self.hasMaterialConfiguration = NO;
    self.glassLayer.hidden = usesSharedBackdrop;
    self.rimLayer.hidden = usesSharedBackdrop;
    self.rimBloomLayer.hidden = usesSharedBackdrop;
    self.glossLayer.hidden = usesSharedBackdrop;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.userInteractionEnabled = NO;
    self.backgroundColor = UIColor.clearColor;
    self.clipsToBounds = NO;

    _glassLayer = [CAGradientLayer layer];
    _glassLayer.startPoint = CGPointMake(0.12, 0.0);
    _glassLayer.endPoint = CGPointMake(0.88, 1.0);
    _glassLayer.locations = @[@0.0, @0.5, @1.0];
    _glassLayer.shadowColor = UIColor.blackColor.CGColor;
    _glassLayer.shadowOpacity = 0.16f;
    _glassLayer.shadowRadius = 2.2;
    _glassLayer.shadowOffset = CGSizeMake(0.0, 1.3);
    [self.layer addSublayer:_glassLayer];

    _sourceLayer = [CALayer layer];
    _sourceLayer.contentsGravity = kCAGravityResizeAspectFill;
    _sourceLayer.masksToBounds = YES;
    [self.layer addSublayer:_sourceLayer];

    [self configureMaterial];

    _glyphHighlightLayer = [CALayer layer];
    _glyphHighlightLayer.contentsGravity = kCAGravityResizeAspectFill;
    _glyphHighlightLayer.masksToBounds = YES;
    _glyphHighlightLayer.compositingFilter = @"screenBlendMode";
    [self.layer addSublayer:_glyphHighlightLayer];

    _rimBloomLayer = [CAGradientLayer layer];
    _rimBloomLayer.type = kCAGradientLayerConic;
    _rimBloomLayer.colors = @[
        (id)UIColor.clearColor.CGColor,
        (id)UIColor.clearColor.CGColor,
        (id)[UIColor colorWithRed:0.55 green:0.90 blue:1.0 alpha:0.38].CGColor,
        (id)[UIColor colorWithRed:1.0 green:0.82 blue:0.58 alpha:0.12].CGColor,
        (id)UIColor.clearColor.CGColor,
        (id)UIColor.clearColor.CGColor,
    ];
    _rimBloomLayer.locations = @[@0.0, @0.10, @0.18, @0.27, @0.40, @1.0];
    _rimBloomLayer.compositingFilter = @"screenBlendMode";
    _rimBloomMask = [CAShapeLayer layer];
    _rimBloomMask.fillColor = UIColor.clearColor.CGColor;
    _rimBloomMask.strokeColor = UIColor.whiteColor.CGColor;
    _rimBloomMask.lineWidth = 2.4;
    _rimBloomLayer.mask = _rimBloomMask;
    [self.layer addSublayer:_rimBloomLayer];

    _rimLayer = [CAGradientLayer layer];
    _rimLayer.type = kCAGradientLayerConic;
    _rimLayer.colors = @[
        (id)UIColor.clearColor.CGColor,
        (id)UIColor.clearColor.CGColor,
        (id)[UIColor colorWithRed:0.88 green:0.97 blue:1.0 alpha:0.78].CGColor,
        (id)[UIColor colorWithRed:1.0 green:0.94 blue:0.82 alpha:0.24].CGColor,
        (id)UIColor.clearColor.CGColor,
        (id)[UIColor colorWithWhite:0.0 alpha:0.07].CGColor,
        (id)UIColor.clearColor.CGColor,
    ];
    _rimLayer.locations = @[@0.0, @0.10, @0.17, @0.25, @0.38, @0.66, @1.0];
    _rimLayer.compositingFilter = @"overlayBlendMode";
    _rimMask = [CAShapeLayer layer];
    _rimMask.fillColor = UIColor.clearColor.CGColor;
    _rimMask.strokeColor = UIColor.whiteColor.CGColor;
    _rimMask.lineWidth = 0.65;
    _rimLayer.mask = _rimMask;
    [self.layer addSublayer:_rimLayer];

    _glossLayer = [CAGradientLayer layer];
    _glossLayer.colors = @[
        (id)[UIColor colorWithWhite:1.0 alpha:0.18].CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:0.045].CGColor,
        (id)UIColor.clearColor.CGColor,
    ];
    _glossLayer.locations = @[@0.0, @0.20, @0.46];
    _glossLayer.compositingFilter = @"softLightBlendMode";
    _glossMask = [CAShapeLayer layer];
    _glossMask.fillColor = UIColor.whiteColor.CGColor;
    _glossLayer.mask = _glossMask;
    [self.layer addSublayer:_glossLayer];

    CGFloat angle = -M_PI_4;
    CGFloat dx = cos(angle) * 0.5;
    CGFloat dy = sin(angle) * 0.5;
    _rimLayer.startPoint = CGPointMake(0.5, 0.5);
    _rimLayer.endPoint = CGPointMake(0.5 - dy, 0.5 + dx);
    _rimBloomLayer.startPoint = _rimLayer.startPoint;
    _rimBloomLayer.endPoint = _rimLayer.endPoint;
    _glossLayer.startPoint = CGPointMake(0.5 + dx, 0.5 + dy);
    _glossLayer.endPoint = CGPointMake(0.5 - dx, 0.5 - dy);
    return self;
}

- (void)configureMaterial {
    if (self.hasMaterialConfiguration) return;

    [self.backdropLayer removeFromSuperlayer];
    self.backdropLayer = nil;
    self.refractionMask = nil;
    self.sourceLayer.hidden = NO;
    if (self.usesSharedBackdrop) {
        self.hasMaterialConfiguration = YES;
        self.laidOutBounds = CGRectNull;
        [self setNeedsLayout];
        return;
    }

    Class backdropClass = NSClassFromString(@"CABackdropLayer");
    if (backdropClass) {
        self.backdropLayer = [backdropClass layer];
        self.backdropLayer.backgroundColor = UIColor.clearColor.CGColor;
        self.backdropLayer.filters = LGIOS26RefractionFilters();
        LGIOS26SetLayerPrivateValue(self.backdropLayer, @NO, @"layerUsesCoreImageFilters");
        LGIOS26SetLayerPrivateValue(self.backdropLayer, @YES, @"windowServerAware");
        LGIOS26SetLayerPrivateValue(self.backdropLayer, @YES, @"ignoresScreenClip");
        LGIOS26SetLayerPrivateValue(self.backdropLayer, @0.5, @"scale");
        LGIOS26SetLayerPrivateValue(self.backdropLayer,
                                    @"dylv.liquidass.ios26icons",
                                    @"groupNamespace");
        LGIOS26SetLayerPrivateValue(self.backdropLayer,
                                    [NSString stringWithFormat:@"dylv.liquidass.ios26icons.%p", self],
                                    @"groupName");
    } else {
        self.backdropLayer = [CALayer layer];
        self.backdropLayer.backgroundColor =
            [UIColor colorWithWhite:1.0 alpha:0.055].CGColor;
    }
    self.backdropLayer.masksToBounds = YES;
    self.refractionMask = [CAShapeLayer layer];
    self.refractionMask.fillColor = UIColor.whiteColor.CGColor;
    self.refractionMask.fillRule = kCAFillRuleEvenOdd;
    self.backdropLayer.mask = self.refractionMask;
    [self.layer insertSublayer:self.backdropLayer atIndex:0];

    self.hasMaterialConfiguration = YES;
    self.laidOutBounds = CGRectNull;
    self.laidOutCornerRadius = -1.0;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    CGFloat cornerRadius = self.layer.cornerRadius;
    if (CGRectEqualToRect(bounds, self.laidOutBounds)
        && fabs(cornerRadius - self.laidOutCornerRadius) < 0.01) return;
    self.laidOutBounds = bounds;
    self.laidOutCornerRadius = cornerRadius;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.backdropLayer.frame = bounds;
    self.refractionMask.frame = bounds;
    self.glassLayer.frame = bounds;
    self.sourceLayer.frame = bounds;
    self.glyphHighlightLayer.frame = bounds;
    self.rimBloomLayer.frame = bounds;
    self.rimLayer.frame = bounds;
    self.glossLayer.frame = bounds;
    self.rimBloomMask.frame = bounds;
    self.rimMask.frame = bounds;
    self.glossMask.frame = bounds;
    CGFloat shortest = MIN(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathAddRoundedRect(path, NULL, bounds, cornerRadius, cornerRadius);
    if (self.currentAlgorithm != LGIOS26IconAlgorithmAppleMitigated) {
        // The older algorithms only use refraction as a static bevel ring.
        CGFloat bezel = LGIOS26Clamp(shortest * 0.13, 5.0, 8.5);
        CGRect innerRect = CGRectInset(bounds, bezel, bezel);
        CGFloat innerRadius = MAX(0.0, cornerRadius - bezel * 0.72);
        CGPathAddRoundedRect(path, NULL, innerRect, innerRadius, innerRadius);
    }
    self.refractionMask.path = path;
    CGPathRelease(path);
    CGFloat rimInset = self.rimMask.lineWidth * 0.5 + 0.15;
    CGRect rimRect = CGRectInset(bounds, rimInset, rimInset);
    self.rimMask.path = [UIBezierPath bezierPathWithRoundedRect:rimRect
                                                   cornerRadius:MAX(0.0, cornerRadius - rimInset)].CGPath;
    CGFloat bloomInset = self.rimBloomMask.lineWidth * 0.5 + 0.15;
    CGRect bloomRect = CGRectInset(bounds, bloomInset, bloomInset);
    self.rimBloomMask.path = [UIBezierPath bezierPathWithRoundedRect:bloomRect
                                                        cornerRadius:MAX(0.0, cornerRadius - bloomInset)].CGPath;
    self.glossMask.path = [UIBezierPath bezierPathWithRoundedRect:bounds
                                                      cornerRadius:cornerRadius].CGPath;
    self.glassLayer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:bounds
                                                            cornerRadius:cornerRadius].CGPath;
    [CATransaction commit];
}

- (void)updateWithImage:(UIImage *)image
           cornerRadius:(CGFloat)cornerRadius
                    mode:(LGIOS26IconMode)mode
               algorithm:(LGIOS26IconAlgorithm)algorithm
          darkAppearance:(BOOL)darkAppearance
                 tintHue:(CGFloat)tintHue
           tintIntensity:(CGFloat)tintIntensity
   preservesSubjectColor:(BOOL)preservesSubjectColor
        imageIsProcessed:(BOOL)imageIsProcessed {
    if (!image.CGImage) return;
    tintHue = tintHue - floor(tintHue);
    tintIntensity = LGIOS26Clamp(tintIntensity, 0.0, 1.0);
    // Layout callbacks must be a no-op for the same retained input/settings,
    // including when the shared processed-image cache has evicted its entry.
    if (self.hasConfiguration && self.currentInputImage.CGImage == image.CGImage
        && self.currentMode == mode && self.currentAlgorithm == algorithm
        && self.currentDarkAppearance == darkAppearance
        && self.currentPreservesSubjectColor == preservesSubjectColor
        && fabs(self.currentTintHue - tintHue) <= 0.0005
        && fabs(self.currentTintIntensity - tintIntensity) <= 0.0005
        && fabs(self.layer.cornerRadius - cornerRadius) < 0.01) return;
    [self configureMaterial];
    UIImage *sourceImage;
    if (imageIsProcessed) {
        sourceImage = image;
    } else if (algorithm == LGIOS26IconAlgorithmAppleMitigated) {
        UIImage *mitigated = LGIOS26AppleMitigatedIconImage(
            image, darkAppearance, preservesSubjectColor);
        sourceImage = mode == LGIOS26IconModeTinted
            ? LGIOS26TintedIconImage(mitigated, tintHue, tintIntensity)
            : mitigated;
    } else if (mode == LGIOS26IconModeTinted) {
        sourceImage = LGIOS26GrayscaleIconImage(image);
    } else {
        sourceImage = LGIOS26ProcessedIconImage(image, LGIOS26IconModeClear);
    }
    const void *identity = (const void *)sourceImage.CGImage;
    BOOL appearanceChanged = !self.hasConfiguration
        || self.currentImageIdentity != identity
        || self.currentMode != mode
        || self.currentAlgorithm != algorithm
        || self.currentDarkAppearance != darkAppearance
        || self.currentPreservesSubjectColor != preservesSubjectColor
        || fabs(self.currentTintHue - tintHue) > 0.0005
        || fabs(self.currentTintIntensity - tintIntensity) > 0.0005;

    if (self.currentImageIdentity != identity) {
        self.sourceLayer.contents = (__bridge id)sourceImage.CGImage;
        self.sourceLayer.contentsScale = sourceImage.scale > 0.0
            ? sourceImage.scale : UIScreen.mainScreen.scale;
        // AppleMitigated already bakes relief into its bitmap. Deriving another
        // contour from a globally processed image outlines those outlines again.
        UIImage *contourImage = algorithm == LGIOS26IconAlgorithmAppleMitigated
            ? nil : LGIOS26ContourHighlightImage(image);
        self.glyphHighlightLayer.contents = contourImage.CGImage
            ? (__bridge id)contourImage.CGImage : nil;
        self.glyphHighlightLayer.contentsScale = contourImage.scale > 0.0
            ? contourImage.scale : UIScreen.mainScreen.scale;
    }
    self.layer.cornerRadius = cornerRadius;
    self.backdropLayer.cornerRadius = cornerRadius;
    self.glassLayer.cornerRadius = cornerRadius;
    self.sourceLayer.cornerRadius = cornerRadius;
    self.glyphHighlightLayer.cornerRadius = cornerRadius;
    if (@available(iOS 13.0, *)) {
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.backdropLayer.cornerCurve = kCACornerCurveContinuous;
        self.glassLayer.cornerCurve = kCACornerCurveContinuous;
        self.sourceLayer.cornerCurve = kCACornerCurveContinuous;
        self.glyphHighlightLayer.cornerCurve = kCACornerCurveContinuous;
    }
    [self setNeedsLayout];
    if (!appearanceChanged) return;

    self.currentImageIdentity = identity;
    self.currentInputImage = image;
    self.currentMode = mode;
    self.currentAlgorithm = algorithm;
    self.currentDarkAppearance = darkAppearance;
    self.currentTintHue = tintHue;
    self.currentTintIntensity = tintIntensity;
    self.currentPreservesSubjectColor = preservesSubjectColor;
    self.hasConfiguration = YES;
    BOOL appleMitigated = algorithm == LGIOS26IconAlgorithmAppleMitigated;
    self.backdropLayer.backgroundColor = darkAppearance
        ? [UIColor colorWithWhite:0.0 alpha:0.20].CGColor
        : UIColor.clearColor.CGColor;
    if (mode == LGIOS26IconModeClear) {
        self.backdropLayer.opacity = appleMitigated
            ? (darkAppearance ? 0.74f : 0.70f)
            : (darkAppearance ? 0.88f : 0.82f);
        self.glassLayer.colors = darkAppearance
            ? @[
                (id)[UIColor colorWithWhite:0.0 alpha:0.28].CGColor,
                (id)[UIColor colorWithWhite:0.0 alpha:0.16].CGColor,
                (id)[UIColor colorWithWhite:1.0 alpha:0.025].CGColor,
            ]
            : @[
                (id)[UIColor colorWithWhite:1.0 alpha:0.095].CGColor,
                (id)[UIColor colorWithWhite:1.0 alpha:0.018].CGColor,
                (id)[UIColor colorWithWhite:0.0 alpha:0.032].CGColor,
            ];
        self.sourceLayer.hidden = NO;
        self.sourceLayer.opacity = appleMitigated ? 1.0f : 0.90f;
        self.rimLayer.opacity = appleMitigated ? 0.42f : 0.72f;
        self.rimBloomLayer.opacity = appleMitigated ? 0.22f : 0.38f;
        self.glossLayer.opacity = appleMitigated ? 0.28f : 0.42f;
        self.glyphHighlightLayer.opacity = appleMitigated
            ? (darkAppearance ? 0.15f : 0.12f)
            : (darkAppearance ? 0.70f : 0.60f);
        self.rimBloomLayer.colors = @[
            (id)UIColor.clearColor.CGColor,
            (id)UIColor.clearColor.CGColor,
            (id)[UIColor colorWithRed:0.55 green:0.90 blue:1.0 alpha:0.38].CGColor,
            (id)[UIColor colorWithRed:1.0 green:0.82 blue:0.58 alpha:0.12].CGColor,
            (id)UIColor.clearColor.CGColor,
            (id)UIColor.clearColor.CGColor,
        ];
        self.rimLayer.colors = @[
            (id)UIColor.clearColor.CGColor,
            (id)UIColor.clearColor.CGColor,
            (id)[UIColor colorWithRed:0.88 green:0.97 blue:1.0 alpha:0.78].CGColor,
            (id)[UIColor colorWithRed:1.0 green:0.94 blue:0.82 alpha:0.24].CGColor,
            (id)UIColor.clearColor.CGColor,
            (id)[UIColor colorWithWhite:0.0 alpha:0.07].CGColor,
            (id)UIColor.clearColor.CGColor,
        ];
    } else {
        UIColor *tint = [UIColor colorWithHue:tintHue
                                   saturation:0.78
                                   brightness:0.92
                                        alpha:1.0];
        UIColor *brightTint = [UIColor colorWithHue:tintHue
                                         saturation:0.42
                                         brightness:1.0
                                              alpha:1.0];
        UIColor *darkTint = [UIColor colorWithHue:tintHue
                                       saturation:0.88
                                       brightness:0.46
                                            alpha:1.0];
        self.backdropLayer.opacity = darkAppearance ? 0.82f : 0.72f;
        self.glassLayer.colors = @[
            (id)[brightTint colorWithAlphaComponent:0.12 + 0.42 * tintIntensity].CGColor,
            (id)[tint colorWithAlphaComponent:0.06 + 0.34 * tintIntensity].CGColor,
            (id)[darkTint colorWithAlphaComponent:0.05 + 0.28 * tintIntensity].CGColor,
        ];
        self.sourceLayer.hidden = NO;
        self.sourceLayer.opacity = 0.84f;
        self.rimLayer.colors = @[
            (id)UIColor.clearColor.CGColor,
            (id)UIColor.clearColor.CGColor,
            (id)[brightTint colorWithAlphaComponent:0.86].CGColor,
            (id)[tint colorWithAlphaComponent:0.40].CGColor,
            (id)UIColor.clearColor.CGColor,
            (id)[darkTint colorWithAlphaComponent:0.16].CGColor,
            (id)UIColor.clearColor.CGColor,
        ];
        self.rimBloomLayer.colors = @[
            (id)UIColor.clearColor.CGColor,
            (id)UIColor.clearColor.CGColor,
            (id)[brightTint colorWithAlphaComponent:0.52].CGColor,
            (id)[tint colorWithAlphaComponent:0.20].CGColor,
            (id)UIColor.clearColor.CGColor,
            (id)UIColor.clearColor.CGColor,
        ];
        self.rimLayer.opacity = 0.74f;
        self.rimBloomLayer.opacity = 0.42f;
        self.glossLayer.opacity = 0.40f;
        self.glyphHighlightLayer.opacity = 0.34f;
    }
}

@end
