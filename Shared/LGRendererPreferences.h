#pragma once

#import <Foundation/Foundation.h>
#import "LGHostRegistry.h"

// Only renderer tuning is scoped. Surface enable flags, fonts, clock rendering
// mode, icon processing and other feature controls deliberately remain shared.
static inline NSDictionary<NSString *, NSString *> *LGRendererPreferenceKeyMap(void) {
    static NSDictionary<NSString *, NSString *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *fields = @[@"BezelRatio", @"BezelWidth", @"BezelMode", @"GlassThickness",
            @"RefractionScale", @"RefractiveIndex", @"Blur", @"SpecularOpacity", @"SpecularEnabled",
            @"DispersionStrength", @"DispersionEnabled", @"LightTintColor", @"DarkTintColor",
            @"TintR", @"TintG", @"TintB", @"TintStrength", @"CornerRadius"];
        NSMutableDictionary *keys = [NSMutableDictionary dictionary];
        for (size_t i = 0; i < LGHostIdentifierCount; ++i) {
            NSString *prefix = [NSString stringWithUTF8String:kLGHostRegistry[i].preferencePrefix];
            for (NSString *field in fields) {
                NSString *key = [NSString stringWithFormat:@"%@.%@", prefix, field];
                keys[key] = [@"Enhanced." stringByAppendingString:key];
            }
        }
        for (NSString *key in @[@"Global.Quality", @"Renderer.FresnelGlareStrength",
                               @"Renderer.BlurMode", @"Clock.FPS", @"Specular.Motion.Enabled",
                               @"Specular.Motion.Sensitivity", @"Keyboard.Overhang",
                               @"Keyboard.KeyRadius", @"ControlCenter.FullscreenBackdropBlurRadius"])
            keys[key] = [@"Enhanced." stringByAppendingString:key];
        map = keys.copy;
    });
    return map;
}

static inline NSString *LGRendererPreferenceKey(NSString *key, BOOL enhanced) {
    if (!key.length || !enhanced) return key;
    return LGRendererPreferenceKeyMap()[key] ?: key;
}

static inline NSString *LGRendererBasePreferenceKey(NSString *key) {
    return [key hasPrefix:@"Enhanced."] ? [key substringFromIndex:9] : key;
}

// Build a logical-key view only when the backend reloads settings. Missing
// Enhanced values stay missing, allowing upstream defaults instead of legacy
// fallback. Classic keeps the original dictionary and values untouched.
static inline NSDictionary *LGRendererPreferenceValues(NSDictionary *stored, BOOL enhanced) {
    if (!enhanced) return stored ?: @{};
    NSMutableDictionary *values = [stored mutableCopy] ?: [NSMutableDictionary dictionary];
    [LGRendererPreferenceKeyMap() enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *scoped, BOOL *stop) {
        (void)stop;
        [values removeObjectForKey:key];
        if (stored[scoped]) values[key] = stored[scoped];
    }];
    return values.copy;
}
