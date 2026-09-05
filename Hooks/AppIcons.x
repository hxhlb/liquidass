#import <UIKit/UIKit.h>
#import <math.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGIOS26IconView.h"
#import <objc/runtime.h>

static void *kLGAppIconGlassKey = &kLGAppIconGlassKey;
static void *kLGAppIconOriginalImageKey = &kLGAppIconOriginalImageKey;
static void *kLGAppIconProcessedImageKey = &kLGAppIconProcessedImageKey;
static void *kLGAppIconImageLayerKey = &kLGAppIconImageLayerKey;
static void *kLGAppIconOriginalContentsKey = &kLGAppIconOriginalContentsKey;

@interface SBIconImageView : UIView
@property (nonatomic, strong) CALayer *contentsLayer;
@property (nonatomic, strong) UIImage *displayedImage;
@end

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

static CALayer *LGAppIconImageLayer(SBIconImageView *iconView) {
    CALayer *contentsLayer = [iconView respondsToSelector:@selector(contentsLayer)]
        ? iconView.contentsLayer : nil;
    return contentsLayer ?: iconView.layer;
}

static void LGRestoreAppIconImage(SBIconImageView *iconView) {
    CALayer *layer = objc_getAssociatedObject(iconView, kLGAppIconImageLayerKey);
    if (!layer) layer = LGAppIconImageLayer(iconView);
    id originalContents = objc_getAssociatedObject(iconView, kLGAppIconOriginalContentsKey);
    UIImage *processed = objc_getAssociatedObject(iconView, kLGAppIconProcessedImageKey);
    if (layer && originalContents
        && (!processed.CGImage || layer.contents == (__bridge id)processed.CGImage)) {
        layer.contents = originalContents;
    }
    objc_setAssociatedObject(iconView, kLGAppIconOriginalImageKey,
                             nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(iconView, kLGAppIconProcessedImageKey,
                             nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(iconView, kLGAppIconImageLayerKey,
                             nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(iconView, kLGAppIconOriginalContentsKey,
                             nil, OBJC_ASSOCIATION_ASSIGN);
}

static void LGApplyAppIconProcessedImage(SBIconImageView *iconView) {
    CALayer *layer = LGAppIconImageLayer(iconView);
    if (!layer) return;
    UIImage *previousProcessed = objc_getAssociatedObject(iconView,
                                                           kLGAppIconProcessedImageKey);
    UIImage *original = objc_getAssociatedObject(iconView, kLGAppIconOriginalImageKey);
    UIImage *displayed = iconView.displayedImage;
    if (displayed.CGImage
        && (!previousProcessed.CGImage || displayed.CGImage != previousProcessed.CGImage)) {
        original = displayed;
        objc_setAssociatedObject(iconView,
                                 kLGAppIconOriginalImageKey,
                                 original,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    id currentContents = layer.contents;
    if (currentContents
        && (!previousProcessed.CGImage
            || currentContents != (__bridge id)previousProcessed.CGImage)) {
        objc_setAssociatedObject(iconView,
                                 kLGAppIconOriginalContentsKey,
                                 currentContents,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!original.CGImage) return;
    UIImage *processed = LGIOS26ProcessedIconImage(original, LGIOS26IconModeClear);
    if (!processed.CGImage) return;
    objc_setAssociatedObject(iconView,
                             kLGAppIconProcessedImageKey,
                             processed,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(iconView,
                             kLGAppIconImageLayerKey,
                             layer,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    layer.contents = (__bridge id)processed.CGImage;
    layer.contentsScale = processed.scale > 0.0
        ? processed.scale : UIScreen.mainScreen.scale;
}

static void LGInstallAppIconGlass(UIView *iconView) {
    if (!LGIsAppIconImageView(iconView) || !iconView.window ||
        !lgHostEnabled(@"AppIcons")) {
        LGRestoreAppIconImage((SBIconImageView *)iconView);
        LGRemoveAppIconGlass(iconView);
        return;
    }

    UIView *parent = iconView.superview;
    if (!parent) return;
    LGApplyAppIconProcessedImage((SBIconImageView *)iconView);

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

    CGFloat radius = CGRectGetWidth(iconView.frame) * 0.225;
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

- (void)prepareForReuse {
    LGRestoreAppIconImage((SBIconImageView *)self);
    LGRemoveAppIconGlass((UIView *)self);
    %orig;
}

- (void)updateImageAnimated:(BOOL)animated {
    %orig;
    LGInstallAppIconGlass((UIView *)self);
}

- (void)updateImageContentsWithImage:(UIImage *)image
                     imageAppearance:(id)appearance
                 isRealContentsImage:(BOOL)isRealContentsImage
                            animated:(BOOL)animated {
    %orig;
    LGInstallAppIconGlass((UIView *)self);
}

%end
