#pragma once

#import <Foundation/Foundation.h>
#include <math.h>

// Old ratios depend on runtime surface geometry; never destructively convert
// them into a guessed fixed width. Explicit mode selections take precedence.
static inline BOOL LGBezelUsesPointWidth(BOOL enhanced, id mode, id ratio,
                                          id width, float defaultWidth) {
    if (!enhanced) return NO;
    if ([mode isKindOfClass:NSString.class] && [mode length])
        return [mode isEqualToString:@"points"];
    if ([width isKindOfClass:NSNumber.class] && isfinite([width doubleValue])) return YES;
    if ([ratio isKindOfClass:NSNumber.class]) return NO;
    return defaultWidth >= 0.0f;
}

static inline float LGBezelPointWidth(id value, float fallback) {
    if (fallback < 0.0f) fallback = 20.0f;
    double width = [value isKindOfClass:NSNumber.class] ? [value doubleValue] : fallback;
    if (!isfinite(width)) width = fallback;
    return fminf(80.0f, fmaxf(0.0f, (float)width));
}

static inline float LGBezelWidthPixels(BOOL points, float width, float ratio,
                                        float shortest, float pixelsPerPoint,
                                        float legacyCap) {
    if (!points) return fminf(ratio * shortest, legacyCap);
    return fminf(width * fmaxf(0.1f, pixelsPerPoint), shortest * 0.5f);
}
