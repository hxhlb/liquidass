#pragma once

#import <Foundation/Foundation.h>
#include <math.h>

// Classic uses ratios; Enhanced uses upstream point widths.
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
