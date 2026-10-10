// creds to owngoalstudios remove widget background

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <unistd.h>
#import "../Shared/LGSharedSupport.h"
#import "../Shared/LGWidgetCompatibility.h"

static BOOL kIsEnabled = YES;
static BOOL kIsEnabledForSystemWidgets = YES;
static BOOL kIsEnabledForMaterialView = NO;
static BOOL kForceDarkMode = NO;
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

@interface RBLayer : CALayer
@end

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
    if (LGWidgetPreservesPhotoContent(bundleIdentifier)) return NO;
    if (!kIsEnabledForSystemWidgets && [bundleIdentifier hasPrefix:@"com.apple."])
        return NO;
    return YES;
}

static BOOL RWBWindowPreservesPhotoContent(UIWindow *window) {
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

- (void)layoutSubviews {
    %orig;
    if ([NSStringFromClass([self class]) containsString:@"UIHostingView"]) return;
    id original = objc_getAssociatedObject(self, kRWBOriginalBackgroundColorKey);
    if (kIsEnabled && self.window && !RWBWindowPreservesPhotoContent(self.window)) {
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

%end

%hook RBLayer

- (void)display {
    UIView *view = (UIView *)self.delegate;

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
        if (@available(iOS 17, *)) {
            %init(RWB_17);
        } else if (@available(iOS 16, *)) {
            %init(RWB_16);
        } else {
            %init(RWB_15);
        }
    }
}
