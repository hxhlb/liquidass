#import <UIKit/UIKit.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGSharedSupport.h"
#import <objc/runtime.h>

typedef struct {
    NSUInteger calls;
    CFTimeInterval total;
    CFTimeInterval peak;
    CFTimeInterval started;
} LGNotificationProfile;

static LGNotificationProfile sLGNotificationProfile;

static void LGNotificationProfileSample(CFTimeInterval elapsed) {
    if (!LGDebugLoggingEnabled()) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (sLGNotificationProfile.started == 0.0) sLGNotificationProfile.started = now;
    sLGNotificationProfile.calls++;
    sLGNotificationProfile.total += elapsed;
    sLGNotificationProfile.peak = MAX(sLGNotificationProfile.peak, elapsed);
    if (now - sLGNotificationProfile.started < 1.0) return;
    LGLog(@"[NOTIFPROF] materialUpdates=%lu avg=%.3fms total=%.3fms peak=%.3fms",
          (unsigned long)sLGNotificationProfile.calls,
          sLGNotificationProfile.total * 1000.0 / MAX((NSUInteger)1, sLGNotificationProfile.calls),
          sLGNotificationProfile.total * 1000.0,
          sLGNotificationProfile.peak * 1000.0);
    sLGNotificationProfile = (LGNotificationProfile){ .started = now };
}

static BOOL LGHasMaterialAncestorBefore(UIView *material, NSString *stopClassName) {
    Class stopCls = NSClassFromString(stopClassName);
    Class materialClass = NSClassFromString(@"MTMaterialView");
    for (UIView *v = material.superview; v; v = v.superview) {
        if (stopCls && [v isKindOfClass:stopCls]) return NO;
        if (materialClass && [v isKindOfClass:materialClass]) return YES;
    }
    return NO;
}

static BOOL LGIsPlatterMaterial(UIView *material) {
    if (!hasAncestorOfClassName(material, @"PLPlatterView")) return NO;
    if (hasAncestorOfClassName(material, @"SBSwitcherAppSuggestionBannerView")) return NO;
    return !LGHasMaterialAncestorBefore(material, @"PLPlatterView");
}

static UIView *LGPlatterActionButtonAncestor(UIView *material) {
    Class materialClass = NSClassFromString(@"MTMaterialView");
    for (UIView *v = material.superview; v; v = v.superview) {
        NSString *name = NSStringFromClass(v.class);
        if ([name isEqualToString:@"PLPlatterActionButton"] ||
            [name isEqualToString:@"NCNotificationListCellActionButton"])
            return v;
        if (materialClass && [v isKindOfClass:materialClass]) return nil;
    }
    return nil;
}

static BOOL LGIsPlatterActionMaterial(UIView *material) {
    if (hasAncestorOfClassName(material, @"SBSwitcherAppSuggestionBannerView")) return NO;
    return LGPlatterActionButtonAncestor(material) != nil;
}

static BOOL LGResponderChainContainsClass(UIResponder *responder, NSString *name) {
    Class cls = NSClassFromString(name);
    for (UIResponder *r = responder; r; r = r.nextResponder)
        if (cls && [r isKindOfClass:cls]) return YES;
    return NO;
}

static void *kLGPlatterClassificationKey = &kLGPlatterClassificationKey;
static void *kLGPlatterOriginalDimmingHiddenKey = &kLGPlatterOriginalDimmingHiddenKey;
static void *kLGPlatterRequestedTextColorKey = &kLGPlatterRequestedTextColorKey;
static void *kLGPlatterRequestedAttributedTextKey = &kLGPlatterRequestedAttributedTextKey;
static void *kLGPlatterApplyingTextStyleKey = &kLGPlatterApplyingTextStyleKey;
static NSHashTable<UILabel *> *sLGStyledPlatterLabels;

static BOOL LGIsTopBannerPresentation(UIView *view) {
    if (!view.window) return NO;
    if ([NSStringFromClass(view.window.class) isEqualToString:@"SBBannerWindow"]) return YES;
    if (hasAncestorOfClassName(view, @"BNContentViewControllerView")) return YES;
    if (LGResponderChainContainsClass(view, @"BNContentViewController")) return YES;
    return LGResponderChainContainsClass(view, @"SBNotificationPresentableViewController");
}

static UIView *LGNotificationAncestor(UIView *view) {
    for (UIView *ancestor = view; ancestor; ancestor = ancestor.superview) {
        NSString *name = NSStringFromClass(ancestor.class);
        if ([name isEqualToString:@"NCNotificationShortLookView"] ||
            [name isEqualToString:@"NCNotificationLongLookView"] ||
            [name isEqualToString:@"PLPlatterView"]) return ancestor;
    }
    return nil;
}

static UIColor *LGForcedPlatterTextColor(UIView *view) {
    if (!view) return nil;
    if (LGIsTopBannerPresentation(view))
        return lgHostEnabled(@"Banner") &&
               view.traitCollection.userInterfaceStyle == UIUserInterfaceStyleLight
            ? UIColor.blackColor : nil;
    if (!lgHostEnabled(@"Notification") || !LGNotificationAncestor(view)) return nil;
    return [LGGlassPreferenceValue(@"Notification.LabelColor") isEqual:@"black"]
        ? UIColor.blackColor : UIColor.whiteColor;
}

static NSAttributedString *LGAttributedTextWithColor(NSAttributedString *text, UIColor *color) {
    if (!color) return text;
    if (!text.length) return text;
    NSMutableAttributedString *copy = [text mutableCopy];
    [copy addAttribute:NSForegroundColorAttributeName
                 value:color
                 range:NSMakeRange(0, copy.length)];
    return copy;
}

static void LGDisableLockscreenStackDimming(id controller) {
    // stack dimming belongs to notifications and not top banners
    if (!controller || LGIsTopBannerPresentation([controller isKindOfClass:[UIViewController class]]
                                                   ? ((UIViewController *)controller).view : nil)) return;
    @try {
        id preview = [controller valueForKey:@"viewForPreview"];
        UIView *dimming = [preview valueForKey:@"stackDimmingOverlayView"];
        if (!dimming) {
            id contentSizeManager = [controller valueForKey:@"contentSizeManagingView"];
            dimming = [contentSizeManager valueForKey:@"stackDimmingView"];
        }
        if (dimming) {
            NSNumber *original = objc_getAssociatedObject(
                dimming, kLGPlatterOriginalDimmingHiddenKey);
            if (lgHostEnabled(@"Notification")) {
                if (!original) {
                    objc_setAssociatedObject(dimming,
                        kLGPlatterOriginalDimmingHiddenKey, @(dimming.hidden),
                        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
                dimming.hidden = YES;
            } else if (original) {
                dimming.hidden = original.boolValue;
                objc_setAssociatedObject(dimming,
                    kLGPlatterOriginalDimmingHiddenKey, nil,
                    OBJC_ASSOCIATION_ASSIGN);
            }
        }
    } @catch (__unused NSException *exception) {

    }
}

static void LGRestorePlatterLabel(UILabel *label) {
    UIColor *color = objc_getAssociatedObject(label, kLGPlatterRequestedTextColorKey);
    id attributed = objc_getAssociatedObject(label, kLGPlatterRequestedAttributedTextKey);
    objc_setAssociatedObject(label, kLGPlatterApplyingTextStyleKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (attributed) label.attributedText = attributed == NSNull.null ? nil : attributed;
    if (color) label.textColor = color;
    objc_setAssociatedObject(label, kLGPlatterApplyingTextStyleKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(label, kLGPlatterRequestedTextColorKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(label, kLGPlatterRequestedAttributedTextKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
    [sLGStyledPlatterLabels removeObject:label];
}

static void LGApplyPlatterLabelStyle(UILabel *label) {
    UIColor *forced = LGForcedPlatterTextColor(label);
    if (!forced) {
        LGRestorePlatterLabel(label);
        return;
    }
    if (!sLGStyledPlatterLabels)
        sLGStyledPlatterLabels = [NSHashTable weakObjectsHashTable];
    [sLGStyledPlatterLabels addObject:label];
    if (!objc_getAssociatedObject(label, kLGPlatterRequestedTextColorKey)) {
        objc_setAssociatedObject(label, kLGPlatterRequestedTextColorKey,
                                 label.textColor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!objc_getAssociatedObject(label, kLGPlatterRequestedAttributedTextKey)) {
        objc_setAssociatedObject(label, kLGPlatterRequestedAttributedTextKey,
                                 label.attributedText ?: NSNull.null,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    objc_setAssociatedObject(label, kLGPlatterApplyingTextStyleKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (label.attributedText.length)
        label.attributedText = LGAttributedTextWithColor(label.attributedText, forced);
    label.textColor = forced;
    objc_setAssociatedObject(label, kLGPlatterApplyingTextStyleKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
}

static void LGReconcilePlatterLabels(void) {
    for (UILabel *label in sLGStyledPlatterLabels.allObjects)
        LGApplyPlatterLabelStyle(label);
}

static CGFloat LGActionButtonRadius(UIView *material) {
    UIView *button = LGPlatterActionButtonAncestor(material) ?: material;
    if (button.layer.cornerRadius > 0.5) return button.layer.cornerRadius;
    if (material.layer.cornerRadius > 0.5) return material.layer.cornerRadius;
    return CGRectGetHeight(button.bounds) * 0.5;
}

static void LGUpdatePlatterGlass(UIView *material) {
    // one platter class serves banners notifications and action buttons

    if (!material.window) return;
    CFTimeInterval start = CACurrentMediaTime();

    if (LGIsPlatterMaterial(material)) {
        BOOL topBanner = LGIsTopBannerPresentation(material);
        NSString *prefix = topBanner ? @"Banner" : @"Notification";
        NSString *previous = objc_getAssociatedObject(material, kLGPlatterClassificationKey);
        if (previous && ![previous isEqualToString:prefix]) {
            LGRemoveGlassFromMaterial(material, kGlassKey);
        }
        if (![previous isEqualToString:prefix]) {
            objc_setAssociatedObject(material, kLGPlatterClassificationKey, prefix,
                                     OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
        LGInstallRegisteredGlassInMaterial(material, kGlassKey, prefix,
                                           UIEdgeInsetsZero, -1.0, nil);
    } else if (LGIsPlatterActionMaterial(material)) {

        LGInstallRegisteredGlassInMaterial(material, kGlassKey, @"Notification",
                                           UIEdgeInsetsZero,
                                           LGActionButtonRadius(material), nil);
    }
    LGNotificationProfileSample(CACurrentMediaTime() - start);
}

%hook MTMaterialView
- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    if (self_.window) LGUpdatePlatterGlass(self_);
}
- (void)layoutSubviews {
    %orig;
    LGUpdatePlatterGlass((UIView *)self);
}
%end

%hook UILabel
- (void)setTextColor:(UIColor *)color {
    if ([objc_getAssociatedObject(self, kLGPlatterApplyingTextStyleKey) boolValue]) {
        %orig(color);
        return;
    }
    UIColor *forced = LGForcedPlatterTextColor((UIView *)self);
    if (forced) {
        objc_setAssociatedObject(self, kLGPlatterRequestedTextColorKey,
                                 color, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!sLGStyledPlatterLabels)
            sLGStyledPlatterLabels = [NSHashTable weakObjectsHashTable];
        [sLGStyledPlatterLabels addObject:self];
        color = forced;
    }
    %orig(color);
}
- (void)setAttributedText:(NSAttributedString *)text {
    if ([objc_getAssociatedObject(self, kLGPlatterApplyingTextStyleKey) boolValue]) {
        %orig(text);
        return;
    }
    UIColor *forced = LGForcedPlatterTextColor((UIView *)self);
    if (forced) {
        objc_setAssociatedObject(self, kLGPlatterRequestedAttributedTextKey,
                                 text ?: NSNull.null,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!sLGStyledPlatterLabels)
            sLGStyledPlatterLabels = [NSHashTable weakObjectsHashTable];
        [sLGStyledPlatterLabels addObject:self];
        text = LGAttributedTextWithColor(text, forced);
    }
    %orig(text);
}
- (void)didMoveToWindow {
    %orig;
    LGApplyPlatterLabelStyle(self);
}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    %orig(previousTraitCollection);
    LGApplyPlatterLabelStyle(self);
}
%end

%ctor {
    lgObservePreferenceReload(^{ LGReconcilePlatterLabels(); });
}

%hook NCNotificationShortLookViewController
- (void)viewDidLoad {
    %orig;
    LGDisableLockscreenStackDimming(self);
}
- (void)viewDidLayoutSubviews {
    %orig;
    LGDisableLockscreenStackDimming(self);
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    LGDisableLockscreenStackDimming(self);
}
%end
