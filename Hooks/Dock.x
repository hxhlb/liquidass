#import <UIKit/UIKit.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGSharedSupport.h"
#import <objc/runtime.h>
#import <objc/message.h>

typedef NS_ENUM(NSInteger, LGDockMode) {
    LGDockModeNone = 0,
    LGDockModeRegular,
    LGDockModeFloating,
};

static const void *kDockHomeButtonBorderKey = &kDockHomeButtonBorderKey;
static const void *kIOS15DockGlassKey = &kIOS15DockGlassKey;
static const void *kIOS15DockBackgroundKey = &kIOS15DockBackgroundKey;
static const void *kVerticalDockMaterialKey = &kVerticalDockMaterialKey;

@interface LGLiveBackdropView (LGVerticalDockShapeSync)
- (void)updateSpecular;
@end

@interface SBDockView : UIView
@property (nonatomic, readonly) UIView *backgroundView;
@end

static BOOL dockUsesIOS15DirectGlass(void) {
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15;
}

static BOOL dockInsideCategoryStackBackground(UIView *view) {
    for (UIView *ancestor = view; ancestor; ancestor = ancestor.superview) {
        if ([NSStringFromClass(ancestor.class) containsString:@"StackViewBackground"])
            return YES;
    }
    return NO;
}

static UIView *dockBackgroundForPlatter(UIView *platter) {
    SEL selector = @selector(backgroundView);
    Method method = class_getInstanceMethod(object_getClass(platter), selector);
    char type[32] = {0};
    if (!method || method_getNumberOfArguments(method) != 2) return nil;
    method_getReturnType(method, type, sizeof(type));
    if (type[0] != '@') return nil;
    id background = ((id (*)(id, SEL))objc_msgSend)(platter, selector);
    return [background isKindOfClass:UIView.class] ? background : nil;
}

static BOOL dockIsVerticalFloatingMaterial(UIView *material) {
    if (!isExactClass(material, @"MTMaterialView")) return NO;
    CGSize size = material.bounds.size;
    if (size.width < 24.0 || size.height <= size.width) return NO;
    Class platterClass = NSClassFromString(@"SBFloatingDockPlatterView");
    if (!platterClass) return NO;
    for (UIView *parent = material.superview; parent; parent = parent.superview) {
        if ([parent isKindOfClass:platterClass]) {
            // Only the native platter background, never Library cards/icons.
            return dockBackgroundForPlatter(parent) == material;
        }
    }
    return NO;
}

static CGFloat dockCornerRadiusForMaterial(UIView *material) {
    return dockIsVerticalFloatingMaterial(material) ? material.layer.cornerRadius : -1.0;
}

static LGDockMode dockModeForMaterial(UIView *material) {
    // each dock family exposes different host geometry
    BOOL regular = hasAncestorOfClassName(material, @"SBDockView");
    BOOL floating = hasAncestorOfClassName(material, @"SBFloatingDockPlatterView");
    BOOL exact = isExactClass(material, @"MTMaterialView");
    BOOL stacked = dockInsideCategoryStackBackground(material);
    if (regular || floating)
        LGLog(@"[Dock] candidate class=%@ frame=%@ bounds=%@ scale=%.1f regular=%d floating=%d exact=%d stacked=%d",
              NSStringFromClass(material.class), NSStringFromCGRect(material.frame),
              NSStringFromCGRect(material.bounds), material.window.screen.scale,
              regular, floating, exact, stacked);
    if (!exact || stacked) return LGDockModeNone;
    if (dockIsVerticalFloatingMaterial(material)) return LGDockModeFloating;

    CGSize size = material.bounds.size;
    if (size.width < 160.0 || size.height < 40.0) {
        if (regular || floating)
            LGLog(@"[Dock] rejected size=%.1fx%.1f", size.width, size.height);
        return LGDockModeNone;
    }

    if (floating && size.width >= size.height * 2.0) {
        return LGDockModeFloating;
    }
    if (dockUsesIOS15DirectGlass()) return LGDockModeNone;
    if (hasAncestorOfClassName(material, @"SBDockView")) {
        return LGDockModeRegular;
    }
    return LGDockModeNone;
}

static BOOL dockIsFullScreenPhone(UIView *material) {
    UIEdgeInsets safeArea = material.window.safeAreaInsets;
    return safeArea.top > 20.0 || safeArea.bottom > 0.0;
}

static void dockUpdateHomeButtonBorder(LGLiveBackdropView *glass,
                                       BOOL needsBorder) {
    CAShapeLayer *border =
        objc_getAssociatedObject(glass, kDockHomeButtonBorderKey);
    if (!needsBorder) {
        [border removeFromSuperlayer];
        objc_setAssociatedObject(glass, kDockHomeButtonBorderKey, nil,
                                 OBJC_ASSOCIATION_ASSIGN);
        return;
    }
    if (!border) {
        border = [CAShapeLayer layer];
        border.fillColor = UIColor.clearColor.CGColor;
        border.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.42].CGColor;
        objc_setAssociatedObject(glass, kDockHomeButtonBorderKey, border,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    [glass.layer addSublayer:border];
    CGFloat scale = glass.window.screen.scale;
    if (scale <= 0.0) scale = UIScreen.mainScreen.scale;
    CGFloat lineWidth = 1.0 / MAX(scale, 1.0);
    CGRect borderRect = CGRectInset(glass.bounds, lineWidth * 0.5,
                                    lineWidth * 0.5);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    border.frame = glass.bounds;
    border.contentsScale = scale;
    border.lineWidth = lineWidth;
    border.path = [UIBezierPath bezierPathWithRect:borderRect].CGPath;
    [CATransaction commit];
}

static void configureDockGlass(UIView *material, LGLiveBackdropView *glass) {
    // home button docks use a border instead of specular
    LGDockMode mode = dockModeForMaterial(material);
    BOOL homeButtonDock = mode == LGDockModeRegular &&
                          !dockIsFullScreenPhone(material);
    glass.lgSpecularEnabledOverride = homeButtonDock ? @NO : nil;
    dockUpdateHomeButtonBorder(glass, homeButtonDock);
    LGLog(@"[Dock] injected mode=%ld homeButton=%d material=%@ glass=%@",
          (long)mode, homeButtonDock, NSStringFromCGRect(material.bounds),
          NSStringFromCGRect(glass.frame));
}

static void dockSyncVerticalGlassAfterLayout(UIView *platter) {
    UIView *material = dockBackgroundForPlatter(platter);
    UIView *previous = objc_getAssociatedObject(platter, kVerticalDockMaterialKey);
    BOOL vertical = dockIsVerticalFloatingMaterial(material);
    if (previous && (previous != material || !platter.window || !vertical)) {
        objc_setAssociatedObject(platter, kVerticalDockMaterialKey, nil,
                                 OBJC_ASSOCIATION_ASSIGN);
        if (previous != material || !platter.window ||
            dockModeForMaterial(previous) == LGDockModeNone) {
            LGRemoveGlassFromMaterial(previous, kGlassKey);
        } else {
            // Leaving a previously-owned vertical Dock: restore the existing
            // horizontal route and its native-radius tracking after layout.
            LGLiveBackdropView *glass = LGInstallRegisteredGlassInMaterial(
                previous, kGlassKey, @"Dock", UIEdgeInsetsZero, -1.0, nil);
            if (glass) configureDockGlass(previous, glass);
        }
    }
    if (!vertical || !platter.window) return;

    // Native layout sets the background frame before its continuous radius.
    // Synchronize only after %orig completed, using that final radius for both
    // the glass and its specular masks. No fixed corner value or global hook.
    CGFloat radius = material.layer.cornerRadius;
    LGLiveBackdropView *glass = LGInstallRegisteredGlassInMaterial(
        material, kGlassKey, @"Dock", UIEdgeInsetsZero, radius, nil);
    if (glass) {
        NSString *curve = material.layer.cornerCurve;
        BOOL curveChanged = glass.layer.cornerCurve != curve &&
                            ![glass.layer.cornerCurve isEqualToString:curve];
        // The generic injector tolerates 0.5pt; the vertical rim must track
        // even smaller native radius changes, without changing horizontal rules.
        if (fabs(glass.layer.cornerRadius - radius) > 0.001 || curveChanged) {
            glass.layer.cornerRadius = radius;
            glass.layer.cornerCurve = curve;
            [glass updateSpecular];
            [glass applyFilters];
        }
        objc_setAssociatedObject(platter, kVerticalDockMaterialKey, material,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        configureDockGlass(material, glass);
    }
}

%group LGVerticalFloatingDockLifecycle

%hook SBFloatingDockPlatterView

- (void)layoutSubviews {
    %orig;
    dockSyncVerticalGlassAfterLayout((UIView *)self);
}

- (void)didMoveToWindow {
    %orig;
    dockSyncVerticalGlassAfterLayout((UIView *)self);
}

%end

%end

static void removeIOS15DockGlass(UIView *dockView) {
    LGLiveBackdropView *glass = objc_getAssociatedObject(dockView,
                                                          kIOS15DockGlassKey);
    [glass removeFromSuperview];
    UIView *background = objc_getAssociatedObject(dockView,
                                                    kIOS15DockBackgroundKey);
    background.hidden = NO;
    objc_setAssociatedObject(dockView, kIOS15DockGlassKey,
                             nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(dockView, kIOS15DockBackgroundKey,
                             nil, OBJC_ASSOCIATION_ASSIGN);
}

static void installIOS15DockGlass(UIView *dockView) {
    if (!dockUsesIOS15DirectGlass() || !dockView.window ||
        !lgHostEnabled(@"Dock")) {
        removeIOS15DockGlass(dockView);
        return;
    }
    UIView *background = [dockView respondsToSelector:@selector(backgroundView)]
        ? [(id)dockView backgroundView] : nil;
    UIView *parent = background.superview;
    if (!background || !parent || CGRectIsEmpty(background.bounds)) return;

    UIView *previousBackground = objc_getAssociatedObject(dockView,
                                                           kIOS15DockBackgroundKey);
    if (previousBackground && previousBackground != background) {
        previousBackground.hidden = NO;
    }
    LGLiveBackdropView *glass = objc_getAssociatedObject(dockView,
                                                          kIOS15DockGlassKey);
    if (!glass) {
        glass = LGCreateRegisteredGlass(background.frame, nil, @"Dock");
        if (!glass) return;
        objc_setAssociatedObject(dockView, kIOS15DockGlassKey,
                                 glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        lgTrackGlass(glass, @"Dock", nil);
    }
    if (glass.superview != parent) {
        [glass removeFromSuperview];
        [parent insertSubview:glass aboveSubview:background];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    glass.frame = background.frame;
    glass.layer.cornerRadius = background.layer.cornerRadius;
    if (@available(iOS 13.0, *)) {
        glass.layer.cornerCurve = background.layer.cornerCurve;
    }
    glass.layer.masksToBounds = YES;
    [CATransaction commit];

    BOOL homeButtonDock = !dockIsFullScreenPhone(dockView);
    glass.lgSpecularEnabledOverride = homeButtonDock ? @NO : nil;
    dockUpdateHomeButtonBorder(glass, homeButtonDock);
    objc_setAssociatedObject(dockView, kIOS15DockBackgroundKey,
                             background, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    lgSuppressStock(background, @"Dock", YES);
}

%group LGIOS15DirectDockLifecycle

%hook SBDockView

- (void)didMoveToWindow {
    %orig;
    installIOS15DockGlass(self);
}

- (void)layoutSubviews {
    %orig;
    installIOS15DockGlass(self);
}

%end

%end

%ctor {
    LGRegisterMaterialHost(@"Dock", 80, ^BOOL(UIView *material) {
        return dockModeForMaterial(material) != LGDockModeNone;
    }, UIEdgeInsetsZero, ^CGFloat(UIView *material) {
        return dockCornerRadiusForMaterial(material);
    }, nil, ^(UIView *material, LGLiveBackdropView *glass) {
        configureDockGlass(material, glass);
    });
    if (NSClassFromString(@"SBFloatingDockPlatterView")) {
        %init(LGVerticalFloatingDockLifecycle);
    }
    if (dockUsesIOS15DirectGlass() && NSClassFromString(@"SBDockView")) {
        %init(LGIOS15DirectDockLifecycle);
    }
}
