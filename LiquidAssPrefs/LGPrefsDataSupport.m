#import "LGPrefsDataSupport.h"
#import "LGPRootListController.h"
#import "LGPrefsLiquidSlider.h"
#import "LGPrefsLiquidSwitch.h"
#import "../Shared/LGSharedSupport.h"
#import "../Shared/LGHostRegistry.h"
#import "../Shared/LGBezelGeometry.h"
#import "../Shared/LGRendererPreferences.h"
#import <notify.h>

NSString * const kLGPrefsUIRefreshNotification = @"LGPrefsUIRefreshNotification";
NSString * const kLGPrefsRespringChangedNotification = @"LGPrefsRespringChangedNotification";
NSString * const kLGPrefsLiveAppliedNotification = @"LGPrefsLiveAppliedNotification";
NSString * const kLGLastSurfaceKey = @"LGPrefsLastSurface";
NSString * const kLGPrefsLanguageChangedNotification = @"LGPrefsLanguageChangedNotification";
NSString * const kLGPrefsLanguageKey = @"LGPrefsLanguage";
static NSString * const kLGNeedsRespringKey = @"LGPrefsNeedsRespring";
static NSString * const kLGRespringBarDismissedKey = @"LGPrefsRespringBarDismissed";
static dispatch_queue_t sLGPrefsWriteQueue;
static NSString * const kLGDynamicDefaultPrefix = @"__dynamic_default.";
static NSMutableDictionary<NSString *, id> *sLGPendingPreferences;
static NSMutableSet<NSString *> *sLGPendingPreferenceRemovals;
static BOOL sLGPrefsCommitScheduled;

static void LGEnsurePendingPreferencesInitialized(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sLGPendingPreferences = [NSMutableDictionary dictionary];
        sLGPendingPreferenceRemovals = [NSMutableSet set];
    });
}

static void LGEnsurePreferencesWriteQueueInitialized(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sLGPrefsWriteQueue = dispatch_queue_create("dylv.liquidass.prefswrite", DISPATCH_QUEUE_SERIAL);
    });
}

static void LGSchedulePendingPreferencesCommit(void) {
    if (sLGPrefsCommitScheduled) return;
    sLGPrefsCommitScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        sLGPrefsCommitScheduled = NO;
        LGForceSynchronizePreferences();
    });
}

static BOOL LGSelectedRendererEnhanced(void) {
    return [LGReadPreferenceObject(@"Renderer.Profile", @"classic") isEqual:@"enhanced"];
}

static NSArray<NSString *> *LGExportablePreferenceKeys(void) {
    NSMutableOrderedSet<NSString *> *orderedKeys = [NSMutableOrderedSet orderedSet];
    NSArray<NSArray<NSDictionary *> *> *sources = @[
        LGAllSurfaceItems(),
        LGMoreOptionsItems(),
        LGPrefsSettingsItems()
    ];
    for (NSArray<NSDictionary *> *items in sources) {
        for (NSDictionary *item in items) {
            NSString *key = item[@"key"];
            if (key.length) [orderedKeys addObject:key];
        }
    }
    // Export/import both physical groups regardless of the currently selected
    // engine. Old unprefixed presets remain Classic-only material presets.
    for (NSString *key in LGRendererPreferenceKeyMap()) {
        [orderedKeys addObject:key];
        [orderedKeys addObject:LGRendererPreferenceKey(key, YES)];
    }
    return orderedKeys.array;
}

static NSBundle *LGActiveLocalizationBundle(void) {
    NSString *languageCode = [LGPrefsUIStateDefaults() stringForKey:kLGPrefsLanguageKey];
    if (!languageCode.length) {
        for (NSString *pref in [NSLocale preferredLanguages]) {
            NSString *canon = [NSLocale canonicalLanguageIdentifierFromString:pref] ?: pref;
            if ([canon hasPrefix:@"he"] || [canon hasPrefix:@"iw"]) {
                languageCode = @"he";
                break;
            }
        }
    }
    NSBundle *baseBundle = [NSBundle bundleForClass:[LGPRootListController class]];
    if (!languageCode.length || [languageCode isEqualToString:@"en"]) {
        return baseBundle;
    }

    NSString *bundlePath = [baseBundle pathForResource:languageCode ofType:@"lproj"];
    if (!bundlePath.length && baseBundle.bundlePath.length) {
        NSString *direct = [baseBundle.bundlePath stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.lproj", languageCode]];
        if ([[NSFileManager defaultManager] fileExistsAtPath:direct]) {
            bundlePath = direct;
        } else if ([languageCode isEqualToString:@"he"]) {
            NSString *iw = [baseBundle.bundlePath stringByAppendingPathComponent:@"iw.lproj"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:iw]) {
                bundlePath = iw;
            }
        }
    }
    if (!bundlePath.length) {
        return baseBundle;
    }

    NSBundle *localizedBundle = [NSBundle bundleWithPath:bundlePath];
    return localizedBundle ?: baseBundle;
}

static NSString *LGDisplayNameForLanguageCode(NSString *languageCode) {
    if (!languageCode.length) return @"";
    if ([languageCode isEqualToString:@"en"]) return @"English";
    if ([languageCode isEqualToString:@"he"] || [languageCode isEqualToString:@"iw"]) {
        return @"עברית (Hebrew)";
    }

    NSLocale *displayLocale = [NSLocale currentLocale];
    NSString *localeIdentifier = [NSLocale canonicalLocaleIdentifierFromString:languageCode];
    NSString *name = [displayLocale displayNameForKey:NSLocaleIdentifier value:localeIdentifier];
    if (!name.length) {
        NSDictionary *components = [NSLocale componentsFromLocaleIdentifier:localeIdentifier];
        NSString *baseLanguageCode = components[NSLocaleLanguageCode];
        if (baseLanguageCode.length) {
            name = [displayLocale localizedStringForLanguageCode:baseLanguageCode];
        }
    }
    return name.length ? name : languageCode;
}

static NSArray<NSDictionary *> *LGAvailableLanguageChoices(void) {
    static NSArray<NSDictionary *> *choices;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSBundle *baseBundle = [NSBundle bundleForClass:[LGPRootListController class]];
        NSMutableOrderedSet<NSString *> *codes = [NSMutableOrderedSet orderedSetWithObject:@"en"];

        // 1. Direct filesystem scan of bundle directory
        NSString *bundlePath = baseBundle.bundlePath;
        if (bundlePath.length) {
            NSArray<NSString *> *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:bundlePath error:nil];
            for (NSString *item in items) {
                if ([item.pathExtension isEqualToString:@"lproj"]) {
                    NSString *code = [item stringByDeletingPathExtension];
                    if (code.length && ![code isEqualToString:@"Base"]) {
                        if ([code isEqualToString:@"iw"]) code = @"he";
                        [codes addObject:code];
                    }
                }
            }
        }

        // 2. Official NSBundle localizations property
        for (NSString *loc in [baseBundle localizations]) {
            NSString *code = loc;
            if ([code isEqualToString:@"iw"]) code = @"he";
            if (code.length && ![code isEqualToString:@"Base"]) {
                [codes addObject:code];
            }
        }

        // 3. Fallback: pathsForResourcesOfType
        for (NSString *path in [baseBundle pathsForResourcesOfType:@"lproj" inDirectory:nil]) {
            NSString *code = [[path lastPathComponent] stringByDeletingPathExtension];
            if ([code isEqualToString:@"iw"]) code = @"he";
            if (code.length && ![code isEqualToString:@"Base"]) {
                [codes addObject:code];
            }
        }

        // 4. Guaranteed check for Hebrew
        NSString *hePath = [bundlePath stringByAppendingPathComponent:@"he.lproj"];
        NSString *iwPath = [bundlePath stringByAppendingPathComponent:@"iw.lproj"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:hePath] ||
            [[NSFileManager defaultManager] fileExistsAtPath:iwPath] ||
            [baseBundle pathForResource:@"Localizable" ofType:@"strings" inDirectory:@"he.lproj"] ||
            [baseBundle pathForResource:@"Localizable" ofType:@"strings" inDirectory:@"iw.lproj"]) {
            [codes addObject:@"he"];
        }

        NSMutableArray<NSDictionary *> *dynamicChoices = [NSMutableArray arrayWithCapacity:codes.count];
        for (NSString *languageCode in codes) {
            [dynamicChoices addObject:@{
                @"value": languageCode,
                @"title": LGDisplayNameForLanguageCode(languageCode)
            }];
        }

        [dynamicChoices sortUsingComparator:^NSComparisonResult(NSDictionary *lhs, NSDictionary *rhs) {
            NSString *leftValue = lhs[@"value"];
            NSString *rightValue = rhs[@"value"];
            if ([leftValue isEqualToString:@"en"]) return NSOrderedAscending;
            if ([rightValue isEqualToString:@"en"]) return NSOrderedDescending;
            return [lhs[@"title"] localizedCaseInsensitiveCompare:rhs[@"title"]];
        }];
        choices = [dynamicChoices copy];
    });
    return choices;
}

Class LGPrefsSwitchClass(void) {
    return NSClassFromString(@"LGPrefsLiquidSwitch") ?: [UISwitch class];
}

Class LGPrefsSliderClass(void) {
    return NSClassFromString(@"LGPrefsLiquidSlider") ?: [UISlider class];
}

NSUserDefaults *LGPrefsUIStateDefaults(void) {
    return [NSUserDefaults standardUserDefaults];
}

void LGSynchronizeSurfaceStateDefaults(void) {
    [LGPrefsUIStateDefaults() synchronize];
}

NSString *LGLastSurfaceIdentifier(void) {
    return [LGPrefsUIStateDefaults() stringForKey:kLGLastSurfaceKey];
}

void LGSetLastSurfaceIdentifier(NSString *identifier) {
    NSUserDefaults *defaults = LGPrefsUIStateDefaults();
    if (identifier.length) {
        [defaults setObject:identifier forKey:kLGLastSurfaceKey];
    } else {
        [defaults removeObjectForKey:kLGLastSurfaceKey];
    }
    LGSynchronizeSurfaceStateDefaults();
}

void LGClearLastSurfaceIdentifierIfMatching(NSString *identifier) {
    if (!identifier.length) return;
    NSString *current = LGLastSurfaceIdentifier();
    if ([current isEqualToString:identifier]) {
        LGSetLastSurfaceIdentifier(nil);
    }
}

void LGObservePrefsNotifications(id target) {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:target
               selector:@selector(handlePrefsUIRefresh:)
                   name:kLGPrefsUIRefreshNotification
                 object:nil];
    [center addObserver:target
               selector:@selector(handleRespringStateChanged:)
                   name:kLGPrefsRespringChangedNotification
                 object:nil];
    [center addObserver:target
               selector:@selector(handleLiveApplied:)
                   name:kLGPrefsLiveAppliedNotification
                 object:nil];
}

NSString *LGLocalized(NSString *key) {
    NSBundle *bundle = LGActiveLocalizationBundle();
    NSString *localized = [bundle localizedStringForKey:key value:key table:nil];
    if (localized.length && ![localized isEqualToString:key]) return localized;
    NSBundle *baseBundle = [NSBundle bundleForClass:[LGPRootListController class]];
    return [baseBundle localizedStringForKey:key value:key table:nil];
}

NSString *LGPrefsAppName(void) {
    return LGLocalized(@"prefs.app_name");
}

NSString *LGCurrentPrefsLanguageCode(void) {
    NSString *languageCode = [LGPrefsUIStateDefaults() stringForKey:kLGPrefsLanguageKey];
    if (languageCode.length) return languageCode;
    for (NSString *pref in [NSLocale preferredLanguages]) {
        NSString *code = [NSLocale canonicalLanguageIdentifierFromString:pref] ?: pref;
        if ([code hasPrefix:@"he"] || [code hasPrefix:@"iw"]) {
            return @"he";
        }
    }
    return @"en";
}

void LGSetCurrentPrefsLanguageCode(NSString *languageCode) {
    NSUserDefaults *defaults = LGPrefsUIStateDefaults();
    if (!languageCode.length || [languageCode isEqualToString:@"en"]) {
        [defaults removeObjectForKey:kLGPrefsLanguageKey];
    } else {
        [defaults setObject:languageCode forKey:kLGPrefsLanguageKey];
    }
    LGSynchronizeSurfaceStateDefaults();
    [[NSNotificationCenter defaultCenter] postNotificationName:kLGPrefsLanguageChangedNotification object:nil];
}

BOOL LGNeedsRespring(void) {
    return [LGPrefsUIStateDefaults() boolForKey:kLGNeedsRespringKey];
}

BOOL LGRespringBarDismissed(void) {
    return [LGPrefsUIStateDefaults() boolForKey:kLGRespringBarDismissedKey];
}

void LGSetRespringBarDismissed(BOOL dismissed) {
    NSUserDefaults *defaults = LGPrefsUIStateDefaults();
    [defaults setBool:dismissed forKey:kLGRespringBarDismissedKey];
    LGSynchronizeSurfaceStateDefaults();
}

void LGSetNeedsRespring(BOOL needsRespring) {
    NSUserDefaults *defaults = LGPrefsUIStateDefaults();
    [defaults setBool:needsRespring forKey:kLGNeedsRespringKey];
    if (!needsRespring) {
        [defaults setBool:NO forKey:kLGRespringBarDismissedKey];
    }
    LGSynchronizeSurfaceStateDefaults();
    [[NSNotificationCenter defaultCenter] postNotificationName:kLGPrefsRespringChangedNotification object:nil];
}

void LGForceSynchronizePreferences(void) {
    // Coalesce changes made in one UI event into a single preferences update.
    LGEnsurePendingPreferencesInitialized();

    NSDictionary<NSString *, id> *pendingValues = [sLGPendingPreferences copy];
    NSSet<NSString *> *pendingRemovals = [sLGPendingPreferenceRemovals copy];
    if (pendingValues.count == 0 && pendingRemovals.count == 0) return;
    LGEnsurePreferencesWriteQueueInitialized();
    dispatch_sync(sLGPrefsWriteQueue, ^{
        [pendingValues enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
            (void)stop;
            CFPreferencesSetAppValue((__bridge CFStringRef)key,
                                     (__bridge CFPropertyListRef)value,
                                     (__bridge CFStringRef)LGPrefsDomain);
        }];
        for (NSString *key in pendingRemovals) {
            CFPreferencesSetAppValue((__bridge CFStringRef)key,
                                     NULL,
                                     (__bridge CFStringRef)LGPrefsDomain);
        }
        BOOL wrote = CFPreferencesAppSynchronize((__bridge CFStringRef)LGPrefsDomain);
        LGLog(@"[prefs-apply] committed=%lu removed=%lu wrote=%d; posting Reload",
              (unsigned long)pendingValues.count,
              (unsigned long)pendingRemovals.count,
              wrote);
        notify_post(LGPrefsChangedNotificationCString);
    });

    [sLGPendingPreferences removeAllObjects];
    [sLGPendingPreferenceRemovals removeAllObjects];

    [[NSNotificationCenter defaultCenter]
        postNotificationName:kLGPrefsLiveAppliedNotification object:nil];
}

void LGAfterPendingPreferencesCommit(dispatch_block_t completion) {
    LGForceSynchronizePreferences();
    dispatch_async(sLGPrefsWriteQueue, ^{
        dispatch_async(dispatch_get_main_queue(), completion);
    });
}

NSNumber *LGReadPreference(NSString *key, NSNumber *fallback) {
    id obj = LGReadPreferenceObject(key, fallback);
    return [obj isKindOfClass:[NSNumber class]] ? obj : fallback;
}

id LGReadPreferenceObject(NSString *key, id fallback) {
    LGEnsurePendingPreferencesInitialized();
    if ([sLGPendingPreferences objectForKey:key]) {
        return sLGPendingPreferences[key];
    }
    if ([sLGPendingPreferenceRemovals containsObject:key]) {
        return fallback;
    }
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)LGPrefsDomain);
    id obj = CFBridgingRelease(value);
    return obj ?: fallback;
}

void LGWritePreference(NSString *key, NSNumber *value) {
    LGWritePreferenceObject(key, value);
}

void LGWritePreferenceObject(NSString *key, id value) {
    if (!key.length || !value) return;
    LGEnsurePendingPreferencesInitialized();
    sLGPendingPreferences[key] = value;
    [sLGPendingPreferenceRemovals removeObject:key];
    LGLog(@"[prefs-pending] staged %@=%@", key, value);
    LGSchedulePendingPreferencesCommit();
}

void LGWritePreferenceAndMaybeRequireRespring(NSString *key, NSNumber *value) {
    LGWritePreference(key, value);
}

void LGRemovePreference(NSString *key) {
    if (!key.length) return;
    LGEnsurePendingPreferencesInitialized();
    [sLGPendingPreferences removeObjectForKey:key];
    [sLGPendingPreferenceRemovals addObject:key];
    LGLog(@"[prefs-pending] staged removal %@", key);
    LGSchedulePendingPreferencesCommit();
}

NSDictionary *LGSwitchSetting(NSString *key, NSString *title, NSString *subtitle, BOOL fallback) {
    key = LGRendererPreferenceKey(key, LGSelectedRendererEnhanced());
    return @{
        @"type": @"switch",
        @"key": key,
        @"title": title,
        @"subtitle": subtitle ?: @"",
        @"default": @(fallback)
    };
}

NSDictionary *LGSectionSetting(NSString *title, NSString *subtitle) {
    return @{
        @"type": @"section",
        @"title": title ?: @"",
        @"subtitle": subtitle ?: @""
    };
}

static NSDictionary *LGSpacerSetting(CGFloat height, CGFloat afterSpacing) {
    return @{
        @"type": @"section",
        @"title": @"",
        @"subtitle": @"",
        @"height": @(height),
        @"after_spacing": @(afterSpacing)
    };
}

static NSDictionary *LGAboutContentSetting(void) {
    return @{
        @"type": @"about_content"
    };
}

NSDictionary *LGNavSetting(NSString *title, NSString *subtitle, NSString *action) {
    return @{
        @"type": @"nav",
        @"title": title ?: @"",
        @"subtitle": subtitle ?: @"",
        @"action": action ?: @""
    };
}

static NSDictionary *LGKeyedNavSetting(NSString *key, NSString *title, NSString *subtitle, NSString *action) {
    return @{
        @"type": @"nav",
        @"key": key ?: @"",
        @"title": title ?: @"",
        @"subtitle": subtitle ?: @"",
        @"action": action ?: @"",
        @"default": @""
    };
}

NSDictionary *LGMenuSetting(NSString *key, NSString *title, NSString *subtitle, NSString *fallback, NSArray<NSDictionary *> *choices) {
    key = LGRendererPreferenceKey(key, LGSelectedRendererEnhanced());
    return @{
        @"type": @"menu",
        @"key": key ?: @"",
        @"title": title ?: @"",
        @"subtitle": subtitle ?: @"",
        @"default": fallback ?: @"",
        @"choices": choices ?: @[]
    };
}

static NSDictionary *LGStringSetting(NSString *key, NSString *title, NSString *subtitle,
                                     NSString *fallback, NSString *placeholder) {
    key = LGRendererPreferenceKey(key, LGSelectedRendererEnhanced());
    return @{
        @"type": @"string",
        @"key": key ?: @"",
        @"title": title ?: @"",
        @"subtitle": subtitle ?: @"",
        @"default": fallback ?: @"",
        @"placeholder": placeholder ?: @""
    };
}

NSDictionary *LGSliderSetting(NSString *key, NSString *title, NSString *subtitle,
                              CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals) {
    key = LGRendererPreferenceKey(key, LGSelectedRendererEnhanced());
    return @{
        @"type": @"slider",
        @"key": key,
        @"title": title,
        @"subtitle": subtitle ?: @"",
        @"default": @(fallback),
        @"min": @(min),
        @"max": @(max),
        @"decimals": @(decimals)
    };
}

static NSDictionary *LGSettingControlledByKey(NSDictionary *item, NSString *enabledKey, id enabledDefault) {
    NSMutableDictionary *copy = [item mutableCopy];
    if (enabledKey.length) copy[@"enabled_key"] = LGRendererPreferenceKey(enabledKey, LGSelectedRendererEnhanced());
    if (enabledDefault) copy[@"enabled_default"] = enabledDefault;
    return [copy copy];
}

static NSArray<NSDictionary *> *LGSettingsControlledByKey(
    NSArray<NSDictionary *> *items, NSString *enabledKey, id enabledDefault) {
    NSMutableArray<NSDictionary *> *controlled =
        [NSMutableArray arrayWithCapacity:items.count];
    for (NSDictionary *item in items) {
        [controlled addObject:LGSettingControlledByKey(
            item, enabledKey, enabledDefault)];
    }
    return [controlled copy];
}

NSDictionary *LGGlassEnabledSetting(NSString *key, BOOL fallback) {
    NSMutableDictionary *item = [LGSwitchSetting(key,
                                                 LGLocalized(@"prefs.control.enabled"),
                                                 LGLocalized(@"prefs.subtitle.enabled"),
                                                 fallback) mutableCopy];
    item[@"controls_following_panel"] = @YES;
    return [item copy];
}

static const CGFloat kLGUniversalBlurMax = 50.0f;
static const CGFloat kLGUniversalThicknessMax = 500.0f;
static const CGFloat kLGUniversalRefractiveIndexMax = 5.0f;
static const CGFloat kLGUniversalRefractionMax = 5.0f;
static const CGFloat kLGUniversalDispersionMax = 10.0f;

static NSDictionary *LGGlassBlurSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals);
static NSDictionary *LGGlassThicknessSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals);
static NSDictionary *LGGlassRefractiveIndexSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals);
static NSDictionary *LGGlassRefractionSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals);
static NSDictionary *LGGlassSpecularSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals);
static const CGFloat kLGUniversalQualityMax = 1.0f;
static const CGFloat kLGCoverSheetCornerRadiusPoints = 64.0f;

static CGFloat LGDefaultBezelRatioForHost(NSString *prefix, const LGHostDefinition *host) {
    if (!host || ![prefix isEqualToString:@"CoverSheet"]) return host ? host->bezelRatio : 0.0;
    CGFloat screenWidth = UIScreen.mainScreen.bounds.size.width;
    CGFloat cornerRadius = LGReadPreference(@"CoverSheet.CornerRadius",
                                            @(kLGCoverSheetCornerRadiusPoints)).doubleValue;
    return screenWidth > 0.0 ? cornerRadius / screenWidth : host->bezelRatio;
}

NSArray<NSDictionary *> *LGRendererItemsForHostPrefix(NSString *prefix) {
    BOOL enhanced = LGSelectedRendererEnhanced();
    const LGHostDefinition *host = LGHostDefinitionForProfile(prefix.UTF8String, enhanced);
    if (!host) return @[];
    NSString *(^key)(NSString *) = ^NSString *(NSString *field) {
        return LGRendererPreferenceKey([prefix stringByAppendingFormat:@".%@", field], enhanced);
    };
    NSString *lightTint = [NSString stringWithUTF8String:host->lightTintHex];
    NSString *darkTint = [NSString stringWithUTF8String:host->darkTintHex];
    CGFloat dispersionMax = LGHostIdentifierForDefinition(host) == LGHostIdentifierCoverSheet
        ? kLGUniversalDispersionMax : 2.0f;
    CGFloat bezelRatioDefault = enhanced ? 0.0 : LGDefaultBezelRatioForHost(prefix, host);
    BOOL enabledByDefault = ![prefix isEqualToString:@"AppIcons"]
        && ![prefix isEqualToString:@"DynamicIsland"];
    NSMutableDictionary *enabled = [LGGlassEnabledSetting(key(@"Enabled"), enabledByDefault) mutableCopy];
    if ([prefix isEqualToString:@"DynamicIsland"]) enabled[@"requires_island_restart"] = @YES;
    NSMutableArray<NSDictionary *> *items = [NSMutableArray arrayWithArray:@[
        enabled.copy,
        (enhanced || [prefix isEqualToString:@"Clock"])
            ? LGSliderSetting(key(@"BezelWidth"), LGLocalized(@"prefs.control.bezel_width"),
                              LGLocalized(@"prefs.subtitle.bezel_width"),
                              enhanced ? host->bezelWidthPoints : 12.0,
                              enhanced ? 0.0 : 1.0, enhanced ? 80.0 : 40.0, 1)
            : LGSliderSetting(key(@"BezelRatio"), LGLocalized(@"prefs.control.bezel_ratio"),
                              LGLocalized(@"prefs.subtitle.bezel_ratio"),
                              bezelRatioDefault, 0.0, 1.0, 3),
        LGGlassThicknessSetting(key(@"GlassThickness"), host->glassThickness, 0.0, 220.0, 1),
        LGGlassRefractionSetting(key(@"RefractionScale"), host->refractionScale, 0.0, 5.0, 2),
        LGGlassRefractiveIndexSetting(key(@"RefractiveIndex"), host->refractiveIndex, 1.0, 3.0, 2),
        LGSwitchSetting(key(@"DispersionEnabled"),
                        LGLocalized(@"prefs.control.chromatic_dispersion"),
                        LGLocalized(@"prefs.subtitle.chromatic_dispersion"),
                        host->dispersionStrength > 0.001f),
        LGSliderSetting(key(@"DispersionStrength"),
                        LGLocalized(@"prefs.control.dispersion_strength"),
                        LGLocalized(@"prefs.subtitle.dispersion_strength"),
                        host->dispersionStrength, 1.0, dispersionMax, 1),
        LGGlassSpecularSetting(key(@"SpecularOpacity"), host->specularOpacity, 0.0, 1.0, 2),
        LGGlassBlurSetting(key(@"Blur"), host->blur, 0.0, 50.0, 1),
    ]];
    if (![prefix isEqualToString:@"AssistiveTouch"]) {
        [items addObject:@{
            @"type": @"color", @"key": key(@"LightTintColor"),
            @"title": LGLocalized(@"prefs.control.light_tint_color"),
            @"subtitle": LGLocalized(@"prefs.subtitle.light_tint_color"), @"default": lightTint
        }];
        [items addObject:@{
            @"type": @"color", @"key": key(@"DarkTintColor"),
            @"title": LGLocalized(@"prefs.control.dark_tint_color"),
            @"subtitle": LGLocalized(@"prefs.subtitle.dark_tint_color"), @"default": darkTint
        }];
    }
    if ([prefix isEqualToString:@"CoverSheet"]) {
        [items insertObject:LGSliderSetting(key(@"CornerRadius"),
                                            LGLocalized(@"prefs.control.corner_radius"),
                                            LGLocalized(@"prefs.subtitle.corner_radius"),
                                            LGReadPreference(key(@"CornerRadius"),
                                                             @(kLGCoverSheetCornerRadiusPoints)).doubleValue,
                                            0.0, 200.0, 1)
                      atIndex:2];
    }
    if ([prefix isEqualToString:@"Notification"]) {
        [items addObject:LGSettingControlledByKey(
            LGMenuSetting(@"Notification.LabelColor",
                          LGLocalized(@"prefs.notification.label_color.title"),
                          LGLocalized(@"prefs.notification.label_color.subtitle"),
                          @"white",
                          @[
                              @{ @"value": @"white", @"title": LGLocalized(@"prefs.color.white") },
                              @{ @"value": @"black", @"title": LGLocalized(@"prefs.color.black") },
                          ]),
            @"Notification.Enabled", @YES)];
    }
    return [items copy];
}

BOOL LGPrefsItemIsEnabled(NSDictionary *item) {
    return ![item[@"requires_enhanced_renderer"] boolValue] || LGSelectedRendererEnhanced();
}

BOOL LGPrefsItemIsVisible(NSDictionary *item) {
    NSString *visibleKey = item[@"visible_key"];
    NSArray *visibleValues = item[@"visible_values"];
    if (!visibleKey.length || visibleValues.count == 0) return YES;

    id fallback = item[@"visible_default"];
    id storedValue = LGReadPreferenceObject(visibleKey, fallback);
    NSString *currentValue = nil;
    if ([storedValue isKindOfClass:NSString.class]) {
        currentValue = storedValue;
    } else if ([storedValue respondsToSelector:@selector(stringValue)]) {
        currentValue = [storedValue stringValue];
    } else if ([storedValue respondsToSelector:@selector(description)]) {
        currentValue = [storedValue description];
    }
    if (!currentValue.length && [fallback isKindOfClass:NSString.class]) {
        currentValue = fallback;
    }
    return currentValue.length && [visibleValues containsObject:currentValue];
}

static NSArray<NSDictionary *> *LGJoinItemGroups(NSArray<NSArray<NSDictionary *> *> *groups) {
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    for (NSArray<NSDictionary *> *group in groups) [items addObjectsFromArray:group];
    return items;
}

static NSDictionary *LGGlassBlurSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals) {
    return LGSliderSetting(key, LGLocalized(@"prefs.control.blur"), LGLocalized(@"prefs.subtitle.blur"), fallback, min, kLGUniversalBlurMax, decimals);
}

static NSDictionary *LGGlassThicknessSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals) {
    return LGSliderSetting(key, LGLocalized(@"prefs.control.glass_thickness"), LGLocalized(@"prefs.subtitle.glass_thickness"), fallback, min, kLGUniversalThicknessMax, decimals);
}

static NSDictionary *LGGlassRefractiveIndexSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals) {
    return LGSliderSetting(key, LGLocalized(@"prefs.control.refractive_index"), LGLocalized(@"prefs.subtitle.refractive_index"), fallback, min, kLGUniversalRefractiveIndexMax, decimals);
}

static NSDictionary *LGGlassRefractionSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals) {
    return LGSliderSetting(key, LGLocalized(@"prefs.control.refraction"), LGLocalized(@"prefs.subtitle.refraction"), fallback, min, kLGUniversalRefractionMax, decimals);
}

static NSDictionary *LGGlassSpecularSetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals) {
    (void)fallback; (void)min; (void)max; (void)decimals;

    NSString *enabledKey = [key hasSuffix:@".SpecularOpacity"]
        ? [[key substringToIndex:key.length - @".SpecularOpacity".length]
           stringByAppendingString:@".SpecularEnabled"]
        : key;
    return LGSwitchSetting(enabledKey,
                           LGLocalized(@"prefs.control.specular"),
                           LGLocalized(@"prefs.subtitle.specular"), YES);
}

NSDictionary *LGGlassQualitySetting(NSString *key, CGFloat fallback, CGFloat min, CGFloat max, NSInteger decimals) {
    return LGSliderSetting(key,
                           LGLocalized(@"prefs.control.quality"),
                           LGLocalized(@"prefs.subtitle.quality"),
                           fallback,
                           min,
                           MIN(max, kLGUniversalQualityMax),
                           decimals);
}

NSString *LGFormatSliderValue(CGFloat value, NSInteger decimals) {
    return [NSString stringWithFormat:[NSString stringWithFormat:@"%%.%ldf", (long)decimals], value];
}

static NSString *LGSurfaceGroupSortTitle(NSArray<NSDictionary *> *items) {
    for (NSDictionary *item in items) {
        if ([item[@"type"] isEqualToString:@"section"]) {
            NSString *title = item[@"title"];
            if (title.length) return title;
        }
    }
    NSString *title = items.firstObject[@"title"];
    return title ?: @"";
}

static NSArray<NSDictionary *> *LGSurfaceItemsBySortingSectionGroups(NSArray<NSDictionary *> *items) {
    NSMutableArray<NSDictionary *> *leadingItems = [NSMutableArray array];
    NSMutableArray<NSArray<NSDictionary *> *> *groups = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *currentGroup = nil;
    for (NSDictionary *item in items) {
        if ([item[@"type"] isEqualToString:@"section"]) {
            NSString *title = item[@"title"];
            NSString *subtitle = item[@"subtitle"];
            if (!title.length && !subtitle.length) {
                if (currentGroup) {
                    [currentGroup addObject:item];
                } else {
                    [leadingItems addObject:item];
                }
                continue;
            }
            if (currentGroup.count) {
                [groups addObject:[currentGroup copy]];
            }
            currentGroup = [NSMutableArray arrayWithObject:item];
            continue;
        }
        if (currentGroup) {
            [currentGroup addObject:item];
        } else {
            [leadingItems addObject:item];
        }
    }
    if (currentGroup.count) {
        [groups addObject:[currentGroup copy]];
    }

    NSArray<NSArray<NSDictionary *> *> *sortedGroups = [groups sortedArrayUsingComparator:^NSComparisonResult(NSArray<NSDictionary *> *lhs,
                                                                                                               NSArray<NSDictionary *> *rhs) {
        NSString *leftTitle = LGSurfaceGroupSortTitle(lhs);
        NSString *rightTitle = LGSurfaceGroupSortTitle(rhs);
        NSComparisonResult result = [leftTitle localizedCaseInsensitiveCompare:rightTitle];
        if (result != NSOrderedSame) return result;
        return [leftTitle compare:rightTitle];
    }];
    NSMutableArray<NSDictionary *> *sortedItems = [leadingItems mutableCopy];
    for (NSArray<NSDictionary *> *group in sortedGroups) {
        [sortedItems addObjectsFromArray:group];
    }
    return [sortedItems copy];
}

NSArray<NSDictionary *> *LGDockItems(void) {
    return LGRendererItemsForHostPrefix(@"Dock");
}

NSArray<NSDictionary *> *LGKeyboardItems(void) {
    return LGJoinItemGroups(@[
        LGRendererItemsForHostPrefix(@"Keyboard"),
        LGSettingsControlledByKey(@[
            LGSwitchSetting(@"Keyboard.CustomFont.Enabled",
                            LGLocalized(@"prefs.control.keyboard_custom_font"),
                            LGLocalized(@"prefs.subtitle.keyboard_custom_font"),
                            YES),
            LGSectionSetting(LGLocalized(@"prefs.section.keyboard_geometry.title"),
                             LGLocalized(@"prefs.section.keyboard_geometry.subtitle")),
            LGSliderSetting(@"Keyboard.CornerRadius",
                            LGLocalized(@"prefs.control.corner_radius"),
                            LGLocalized(@"prefs.subtitle.corner_radius"),
                            LGKeyboardDefaultCornerRadius, 0.0, 60.0, 1),
            LGSliderSetting(@"Keyboard.KeyRadius",
                            LGLocalized(@"prefs.control.keyboard_key_radius"),
                            LGLocalized(@"prefs.subtitle.keyboard_key_radius"),
                            LGKeyboardDefaultKeyRadius, 0.0, 23.0, 1),
            LGSliderSetting(@"Keyboard.Overhang",
                            LGLocalized(@"prefs.control.keyboard_overhang"),
                            LGLocalized(@"prefs.subtitle.keyboard_overhang"),
                            LGKeyboardDefaultOverhang, 0.0, 60.0, 1),
        ], @"Keyboard.Enabled", @YES),
    ]);
}

NSArray<NSDictionary *> *LGFolderItems(void) {
    return LGJoinItemGroups(@[
        @[
            LGSectionSetting(LGLocalized(@"prefs.section.folder_icons.title"), nil),
        ],
        LGRendererItemsForHostPrefix(@"FolderIcon"),
        @[
            LGSectionSetting(LGLocalized(@"prefs.section.folder_open.title"), nil),
        ],
        LGRendererItemsForHostPrefix(@"OpenFolder"),
    ]);
}

NSArray<NSDictionary *> *LGAppIconItems(void) {
    return LGJoinItemGroups(@[
        @[
            LGSectionSetting(LGLocalized(@"prefs.section.app_icons.title"), nil),
        ],
        LGRendererItemsForHostPrefix(@"AppIcons"),
    ]);
}

NSArray<NSDictionary *> *LGAppIconExItems(void) {
    return @[
        LGGlassEnabledSetting(@"AppIconsEx.Enabled", NO),
        LGSliderSetting(@"AppIconsEx.Intensity",
                        LGLocalized(@"prefs.control.highlight_intensity"),
                        LGLocalized(@"prefs.subtitle.highlight_intensity"),
                        0.65, 0.0, 1.0, 2),
        LGSwitchSetting(@"AppIconsEx.Motion.Enabled",
                        LGLocalized(@"prefs.control.motion_highlights"),
                        LGLocalized(@"prefs.subtitle.motion_highlights"), NO),
    ];
}

NSArray<NSDictionary *> *LGIOS26IconItems(void) {
    NSDictionary *algorithm = LGMenuSetting(
        @"IOS26Icons.Algorithm",
        LGLocalized(@"prefs.control.icon_algorithm"),
        LGLocalized(@"prefs.subtitle.icon_algorithm"),
        @"apple",
        @[
            @{ @"value": @"apple", @"title": LGLocalized(@"prefs.option.apple_mitigated") },
            @{ @"value": @"legacy", @"title": LGLocalized(@"prefs.option.legacy_algorithm") },
        ]);
    NSDictionary *mode = LGMenuSetting(
        @"IOS26Icons.Mode",
        LGLocalized(@"prefs.control.icon_mode"),
        LGLocalized(@"prefs.subtitle.icon_mode"),
        @"clear",
        @[
            @{ @"value": @"clear", @"title": LGLocalized(@"prefs.option.clear") },
            @{ @"value": @"color", @"title": LGLocalized(@"prefs.option.tinted") },
        ]);
    NSDictionary *subjectStyle = LGMenuSetting(
        @"IOS26Icons.SubjectStyle",
        LGLocalized(@"prefs.control.subject_style"),
        LGLocalized(@"prefs.subtitle.subject_style"),
        @"soft",
        @[
            @{ @"value": @"soft", @"title": LGLocalized(@"prefs.option.soft_white") },
            @{ @"value": @"fresh", @"title": LGLocalized(@"prefs.option.fresh_color") },
        ]);
    NSMutableDictionary *globalProvider = [LGSwitchSetting(
        @"IOS26Icons.GlobalProvider.Enabled",
        LGLocalized(@"prefs.control.global_icon_provider"),
        LGLocalized(@"prefs.subtitle.global_icon_provider"),
        NO) mutableCopy];
    globalProvider[@"requires_icon_provider_restart"] = @YES;
    NSMutableDictionary *hue = [LGSliderSetting(
        @"IOS26Icons.TintHue",
        LGLocalized(@"prefs.control.tint_hue"),
        LGLocalized(@"prefs.subtitle.tint_hue"),
        0.37, 0.0, 1.0, 2) mutableCopy];
    hue[@"hue_slider"] = @YES;
    return @[
        LGGlassEnabledSetting(@"IOS26Icons.Enabled", NO),
        LGSettingControlledByKey(algorithm, @"IOS26Icons.Enabled", @NO),
        LGSettingControlledByKey(mode, @"IOS26Icons.Enabled", @NO),
        LGSettingControlledByKey(subjectStyle, @"IOS26Icons.Enabled", @NO),
        LGSettingControlledByKey(globalProvider.copy, @"IOS26Icons.Enabled", @NO),
        LGSettingControlledByKey([hue copy], @"IOS26Icons.Enabled", @NO),
        LGSettingControlledByKey(
            LGSliderSetting(@"IOS26Icons.TintIntensity",
                            LGLocalized(@"prefs.control.tint_intensity"),
                            LGLocalized(@"prefs.subtitle.tint_intensity"),
                            0.78, 0.0, 1.0, 2),
            @"IOS26Icons.Enabled", @NO),
    ];
}

NSArray<NSDictionary *> *LGSearchPillItems(void) {
    return LGRendererItemsForHostPrefix(@"SearchPill");
}

NSArray<NSDictionary *> *LGContextMenuItems(void) {
    return LGRendererItemsForHostPrefix(@"ContextMenu");
}

static NSArray<NSDictionary *> *LGControlCenterFullscreenBackdropItems(BOOL includeSection) {
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    if (includeSection) {
        [items addObject:LGSectionSetting(LGLocalized(@"prefs.section.control_center_fullscreen.title"), nil)];
    }
    [items addObject:LGSettingControlledByKey(
        LGSliderSetting(@"ControlCenter.FullscreenBackdropBlurRadius",
                        LGLocalized(@"prefs.control_center.fullscreen_backdrop_blur_radius.title"),
                        LGLocalized(@"prefs.control_center.fullscreen_backdrop_blur_radius.subtitle"),
                        8.0, 0.0, 50.0, 1),
        @"ControlCenter.Enabled", @YES)];
    [items addObject:LGSettingControlledByKey(@{
        @"type": @"color",
        @"key": @"ControlCenter.FullscreenBackdropDimColor",
        @"title": LGLocalized(@"prefs.control_center.fullscreen_backdrop_dim_color.title"),
        @"subtitle": LGLocalized(@"prefs.control_center.fullscreen_backdrop_dim_color.subtitle"),
        @"default": @"#00000033"
    }, @"ControlCenter.Enabled", @YES)];
    return [items copy];
}

NSArray<NSDictionary *> *LGControlCenterItems(void) {
    return LGJoinItemGroups(@[
        LGRendererItemsForHostPrefix(@"ControlCenter"),
        LGControlCenterFullscreenBackdropItems(YES),
    ]);
}

static NSArray<NSDictionary *> *LGClockVariableFontItems(void) {

    NSMutableDictionary *variableFontEnabled = [LGSwitchSetting(@"Clock.VariableFont.Enabled",
                                                                  LGLocalized(@"prefs.control.variable_font"),
                                                                  LGLocalized(@"prefs.subtitle.variable_font"),
                                                                  YES) mutableCopy];
    variableFontEnabled[@"controls_following_panel"] = @YES;
    return @[
        LGSpacerSetting(8.0, 0.0),
        variableFontEnabled.copy,
        LGSettingControlledByKey(LGSliderSetting(@"Clock.VariableFont.Weight",
                                                  LGLocalized(@"prefs.control.variable_font_weight"),
                                                  LGLocalized(@"prefs.subtitle.variable_font_weight"),
                                                  750.0, 1.0, 1000.0, 0), @"Clock.VariableFont.Enabled", @YES),
        LGSettingControlledByKey(LGSliderSetting(@"Clock.VariableFont.SizeScale",
                                                  LGLocalized(@"prefs.control.variable_font_size"),
                                                  LGLocalized(@"prefs.subtitle.variable_font_size"),
                                                  1.4, 0.8, 2.0, 2), @"Clock.VariableFont.Enabled", @YES),
        LGSettingControlledByKey(LGSliderSetting(@"Clock.VariableFont.Width",
                                                  LGLocalized(@"prefs.control.variable_font_width"),
                                                  LGLocalized(@"prefs.subtitle.variable_font_width"),
                                                  100.0, 60.0, 100.0, 0), @"Clock.VariableFont.Enabled", @YES),
        LGSettingControlledByKey(LGSliderSetting(@"Clock.VariableFont.Height",
                                                  LGLocalized(@"prefs.control.variable_font_height"),
                                                  LGLocalized(@"prefs.subtitle.variable_font_height"),
                                                  350.0, 100.0, 500.0, 0), @"Clock.VariableFont.Enabled", @YES),
        LGSettingControlledByKey(LGSliderSetting(@"Clock.VariableFont.Softness",
                                                  LGLocalized(@"prefs.control.variable_font_softness"),
                                                  LGLocalized(@"prefs.subtitle.variable_font_softness"),
                                                  56.0, 0.0, 100.0, 0), @"Clock.VariableFont.Enabled", @YES),
    ];
}

static NSArray<NSDictionary *> *LGClockDateFormatItems(void) {
    NSMutableDictionary *enabled = [LGSwitchSetting(@"Lockscreen.Clock.DateFormat.Enabled",
                                                      LGLocalized(@"prefs.control.date_format_enabled"),
                                                      LGLocalized(@"prefs.subtitle.date_format_enabled"),
                                                      YES) mutableCopy];
    enabled[@"controls_following_panel"] = @YES;
    return @[
        LGSectionSetting(LGLocalized(@"prefs.section.lockscreen_date_label.title"),
                         LGLocalized(@"prefs.section.lockscreen_date_label.subtitle")),
        enabled.copy,
        LGSettingControlledByKey(
            LGStringSetting(@"Lockscreen.Clock.DateFormat.Format",
                            LGLocalized(@"prefs.control.date_format"),
                            LGLocalized(@"prefs.subtitle.date_format"),
                            @"EEE MMM d",
                            @"EEE MMM d"),
            @"Lockscreen.Clock.DateFormat.Enabled", @YES),
    ];
}

NSArray<NSDictionary *> *LGClockItems(void) {
    NSInteger maximumFPS = UIScreen.mainScreen.maximumFramesPerSecond;
    NSMutableArray<NSDictionary *> *rendererItems =
        [LGRendererItemsForHostPrefix(@"Clock") mutableCopy];
    [rendererItems insertObject:LGMenuSetting(@"Clock.RenderingMode",
        LGLocalized(@"prefs.clock.mode.title"), LGLocalized(@"prefs.clock.mode.subtitle"),
        @"native", @[
            @{ @"title": LGLocalized(@"prefs.clock.mode.native"), @"value": @"native" },
            @{ @"title": LGLocalized(@"prefs.clock.mode.custom"), @"value": @"custom" },
        ]) atIndex:1];
    [rendererItems insertObject:LGSliderSetting(@"Clock.FPS",
        LGLocalized(@"prefs.control.clock_fps_limit"),
        LGLocalized(@"prefs.subtitle.clock_fps_limit"),
        maximumFPS, 1.0, maximumFPS, 0) atIndex:2];
    [rendererItems insertObject:LGSwitchSetting(@"Clock.AdaptiveTint.Enabled",
        LGLocalized(@"prefs.clock.adaptive_tint.title"),
        LGLocalized(@"prefs.clock.adaptive_tint.subtitle"),
        !LGSelectedRendererEnhanced()) atIndex:3];
    return LGJoinItemGroups(@[
        rendererItems,
        LGClockVariableFontItems(),
        LGClockDateFormatItems(),
    ]);
}

NSArray<NSDictionary *> *LGTabBarItems(void) {
    return LGJoinItemGroups(@[
        @[
            LGKeyedNavSetting(@"TabBar.Exclusions",
                              LGLocalized(@"prefs.tab_bar.exclusions.title"),
                              LGLocalized(@"prefs.tab_bar.exclusions.subtitle"),
                              @"editTabBarExclusions"),
        ],
        LGRendererItemsForHostPrefix(@"TabBar"),
        @[
            LGSectionSetting(LGLocalized(@"prefs.surface.tab_bar_selection.title"), nil),
        ],
        LGSettingsControlledByKey(
            LGRendererItemsForHostPrefix(@"TabBarSelection"),
            @"TabBar.Enabled", @YES),
    ]);
}

NSArray<NSDictionary *> *LGLockscreenItems(void) {
    return LGJoinItemGroups(@[
        @[
            LGSectionSetting(LGLocalized(@"prefs.section.lockscreen_notifications.title"), nil),
        ],
        LGRendererItemsForHostPrefix(@"Notification"),
        @[
            LGSectionSetting(LGLocalized(@"prefs.section.lockscreen_quick_actions.title"), nil),
        ],
        LGRendererItemsForHostPrefix(@"QuickActions"),
        @[
            LGSectionSetting(LGLocalized(@"prefs.section.lockscreen_passcode.title"), nil),
        ],
        LGRendererItemsForHostPrefix(@"Passcode"),
        @[
            LGSectionSetting(LGLocalized(@"prefs.section.lockscreen_clock.title"), nil),
        ],
        LGClockItems(),
    ]);
}

NSArray<NSDictionary *> *LGAppLibraryItems(void) {
    return LGJoinItemGroups(@[
        @[
            LGSectionSetting(LGLocalized(@"prefs.section.category_pods.title"), nil),
        ],
        LGRendererItemsForHostPrefix(@"AppLibrary"),
        @[
            LGSectionSetting(LGLocalized(@"prefs.section.search_field.title"), nil),
        ],
        LGRendererItemsForHostPrefix(@"AppLibSearch"),
    ]);
}

NSArray<NSDictionary *> *LGWidgetItems(void) {
    NSMutableDictionary *removeBackground = [LGSettingControlledByKey(
        LGSwitchSetting(@"RWB.Enabled",
                        LGLocalized(@"prefs.rwb.enabled.title"),
                        LGLocalized(@"prefs.rwb.enabled.subtitle"), YES),
        @"Widgets.Enabled", @YES) mutableCopy];
    removeBackground[@"requires_backboard_restart"] = @YES;
    NSMutableDictionary *excludePhotos = [LGSettingControlledByKey(
        LGSwitchSetting(@"Widgets.ExcludePhotos.Enabled",
                        LGLocalized(@"prefs.widgets.exclude_photos.title"),
                        LGLocalized(@"prefs.widgets.exclude_photos.subtitle"), NO),
        @"Widgets.Enabled", @YES) mutableCopy];
    excludePhotos[@"requires_backboard_restart"] = @YES;
    return LGJoinItemGroups(@[
        LGRendererItemsForHostPrefix(@"Widgets"),
        @[
            LGSectionSetting(LGLocalized(@"prefs.rwb.section.title"),
                             LGLocalized(@"prefs.rwb.section.subtitle")),
            removeBackground.copy,
            excludePhotos.copy,
            LGSettingControlledByKey(
                LGSwitchSetting(@"RWB.ForceDarkMode",
                                LGLocalized(@"prefs.rwb.force_dark.title"),
                                LGLocalized(@"prefs.rwb.force_dark.subtitle"), NO),
                @"RWB.Enabled", @YES),
            LGSettingControlledByKey(
                LGSwitchSetting(@"RWB.SystemWidgets.Enabled",
                                LGLocalized(@"prefs.rwb.system_widgets.title"),
                                LGLocalized(@"prefs.rwb.system_widgets.subtitle"), YES),
                @"RWB.Enabled", @YES),
            LGSettingControlledByKey(
                LGSwitchSetting(@"RWB.MaterialView.Enabled",
                                LGLocalized(@"prefs.rwb.material_view.title"),
                                LGLocalized(@"prefs.rwb.material_view.subtitle"), NO),
                @"RWB.Enabled", @YES),
        ],
    ]);
}

NSArray<NSDictionary *> *LGHomescreenItems(void) {
    NSMutableArray<NSDictionary *> *rendererItems = [NSMutableArray array];
    [rendererItems addObject:LGSectionSetting(LGLocalized(@"prefs.section.dock.title"), nil)];
    [rendererItems addObjectsFromArray:LGDockItems()];
    [rendererItems addObjectsFromArray:LGFolderItems()];
    [rendererItems addObjectsFromArray:LGAppIconItems()];
    [rendererItems addObject:LGSectionSetting(LGLocalized(@"prefs.section.app_icons_ex.title"), nil)];
    [rendererItems addObjectsFromArray:LGAppIconExItems()];
    [rendererItems addObject:LGSectionSetting(LGLocalized(@"prefs.section.context_menu.title"), nil)];
    [rendererItems addObjectsFromArray:LGContextMenuItems()];
    [rendererItems addObject:LGSectionSetting(LGLocalized(@"prefs.section.alerts.title"), nil)];
    [rendererItems addObjectsFromArray:LGRendererItemsForHostPrefix(@"Alerts")];
    [rendererItems addObject:LGSectionSetting(LGLocalized(@"prefs.section.banner.title"), nil)];
    [rendererItems addObjectsFromArray:LGRendererItemsForHostPrefix(@"Banner")];
    [rendererItems addObject:LGSectionSetting(LGLocalized(@"prefs.section.control_center.title"), nil)];
    [rendererItems addObjectsFromArray:LGRendererItemsForHostPrefix(@"ControlCenter")];
    [rendererItems addObjectsFromArray:LGControlCenterFullscreenBackdropItems(NO)];
    [rendererItems addObject:LGSectionSetting(LGLocalized(@"prefs.section.search_pill.title"), nil)];
    [rendererItems addObjectsFromArray:LGSearchPillItems()];
    [rendererItems addObject:LGSectionSetting(LGLocalized(@"prefs.section.spotlight.title"), nil)];
    [rendererItems addObjectsFromArray:LGRendererItemsForHostPrefix(@"Spotlight")];
    [rendererItems addObject:LGSectionSetting(LGLocalized(@"prefs.section.widgets.title"), nil)];
    [rendererItems addObjectsFromArray:LGWidgetItems()];
    return LGSurfaceItemsBySortingSectionGroups(rendererItems);
}

NSArray<NSDictionary *> *LGAllSurfaceItems(void) {
    NSMutableArray<NSDictionary *> *all = [NSMutableArray array];
    [all addObject:LGSwitchSetting(@"Global.Enabled", LGLocalized(@"prefs.control.enabled"), LGLocalized(@"prefs.subtitle.global_enabled"), NO)];
    [all addObject:LGGlassQualitySetting(@"Global.Quality", 1.0, 0.1, 1.0, 2)];
    [all addObjectsFromArray:LGHomescreenItems()];
    [all addObjectsFromArray:LGLockscreenItems()];
    [all addObjectsFromArray:LGAppLibraryItems()];
    [all addObjectsFromArray:LGRendererItemsForHostPrefix(@"DynamicIsland")];
    [all addObject:LGSwitchSetting(@"DynamicIsland.HideWhenInactive",
        LGLocalized(@"prefs.island.hide_idle.title"),
        LGLocalized(@"prefs.island.hide_idle.subtitle"), NO)];
    return [all copy];
}

NSArray<NSDictionary *> *LGPrefsSettingsItems(void) {
    return @[
        LGMenuSetting(kLGPrefsLanguageKey,
                      LGLocalized(@"prefs.misc.language.title"),
                      @"",
                      @"en",
                      LGAvailableLanguageChoices()),
        LGSpacerSetting(2.0, 0.0),
        LGAboutContentSetting(),
    ];
}

NSArray<NSDictionary *> *LGGlobalControlsItems(void) {
    return @[
        LGKeyedNavSetting(@"GlobalControls.Exclusions",
                          LGLocalized(@"prefs.global_controls.exclusions.title"),
                          LGLocalized(@"prefs.global_controls.exclusions.subtitle"),
                          @"editGlobalControlsExclusions"),
        LGSectionSetting(LGLocalized(@"prefs.global_controls.section.title"),
                         LGLocalized(@"prefs.global_controls.section.subtitle")),
        LGSwitchSetting(@"GlobalControls.Switches.Enabled",
                        LGLocalized(@"prefs.global_controls.switches.title"),
                        LGLocalized(@"prefs.global_controls.switches.subtitle"), YES),
        LGSwitchSetting(@"GlobalControls.Sliders.Enabled",
                        LGLocalized(@"prefs.global_controls.sliders.title"),
                        LGLocalized(@"prefs.global_controls.sliders.subtitle"), NO),
        LGSwitchSetting(@"GlobalControls.Segmented.Enabled",
                        LGLocalized(@"prefs.global_controls.segmented.title"),
                        LGLocalized(@"prefs.global_controls.segmented.subtitle"), NO),
    ];
}

NSArray<NSDictionary *> *LGMoreOptionsItems(void) {
    NSMutableArray<NSDictionary *> *items = [NSMutableArray arrayWithArray:@[
        LGSectionSetting(LGLocalized(@"prefs.misc.options_section.title"),
                         LGLocalized(@"prefs.misc.options_section.subtitle"))]];
    NSMutableDictionary *rendererProfile = [LGMenuSetting(
        @"Renderer.Profile",
        LGLocalized(@"prefs.renderer.profile.title"),
        LGLocalized(@"prefs.renderer.profile.subtitle"),
        @"classic",
        @[
            @{@"value": @"classic", @"title": LGLocalized(@"prefs.renderer.profile.classic")},
            @{@"value": @"enhanced", @"title": LGLocalized(@"prefs.renderer.profile.enhanced")},
        ]) mutableCopy];
    rendererProfile[@"requires_backboard_restart"] = @YES;
    rendererProfile[@"reload_on_change"] = @YES;
    [items addObject:[rendererProfile copy]];
    NSMutableDictionary *blurMode = [LGMenuSetting(@"Renderer.BlurMode",
        LGLocalized(@"prefs.renderer.blur_mode.title"),
        LGLocalized(@"prefs.renderer.blur_mode.subtitle"), @"system", @[
            @{ @"value": @"current", @"title": LGLocalized(@"prefs.renderer.blur_mode.current") },
            @{ @"value": @"system", @"title": LGLocalized(@"prefs.renderer.blur_mode.system") },
        ]) mutableCopy];
    blurMode[@"requires_enhanced_renderer"] = @YES;
    [items addObject:blurMode.copy];
    [items addObject:LGSliderSetting(@"Renderer.FresnelGlareStrength",
                                     LGLocalized(@"prefs.control.fresnel_glare"),
                                     LGLocalized(@"prefs.subtitle.fresnel_glare"),
                                     0.5, 0.0, 1.0, 2)];
    [items addObject:LGSettingControlledByKey(
        LGSwitchSetting(@"SettingsControls.Enabled",
                        LGLocalized(@"prefs.misc.settings_controls.title"),
                        LGLocalized(@"prefs.misc.settings_controls.subtitle"),
                        YES),
        @"Global.Enabled",
        @NO)];
    [items addObject:LGSectionSetting(LGLocalized(@"prefs.section.motion_highlights.title"),
                                      LGLocalized(@"prefs.section.motion_highlights.subtitle"))];
    [items addObject:LGSwitchSetting(@"Specular.Motion.Enabled",
                                     LGLocalized(@"prefs.control.motion_highlights"),
                                     LGLocalized(@"prefs.subtitle.motion_highlights"),
                                     NO)];
    [items addObject:LGSliderSetting(@"Specular.Motion.Sensitivity",
                                     LGLocalized(@"prefs.control.motion_highlights_sensitivity"),
                                     LGLocalized(@"prefs.subtitle.motion_highlights_sensitivity"),
                                     2.0,
                                     0.0,
                                     8.0,
                                     2)];
    [items addObject:LGSectionSetting(@"", @"")];
    [items addObject:LGSectionSetting(LGLocalized(@"prefs.misc.import_export_section.title"),
                                      LGLocalized(@"prefs.misc.import_export_section.subtitle"))];
    [items addObject:LGNavSetting(LGLocalized(@"prefs.misc.export_prefs.title"),
                                  LGLocalized(@"prefs.misc.export_prefs.subtitle"),
                                  @"exportPreferences")];
    [items addObject:LGNavSetting(LGLocalized(@"prefs.misc.import_prefs.title"),
                                  LGLocalized(@"prefs.misc.import_prefs.subtitle"),
                                  @"importPreferences")];
    [items addObject:LGSectionSetting(@"", @"")];
    [items addObject:LGSwitchSetting(@"Debug.Logging.Enabled",
                                     LGLocalized(@"prefs.misc.debug_logging.title"),
                                     LGLocalized(@"prefs.misc.debug_logging.subtitle"),
                                     NO)];
    [items addObject:LGNavSetting(LGLocalized(@"prefs.misc.export_logs.title"),
                                  @"",
                                  @"exportLogs")];

    return [items copy];
}

NSString *LGExportPreferencesJSONString(void) {
    NSMutableDictionary *preferences = [NSMutableDictionary dictionary];
    for (NSString *key in LGExportablePreferenceKeys()) {
        id value = LGReadPreferenceObject(key, nil);
        if (!value) continue;
        preferences[key] = value;
    }

    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[@"format"] = @"liquidass-prefs";
    payload[@"version"] = @"1";
    payload[@"preferences"] = preferences;
    NSString *languageCode = LGCurrentPrefsLanguageCode();
    if (languageCode.length) {
        payload[@"ui_language"] = languageCode;
    }

    NSData *data = [NSJSONSerialization dataWithJSONObject:payload
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:nil];
    if (!data) return nil;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

BOOL LGImportPreferencesJSONString(NSString *jsonString, NSError **error) {
    if (!jsonString.length) {
        if (error) {
            *error = [NSError errorWithDomain:@"love.litten.liquidass.prefs"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: LGLocalized(@"prefs.import_prefs.error_empty")}];
        }
        return NO;
    }

    NSData *data = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) {
        if (error) {
            *error = [NSError errorWithDomain:@"love.litten.liquidass.prefs"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: LGLocalized(@"prefs.import_prefs.error_invalid")}];
        }
        return NO;
    }

    NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![payload isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = [NSError errorWithDomain:@"love.litten.liquidass.prefs"
                                         code:3
                                     userInfo:@{NSLocalizedDescriptionKey: LGLocalized(@"prefs.import_prefs.error_invalid")}];
        }
        return NO;
    }

    NSString *format = payload[@"format"];
    NSString *version = payload[@"version"];
    if (![format isKindOfClass:[NSString class]] ||
        ![format isEqualToString:@"liquidass-prefs"] ||
        ![version isKindOfClass:[NSString class]] ||
        ![version isEqualToString:@"1"]) {
        if (error) {
            *error = [NSError errorWithDomain:@"love.litten.liquidass.prefs"
                                         code:6
                                     userInfo:@{NSLocalizedDescriptionKey: LGLocalized(@"prefs.import_prefs.error_invalid")}];
        }
        return NO;
    }

    NSDictionary *preferences = payload[@"preferences"];
    if (![preferences isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = [NSError errorWithDomain:@"love.litten.liquidass.prefs"
                                         code:4
                                     userInfo:@{NSLocalizedDescriptionKey: LGLocalized(@"prefs.import_prefs.error_invalid")}];
        }
        return NO;
    }

    NSSet<NSString *> *allowedKeys = [NSSet setWithArray:LGExportablePreferenceKeys()];
    __block NSUInteger importedCount = 0;
    [preferences enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        (void)stop;
        if (![key isKindOfClass:[NSString class]]) return;
        if (![allowedKeys containsObject:key]) return;
        if (!obj || obj == [NSNull null]) {
            LGRemovePreference(key);
        } else {
            LGWritePreferenceObject(key, obj);
        }
        importedCount += 1;
    }];

    NSString *languageCode = payload[@"ui_language"];
    if ([languageCode isKindOfClass:[NSString class]] && languageCode.length) {
        LGSetCurrentPrefsLanguageCode(languageCode);
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:kLGPrefsUIRefreshNotification object:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:kLGPrefsLanguageChangedNotification object:nil];

    if (importedCount == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"love.litten.liquidass.prefs"
                                         code:5
                                     userInfo:@{NSLocalizedDescriptionKey: LGLocalized(@"prefs.import_prefs.error_empty")}];
        }
        return NO;
    }
    return YES;
}

void LGResetAllPreferences(void) {
    CFArrayRef allKeys = CFPreferencesCopyKeyList((__bridge CFStringRef)LGPrefsDomain,
                                                  kCFPreferencesCurrentUser,
                                                  kCFPreferencesAnyHost);
    NSArray *keys = CFBridgingRelease(allKeys);
    for (id key in keys) {
        if (![key isKindOfClass:[NSString class]]) continue;
        if ([(NSString *)key isEqualToString:@"Global.Enabled"]) continue;
        if ([(NSString *)key hasPrefix:kLGDynamicDefaultPrefix]) continue;
        LGRemovePreference((NSString *)key);
    }
    [LGPrefsUIStateDefaults() removeObjectForKey:kLGPrefsLanguageKey];
    LGSynchronizeSurfaceStateDefaults();
    [[NSNotificationCenter defaultCenter] postNotificationName:kLGPrefsUIRefreshNotification object:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:kLGPrefsLanguageChangedNotification object:nil];
}

void LGResetPreferencesForKeys(NSArray<NSString *> *keys) {
    if (![keys isKindOfClass:[NSArray class]] || keys.count == 0) return;

    NSMutableOrderedSet<NSString *> *uniqueKeys = [NSMutableOrderedSet orderedSet];
    for (id key in keys) {
        if (![key isKindOfClass:[NSString class]]) continue;
        if (![(NSString *)key length]) continue;
        if ([(NSString *)key isEqualToString:@"Global.Enabled"]) continue;
        if ([(NSString *)key hasPrefix:kLGDynamicDefaultPrefix]) continue;
        [uniqueKeys addObject:(NSString *)key];
    }
    if (uniqueKeys.count == 0) return;

    for (NSString *key in uniqueKeys) {
        LGRemovePreference(key);
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:kLGPrefsUIRefreshNotification object:nil];
}
