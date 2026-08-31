#import <UIKit/UIKit.h>
#import <math.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import <objc/runtime.h>

extern CGFloat LGFolderIconCornerRadiusFallback(void);

static void *kLGAppIconGlassKey = &kLGAppIconGlassKey;

static BOOL LGIsAppIconImageView(UIView *view) {
    if (!view || !isExactClass(view, @"SBIconImageView")) return NO;
    CGSize size = view.bounds.size;
    if (!isfinite(size.width) || !isfinite(size.height) ||
        size.width <= 1.0 || size.height <= 1.0 ||
        fabs(size.width - size.height) > 1.0) return NO;

    UIView *parent = view.superview;
    UIView *grandparent = parent.superview;
    // App Library pods subclass SBIconView and already have their own upstream
    // surface treatment. Exact classes keep this path on Home Screen and Dock.
    return isExactClass(parent, @"SBFTouchPassThroughView") &&
           isExactClass(grandparent, @"SBIconView");
}

static void LGRemoveAppIconGlass(UIView *iconView) {
    LGLiveBackdropView *glass = objc_getAssociatedObject(iconView, kLGAppIconGlassKey);
    [glass removeFromSuperview];
    objc_setAssociatedObject(iconView, kLGAppIconGlassKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

static void LGInstallAppIconGlass(UIView *iconView) {
    if (!LGIsAppIconImageView(iconView) || !iconView.window ||
        !lgHostEnabled(@"AppIcons")) {
        LGRemoveAppIconGlass(iconView);
        return;
    }

    UIView *parent = iconView.superview;
    if (!parent) return;

    LGLiveBackdropView *glass = objc_getAssociatedObject(iconView, kLGAppIconGlassKey);
    if (!glass) {
        glass = LGCreateRegisteredGlass(iconView.frame, nil, @"AppIcons");
        if (!glass) return;
        glass.userInteractionEnabled = NO;
        glass.autoresizingMask = UIViewAutoresizingNone;
        objc_setAssociatedObject(iconView, kLGAppIconGlassKey,
                                 glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (glass.superview != parent) [glass removeFromSuperview];
    // The live backdrop must sit above the opaque icon image so it can sample
    // and refract the icon itself. As an underlay it renders but is invisible.
    [parent insertSubview:glass aboveSubview:iconView];
    glass.frame = iconView.frame;

    CGFloat folderRadius = LGFolderIconCornerRadiusFallback();
    CGFloat radius = (isfinite(folderRadius) && folderRadius > 0.0)
        ? folderRadius : iconView.layer.cornerRadius;
    if (!isfinite(radius) || radius < 0.0) radius = 0.0;
    glass.layer.cornerRadius = radius;
    if (@available(iOS 13.0, *)) glass.layer.cornerCurve = kCACornerCurveContinuous;
    glass.layer.masksToBounds = YES;
    lgTrackGlass(glass, @"AppIcons", nil);
}

%hook SBIconImageView

- (void)didMoveToWindow {
    %orig;
    LGInstallAppIconGlass((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    LGInstallAppIconGlass((UIView *)self);
}

%end
