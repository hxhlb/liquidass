#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import <objc/runtime.h>

static const CGFloat kWidgetCornerRadius = 20.2;
static void *kWidgetGlassKey = &kWidgetGlassKey;
static void *kWidgetContainerStateKey = &kWidgetContainerStateKey;
static void *kLegacyWidgetHostKey = &kLegacyWidgetHostKey;

static BOOL widgetUsesLegacyDirectGlass(void) {
    NSInteger majorVersion = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
    return majorVersion == 15 || majorVersion == 16;
}

@interface CHSWidget : NSObject
@property (nonatomic, copy, readonly) NSString *extensionBundleIdentifier;
@end

@interface CHUISWidgetHostViewController : UIViewController
@property (nonatomic, copy) CHSWidget *widget;
@end

@interface CHUISAvocadoHostViewController : UIViewController
@property (nonatomic, copy) CHSWidget *widget;
- (NSInteger)_expectedBackgroundViewMode;
- (void)setBackgroundViewMode:(NSInteger)mode;
@end

@interface SBHWidgetWrapperView : UIView
@property (nonatomic, readonly) UIView *containerView;
@property (nonatomic, readonly) UIView *contentView;
@property (nonatomic, readonly) UIView *shadowedWidgetView;
@end

@interface SBHWidgetWrapperBackgroundView : UIView
@property (nonatomic, readonly) UIView *underlyingBackgroundView;
@property (nonatomic, readonly) UIView *widgetBackgroundView;
@end

static UIViewController *widgetNearestStackController(UIView *view) {
    for (UIResponder *r = view; r; r = r.nextResponder)
        if ([NSStringFromClass(r.class) isEqualToString:@"SBHWidgetStackViewController"] &&
            [r isKindOfClass:[UIViewController class]])
            return (UIViewController *)r;
    return nil;
}

static BOOL widgetHasAncestorNamedWithinDepth(UIView *view, NSString *name, NSInteger maxDepth) {
    NSInteger depth = 0;
    for (UIView *a = view.superview; a && depth < maxDepth; a = a.superview, depth++)
        if ([NSStringFromClass(a.class) isEqualToString:name]) return YES;
    return NO;
}

static BOOL widgetSubtreeContainsClass(UIView *view, NSString *name) {
    if ([NSStringFromClass(view.class) isEqualToString:name]) return YES;
    for (UIView *sub in view.subviews)
        if (widgetSubtreeContainsClass(sub, name)) return YES;
    return NO;
}

static UIView *widgetFindDescendantNamed(UIView *view, NSString *name) {
    for (UIView *sub in view.subviews) {
        if ([NSStringFromClass(sub.class) isEqualToString:name]) return sub;
        UIView *found = widgetFindDescendantNamed(sub, name);
        if (found) return found;
    }
    return nil;
}

static BOOL isWidgetGlassHostContainer(UIView *view) {
    if (widgetUsesLegacyDirectGlass()) return NO;
    // widget internals vary so use the nearest stable container
    if (!isExactClass(view, @"UIView")) return NO;
    if (view.bounds.size.width < 120.0 || view.bounds.size.height < 120.0) return NO;
    if (!widgetNearestStackController(view)) return NO;
    if (!widgetHasAncestorNamedWithinDepth(view, @"SBFTouchPassThroughView", 8)) return NO;
    if (!widgetHasAncestorNamedWithinDepth(view, @"SBIconView", 10)) return NO;
    for (UIView *sub in view.subviews) {
        if (!isExactClass(sub, @"UIView") && !isExactClass(sub, @"BSUIScrollView")) continue;
        UIView *scroll = isExactClass(sub, @"BSUIScrollView") ? sub
                       : widgetFindDescendantNamed(sub, @"BSUIScrollView");
        if (scroll && widgetSubtreeContainsClass(scroll, @"SBHWidgetContainerView")) return YES;
    }
    return NO;
}

static UIView *widgetAncestorContainerHost(UIView *view) {
    NSInteger depth = 0;
    for (UIView *a = view; a && depth < 12; a = a.superview, depth++)
        if (isWidgetGlassHostContainer(a)) return a;
    return nil;
}

static BOOL isWidgetStackBackgroundMaterial(UIView *mat) {
    if (widgetUsesLegacyDirectGlass()) return NO;
    // stack backgrounds stay stock so child widgets keep separate lenses
    if (!isExactClass(mat, @"MTMaterialView")) return NO;
    UIView *parent = mat.superview;
    if (!isExactClass(parent, @"UIView")) return NO;
    UIViewController *vc = widgetNearestStackController(parent);
    if (!vc) return NO;
    return vc.view == parent || parent.superview == vc.view;
}

static void removeWidgetGlass(UIView *container) {
    LGLiveBackdropView *glass = objc_getAssociatedObject(container, kWidgetGlassKey);
    [glass removeFromSuperview];
    objc_setAssociatedObject(container, kWidgetGlassKey, nil, OBJC_ASSOCIATION_ASSIGN);
    NSDictionary *state = objc_getAssociatedObject(container, kWidgetContainerStateKey);
    if (state) {
        container.layer.cornerRadius = [state[@"radius"] doubleValue];
        container.layer.masksToBounds = [state[@"masks"] boolValue];
        container.clipsToBounds = [state[@"clips"] boolValue];
        id curve = state[@"curve"];
        container.layer.cornerCurve = curve == NSNull.null ? nil : curve;
        objc_setAssociatedObject(container, kWidgetContainerStateKey, nil,
                                 OBJC_ASSOCIATION_ASSIGN);
    }
}

static void injectWidgetGlass(UIView *container) {
    if (!lgHostEnabled(@"Widgets")) { removeWidgetGlass(container); return; }
    LGLiveBackdropView *glass = objc_getAssociatedObject(container, kWidgetGlassKey);
    if (!glass) {
        glass = LGCreateRegisteredGlass(container.bounds, nil, @"Widgets");
        if (!glass) return;
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [container insertSubview:glass atIndex:0];
        objc_setAssociatedObject(container, kWidgetGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (glass.superview != container) [container insertSubview:glass atIndex:0];
    else if (container.subviews.firstObject != glass) [container sendSubviewToBack:glass];
    glass.frame = container.bounds;
    glass.layer.cornerRadius  = kWidgetCornerRadius;
    glass.layer.cornerCurve   = kCACornerCurveContinuous;
    glass.layer.masksToBounds = YES;
    [glass applyFilters];
    if (!objc_getAssociatedObject(container, kWidgetContainerStateKey)) {
        objc_setAssociatedObject(container, kWidgetContainerStateKey,
            @{@"radius": @(container.layer.cornerRadius),
              @"masks": @(container.layer.masksToBounds),
              @"clips": @(container.clipsToBounds),
              @"curve": container.layer.cornerCurve ?: NSNull.null},
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    container.layer.cornerRadius  = kWidgetCornerRadius;
    container.layer.cornerCurve   = kCACornerCurveContinuous;
    container.layer.masksToBounds = YES;
    container.clipsToBounds       = YES;
    lgTrackGlass(glass, @"Widgets", nil);
}

static void removeLegacyWidgetGlass(SBHWidgetWrapperView *wrapper) {
    UIView *host = objc_getAssociatedObject(wrapper, kLegacyWidgetHostKey);
    LGLiveBackdropView *glass = host
        ? objc_getAssociatedObject(host, kWidgetGlassKey) : nil;
    [glass removeFromSuperview];
    if (host) objc_setAssociatedObject(host, kWidgetGlassKey, nil,
                                       OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(wrapper, kLegacyWidgetHostKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
}

static UIView *legacyWidgetHost(SBHWidgetWrapperView *wrapper) {
    UIView *host = nil;
    if ([wrapper respondsToSelector:@selector(containerView)])
        host = wrapper.containerView;
    if (!host && [wrapper respondsToSelector:@selector(shadowedWidgetView)])
        host = wrapper.shadowedWidgetView;
    return host;
}

static void updateLegacyWidgetWrapper(SBHWidgetWrapperView *wrapper) {
    UIView *host = legacyWidgetHost(wrapper);
    UIView *previousHost = objc_getAssociatedObject(wrapper, kLegacyWidgetHostKey);
    if (previousHost && previousHost != host) removeLegacyWidgetGlass(wrapper);
    if (!widgetUsesLegacyDirectGlass() || !lgHostEnabled(@"Widgets") ||
        !wrapper.window || !host || CGRectIsEmpty(host.bounds) ||
        host.bounds.size.width < 100.0 || host.bounds.size.height < 100.0) {
        removeLegacyWidgetGlass(wrapper);
        return;
    }

    LGLiveBackdropView *glass = objc_getAssociatedObject(host, kWidgetGlassKey);
    if (!glass) {
        glass = LGCreateRegisteredGlass(host.bounds, nil, @"Widgets");
        if (!glass) return;
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                UIViewAutoresizingFlexibleHeight;
        objc_setAssociatedObject(host, kWidgetGlassKey, glass,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        lgTrackGlass(glass, @"Widgets", nil);
    }
    if (glass.superview != host) [host insertSubview:glass atIndex:0];
    else if (host.subviews.firstObject != glass) [host sendSubviewToBack:glass];
    glass.frame = host.bounds;
    glass.layer.cornerRadius = kWidgetCornerRadius;
    glass.layer.cornerCurve = kCACornerCurveContinuous;
    glass.layer.masksToBounds = YES;
    [glass applyFilters];
    objc_setAssociatedObject(wrapper, kLegacyWidgetHostKey, host,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void updateLegacyWidgetBackground(SBHWidgetWrapperBackgroundView *background) {
    UIView *underlying = [background respondsToSelector:
        @selector(underlyingBackgroundView)] ? background.underlyingBackgroundView : nil;
    UIView *widget = [background respondsToSelector:
        @selector(widgetBackgroundView)] ? background.widgetBackgroundView : nil;
    BOOL suppress = widgetUsesLegacyDirectGlass() &&
                    lgHostEnabled(@"Widgets") && background.window;
    if (underlying) {
        if (suppress) lgSuppressStock(underlying, @"Widgets", YES);
        else underlying.hidden = NO;
    }
    if (widget) {
        if (suppress) lgSuppressStock(widget, @"Widgets", YES);
        else widget.hidden = NO;
    }
}

#pragma mark - hooks

%hook MTMaterialView
- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    if (self_.window && lgHostEnabled(@"Widgets") && isWidgetStackBackgroundMaterial(self_))
        lgSuppressStock(self_, @"Widgets", YES);
}
- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;
    if (lgHostEnabled(@"Widgets") && isWidgetStackBackgroundMaterial(self_))
        lgSuppressStock(self_, @"Widgets", YES);
}
- (void)setHidden:(BOOL)hidden {
    UIView *self_ = (UIView *)self;
    if (lgHostEnabled(@"Widgets") && isWidgetStackBackgroundMaterial(self_)) {
        hidden = YES;
        lgSuppressStock(self_, @"Widgets", NO);
    }
    %orig(hidden);
}
%end

%hook CHUISAvocadoHostViewController
- (void)_updateBackgroundMaterialAndColor {
    if (widgetUsesLegacyDirectGlass() && lgHostEnabled(@"Widgets")) {
        [self setBackgroundViewMode:0];
        return;
    }
    if (lgHostEnabled(@"Widgets") && self.widget.extensionBundleIdentifier.length) return;
    %orig;
}
- (NSInteger)_expectedBackgroundViewMode {
    if (widgetUsesLegacyDirectGlass() && lgHostEnabled(@"Widgets")) return 0;
    return %orig;
}
- (void)setBackgroundViewMode:(NSInteger)mode {
    if (widgetUsesLegacyDirectGlass() && lgHostEnabled(@"Widgets")) mode = 0;
    %orig(mode);
}
- (id)screenshotManager {
    if (lgHostEnabled(@"Widgets") && self.widget.extensionBundleIdentifier.length) return nil;
    return %orig;
}
%end

%hook CHUISWidgetHostViewController
- (void)_updateBackgroundMaterialAndColor {
    if (lgHostEnabled(@"Widgets") && self.widget.extensionBundleIdentifier.length) return;
    %orig;
}
- (void)_updatePersistedSnapshotContent {
    if (lgHostEnabled(@"Widgets") && self.widget.extensionBundleIdentifier.length) return;
    %orig;
}
- (void)_updatePersistedSnapshotContentIfNecessary {
    if (lgHostEnabled(@"Widgets") && self.widget.extensionBundleIdentifier.length) return;
    %orig;
}
- (id)_snapshotImageFromURL:(id)arg1 {
    if (lgHostEnabled(@"Widgets") && self.widget.extensionBundleIdentifier.length) return nil;
    return %orig;
}
%end

%hook BSUIScrollView
- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    UIView *host = widgetAncestorContainerHost(self_);
    if (!host) return;
    if (!self_.window) { removeWidgetGlass(host); return; }
    injectWidgetGlass(host);
}
- (void)layoutSubviews {
    %orig;
    UIView *host = widgetAncestorContainerHost((UIView *)self);
    if (host) injectWidgetGlass(host);
}
%end

%group LGLegacyWidgetWrapperLifecycle

%hook SBHWidgetWrapperView

- (void)didMoveToWindow {
    %orig;
    updateLegacyWidgetWrapper(self);
}

- (void)layoutSubviews {
    %orig;
    updateLegacyWidgetWrapper(self);
}

- (void)setContentView:(UIView *)contentView {
    %orig;
    updateLegacyWidgetWrapper(self);
}

%end


%end


%group LGLegacyWidgetBackgroundLifecycle

%hook SBHWidgetWrapperBackgroundView

- (void)didMoveToWindow {
    %orig;
    updateLegacyWidgetBackground(self);
}

- (void)layoutSubviews {
    %orig;
    updateLegacyWidgetBackground(self);
}

%end


%end


%ctor {
    %init;
    if (widgetUsesLegacyDirectGlass() &&
        NSClassFromString(@"SBHWidgetWrapperView")) {
        %init(LGLegacyWidgetWrapperLifecycle);
    }
    if (widgetUsesLegacyDirectGlass() &&
        NSClassFromString(@"SBHWidgetWrapperBackgroundView")) {
        %init(LGLegacyWidgetBackgroundLifecycle);
    }
}
