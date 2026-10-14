// creds to owngoalstudios remove widget background

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <unistd.h>
#import <notify.h>
#import <math.h>
#import <string.h>
#import "../Shared/LGSharedSupport.h"
#import "../Shared/LGWidgetCompatibility.h"

static BOOL kIsEnabled = YES;
static BOOL kIsEnabledForSystemWidgets = YES;
static BOOL kIsEnabledForMaterialView = NO;
static BOOL kForceDarkMode = NO;
static BOOL kExcludePhotos = NO;
static BOOL kActivityEnabled = NO;
static BOOL sActivityColorSupported = NO;
static NSHashTable *sActivityLayers;
static char kActivityLayerStateKey;
static __thread NSUInteger sApplyingActivityColor;
static int sActivityDiagnosticToken = -1;
static uint64_t sActivityDiagnosticState;
static void RWBRestoreActivityLayers(void);
@class RBLayer;
static void RWBPrepareActivityHostingBackground(UIView *view);
static void RWBPrepareActivityHostingAncestors(UIView *view);
static void RWBRestoreActivityHostingBackground(CALayer *layer);
static void RWBRestoreActivityHostingLayers(void);
static BOOL RWBUpdateActivityHostingBackground(UIView *view);
static NSHashTable *sActivityHostingLayers;
static __thread NSUInteger sApplyingHostingBackground;
static char kActivityHostingStateKey;
static int sHostingDiagnosticToken = -1;
static uint64_t sHostingDiagnosticState;
static uint64_t sHostingSeenFlags, sHostingColorSample;
static void RWBPublishHostingStatus(UIView *view, UIColor *viewColor, UIColor *layerColor, BOOL opaque);
static CGFloat kMaxWidgetWidth = 140.0;
static CGFloat kMaxWidgetHeight = 140.0;
static NSSet<NSString *> *kWidgetBundleIdentifiers = nil;
static void *kRWBOriginalBackgroundColorKey = &kRWBOriginalBackgroundColorKey;
static void *kRWBOriginalWindowStyleKey = &kRWBOriginalWindowStyleKey;
static NSHashTable<UIWindow *> *sRWBWindows;
static BOOL sRWBIsWidgetRenderer = NO;
static BOOL sRWBIsChronod = NO;

static NSUserDefaults *RWBPreferences(void) {
    static NSUserDefaults *preferences;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *suiteName = sRWBIsWidgetRenderer
            ? @"/var/mobile/Library/Preferences/dylv.liquidassprefs.plist"
            : LGPrefsDomain;
        preferences = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
    });
    return preferences;
}

static NSDictionary<NSString *, id> *RWBCopyPreferences(void) {
    NSDictionary<NSString *, id> *preferences = RWBPreferences().dictionaryRepresentation;
    return [preferences isKindOfClass:NSDictionary.class] ? preferences : @{};
}

static BOOL RWBPreferenceBool(NSDictionary<NSString *, id> *preferences,
                              NSString *key, BOOL fallback) {
    id value = preferences[key];
    return [value isKindOfClass:NSNumber.class] ? [value boolValue] : fallback;
}

static NSString *RWBPreferenceString(NSDictionary<NSString *, id> *preferences,
                                     NSString *key, NSString *fallback) {
    id value = preferences[key];
    return [value isKindOfClass:NSString.class] ? value : fallback;
}

static NSArray<NSString *> *RWBParseThirdPartyBundleIDs(NSString *rawText) {
    if (![rawText isKindOfClass:[NSString class]] || rawText.length == 0) return @[];
    NSMutableOrderedSet<NSString *> *bundleIDs = [NSMutableOrderedSet orderedSet];
    [[rawText componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] enumerateObjectsUsingBlock:^(NSString *rawLine, NSUInteger idx, BOOL *stop) {
        (void)idx;
        (void)stop;
        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!line.length) return;
        [bundleIDs addObject:line];
    }];
    return bundleIDs.array;
}

static void ReloadPrefs(void) {
    // Use the Settings domain for this new shared option in every process.
    LGReloadPreferences();
    kExcludePhotos = LG_prefBool(@"Widgets.ExcludePhotos.Enabled", NO);
    kActivityEnabled = LG_globalEnabled() && LG_prefBool(@"DynamicIsland.Enabled", NO);
    NSDictionary<NSString *, id> *preferences = RWBCopyPreferences();
    kIsEnabled = RWBPreferenceBool(preferences, @"Global.Enabled", YES) &&
                 RWBPreferenceBool(preferences, @"Widgets.Enabled", YES) &&
                 RWBPreferenceBool(preferences, @"RWB.Enabled", YES);
    kIsEnabledForSystemWidgets =
        RWBPreferenceBool(preferences, @"RWB.SystemWidgets.Enabled", YES);
    kIsEnabledForMaterialView =
        RWBPreferenceBool(preferences, @"RWB.MaterialView.Enabled", NO);
    kForceDarkMode = RWBPreferenceBool(preferences, @"RWB.ForceDarkMode", NO);
    kMaxWidgetWidth = 140.0;
    kMaxWidgetHeight = 140.0;

    NSString *configuredBundleIDs = RWBPreferenceString(
        preferences, @"RWB.ThirdPartyBundleIDs", LGRWBDefaultWidgetBundleIDsText());
    NSMutableOrderedSet<NSString *> *bundleIDs =
        [NSMutableOrderedSet orderedSetWithArray:
            RWBParseThirdPartyBundleIDs(configuredBundleIDs)];
    kWidgetBundleIdentifiers = [NSSet setWithArray:bundleIDs.array];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!kActivityEnabled) RWBRestoreActivityLayers();
        for (UIWindow *window in sRWBWindows.allObjects) {
            NSNumber *originalStyle =
                objc_getAssociatedObject(window, kRWBOriginalWindowStyleKey);
            if (kIsEnabled && kForceDarkMode) {
                if (!originalStyle) {
                    objc_setAssociatedObject(window, kRWBOriginalWindowStyleKey,
                                             @(window.overrideUserInterfaceStyle),
                                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
                window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
            } else if (originalStyle) {
                window.overrideUserInterfaceStyle = originalStyle.integerValue;
                objc_setAssociatedObject(window, kRWBOriginalWindowStyleKey, nil,
                                         OBJC_ASSOCIATION_ASSIGN);
            }
            if (!kIsEnabled) {
                NSMutableArray<UIView *> *stack =
                    [NSMutableArray arrayWithObject:window];
                while (stack.count) {
                    UIView *view = stack.lastObject;
                    [stack removeLastObject];
                    id original = objc_getAssociatedObject(
                        view, kRWBOriginalBackgroundColorKey);
                    if (original) {
                        view.backgroundColor = original == NSNull.null ? nil : original;
                        objc_setAssociatedObject(view,
                            kRWBOriginalBackgroundColorKey, nil,
                            OBJC_ASSOCIATION_ASSIGN);
                    }
                    [stack addObjectsFromArray:view.subviews];
                }
            }
        }
    });
}

static void RWBReloadPrefsCallback(CFNotificationCenterRef __unused center,
                                   void * __unused observer,
                                   CFStringRef __unused name,
                                   const void * __unused object,
                                   CFDictionaryRef __unused userInfo) {
    ReloadPrefs();
}

static void RWBRestartChronodCallback(
    CFNotificationCenterRef __unused center,
    void * __unused observer,
    CFStringRef __unused name,
    const void * __unused object,
    CFDictionaryRef __unused userInfo) {
    if (sRWBIsChronod) _exit(0);
}

@interface CHSWidget : NSObject
@property (nonatomic, copy, readonly) NSString *extensionBundleIdentifier;
@end

@interface CHUISWidgetScene : UIWindowScene
@property (nonatomic, copy, readonly) CHSWidget *widget;
@end

@interface CHUISAvocadoWindowScene : UIWindowScene
@property (nonatomic, copy, readonly) CHSWidget *widget;
@end

@interface UIWindow (LiquidAssRWB)
@property (nonatomic, strong) NSNumber *rwb_shouldHideBackground;
@end

typedef struct { float c0, c1, c2, c3; } LGActivityClearColor;

@interface RBLayer : CALayer
@property (nonatomic) LGActivityClearColor clearColor;
@end

static BOOL RWBActivitySceneMatches(NSString *role, NSString *identifier) {
    return ([role isKindOfClass:NSString.class] &&
            [role rangeOfString:@"SystemAperture" options:NSCaseInsensitiveSearch].location != NSNotFound)
        || ([identifier isKindOfClass:NSString.class] && [identifier hasPrefix:@"activity:"]);
}

static BOOL RWBActivityLayerMatches(RBLayer *layer) {
    if (!sRWBIsChronod || !kActivityEnabled || !sActivityColorSupported) return NO;
    id delegate = layer.delegate;
    if (![delegate isKindOfClass:UIView.class]) return NO;
    UIWindow *window = ((UIView *)delegate).window;
    if (!window) return objc_getAssociatedObject(layer, &kActivityLayerStateKey) != nil;
    UIWindowScene *scene = window.windowScene;
    if (!scene) return NO;
    NSString *identifier = scene.session.persistentIdentifier;
    if (RWBActivitySceneMatches(scene.session.role, identifier)) return YES;
    id sceneIdentifier = LGWidgetObjectProperty(scene, NSSelectorFromString(@"_sceneIdentifier"));
    return RWBActivitySceneMatches(nil, sceneIdentifier);
}

static void RWBPublishActivityStatus(RBLayer *layer, LGActivityClearColor color) {
    if (sActivityDiagnosticToken < 0) return;
    uint64_t state = UINT64_C(0xAC48000000000000) | (sActivityColorSupported ? 1u : 0u);
    state |= kActivityEnabled ? 2u : 0u;
    if (layer) {
        state |= 4u;
        state |= layer.opaque ? 8u : 0u;
        UIView *view = [layer.delegate isKindOfClass:UIView.class] ? (UIView *)layer.delegate : nil;
        state |= view.window.rwb_shouldHideBackground.boolValue ? 16u : 0u;
        const float values[] = {color.c0, color.c1, color.c2, color.c3};
        for (NSUInteger i = 0; i < 4; i++) {
            float value = isfinite(values[i]) ? fminf(1, fmaxf(0, values[i])) : 0;
            state |= ((uint64_t)lrintf(value * 255)) << (8 + i * 8);
        }
    }
    if (state == sActivityDiagnosticState) return;
    sActivityDiagnosticState = state;
    notify_set_state(sActivityDiagnosticToken, state);
}

static void RWBCaptureActivityLayer(RBLayer *layer, LGActivityClearColor color, BOOL nativeRequest) {
    NSDictionary *state = objc_getAssociatedObject(layer, &kActivityLayerStateKey);
    if (!state) {
        state = @{@"opaque": @(layer.opaque),
                  @"color": [NSValue valueWithBytes:&color objCType:@encode(LGActivityClearColor)]};
        objc_setAssociatedObject(layer, &kActivityLayerStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        @synchronized (sActivityLayers) { [sActivityLayers addObject:layer]; }
        RWBPublishActivityStatus(layer, color);
    } else if (nativeRequest) {
        LGActivityClearColor previous;
        [state[@"color"] getValue:&previous size:sizeof(previous)];
        if (memcmp(&previous, &color, sizeof(color)) != 0) {
            state = @{@"opaque": state[@"opaque"],
                      @"color": [NSValue valueWithBytes:&color objCType:@encode(LGActivityClearColor)]};
            objc_setAssociatedObject(layer, &kActivityLayerStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        RWBPublishActivityStatus(layer, color);
    }
}

static void RWBPrepareActivityLayer(RBLayer *layer) {
    LGActivityClearColor color = layer.clearColor;
    RWBCaptureActivityLayer(layer, color, NO);
    if ([layer.delegate isKindOfClass:UIView.class])
        RWBPrepareActivityHostingAncestors((UIView *)layer.delegate);
    if (layer.opaque) layer.opaque = NO;
    if (color.c0 || color.c1 || color.c2 || color.c3) {
        sApplyingActivityColor++;
        layer.clearColor = (LGActivityClearColor){0};
        sApplyingActivityColor--;
    }
}

static void RWBRestoreActivityLayer(RBLayer *layer) {
    NSDictionary *state = objc_getAssociatedObject(layer, &kActivityLayerStateKey);
    if (!state) { RWBRestoreActivityHostingBackground(layer); return; }
    LGActivityClearColor color;
    [state[@"color"] getValue:&color size:sizeof(color)];
    sApplyingActivityColor++;
    layer.clearColor = color;
    sApplyingActivityColor--;
    layer.opaque = [state[@"opaque"] boolValue];
    objc_setAssociatedObject(layer, &kActivityLayerStateKey, nil, OBJC_ASSOCIATION_ASSIGN);
    @synchronized (sActivityLayers) { [sActivityLayers removeObject:layer]; }
    RWBRestoreActivityHostingBackground(layer);
    [layer setNeedsDisplay];
}

static void RWBRestoreActivityLayers(void) {
    NSArray *layers;
    @synchronized (sActivityLayers) { layers = sActivityLayers.allObjects; }
    for (RBLayer *layer in layers) RWBRestoreActivityLayer(layer);
    RWBRestoreActivityHostingLayers();
    RWBPublishActivityStatus(nil, (LGActivityClearColor){0});
    RWBPublishHostingStatus(nil, nil, nil, NO);
}

static BOOL RWBFourFloatColorType(const char *type) {
    const char *fields = type && type[0] == '{' ? strchr(type, '=') : NULL;
    return fields && strcmp(fields + 1, "ffff}") == 0;
}

static BOOL RWBActivityColorABICompatible(Class cls) {
    Method getter = class_getInstanceMethod(cls, @selector(clearColor));
    Method setter = class_getInstanceMethod(cls, @selector(setClearColor:));
    if (!getter || !setter || method_getNumberOfArguments(getter) != 2 || method_getNumberOfArguments(setter) != 3) return NO;
    char *returned = method_copyReturnType(getter);
    char *argument = method_copyArgumentType(setter, 2);
    char *setterReturn = method_copyReturnType(setter);
    BOOL compatible = RWBFourFloatColorType(returned) && RWBFourFloatColorType(argument)
        && setterReturn && strcmp(setterReturn, @encode(void)) == 0;
    free(returned); free(argument); free(setterReturn);
    return compatible;
}

@interface LGActivityHostingBackgroundState : NSObject
@property (weak) UIView *view;
@property (strong) UIColor *viewColor;
@property (strong) UIColor *layerColor;
@property BOOL viewOpaque;
@end
@implementation LGActivityHostingBackgroundState
@end

static BOOL RWBIsHostingView(UIView *view) {
    NSUInteger depth = 0;
    for (Class cls = object_getClass(view); cls && depth < 16; cls = class_getSuperclass(cls), depth++) {
        if ([NSStringFromClass(cls) containsString:@"UIHostingView"]) return YES;
    }
    return NO;
}

static BOOL RWBActivityHostingViewMatches(UIView *view) {
    if (!sActivityColorSupported || !kActivityEnabled || !sRWBIsChronod || !RWBIsHostingView(view)) return NO;
    UIWindow *window = view.window;
    if (!window) return objc_getAssociatedObject(view.layer, &kActivityHostingStateKey) != nil;
    UIWindowScene *scene = window.windowScene;
    if (!scene) return NO;
    if (RWBActivitySceneMatches(scene.session.role, scene.session.persistentIdentifier)) return YES;
    return RWBActivitySceneMatches(nil, LGWidgetObjectProperty(scene, NSSelectorFromString(@"_sceneIdentifier")));
}

static UIColor *RWBResolvedHostingColor(UIView *view, UIColor *color) {
    return [color resolvedColorWithTraitCollection:view.traitCollection];
}

static BOOL RWBHostingColorIsBlack(UIView *view, UIColor *color) {
    UIColor *resolved = RWBResolvedHostingColor(view, color);
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![resolved getRed:&r green:&g blue:&b alpha:&a]) return NO;
    return a > 0 && r >= 0 && g >= 0 && b >= 0 && r <= 0.02 && g <= 0.02 && b <= 0.02;
}

static UIColor *RWBLayerBackgroundColor(CALayer *layer) {
    CGColorRef color = layer.backgroundColor;
    return color ? [UIColor colorWithCGColor:color] : nil;
}

static void RWBPublishHostingStatus(UIView *view, UIColor *viewColor, UIColor *layerColor, BOOL opaque) {
    if (sHostingDiagnosticToken < 0) return;
    uint64_t state = UINT64_C(0xAC50000000000000) | (sActivityColorSupported ? 1u : 0u)
        | (kActivityEnabled ? 2u : 0u);
    if (view) {
        BOOL hosting = RWBIsHostingView(view);
        uint64_t flags = 4u | (hosting ? 8u : 0u);
        if (hosting) {
            flags |= opaque ? 64u : 0u;
            flags |= RWBHostingColorIsBlack(view, viewColor) ? 16u : 0u;
            flags |= RWBHostingColorIsBlack(view, layerColor) ? 32u : 0u;
        }
        sHostingSeenFlags |= flags;
        if (!sHostingColorSample && (flags & (16u | 32u))) {
            CGFloat r = 0, g = 0, b = 0, a = 0;
            [RWBResolvedHostingColor(view, viewColor) getRed:&r green:&g blue:&b alpha:&a];
            const CGFloat values[] = {r, g, b, a};
            for (NSUInteger i = 0; i < 4; i++) {
                CGFloat v = isfinite(values[i]) ? fmin(1, fmax(0, values[i])) : 0;
                sHostingColorSample |= ((uint64_t)lrint(v * 255)) << (8 + 8 * i);
            }
            CGColorRef layerCGColor = RWBResolvedHostingColor(view, layerColor).CGColor;
            CGFloat layerAlpha = layerCGColor ? CGColorGetAlpha(layerCGColor) : 0;
            if (isfinite(layerAlpha)) sHostingColorSample |= ((uint64_t)lrint(fmin(1, fmax(0, layerAlpha)) * 255)) << 40;
        }
    } else if (!kActivityEnabled) {
        sHostingSeenFlags = 0; sHostingColorSample = 0;
    }
    state |= sHostingSeenFlags | sHostingColorSample;
    if (state == sHostingDiagnosticState) return;
    sHostingDiagnosticState = state;
    notify_set_state(sHostingDiagnosticToken, state);
}

static LGActivityHostingBackgroundState *RWBCaptureHostingBackground(UIView *view) {
    CALayer *layer = view.layer;
    LGActivityHostingBackgroundState *state = objc_getAssociatedObject(layer, &kActivityHostingStateKey);
    if (!state) {
        state = [LGActivityHostingBackgroundState new];
        state.view = view;
        state.viewColor = view.backgroundColor;
        state.layerColor = RWBLayerBackgroundColor(layer);
        state.viewOpaque = view.opaque;
        objc_setAssociatedObject(layer, &kActivityHostingStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!sActivityHostingLayers) sActivityHostingLayers = [NSHashTable weakObjectsHashTable];
        [sActivityHostingLayers addObject:layer];
    }
    return state;
}

static void RWBPrepareActivityHostingBackground(UIView *view) {
    if (![NSThread isMainThread]) return;
    if (!RWBActivityHostingViewMatches(view)) {
        RWBPublishHostingStatus(view, view.backgroundColor, RWBLayerBackgroundColor(view.layer), view.opaque);
        return;
    }
    LGActivityHostingBackgroundState *state = RWBCaptureHostingBackground(view);
    RWBPublishHostingStatus(view, state.viewColor, state.layerColor, state.viewOpaque);
    sApplyingHostingBackground++;
    if (RWBHostingColorIsBlack(view, view.backgroundColor)) view.backgroundColor = UIColor.clearColor;
    if (RWBHostingColorIsBlack(view, RWBLayerBackgroundColor(view.layer))) view.layer.backgroundColor = NULL;
    if (view.opaque) view.opaque = NO;
    sApplyingHostingBackground--;
}

static void RWBPrepareActivityHostingAncestors(UIView *view) {
    if (![NSThread isMainThread]) return;
    for (NSUInteger depth = 0; view && depth < 32; depth++, view = view.superview) {
        RWBPrepareActivityHostingBackground(view);
    }
}

static void RWBRestoreActivityHostingBackground(CALayer *layer) {
    LGActivityHostingBackgroundState *state = objc_getAssociatedObject(layer, &kActivityHostingStateKey);
    if (!state) return;
    if (![NSThread isMainThread]) {
        __weak CALayer *weakLayer = layer;
        dispatch_async(dispatch_get_main_queue(), ^{
            CALayer *live = weakLayer;
            if (live && objc_getAssociatedObject(live, &kActivityHostingStateKey) == state
                && !RWBActivityHostingViewMatches(state.view)) RWBRestoreActivityHostingBackground(live);
        });
        return;
    }
    UIView *view = state.view;
    sApplyingHostingBackground++;
    if (view && view.layer == layer) {
        view.backgroundColor = state.viewColor;
        view.opaque = state.viewOpaque;
    }
    layer.backgroundColor = state.layerColor.CGColor;
    sApplyingHostingBackground--;
    objc_setAssociatedObject(layer, &kActivityHostingStateKey, nil, OBJC_ASSOCIATION_ASSIGN);
    [sActivityHostingLayers removeObject:layer];
    [layer setNeedsDisplay];
}

static void RWBRestoreActivityHostingLayers(void) {
    for (CALayer *layer in sActivityHostingLayers.allObjects) RWBRestoreActivityHostingBackground(layer);
}

static BOOL RWBUpdateActivityHostingBackground(UIView *view) {
    if (RWBActivityHostingViewMatches(view)) { RWBPrepareActivityHostingBackground(view); return YES; }
    if (sActivityColorSupported) RWBRestoreActivityHostingBackground(view.layer);
    return NO;
}

@interface CHUISWidgetHostViewController : UIViewController
@property (nonatomic, copy) CHSWidget *widget;
@end

@interface CHUISAvocadoHostViewController : UIViewController
@property (nonatomic, copy) CHSWidget *widget;
@end

@interface SBHWidgetStackViewController : UIViewController
@end

@interface WGWidgetListItemViewController : UIViewController
@end

@interface CHSMutableScreenshotPresentationAttributes : NSObject
@end

@interface CHSScreenshotPresentationAttributes : NSObject
@end

static BOOL ShouldHandleWidget(NSString *bundleIdentifier) {
    if (!kIsEnabled || bundleIdentifier.length == 0) return NO;
    if (kExcludePhotos && LGWidgetPreservesPhotoContent(bundleIdentifier)) return NO;
    if (!kIsEnabledForSystemWidgets && [bundleIdentifier hasPrefix:@"com.apple."])
        return NO;
    return YES;
}

static BOOL RWBWindowPreservesPhotoContent(UIWindow *window) {
    if (!kExcludePhotos) return NO;
    return LGWidgetPreservesPhotoContent(LGWidgetIdentifierForObject(window.windowScene))
        || LGWidgetPreservesPhotoContent(NSBundle.mainBundle.bundleIdentifier);
}

%group RWBSpringBoard

%hook CHUISAvocadoHostViewController

- (void)_updateBackgroundMaterialAndColor {
    CHSWidget *widget = self.widget;
    if (ShouldHandleWidget(widget.extensionBundleIdentifier)) return;
    %orig;
}

- (id)screenshotManager {
    CHSWidget *widget = self.widget;
    if (ShouldHandleWidget(widget.extensionBundleIdentifier)) return nil;
    return %orig;
}

%end

%hook CHUISWidgetHostViewController

- (unsigned long long)colorScheme {
    if (kIsEnabled && kForceDarkMode) return 2;
    return %orig;
}

- (void)_updateBackgroundMaterialAndColor {
    CHSWidget *widget = self.widget;
    if (ShouldHandleWidget(widget.extensionBundleIdentifier)) return;
    %orig;
}

- (void)_updatePersistedSnapshotContent {
    CHSWidget *widget = self.widget;
    if (ShouldHandleWidget(widget.extensionBundleIdentifier)) return;
    %orig;
}

- (void)_updatePersistedSnapshotContentIfNecessary {
    CHSWidget *widget = self.widget;
    if (ShouldHandleWidget(widget.extensionBundleIdentifier)) return;
    %orig;
}

- (id)_snapshotImageFromURL:(id)arg1 {
    CHSWidget *widget = self.widget;
    if (ShouldHandleWidget(widget.extensionBundleIdentifier)) return nil;
    return %orig;
}

%end

%hook SBHWidgetStackViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (!kIsEnabled || !kIsEnabledForMaterialView) return;
    UIView *firstChild = ((UIViewController *)self).view.subviews.firstObject;
    firstChild = firstChild.subviews.firstObject;
    if ([NSStringFromClass(firstChild.class) isEqualToString:@"MTMaterialView"]) {
        firstChild.alpha = 0.0;
    }
}

%end

%hook WGWidgetListItemViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (!kIsEnabled || !kIsEnabledForMaterialView) return;
    UIView *firstChild = ((UIViewController *)self).view.subviews.firstObject;
    if ([NSStringFromClass(firstChild.class) isEqualToString:@"MTMaterialView"]) {
        firstChild.alpha = 0.0;
    }
}

%end

%end

%group RWB

%hook UIWindow

%property (nonatomic, strong) NSNumber *rwb_shouldHideBackground;

- (UIWindow *)initWithFrame:(CGRect)frame {
    UIWindow *window = %orig;
    if (!sRWBWindows) sRWBWindows = [NSHashTable weakObjectsHashTable];
    if (window) [sRWBWindows addObject:window];
    if (window && sRWBIsWidgetRenderer && kIsEnabled) {
        window.rwb_shouldHideBackground = @YES;
    }
    return window;
}

- (UIWindow *)initWithWindowScene:(UIWindowScene *)scene {
    if ([scene isKindOfClass:%c(CHUISAvocadoWindowScene)]) {
        CHUISAvocadoWindowScene *avocadoScene = (CHUISAvocadoWindowScene *)scene;
        if (ShouldHandleWidget(avocadoScene.widget.extensionBundleIdentifier)) {
            self.rwb_shouldHideBackground = @YES;
        }
    } else if ([scene isKindOfClass:%c(CHUISWidgetScene)]) {
        CHUISWidgetScene *widgetScene = (CHUISWidgetScene *)scene;
        if (ShouldHandleWidget(widgetScene.widget.extensionBundleIdentifier)) {
            self.rwb_shouldHideBackground = @YES;
        }
    }
    UIWindow *window = %orig;
    if (!sRWBWindows) sRWBWindows = [NSHashTable weakObjectsHashTable];
    if (window) [sRWBWindows addObject:window];
    if (window && sRWBIsWidgetRenderer && kIsEnabled &&
        !window.rwb_shouldHideBackground.boolValue) {
        window.rwb_shouldHideBackground = @YES;
    }
    if (window && RWBWindowPreservesPhotoContent(window)) window.rwb_shouldHideBackground = @NO;
    if (window && kIsEnabled && kForceDarkMode) {
        if (!objc_getAssociatedObject(window, kRWBOriginalWindowStyleKey)) {
            objc_setAssociatedObject(window, kRWBOriginalWindowStyleKey,
                                     @(window.overrideUserInterfaceStyle),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [window setOverrideUserInterfaceStyle:UIUserInterfaceStyleDark];
    }
    return window;
}

- (void)setWindowScene:(UIWindowScene *)scene {
    %orig;
    if (sRWBIsWidgetRenderer && kIsEnabled) {
        self.rwb_shouldHideBackground = @(!RWBWindowPreservesPhotoContent(self));
    }
    if (!sRWBWindows) sRWBWindows = [NSHashTable weakObjectsHashTable];
    [sRWBWindows addObject:self];
}

%end

%hook CHUISWidgetScene

- (unsigned long long)colorScheme {
    if (kIsEnabled && kForceDarkMode) return 2;
    return %orig;
}

%end

%hook CHSMutableScreenshotPresentationAttributes

- (long long)colorScheme {
    if (kIsEnabled && kForceDarkMode) return 2;
    return %orig;
}

%end

%hook CHSScreenshotPresentationAttributes

- (long long)colorScheme {
    if (kIsEnabled && kForceDarkMode) return 2;
    return %orig;
}

%end

%hook UIView

- (void)didMoveToWindow {
    %orig;
    if (sActivityColorSupported && [self.layer isKindOfClass:objc_getClass("RBLayer")]
        && RWBActivityLayerMatches((RBLayer *)self.layer)) {
        RWBPrepareActivityLayer((RBLayer *)self.layer);
        [self.layer setNeedsDisplay];
    }
}

- (void)layoutSubviews {
    %orig;
    if (sActivityColorSupported && RWBUpdateActivityHostingBackground(self)) return;
    if ([NSStringFromClass([self class]) containsString:@"UIHostingView"]) return;
    id original = objc_getAssociatedObject(self, kRWBOriginalBackgroundColorKey);
    if (kIsEnabled && (!kExcludePhotos || self.window)
        && !RWBWindowPreservesPhotoContent(self.window)) {
        if (!original) {
            objc_setAssociatedObject(self, kRWBOriginalBackgroundColorKey,
                                     self.backgroundColor ?: NSNull.null,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        self.backgroundColor = UIColor.clearColor;
    } else if (original) {
        self.backgroundColor = original == NSNull.null ? nil : original;
        objc_setAssociatedObject(self, kRWBOriginalBackgroundColorKey, nil,
                                 OBJC_ASSOCIATION_ASSIGN);
    }
}

- (void)setBackgroundColor:(UIColor *)color {
    if (![NSThread isMainThread]) { %orig(color); return; }
    if (!sApplyingHostingBackground && RWBActivityHostingViewMatches(self)) {
        LGActivityHostingBackgroundState *state = RWBCaptureHostingBackground(self);
        state.viewColor = color;
        state.layerColor = RWBResolvedHostingColor(self, color);
        RWBPublishHostingStatus(self, state.viewColor, state.layerColor, state.viewOpaque);
        sApplyingHostingBackground++;
        %orig(RWBHostingColorIsBlack(self, color) ? UIColor.clearColor : color);
        sApplyingHostingBackground--;
        return;
    }
    if (!sApplyingHostingBackground && sActivityColorSupported)
        RWBRestoreActivityHostingBackground(self.layer);
    %orig(color);
}

- (void)setOpaque:(BOOL)opaque {
    if (![NSThread isMainThread]) { %orig(opaque); return; }
    if (!sApplyingHostingBackground && RWBActivityHostingViewMatches(self)) {
        LGActivityHostingBackgroundState *state = RWBCaptureHostingBackground(self);
        state.viewOpaque = opaque;
        %orig(NO);
        return;
    }
    if (!sApplyingHostingBackground && sActivityColorSupported)
        RWBRestoreActivityHostingBackground(self.layer);
    %orig(opaque);
}

%end

%hook RBLayer

- (void)display {
    UIView *view = (UIView *)self.delegate;

    if (RWBActivityLayerMatches(self)) {
        RWBPrepareActivityLayer(self);
        // Activity content keeps every native shape, glyph and image operation.
        %orig;
        return;
    }
    if (sActivityColorSupported) RWBRestoreActivityLayer(self);

    if (kIsEnabled && [view isKindOfClass:[UIView class]]
        && !RWBWindowPreservesPhotoContent(view.window) && view.window.rwb_shouldHideBackground.boolValue) {
        NSMutableDictionary *threadDict = [NSThread currentThread].threadDictionary;
        threadDict[@"rwb_shouldHideBackground"] = @YES;
        if (@available(iOS 17, *)) {
            if (self.opaque) self.opaque = NO;
        }

        %orig;

        [threadDict removeObjectForKey:@"rwb_shouldHideBackground"];
        if (@available(iOS 17, *)) {
            [threadDict removeObjectForKey:@"rwb_didSkipFirstN"];
        } else {
            [threadDict removeObjectForKey:@"rwb_didSkipFirst"];
        }
        return;
    }

    %orig;
}

%end

%end

%group RWBActivityClearColor
%hook CALayer
- (void)setBackgroundColor:(CGColorRef)color {
    if (![NSThread isMainThread]) {
        LGActivityHostingBackgroundState *state = objc_getAssociatedObject(self, &kActivityHostingStateKey);
        if (state) state.layerColor = color ? [UIColor colorWithCGColor:color] : nil;
        %orig(color); return;
    }
    UIView *view = [self.delegate isKindOfClass:UIView.class] ? (UIView *)self.delegate : nil;
    if (!sApplyingHostingBackground && view.layer == self && RWBActivityHostingViewMatches(view)) {
        LGActivityHostingBackgroundState *state = RWBCaptureHostingBackground(view);
        state.layerColor = color ? [UIColor colorWithCGColor:color] : nil;
        RWBPublishHostingStatus(view, state.viewColor, state.layerColor, state.viewOpaque);
        %orig(RWBHostingColorIsBlack(view, state.layerColor) ? NULL : color);
        return;
    }
    if (!sApplyingHostingBackground) RWBRestoreActivityHostingBackground(self);
    %orig(color);
}
%end

%hook RBLayer
- (void)setClearColor:(LGActivityClearColor)color {
    if (!sApplyingActivityColor) {
        if (RWBActivityLayerMatches(self)) {
            RWBCaptureActivityLayer(self, color, YES);
            %orig((LGActivityClearColor){0});
            return;
        }
        RWBRestoreActivityLayer(self);
    }
    %orig(color);
}
%end
%end

%group RWB_15

%hook RBShape

- (void)setRect:(CGRect)rect {
    if (kIsEnabled && [NSThread currentThread].threadDictionary[@"rwb_shouldHideBackground"]) {
        if (rect.size.width > kMaxWidgetWidth && rect.size.height > kMaxWidgetHeight) {
            %orig(CGRectZero);
            return;
        }
    }
    %orig;
}

%end

%hook UISCurrentUserInterfaceStyleValue

- (long long)userInterfaceStyle {
    if (kIsEnabled && kForceDarkMode) return 2;
    return %orig;
}

%end

%end

%group RWB_16

%hook RBShape

- (void)setRect:(CGRect)rect {
    NSMutableDictionary *threadDict = [NSThread currentThread].threadDictionary;
    if (kIsEnabled && threadDict[@"rwb_shouldHideBackground"]) {
        if (rect.size.width > kMaxWidgetWidth && rect.size.height > kMaxWidgetHeight) {
            if ([threadDict[@"rwb_didSkipFirst"] boolValue]) {
                %orig(CGRectZero);
                return;
            }
            threadDict[@"rwb_didSkipFirst"] = @YES;
        }
    }
    %orig;
}

%end

%end

%group RWB_17

%hook RBShape

- (void)setRect:(CGRect)rect {
    NSMutableDictionary *threadDict = [NSThread currentThread].threadDictionary;
    if (kIsEnabled && threadDict[@"rwb_shouldHideBackground"]) {
        if (rect.size.width > kMaxWidgetWidth && rect.size.height > kMaxWidgetHeight) {
            NSNumber *firstN = threadDict[@"rwb_didSkipFirstN"];
            if ([firstN intValue] > 1) {
                %orig(CGRectZero);
                return;
            }
            int newN = firstN ? [firstN intValue] + 1 : 0;
            threadDict[@"rwb_didSkipFirstN"] = @(newN);
            if (newN == 1) {
                %orig(CGRectZero);
                return;
            }
        }
    }
    %orig;
}

%end

%end

%ctor {
    NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier ?: @"";
    sRWBIsWidgetRenderer =
        [bundleIdentifier hasPrefix:@"com.apple.chrono.WidgetRenderer-"];
    sRWBIsChronod = [bundleIdentifier isEqualToString:@"com.apple.chronod"];

    if (sRWBIsChronod &&
        NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15) {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            RWBRestartChronodCallback,
            CFSTR("dylv.liquidassprefs/RestartChronod"),
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
    }

    ReloadPrefs();

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    RWBReloadPrefsCallback,
                                    CFSTR("dylv.liquidassprefs/Reload"),
                                    NULL,
                                    CFNotificationSuspensionBehaviorCoalesce);

    if ([bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
        %init(RWBSpringBoard);
    } else if ([bundleIdentifier isEqualToString:@"com.apple.chronod"] ||
               [bundleIdentifier hasPrefix:@"com.apple.chrono.WidgetRenderer-"]) {
        %init(RWB);
        if (@available(iOS 16.0, *)) {
            if (sRWBIsChronod) {
                notify_register_check("dylv.liquidass/activity-background-status", &sActivityDiagnosticToken);
                notify_register_check("dylv.liquidass/activity-hosting-background-status", &sHostingDiagnosticToken);
                if (RWBActivityColorABICompatible(objc_getClass("RBLayer"))) {
                    sActivityLayers = [NSHashTable weakObjectsHashTable];
                    sActivityColorSupported = YES;
                    %init(RWBActivityClearColor);
                }
                RWBPublishActivityStatus(nil, (LGActivityClearColor){0});
                RWBPublishHostingStatus(nil, nil, nil, NO);
            }
        }
        if (@available(iOS 17, *)) {
            %init(RWB_17);
        } else if (@available(iOS 16, *)) {
            %init(RWB_16);
        } else {
            %init(RWB_15);
        }
    }
}
