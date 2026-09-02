#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "../Shared/LGGlassKit.h"
#import "../Shared/LGIOS26IconView.h"
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGSharedSupport.h"

typedef struct SBIconImageInfo {
    CGSize size;
    CGFloat scale;
    CGFloat continuousCornerRadius;
} SBIconImageInfo;

static void *kLGIOS26EffectViewKey = &kLGIOS26EffectViewKey;
static void *kLGIOS26OriginalContentsOpacityKey = &kLGIOS26OriginalContentsOpacityKey;
static void *kLGIOS26OriginalHostContentsKey = &kLGIOS26OriginalHostContentsKey;
static void *kLGIOS26LegacyGlassKey = &kLGIOS26LegacyGlassKey;
static void *kLGIOS26LegacyHomeEligibilityKey = &kLGIOS26LegacyHomeEligibilityKey;
static void *kLGIOS26LegacyOriginalImageKey = &kLGIOS26LegacyOriginalImageKey;
static void *kLGIOS26LegacyProcessedImageKey = &kLGIOS26LegacyProcessedImageKey;
static void *kLGIOS26FolderOriginalContentsKey = &kLGIOS26FolderOriginalContentsKey;
static void *kLGIOS26FolderProcessedImageKey = &kLGIOS26FolderProcessedImageKey;
static void *kLGIOS26FolderOriginalOpacityKey = &kLGIOS26FolderOriginalOpacityKey;
static void *kLGIOS26LibraryOriginalImageKey = &kLGIOS26LibraryOriginalImageKey;
static void *kLGIOS26LibraryProcessedImageKey = &kLGIOS26LibraryProcessedImageKey;
static void *kLGIOS26LibraryOriginalLayerStyleKey =
    &kLGIOS26LibraryOriginalLayerStyleKey;
static void *kLGIOS26StackOriginalImageKey = &kLGIOS26StackOriginalImageKey;
static void *kLGIOS26StackProcessedImageKey = &kLGIOS26StackProcessedImageKey;
static void *kLGIOS26StaticOriginalImageKey = &kLGIOS26StaticOriginalImageKey;
static void *kLGIOS26StaticSignatureKey = &kLGIOS26StaticSignatureKey;

static NSHashTable<UIView *> *sLGIOS26IconViews;
static NSHashTable<UIView *> *sLGIOS26FolderViews;
static NSHashTable<UIImageView *> *sLGIOS26StackImageViews;
static NSHashTable *sLGIOS26FolderSharedCaches;
static LGIOS26IconMode sLGIOS26Mode = LGIOS26IconModeClear;
static LGIOS26IconAlgorithm sLGIOS26Algorithm = LGIOS26IconAlgorithmAppleMitigated;
static CGFloat sLGIOS26TintHue = 0.37;
static CGFloat sLGIOS26TintIntensity = 0.78;

@interface SBIconImageView : UIView
@property (nonatomic, strong) CALayer *contentsLayer;
@property (nonatomic, strong) UIImage *displayedImage;
@property (nonatomic, readonly) CGFloat continuousCornerRadius;
@end

static BOOL LGIOS26Enabled(void) {
    return LG_globalEnabled() && LG_prefBool(@"IOS26Icons.Enabled", NO);
}

static BOOL LGIOS26UsesLegacyIconLifecycle(void) {
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 18;
}

static BOOL LGIOS26UsesLegacyClockLifecycle(void) {
    NSInteger majorVersion = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
    return majorVersion >= 15 && majorVersion < 18;
}

static BOOL LGIOS26SystemUsesDarkAppearance(void) {
    if (@available(iOS 13.0, *)) {
        UIUserInterfaceStyle style = UIScreen.mainScreen.traitCollection.userInterfaceStyle;
        if (style == UIUserInterfaceStyleUnspecified) {
            style = UITraitCollection.currentTraitCollection.userInterfaceStyle;
        }
        return style == UIUserInterfaceStyleDark;
    }
    return NO;
}

static BOOL LGIOS26UsesDarkAppearance(void) {
    return sLGIOS26Algorithm == LGIOS26IconAlgorithmAppleMitigated
        && LGIOS26SystemUsesDarkAppearance();
}

static void LGReloadIOS26Mode(void) {
    NSString *mode = LGPreferenceValue(@"IOS26Icons.Mode");
    BOOL tinted = [mode isKindOfClass:NSString.class]
        && ([mode isEqualToString:@"tinted"] || [mode isEqualToString:@"color"]);
    sLGIOS26Mode = tinted ? LGIOS26IconModeTinted : LGIOS26IconModeClear;
    NSString *algorithm = LGPreferenceValue(@"IOS26Icons.Algorithm");
    sLGIOS26Algorithm = [algorithm isKindOfClass:NSString.class]
        && [algorithm isEqualToString:@"legacy"]
        ? LGIOS26IconAlgorithmLegacy : LGIOS26IconAlgorithmAppleMitigated;
    sLGIOS26TintHue = MIN(MAX(LG_prefFloat(@"IOS26Icons.TintHue", 0.37), 0.0), 1.0);
    sLGIOS26TintIntensity = MIN(MAX(
        LG_prefFloat(@"IOS26Icons.TintIntensity", 0.78), 0.0), 1.0);
}

static NSString *LGIOS26StaticImageSignature(void) {
    NSString *algorithm = sLGIOS26Algorithm == LGIOS26IconAlgorithmLegacy
        ? @"legacy" : @"apple";
    NSString *appearance = LGIOS26UsesDarkAppearance() ? @"dark" : @"light";
    if (sLGIOS26Mode == LGIOS26IconModeTinted) {
        return [NSString stringWithFormat:@"%@-%@-tinted-%.3f-%.3f",
                algorithm, appearance, sLGIOS26TintHue, sLGIOS26TintIntensity];
    }
    return [NSString stringWithFormat:@"%@-%@-clear", algorithm, appearance];
}

static UIImage *LGIOS26StaticImageForCurrentMode(UIImage *image) {
    if (!image.CGImage) return image;
    NSString *signature = LGIOS26StaticImageSignature();
    NSString *existingSignature = objc_getAssociatedObject(image,
                                                            kLGIOS26StaticSignatureKey);
    if ([existingSignature isEqualToString:signature]) return image;

    UIImage *original = objc_getAssociatedObject(image, kLGIOS26StaticOriginalImageKey);
    if (!original.CGImage) original = image;
    UIImage *transparent = sLGIOS26Algorithm == LGIOS26IconAlgorithmAppleMitigated
        ? LGIOS26AppleMitigatedIconImage(original, LGIOS26UsesDarkAppearance())
        : LGIOS26ProcessedIconImage(original, LGIOS26IconModeClear);
    UIImage *neutral = sLGIOS26Algorithm == LGIOS26IconAlgorithmAppleMitigated
        ? transparent : LGIOS26GrayscaleIconImage(transparent);
    UIImage *processed = sLGIOS26Mode == LGIOS26IconModeTinted
        ? LGIOS26TintedIconImage(neutral,
                                 sLGIOS26TintHue,
                                 sLGIOS26TintIntensity)
        : neutral;
    if (!processed.CGImage) return image;
    objc_setAssociatedObject(processed,
                             kLGIOS26StaticOriginalImageKey,
                             original,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(processed,
                             kLGIOS26StaticSignatureKey,
                             signature,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    return processed;
}

static UIImage *LGIOS26OriginalStaticImage(UIImage *image) {
    UIImage *original = objc_getAssociatedObject(image, kLGIOS26StaticOriginalImageKey);
    return original.CGImage ? original : image;
}

static BOOL LGIsIOS26AppIconImageView(UIView *view) {
    Class iconImageViewClass = NSClassFromString(@"SBIconImageView");
    Class folderImageViewClass = NSClassFromString(@"SBFolderIconImageView");
    if (!view || !iconImageViewClass || ![view isKindOfClass:iconImageViewClass]
        || (folderImageViewClass && [view isKindOfClass:folderImageViewClass])) return NO;
    CGSize size = view.bounds.size;
    CGFloat shortest = MIN(size.width, size.height);
    CGFloat longest = MAX(size.width, size.height);
    if (!isfinite(size.width) || !isfinite(size.height)
        || shortest < 40.0 || longest > 96.0
        || fabs(size.width - size.height) > 2.0) return NO;

    Class iconViewClass = NSClassFromString(@"SBIconView");
    UIView *ancestor = view.superview;
    for (NSInteger depth = 0; ancestor && depth < 6; depth++, ancestor = ancestor.superview) {
        NSString *className = NSStringFromClass(ancestor.class);
        if ([className containsString:@"Library"] ||
            [className containsString:@"AppLibrary"]) return NO;
        if (iconViewClass && [ancestor isKindOfClass:iconViewClass]) return YES;
    }
    return NO;
}

static BOOL LGIsIOS26LibraryIconImageView(UIView *view) {
    Class iconImageViewClass = NSClassFromString(@"SBIconImageView");
    Class folderImageViewClass = NSClassFromString(@"SBFolderIconImageView");
    if (!view || !iconImageViewClass || ![view isKindOfClass:iconImageViewClass]
        || (folderImageViewClass && [view isKindOfClass:folderImageViewClass])) return NO;

    UIView *ancestor = view;
    for (NSInteger depth = 0; ancestor && depth < 10; depth++, ancestor = ancestor.superview) {
        NSString *className = NSStringFromClass(ancestor.class);
        if ([className containsString:@"Library"] ||
            [className containsString:@"AppLibrary"]) return YES;
    }
    return NO;
}

static CGFloat LGIOS26CornerRadiusForIconView(SBIconImageView *iconView) {
    if ([iconView respondsToSelector:@selector(continuousCornerRadius)]) {
        CGFloat radius = iconView.continuousCornerRadius;
        if (isfinite(radius) && radius > 0.0) return radius;
    }
    return MIN(iconView.bounds.size.width, iconView.bounds.size.height) * 0.225;
}

static BOOL LGIOS26LayerContainsCGImage(CALayer *layer);

static CALayer *LGIOS26ContentsLayer(SBIconImageView *iconView) {
    return [iconView respondsToSelector:@selector(contentsLayer)]
        ? iconView.contentsLayer : nil;
}

static void LGRestoreIOS26LibraryChicletStyle(SBIconImageView *iconView) {
    NSDictionary *style = objc_getAssociatedObject(
        iconView, kLGIOS26LibraryOriginalLayerStyleKey);
    if (!style) return;
    CALayer *layer = iconView.layer;
    id backgroundColor = style[@"backgroundColor"];
    id borderColor = style[@"borderColor"];
    layer.backgroundColor = backgroundColor == NSNull.null
        ? nil : (__bridge CGColorRef)backgroundColor;
    layer.borderColor = borderColor == NSNull.null
        ? nil : (__bridge CGColorRef)borderColor;
    layer.borderWidth = [style[@"borderWidth"] doubleValue];
    layer.cornerRadius = [style[@"cornerRadius"] doubleValue];
    layer.masksToBounds = [style[@"masksToBounds"] boolValue];
    if (@available(iOS 13.0, *)) {
        id cornerCurve = style[@"cornerCurve"];
        layer.cornerCurve = cornerCurve == NSNull.null ? nil : cornerCurve;
    }
    objc_setAssociatedObject(iconView,
                             kLGIOS26LibraryOriginalLayerStyleKey,
                             nil,
                             OBJC_ASSOCIATION_ASSIGN);
}

static void LGApplyIOS26LibraryChicletStyle(SBIconImageView *iconView) {
    if (!LGIsIOS26LibraryIconImageView(iconView)) return;
    if (!LGIOS26Enabled()) {
        LGRestoreIOS26LibraryChicletStyle(iconView);
        return;
    }
    CALayer *layer = iconView.layer;
    if (!objc_getAssociatedObject(iconView,
                                  kLGIOS26LibraryOriginalLayerStyleKey)) {
        id backgroundColor = layer.backgroundColor
            ? (__bridge id)layer.backgroundColor : NSNull.null;
        id borderColor = layer.borderColor
            ? (__bridge id)layer.borderColor : NSNull.null;
        id cornerCurve = NSNull.null;
        if (@available(iOS 13.0, *)) cornerCurve = layer.cornerCurve ?: NSNull.null;
        NSDictionary *style = @{
            @"backgroundColor": backgroundColor,
            @"borderColor": borderColor,
            @"borderWidth": @(layer.borderWidth),
            @"cornerRadius": @(layer.cornerRadius),
            @"masksToBounds": @(layer.masksToBounds),
            @"cornerCurve": cornerCurve,
        };
        objc_setAssociatedObject(iconView,
                                 kLGIOS26LibraryOriginalLayerStyleKey,
                                 style,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    UIColor *fillColor = nil;
    UIColor *edgeColor = nil;
    if (LGIOS26UsesDarkAppearance()) {
        fillColor = [UIColor colorWithWhite:0.0 alpha:0.20];
        edgeColor = [UIColor colorWithWhite:1.0 alpha:0.30];
    } else if (sLGIOS26Mode == LGIOS26IconModeTinted) {
        fillColor = [UIColor colorWithHue:sLGIOS26TintHue
                               saturation:0.52
                               brightness:0.96
                                    alpha:0.16 + 0.08 * sLGIOS26TintIntensity];
        edgeColor = [UIColor colorWithHue:sLGIOS26TintHue
                               saturation:0.28
                               brightness:1.0
                                    alpha:0.46];
    } else {
        fillColor = [UIColor colorWithWhite:1.0 alpha:0.055];
        edgeColor = [UIColor colorWithWhite:1.0 alpha:0.38];
    }
    layer.backgroundColor = fillColor.CGColor;
    layer.borderColor = edgeColor.CGColor;
    layer.borderWidth = 0.55;
    layer.cornerRadius = LGIOS26CornerRadiusForIconView(iconView);
    if (@available(iOS 13.0, *)) layer.cornerCurve = kCACornerCurveContinuous;
    layer.masksToBounds = YES;
}

static void LGClearIOS26LibraryImages(SBIconImageView *iconView) {
    LGRestoreIOS26LibraryChicletStyle(iconView);
    objc_setAssociatedObject(iconView, kLGIOS26LibraryOriginalImageKey,
                             nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(iconView, kLGIOS26LibraryProcessedImageKey,
                             nil, OBJC_ASSOCIATION_ASSIGN);
}

static UIImage *LGIOS26LibraryRenderImage(SBIconImageView *iconView, UIImage *image) {
    if (!LGIsIOS26LibraryIconImageView(iconView) || !image.CGImage) return image;

    UIImage *original = objc_getAssociatedObject(iconView, kLGIOS26LibraryOriginalImageKey);
    UIImage *previousProcessed = objc_getAssociatedObject(iconView,
                                                           kLGIOS26LibraryProcessedImageKey);
    BOOL receivedProcessedImage = previousProcessed.CGImage
        && image.CGImage == previousProcessed.CGImage;
    if (!receivedProcessedImage) {
        original = image;
        objc_setAssociatedObject(iconView,
                                 kLGIOS26LibraryOriginalImageKey,
                                 original,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (!LGIOS26Enabled()) {
        UIImage *restored = receivedProcessedImage && original ? original : image;
        LGClearIOS26LibraryImages(iconView);
        return restored;
    }

    LGApplyIOS26LibraryChicletStyle(iconView);

    if (receivedProcessedImage) return previousProcessed;
    UIImage *processed = LGIOS26StaticImageForCurrentMode(original ?: image);
    if (processed.CGImage) {
        objc_setAssociatedObject(iconView,
                                 kLGIOS26LibraryProcessedImageKey,
                                 processed,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return processed;
    }
    return image;
}

static void LGRefreshIOS26LibraryImageView(SBIconImageView *iconView) {
    if (!LGIsIOS26LibraryIconImageView(iconView) || !iconView.window) return;
    LGApplyIOS26LibraryChicletStyle(iconView);
    UIImage *original = objc_getAssociatedObject(iconView, kLGIOS26LibraryOriginalImageKey);
    UIImage *processed = objc_getAssociatedObject(iconView, kLGIOS26LibraryProcessedImageKey);
    UIImage *displayed = iconView.displayedImage;
    if (LGIOS26Enabled() && sLGIOS26Mode == LGIOS26IconModeClear
        && processed.CGImage && displayed.CGImage == processed.CGImage) return;
    if (!LGIOS26Enabled() && !processed.CGImage) return;

    UIImage *image = original ?: displayed;
    if (LGIOS26UsesLegacyIconLifecycle()) {
        UIImage *renderImage = LGIOS26LibraryRenderImage(iconView, image);
        if (renderImage.CGImage) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            iconView.layer.contents = (__bridge id)renderImage.CGImage;
            iconView.layer.contentsScale = renderImage.scale > 0.0
                ? renderImage.scale : UIScreen.mainScreen.scale;
            [CATransaction commit];
        }
        return;
    }
    SEL updateSelector = @selector(updateImageContentsWithImage:
                                     imageAppearance:
                                 isRealContentsImage:
                                            animated:);
    SEL appearanceSelector = NSSelectorFromString(@"effectiveIconImageAppearance");
    id appearance = [iconView respondsToSelector:appearanceSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(iconView, appearanceSelector) : nil;
    if (image.CGImage && [iconView respondsToSelector:updateSelector]) {
        ((void (*)(id, SEL, id, id, BOOL, BOOL))objc_msgSend)(
            iconView, updateSelector, image, appearance, YES, NO);
    }
}

static BOOL LGIsIOS26LibraryCategoryStackImageView(UIImageView *imageView) {
    if (!imageView) return NO;
    UIView *ancestor = imageView.superview;
    for (NSInteger depth = 0; ancestor && depth < 6; depth++, ancestor = ancestor.superview) {
        if ([NSStringFromClass(ancestor.class) isEqualToString:@"SBHLibraryCategoryStackView"])
            return YES;
    }
    return NO;
}

static UIImage *LGIOS26LibraryCategoryStackRenderImage(UIImageView *imageView,
                                                        UIImage *image) {
    if (!LGIsIOS26LibraryCategoryStackImageView(imageView) || !image.CGImage) return image;
    if (!sLGIOS26StackImageViews) {
        sLGIOS26StackImageViews = [NSHashTable weakObjectsHashTable];
    }
    [sLGIOS26StackImageViews addObject:imageView];

    UIImage *original = objc_getAssociatedObject(imageView, kLGIOS26StackOriginalImageKey);
    UIImage *previousProcessed = objc_getAssociatedObject(imageView,
                                                           kLGIOS26StackProcessedImageKey);
    BOOL receivedProcessedImage = previousProcessed.CGImage
        && image.CGImage == previousProcessed.CGImage;
    if (!receivedProcessedImage) {
        original = image;
        objc_setAssociatedObject(imageView,
                                 kLGIOS26StackOriginalImageKey,
                                 original,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (!LGIOS26Enabled()) {
        UIImage *restored = receivedProcessedImage && original ? original : image;
        objc_setAssociatedObject(imageView, kLGIOS26StackOriginalImageKey,
                                 nil, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(imageView, kLGIOS26StackProcessedImageKey,
                                 nil, OBJC_ASSOCIATION_ASSIGN);
        return restored;
    }

    if (receivedProcessedImage) return previousProcessed;
    UIImage *processed = LGIOS26StaticImageForCurrentMode(original ?: image);
    if (processed.CGImage) {
        objc_setAssociatedObject(imageView,
                                 kLGIOS26StackProcessedImageKey,
                                 processed,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return processed;
    }
    return image;
}

static void LGApplyIOS26LibraryCategoryStackView(UIView *view) {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:UIImageView.class]) {
            UIImageView *imageView = (UIImageView *)subview;
            UIImage *renderImage = LGIOS26LibraryCategoryStackRenderImage(imageView,
                                                                           imageView.image);
            if (renderImage && renderImage != imageView.image) imageView.image = renderImage;
        }
        LGApplyIOS26LibraryCategoryStackView(subview);
    }
}

static void LGRemoveIOS26Effect(SBIconImageView *iconView) {
    LGIOS26IconView *effectView = objc_getAssociatedObject(iconView, kLGIOS26EffectViewKey);
    [effectView removeFromSuperview];
    objc_setAssociatedObject(iconView, kLGIOS26EffectViewKey, nil, OBJC_ASSOCIATION_ASSIGN);

    NSNumber *originalOpacity = objc_getAssociatedObject(iconView,
                                                          kLGIOS26OriginalContentsOpacityKey);
    CALayer *contentsLayer = LGIOS26ContentsLayer(iconView);
    if (originalOpacity && contentsLayer) {
        contentsLayer.opacity = originalOpacity.floatValue;
    }
    objc_setAssociatedObject(iconView, kLGIOS26OriginalContentsOpacityKey,
                             nil, OBJC_ASSOCIATION_ASSIGN);

    id originalHostContents = objc_getAssociatedObject(iconView,
                                                        kLGIOS26OriginalHostContentsKey);
    if (!iconView.layer.contents && originalHostContents) {
        iconView.layer.contents = originalHostContents;
    }
    objc_setAssociatedObject(iconView, kLGIOS26OriginalHostContentsKey,
                             nil, OBJC_ASSOCIATION_ASSIGN);
}

static BOOL LGIsIOS26LegacyHomeIconImageView(UIView *view) {
    BOOL supportedClass = isExactClass(view, @"SBIconImageView")
        || (LGIOS26UsesLegacyClockLifecycle()
            && isExactClass(view, @"SBHClockApplicationIconImageView"));
    if (!view || !supportedClass) return NO;
    CGSize size = view.bounds.size;
    if (!isfinite(size.width) || !isfinite(size.height)
        || size.width <= 1.0 || size.height <= 1.0
        || fabs(size.width - size.height) > 1.0) return NO;
    if ([objc_getAssociatedObject(view, kLGIOS26LegacyHomeEligibilityKey) boolValue]) {
        return YES;
    }
    UIView *parent = view.superview;
    UIView *grandparent = parent.superview;
    BOOL eligible = isExactClass(parent, @"SBFTouchPassThroughView")
        && isExactClass(grandparent, @"SBIconView");
    if (eligible) {
        objc_setAssociatedObject(view,
                                 kLGIOS26LegacyHomeEligibilityKey,
                                 @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return eligible;
}

static UIImage *LGIOS26LegacySourceImage(SBIconImageView *iconView,
                                         UIImage *candidate) {
    if (isExactClass(iconView, @"SBHClockApplicationIconImageView")) {
        SEL selector = NSSelectorFromString(@"contentsImage");
        if ([iconView respondsToSelector:selector]) {
            UIImage *contentsImage = ((id (*)(id, SEL))objc_msgSend)(iconView, selector);
            if (contentsImage.CGImage) return contentsImage;
        }
    }
    return candidate.CGImage ? candidate : iconView.displayedImage;
}

static void LGRemoveIOS26LegacyGlass(SBIconImageView *iconView) {
    LGLiveBackdropView *glass = objc_getAssociatedObject(iconView, kLGIOS26LegacyGlassKey);
    [glass removeFromSuperview];
    objc_setAssociatedObject(iconView, kLGIOS26LegacyGlassKey,
                             nil, OBJC_ASSOCIATION_ASSIGN);

    UIImage *original = objc_getAssociatedObject(iconView, kLGIOS26LegacyOriginalImageKey);
    if (original.CGImage) {
        iconView.layer.contents = (__bridge id)original.CGImage;
        iconView.layer.contentsScale = original.scale > 0.0
            ? original.scale : UIScreen.mainScreen.scale;
    }
    objc_setAssociatedObject(iconView, kLGIOS26LegacyOriginalImageKey,
                             nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(iconView, kLGIOS26LegacyProcessedImageKey,
                             nil, OBJC_ASSOCIATION_ASSIGN);
}

static void LGApplyIOS26LegacyGlass(SBIconImageView *iconView, UIImage *image) {
    LGRemoveIOS26Effect(iconView);
    if (!LGIsIOS26LegacyHomeIconImageView(iconView)
        || !iconView.window || !LGIOS26Enabled()) {
        LGRemoveIOS26LegacyGlass(iconView);
        return;
    }

    UIImage *original = objc_getAssociatedObject(iconView, kLGIOS26LegacyOriginalImageKey);
    UIImage *previousProcessed = objc_getAssociatedObject(iconView,
                                                           kLGIOS26LegacyProcessedImageKey);
    UIImage *candidate = LGIOS26LegacySourceImage(iconView, image);
    BOOL receivedProcessed = candidate.CGImage && previousProcessed.CGImage
        && candidate.CGImage == previousProcessed.CGImage;
    BOOL receivedOriginal = candidate.CGImage && original.CGImage
        && candidate.CGImage == original.CGImage;
    if (candidate.CGImage && !receivedProcessed && !receivedOriginal) {
        original = candidate;
        objc_setAssociatedObject(iconView,
                                 kLGIOS26LegacyOriginalImageKey,
                                 original,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!original.CGImage) {
        LGRemoveIOS26LegacyGlass(iconView);
        return;
    }

    NSString *processedSignature = objc_getAssociatedObject(
        previousProcessed, kLGIOS26StaticSignatureKey);
    UIImage *processed = receivedOriginal
        && [processedSignature isEqualToString:LGIOS26StaticImageSignature()]
        ? previousProcessed : LGIOS26StaticImageForCurrentMode(original);
    if (!processed.CGImage) return;
    objc_setAssociatedObject(iconView,
                             kLGIOS26LegacyProcessedImageKey,
                             processed,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    iconView.layer.contents = (__bridge id)processed.CGImage;
    iconView.layer.contentsScale = processed.scale > 0.0
        ? processed.scale : UIScreen.mainScreen.scale;
    [CATransaction commit];

    UIView *parent = iconView.superview;
    if (!parent) return;
    LGLiveBackdropView *glass = objc_getAssociatedObject(iconView, kLGIOS26LegacyGlassKey);
    if (!glass) {
        glass = LGCreateRegisteredGlass(iconView.frame, nil, @"AppIcons");
        if (!glass) return;
        glass.userInteractionEnabled = NO;
        glass.autoresizingMask = UIViewAutoresizingNone;
        objc_setAssociatedObject(iconView,
                                 kLGIOS26LegacyGlassKey,
                                 glass,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (glass.superview != parent) [glass removeFromSuperview];
    [parent insertSubview:glass belowSubview:iconView];
    glass.frame = iconView.frame;
    CGFloat radius = LGIOS26CornerRadiusForIconView(iconView);
    glass.layer.cornerRadius = isfinite(radius) && radius > 0.0 ? radius : 0.0;
    if (@available(iOS 13.0, *)) glass.layer.cornerCurve = kCACornerCurveContinuous;
    glass.layer.masksToBounds = YES;
    glass.backgroundColor = LGIOS26UsesDarkAppearance()
        ? [UIColor colorWithWhite:0.0 alpha:0.20] : UIColor.clearColor;
    lgTrackGlass(glass, @"IOS26Icons", nil);
}

static void LGApplyIOS26Effect(SBIconImageView *iconView, UIImage *image) {
    if (!iconView) return;
    if (!sLGIOS26IconViews) sLGIOS26IconViews = [NSHashTable weakObjectsHashTable];
    [sLGIOS26IconViews addObject:iconView];

    if (LGIOS26UsesLegacyIconLifecycle()) {
        LGApplyIOS26LegacyGlass(iconView, image);
        return;
    }

    UIImage *effectiveImage = image ?: iconView.displayedImage;
    BOOL libraryIcon = LGIsIOS26LibraryIconImageView(iconView);
    if (!LGIOS26Enabled() || !iconView.window || !effectiveImage.CGImage) {
        LGRemoveIOS26Effect(iconView);
        return;
    }
    if (libraryIcon) {
        LGRemoveIOS26Effect(iconView);
        return;
    }
    if (!LGIsIOS26AppIconImageView(iconView)) {
        LGRemoveIOS26Effect(iconView);
        return;
    }

    LGIOS26IconView *effectView = objc_getAssociatedObject(iconView, kLGIOS26EffectViewKey);
    if (!effectView) {
        effectView = [[LGIOS26IconView alloc] initWithFrame:iconView.bounds];
        effectView.autoresizingMask = UIViewAutoresizingFlexibleWidth
            | UIViewAutoresizingFlexibleHeight;
        objc_setAssociatedObject(iconView, kLGIOS26EffectViewKey,
                                 effectView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [iconView insertSubview:effectView atIndex:0];
    } else if (effectView.superview != iconView) {
        [effectView removeFromSuperview];
        [iconView insertSubview:effectView atIndex:0];
    } else if (iconView.subviews.firstObject != effectView) {
        [iconView sendSubviewToBack:effectView];
    }

    effectView.frame = iconView.bounds;
    [effectView updateWithImage:effectiveImage
                   cornerRadius:LGIOS26CornerRadiusForIconView(iconView)
                            mode:sLGIOS26Mode
                       algorithm:sLGIOS26Algorithm
                  darkAppearance:LGIOS26UsesDarkAppearance()
                         tintHue:sLGIOS26TintHue
                   tintIntensity:sLGIOS26TintIntensity];

    CALayer *contentsLayer = LGIOS26ContentsLayer(iconView);
    if (contentsLayer) {
        if (!objc_getAssociatedObject(iconView, kLGIOS26OriginalContentsOpacityKey)) {
            objc_setAssociatedObject(iconView,
                                     kLGIOS26OriginalContentsOpacityKey,
                                     @(contentsLayer.opacity),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        contentsLayer.opacity = 0.0f;
    } else {
        id hostContents = iconView.layer.contents;
        if (hostContents) {
            objc_setAssociatedObject(iconView,
                                     kLGIOS26OriginalHostContentsKey,
                                     hostContents,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        iconView.layer.contents = nil;
    }
}

static BOOL LGIOS26LayerContainsCGImage(CALayer *layer) {
    id contents = layer.contents;
    if (!contents) return NO;
    return CFGetTypeID((__bridge CFTypeRef)contents) == CGImageGetTypeID();
}

static void LGRestoreIOS26FolderMiniLayer(CALayer *layer, NSInteger depth) {
    if (!layer || depth > 4) return;
    id originalContents = objc_getAssociatedObject(layer, kLGIOS26FolderOriginalContentsKey);
    if (originalContents) layer.contents = originalContents;
    NSNumber *originalOpacity = objc_getAssociatedObject(layer, kLGIOS26FolderOriginalOpacityKey);
    if (originalOpacity) layer.opacity = originalOpacity.floatValue;
    objc_setAssociatedObject(layer, kLGIOS26FolderOriginalContentsKey,
                             nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(layer, kLGIOS26FolderProcessedImageKey,
                             nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(layer, kLGIOS26FolderOriginalOpacityKey,
                             nil, OBJC_ASSOCIATION_ASSIGN);
    for (CALayer *sublayer in layer.sublayers) {
        LGRestoreIOS26FolderMiniLayer(sublayer, depth + 1);
    }
}

static void LGProcessIOS26FolderMiniLayer(CALayer *layer, NSInteger depth) {
    if (!layer || depth > 4) return;
    if (LGIOS26LayerContainsCGImage(layer)) {
        id currentContents = layer.contents;
        UIImage *previousProcessed = objc_getAssociatedObject(layer,
                                                               kLGIOS26FolderProcessedImageKey);
        if (previousProcessed && currentContents == (__bridge id)previousProcessed.CGImage) {
            for (CALayer *sublayer in layer.sublayers) {
                LGProcessIOS26FolderMiniLayer(sublayer, depth + 1);
            }
            return;
        }
        id originalContents = objc_getAssociatedObject(layer,
                                                        kLGIOS26FolderOriginalContentsKey);
        originalContents = currentContents;
        objc_setAssociatedObject(layer,
                                 kLGIOS26FolderOriginalContentsKey,
                                 originalContents,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!objc_getAssociatedObject(layer, kLGIOS26FolderOriginalOpacityKey)) {
            objc_setAssociatedObject(layer,
                                     kLGIOS26FolderOriginalOpacityKey,
                                     @(layer.opacity),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (originalContents) {
            UIImage *source = [UIImage imageWithCGImage:(__bridge CGImageRef)originalContents
                                                    scale:MAX(layer.contentsScale, 1.0)
                                              orientation:UIImageOrientationUp];
            UIImage *processed = LGIOS26StaticImageForCurrentMode(source);
            if (processed.CGImage) {
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                layer.contents = (__bridge id)processed.CGImage;
                layer.opacity = sLGIOS26Mode == LGIOS26IconModeClear ? 0.90f : 0.78f;
                [CATransaction commit];
                objc_setAssociatedObject(layer,
                                         kLGIOS26FolderProcessedImageKey,
                                         processed,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    }
    for (CALayer *sublayer in layer.sublayers) {
        LGProcessIOS26FolderMiniLayer(sublayer, depth + 1);
    }
}

static NSArray<CALayer *> *LGIOS26FolderMiniLayersForElement(id element) {
    SEL gridLayerSelector = NSSelectorFromString(@"gridLayer");
    if (![element respondsToSelector:gridLayerSelector]) return @[];
    CALayer *gridLayer = ((id (*)(id, SEL))objc_msgSend)(element, gridLayerSelector);
    return [gridLayer.sublayers isKindOfClass:NSArray.class]
        ? gridLayer.sublayers : @[];
}

static NSArray<CALayer *> *LGIOS26AllFolderMiniLayers(UIView *folderView) {
    SEL pageElementsSelector = NSSelectorFromString(@"pageElements");
    if (![folderView respondsToSelector:pageElementsSelector]) return @[];
    id pageElements = ((id (*)(id, SEL))objc_msgSend)(folderView, pageElementsSelector);
    if (![pageElements isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<CALayer *> *layers = [NSMutableArray array];
    for (id element in (NSArray *)pageElements) {
        [layers addObjectsFromArray:LGIOS26FolderMiniLayersForElement(element)];
    }
    return layers;
}

static void LGRestoreIOS26FolderView(UIView *folderView) {
    for (CALayer *layer in LGIOS26AllFolderMiniLayers(folderView)) {
        LGRestoreIOS26FolderMiniLayer(layer, 0);
    }
}

static void LGTrackIOS26FolderView(UIView *folderView) {
    if (!sLGIOS26FolderViews) sLGIOS26FolderViews = [NSHashTable weakObjectsHashTable];
    if (folderView) [sLGIOS26FolderViews addObject:folderView];
}

static void LGApplyIOS26LibraryGridAppearance(UIView *view) {
    if (!view.layer) return;
    if (!LGIOS26Enabled()) {
        LGRestoreIOS26FolderMiniLayer(view.layer, 0);
        return;
    }
    LGProcessIOS26FolderMiniLayer(view.layer, 0);
}

static void LGApplyIOS26GridCellLayer(CALayer *layer) {
    if (!layer) return;
    if (!LGIOS26Enabled()) {
        LGRestoreIOS26FolderMiniLayer(layer, 0);
        return;
    }
    LGProcessIOS26FolderMiniLayer(layer, 0);
}

static void LGSweepIOS26ViewTree(UIView *view) {
    if (!view) return;
    NSString *className = NSStringFromClass(view.class);
    Class iconImageViewClass = NSClassFromString(@"SBIconImageView");
    if (LGIOS26UsesLegacyIconLifecycle()
        && iconImageViewClass && [view isKindOfClass:iconImageViewClass]) {
        SBIconImageView *iconView = (SBIconImageView *)view;
        if (LGIsIOS26LibraryIconImageView(iconView)) {
            LGApplyIOS26Effect(iconView, iconView.displayedImage);
            LGRefreshIOS26LibraryImageView(iconView);
        } else {
            LGApplyIOS26Effect(iconView, iconView.displayedImage);
        }
    }
    if ([className isEqualToString:@"SBHLibraryAdditionalItemsIndicatorIconImageView"]) {
        LGTrackIOS26FolderView(view);
        LGApplyIOS26LibraryGridAppearance(view);
    } else if ([className isEqualToString:@"SBHLibraryCategoryStackView"]) {
        LGApplyIOS26LibraryCategoryStackView(view);
    }
    for (UIView *subview in view.subviews) {
        LGSweepIOS26ViewTree(subview);
    }
}

static void LGSweepAllIOS26Views(void) {
    UIApplication *application = UIApplication.sharedApplication;
    for (UIWindow *window in application.windows) {
        LGSweepIOS26ViewTree(window);
    }
}

static NSUInteger sLGIOS26SweepGeneration;

static void LGScheduleIOS26ViewSweep(void) {
    if (!LGIOS26UsesLegacyIconLifecycle()) return;
    NSUInteger generation = ++sLGIOS26SweepGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != sLGIOS26SweepGeneration) return;
        LGSweepAllIOS26Views();
    });
}

static void LGRebuildIOS26LegacyFolderCache(UIView *folderView) {
    if (!LGIOS26UsesLegacyIconLifecycle() || !folderView) return;
    SEL cacheSelector = NSSelectorFromString(@"_folderIconImageCache");
    SEL iconSelector = NSSelectorFromString(@"_folderIcon");
    if (![folderView respondsToSelector:cacheSelector]
        || ![folderView respondsToSelector:iconSelector]) return;
    id cache = ((id (*)(id, SEL))objc_msgSend)(folderView, cacheSelector);
    id folderIcon = ((id (*)(id, SEL))objc_msgSend)(folderView, iconSelector);
    SEL rebuildSelector = NSSelectorFromString(@"rebuildImagesForFolderIcon:");
    if (cache && folderIcon && [cache respondsToSelector:rebuildSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(cache, rebuildSelector, folderIcon);
    }
}

static void LGRefreshAllIOS26Icons(void) {
    NSArray<UIView *> *folderViews = sLGIOS26FolderViews.allObjects;
    for (UIView *folderView in folderViews) LGRestoreIOS26FolderView(folderView);
    LGReloadIOS26Mode();
    for (SBIconImageView *iconView in sLGIOS26IconViews.allObjects) {
        if (LGIsIOS26LibraryIconImageView(iconView)) {
            if (LGIOS26UsesLegacyIconLifecycle()) {
                LGApplyIOS26Effect(iconView, iconView.displayedImage);
            }
            LGRefreshIOS26LibraryImageView(iconView);
            continue;
        }
        LGApplyIOS26Effect(iconView, iconView.displayedImage);
    }
    for (UIImageView *imageView in sLGIOS26StackImageViews.allObjects) {
        UIImage *original = objc_getAssociatedObject(imageView, kLGIOS26StackOriginalImageKey);
        UIImage *renderImage = LGIOS26LibraryCategoryStackRenderImage(
            imageView, original ?: imageView.image);
        if (renderImage && renderImage != imageView.image) imageView.image = renderImage;
    }
    for (id sharedCache in sLGIOS26FolderSharedCaches.allObjects) {
        SEL purge = NSSelectorFromString(@"purgeAllCachedFolderImages");
        if ([sharedCache respondsToSelector:purge]) {
            ((void (*)(id, SEL))objc_msgSend)(sharedCache, purge);
        }
    }
    for (UIView *folderView in folderViews) {
        LGRebuildIOS26LegacyFolderCache(folderView);
        SEL update = NSSelectorFromString(@"updateImageAnimated:");
        if ([folderView respondsToSelector:update]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(folderView, update, NO);
        }
    }
}

static NSUInteger sLGIOS26AppearanceRefreshGeneration;

static void LGScheduleIOS26AppearanceRefresh(void) {
    NSUInteger generation = ++sLGIOS26AppearanceRefreshGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != sLGIOS26AppearanceRefreshGeneration) return;
        LGRefreshAllIOS26Icons();
        LGSweepAllIOS26Views();
    });
}

%hook SBIconImageView

- (void)updateImageContentsWithImage:(UIImage *)image
                     imageAppearance:(id)appearance
                 isRealContentsImage:(BOOL)isRealContentsImage
                            animated:(BOOL)animated {
    UIImage *renderImage = LGIOS26LibraryRenderImage(self, image);
    %orig(renderImage, appearance, isRealContentsImage, animated);
    LGApplyIOS26Effect(self, renderImage);
}

- (void)didMoveToWindow {
    %orig;
    if (LGIOS26UsesLegacyIconLifecycle()) {
        LGApplyIOS26Effect(self, self.displayedImage);
        LGRefreshIOS26LibraryImageView(self);
    } else {
        LGRefreshIOS26LibraryImageView(self);
        LGApplyIOS26Effect(self, self.displayedImage);
    }
}

- (void)didMoveToSuperview {
    %orig;
    if (LGIOS26UsesLegacyIconLifecycle()) {
        LGApplyIOS26Effect(self, self.displayedImage);
        LGRefreshIOS26LibraryImageView(self);
    }
}

- (void)layoutSubviews {
    %orig;
    LGApplyIOS26LibraryChicletStyle(self);
    LGApplyIOS26Effect(self, self.displayedImage);
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    %orig(previousTraitCollection);
    if (@available(iOS 13.0, *)) {
        if ([self.traitCollection
                hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
            LGScheduleIOS26AppearanceRefresh();
        }
    }
}

- (void)prepareForReuse {
    if (LGIOS26UsesLegacyIconLifecycle()) {
        LGRemoveIOS26LegacyGlass(self);
    }
    LGClearIOS26LibraryImages(self);
    objc_setAssociatedObject(self,
                             kLGIOS26LegacyHomeEligibilityKey,
                             nil,
                             OBJC_ASSOCIATION_ASSIGN);
    %orig;
    LGRemoveIOS26Effect(self);
    if (LGIOS26UsesLegacyIconLifecycle() && self.window) {
        LGApplyIOS26Effect(self, self.displayedImage);
        LGRefreshIOS26LibraryImageView(self);
    }
}

%end

%group LGIOS26LegacyClockImagesLifecycle

%hook SBHClockApplicationIconImageView

- (void)updateClockImages {
    %orig;
    LGApplyIOS26LegacyGlass((SBIconImageView *)self, nil);
}

%end

%end


%group LGIOS26LegacyClockUnanimatedLifecycle

%hook SBHClockApplicationIconImageView

- (void)updateUnanimated {
    %orig;
    LGApplyIOS26LegacyGlass((SBIconImageView *)self, nil);
}

%end

%end


%group LGIOS26LegacyClockComponentsLifecycle

%hook SBHClockApplicationIconImageView

- (void)_updateUnanimatedWithComponents:(id)components {
    %orig(components);
    LGApplyIOS26LegacyGlass((SBIconImageView *)self, nil);
}

%end

%end


%group LGIOS26LegacyClockLayoutLifecycle

%hook SBHClockApplicationIconImageView

- (void)layoutSubviews {
    %orig;
    LGApplyIOS26LegacyGlass((SBIconImageView *)self, nil);
}

%end

%end

%group LGIOS26LegacyLifecycle

%hook SBIconImageView

- (void)setIcon:(id)icon location:(id)location animated:(BOOL)animated {
    %orig(icon, location, LGIOS26Enabled() ? NO : animated);
    LGApplyIOS26Effect(self, self.displayedImage);
    LGRefreshIOS26LibraryImageView(self);
}

- (void)updateImageAnimated:(BOOL)animated {
    %orig(LGIOS26Enabled() ? NO : animated);
    LGApplyIOS26Effect(self, self.displayedImage);
    LGRefreshIOS26LibraryImageView(self);
}

- (void)iconImageCache:(id)cache didUpdateImageForIcon:(id)icon {
    %orig;
    LGApplyIOS26Effect(self, self.displayedImage);
    LGRefreshIOS26LibraryImageView(self);
}

- (void)iconImageDidUpdate:(id)icon {
    %orig;
    LGApplyIOS26Effect(self, self.displayedImage);
    LGRefreshIOS26LibraryImageView(self);
}

%end

%hook SBFolderIconImageSharedCache

- (UIImage *)gridCellImageForIcon:(id)icon {
    if (!sLGIOS26FolderSharedCaches) {
        sLGIOS26FolderSharedCaches = [NSHashTable weakObjectsHashTable];
    }
    [sLGIOS26FolderSharedCaches addObject:self];
    UIImage *image = %orig;
    return LGIOS26Enabled()
        ? LGIOS26StaticImageForCurrentMode(image)
        : LGIOS26OriginalStaticImage(image);
}

%end

%hook SBFolderIconImageCache

- (UIImage *)gridCellImageForIcon:(id)icon {
    UIImage *image = %orig;
    return LGIOS26Enabled()
        ? LGIOS26StaticImageForCurrentMode(image)
        : LGIOS26OriginalStaticImage(image);
}

%end

%hook SBIconScrollView

- (void)setContentOffset:(CGPoint)contentOffset {
    %orig;
    LGScheduleIOS26ViewSweep();
}

%end

%end

%group LGIOS26LegacyFolderCellImageLifecycle

%hook SBFolderIconImageCache

+ (UIImage *)gridCellImageOfSize:(CGSize)size forIconImage:(UIImage *)iconImage {
    UIImage *cellImage = %orig(size, iconImage);
    return LGIOS26Enabled()
        ? LGIOS26StaticImageForCurrentMode(cellImage)
        : LGIOS26OriginalStaticImage(cellImage);
}

%end

%end

%group LGIOS26LegacyFolderCellImageInfoClassLifecycle

%hook SBFolderIconImageCache

+ (UIImage *)gridCellImageOfSize:(CGSize)size
                         forIcon:(id)icon
                   iconImageInfo:(SBIconImageInfo)iconImageInfo {
    UIImage *cellImage = %orig(size, icon, iconImageInfo);
    return LGIOS26Enabled()
        ? LGIOS26StaticImageForCurrentMode(cellImage)
        : LGIOS26OriginalStaticImage(cellImage);
}

%end

%end

%group LGIOS26LegacyFolderCellImageInfoInstanceLifecycle

%hook SBFolderIconImageCache

- (UIImage *)gridCellImageOfSize:(CGSize)size
                         forIcon:(id)icon
                   iconImageInfo:(SBIconImageInfo)iconImageInfo {
    UIImage *cellImage = %orig(size, icon, iconImageInfo);
    return LGIOS26Enabled()
        ? LGIOS26StaticImageForCurrentMode(cellImage)
        : LGIOS26OriginalStaticImage(cellImage);
}

%end

%end

%hook SBHLibraryAdditionalItemsIndicatorIconImageView

- (void)updateImageContentsWithImage:(UIImage *)image
                     imageAppearance:(id)appearance
                 isRealContentsImage:(BOOL)isRealContentsImage
                            animated:(BOOL)animated {
    UIImage *renderImage = LGIOS26LibraryRenderImage((SBIconImageView *)self, image);
    %orig(renderImage, appearance, isRealContentsImage, animated);
    LGApplyIOS26Effect((SBIconImageView *)self, renderImage);
}

- (void)didMoveToWindow {
    %orig;
    LGRefreshIOS26LibraryImageView((SBIconImageView *)self);
    LGApplyIOS26Effect((SBIconImageView *)self,
                       ((SBIconImageView *)self).displayedImage);
    LGTrackIOS26FolderView((UIView *)self);
    LGApplyIOS26LibraryGridAppearance((UIView *)self);
}

- (void)fulfillGridLayerForPageElement:(id)element {
    %orig;
    LGTrackIOS26FolderView((UIView *)self);
    LGApplyIOS26LibraryGridAppearance((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    LGApplyIOS26LibraryGridAppearance((UIView *)self);
}

- (void)prepareForReuse {
    LGRestoreIOS26FolderMiniLayer(((UIView *)self).layer, 0);
    LGClearIOS26LibraryImages((SBIconImageView *)self);
    %orig;
}

%end

%hook SBHLibraryCategoryStackView

- (void)layoutSubviews {
    %orig;
    LGApplyIOS26LibraryCategoryStackView((UIView *)self);
}

- (void)setInnerIcons:(id)icons animated:(BOOL)animated {
    %orig;
    LGApplyIOS26LibraryCategoryStackView((UIView *)self);
}

- (void)_updateIconImageViewsAnimated:(BOOL)animated {
    %orig;
    LGApplyIOS26LibraryCategoryStackView((UIView *)self);
}

- (void)_updateIconImageViewAtIndex:(NSUInteger)index animated:(BOOL)animated {
    %orig;
    LGApplyIOS26LibraryCategoryStackView((UIView *)self);
}

- (void)iconImageCache:(id)cache
  didUpdateImageForIcon:(id)icon
        imageAppearance:(id)appearance {
    %orig;
    LGApplyIOS26LibraryCategoryStackView((UIView *)self);
}

%end

%hook SBHIconGridLayer

- (void)setLayer:(CALayer *)layer forIcon:(id)icon {
    %orig;
    LGApplyIOS26GridCellLayer(layer);
}

- (void)replaceLayerForIcon:(id)icon withLayer:(CALayer *)layer {
    %orig;
    LGApplyIOS26GridCellLayer(layer);
}

%end

%hook SBFolderIconImageView

- (void)fulfillGridImageForPageElement:(id)element {
    %orig;
    LGTrackIOS26FolderView((UIView *)self);
}

- (void)fulfillGridLayerForPageElement:(id)element {
    %orig;
    LGTrackIOS26FolderView((UIView *)self);
    if (!LGIOS26Enabled()) {
        LGRestoreIOS26FolderView((UIView *)self);
        return;
    }
    for (CALayer *layer in LGIOS26FolderMiniLayersForElement(element)) {
        LGProcessIOS26FolderMiniLayer(layer, 0);
    }
}

- (void)prepareForReuse {
    LGRestoreIOS26FolderView((UIView *)self);
    %orig;
}

%end

%hook SBFolderIconImageSharedCache

- (UIImage *)gridCellImageForIcon:(id)icon
                  imageAppearance:(id)appearance
                   imageAttributes:(NSUInteger *)imageAttributes {
    if (!sLGIOS26FolderSharedCaches) {
        sLGIOS26FolderSharedCaches = [NSHashTable weakObjectsHashTable];
    }
    [sLGIOS26FolderSharedCaches addObject:self];
    UIImage *image = %orig;
    if (!LGIOS26Enabled()) return LGIOS26OriginalStaticImage(image);
    return LGIOS26StaticImageForCurrentMode(image);
}

%end

%ctor {
    %init;
    LGReloadIOS26Mode();
    if (LGIOS26UsesLegacyIconLifecycle()) {
        %init(LGIOS26LegacyLifecycle);
    }
    if (LGIOS26UsesLegacyClockLifecycle()) {
        Class clockImageViewClass = NSClassFromString(@"SBHClockApplicationIconImageView");
        if (class_getInstanceMethod(clockImageViewClass,
                                    NSSelectorFromString(@"updateClockImages"))) {
            %init(LGIOS26LegacyClockImagesLifecycle);
        }
        if (class_getInstanceMethod(clockImageViewClass,
                                    NSSelectorFromString(@"updateUnanimated"))) {
            %init(LGIOS26LegacyClockUnanimatedLifecycle);
        }
        if (class_getInstanceMethod(
                clockImageViewClass,
                NSSelectorFromString(@"_updateUnanimatedWithComponents:"))) {
            %init(LGIOS26LegacyClockComponentsLifecycle);
        }
        if (class_getInstanceMethod(clockImageViewClass,
                                    @selector(layoutSubviews))) {
            %init(LGIOS26LegacyClockLayoutLifecycle);
        }
    }
    if (LGIOS26UsesLegacyIconLifecycle()) {
        Class folderImageCacheClass = NSClassFromString(@"SBFolderIconImageCache");
        if (class_getClassMethod(
                folderImageCacheClass,
                NSSelectorFromString(@"gridCellImageOfSize:forIconImage:"))) {
            %init(LGIOS26LegacyFolderCellImageLifecycle);
        }
        if (class_getClassMethod(
                folderImageCacheClass,
                NSSelectorFromString(@"gridCellImageOfSize:forIcon:iconImageInfo:"))) {
            %init(LGIOS26LegacyFolderCellImageInfoClassLifecycle);
        }
        if (class_getInstanceMethod(
                folderImageCacheClass,
                NSSelectorFromString(@"gridCellImageOfSize:forIcon:iconImageInfo:"))) {
            %init(LGIOS26LegacyFolderCellImageInfoInstanceLifecycle);
        }
    }
    if (NSClassFromString(@"SBIconImageView")) {
        dispatch_async(dispatch_get_main_queue(), ^{
            LGSweepAllIOS26Views();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (LGIOS26UsesLegacyIconLifecycle()) {
                    LGRefreshAllIOS26Icons();
                } else {
                    LGSweepAllIOS26Views();
                }
            });
        });
    }
    lgObservePreferenceReload(^{
        LGRefreshAllIOS26Icons();
    });
}
