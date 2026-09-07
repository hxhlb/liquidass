#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
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
static void *kLGIOS26FolderMiniOriginalImageKey =
    &kLGIOS26FolderMiniOriginalImageKey;
static void *kLGIOS26FolderMiniProcessedImageKey =
    &kLGIOS26FolderMiniProcessedImageKey;
static void *kLGIOS26FolderMiniSignatureKey =
    &kLGIOS26FolderMiniSignatureKey;
static void *kLGIOS26LibraryOriginalImageKey = &kLGIOS26LibraryOriginalImageKey;
static void *kLGIOS26LibraryProcessedImageKey = &kLGIOS26LibraryProcessedImageKey;
static void *kLGIOS26LibraryOriginalLayerStyleKey =
    &kLGIOS26LibraryOriginalLayerStyleKey;
static void *kLGIOS26LibraryOriginalContentsOpacityKey =
    &kLGIOS26LibraryOriginalContentsOpacityKey;
static void *kLGIOS26LibraryRimLayerKey =
    &kLGIOS26LibraryRimLayerKey;
static void *kLGIOS26LibraryGlassKey =
    &kLGIOS26LibraryGlassKey;
static void *kLGIOS26LibraryOriginalHostContentsKey =
    &kLGIOS26LibraryOriginalHostContentsKey;
static void *kLGIOS26StackOriginalImageKey = &kLGIOS26StackOriginalImageKey;
static void *kLGIOS26StackProcessedImageKey = &kLGIOS26StackProcessedImageKey;
static void *kLGIOS26StaticOriginalImageKey = &kLGIOS26StaticOriginalImageKey;
static void *kLGIOS26StaticSignatureKey = &kLGIOS26StaticSignatureKey;
static void *kLGIOS26ProviderOriginalCGImageKey =
    &kLGIOS26ProviderOriginalCGImageKey;
static void *kLGIOS26ProviderProcessedImageKey =
    &kLGIOS26ProviderProcessedImageKey;
static void *kLGIOS26ProviderSignatureKey =
    &kLGIOS26ProviderSignatureKey;

static NSHashTable<UIView *> *sLGIOS26IconViews;
static NSHashTable<UIView *> *sLGIOS26FolderViews;
static NSHashTable<UIImageView *> *sLGIOS26StackImageViews;
static NSHashTable *sLGIOS26FolderSharedCaches;
static NSHashTable<UIView *> *sLGIOS26DockLibraryCards;
static char kLGIOS26DockLibraryCardKey;
static char kLGIOS26CrossfadeCardKey;
static LGIOS26IconMode sLGIOS26Mode = LGIOS26IconModeClear;
static LGIOS26IconAlgorithm sLGIOS26Algorithm = LGIOS26IconAlgorithmAppleMitigated;
static CGFloat sLGIOS26TintHue = 0.37;
static CGFloat sLGIOS26TintIntensity = 0.78;
static BOOL sLGIOS26PreservesSubjectColor;
static BOOL sLGIOS26ProviderPipelineActive;
static BOOL sLGIOS26GlobalProviderEnabled;
static NSCache<NSValue *, NSDictionary<NSString *, id> *> *
    sLGIOS26ProviderImageRegistry;

@interface SBIconImageView : UIView
@property (nonatomic, strong) CALayer *contentsLayer;
@property (nonatomic, strong) UIImage *displayedImage;
@property (nonatomic, readonly) CGFloat continuousCornerRadius;
@end

@interface LGIOS26DockLibraryCardState : NSObject
@property (nonatomic, strong) LGLiveBackdropView *glass;
@property (nonatomic, strong) CAGradientLayer *rim;
@property (nonatomic, weak) UIView *material;
@property (nonatomic, weak) UIView *tint;
@property (nonatomic) BOOL materialHidden;
@property (nonatomic) BOOL tintHidden;
@end

@implementation LGIOS26DockLibraryCardState
@end

@interface LGIOS26CrossfadeCardState : NSObject
@property (nonatomic, weak) UIView *material;
@property (nonatomic, weak) UIView *tint;
@property (nonatomic) BOOL materialHidden;
@property (nonatomic) BOOL tintHidden;
@end

@implementation LGIOS26CrossfadeCardState
@end

static BOOL LGIOS26Enabled(void) {
    return LG_globalEnabled() && LG_prefBool(@"IOS26Icons.Enabled", NO);
}

static BOOL LGIOS26ProviderProcessingEnabled(void) {
    return sLGIOS26ProviderPipelineActive
        && sLGIOS26GlobalProviderEnabled;
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
    NSString *subjectStyle = LGPreferenceValue(@"IOS26Icons.SubjectStyle");
    sLGIOS26PreservesSubjectColor = [subjectStyle isKindOfClass:NSString.class]
        && [subjectStyle isEqualToString:@"fresh"];
    sLGIOS26GlobalProviderEnabled = LG_prefBool(
        @"IOS26Icons.GlobalProvider.Enabled", NO);
}

static NSString *LGIOS26StaticImageSignature(void) {
    NSString *algorithm = sLGIOS26Algorithm == LGIOS26IconAlgorithmLegacy
        ? @"legacy" : @"apple";
    NSString *appearance = LGIOS26UsesDarkAppearance() ? @"dark" : @"light";
    NSString *subjectStyle = sLGIOS26PreservesSubjectColor ? @"fresh" : @"soft";
    if (sLGIOS26Mode == LGIOS26IconModeTinted) {
        return [NSString stringWithFormat:@"%@-%@-%@-tinted-%.3f-%.3f",
                algorithm, appearance, subjectStyle,
                sLGIOS26TintHue, sLGIOS26TintIntensity];
    }
    return [NSString stringWithFormat:@"%@-%@-%@-clear",
            algorithm, appearance, subjectStyle];
}

static NSCache<NSValue *, NSDictionary<NSString *, id> *> *
LGIOS26ProviderImageRegistry(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sLGIOS26ProviderImageRegistry = [NSCache new];
        sLGIOS26ProviderImageRegistry.countLimit = 512;
        sLGIOS26ProviderImageRegistry.totalCostLimit = 24 * 1024 * 1024;
    });
    return sLGIOS26ProviderImageRegistry;
}

static UIImage *LGIOS26ProviderOriginalImageForImage(UIImage *image) {
    if (!image.CGImage) return nil;
    NSDictionary<NSString *, id> *entry = [LGIOS26ProviderImageRegistry()
        objectForKey:[NSValue valueWithPointer:image.CGImage]];
    UIImage *processed = entry[@"processed"];
    return processed.CGImage == image.CGImage ? entry[@"original"] : nil;
}

static UIImage *LGIOS26CachedProviderImage(UIImage *original,
                                           NSString *signature) {
    if (!original.CGImage || !signature.length) return nil;
    NSDictionary<NSString *, id> *entry = [LGIOS26ProviderImageRegistry()
        objectForKey:[NSValue valueWithPointer:original.CGImage]];
    UIImage *cachedOriginal = entry[@"original"];
    UIImage *processed = entry[@"processed"];
    return cachedOriginal.CGImage == original.CGImage
        && processed.CGImage
        && [entry[@"signature"] isEqualToString:signature]
        ? processed : nil;
}

static void LGIOS26RegisterProviderImage(UIImage *original,
                                         UIImage *processed,
                                         NSString *signature) {
    if (!original.CGImage || !processed.CGImage
        || original.CGImage == processed.CGImage) return;
    NSUInteger cost = CGImageGetBytesPerRow(processed.CGImage)
        * CGImageGetHeight(processed.CGImage);
    NSDictionary<NSString *, id> *entry = @{
        @"original": original,
        @"processed": processed,
        @"signature": signature ?: @"",
    };
    [LGIOS26ProviderImageRegistry()
        setObject:entry
           forKey:[NSValue valueWithPointer:original.CGImage]
             cost:cost];
    [LGIOS26ProviderImageRegistry()
        setObject:entry
           forKey:[NSValue valueWithPointer:processed.CGImage]];
}

static UIImage *LGIOS26StaticImageForCurrentMode(UIImage *image) {
    if (!image.CGImage) return image;
    if (LGIOS26ProviderOriginalImageForImage(image)) return image;
    NSString *signature = LGIOS26StaticImageSignature();
    NSString *existingSignature = objc_getAssociatedObject(image,
                                                            kLGIOS26StaticSignatureKey);
    if ([existingSignature isEqualToString:signature]) return image;

    UIImage *original = objc_getAssociatedObject(image, kLGIOS26StaticOriginalImageKey);
    if (!original.CGImage) original = image;
    UIImage *transparent = sLGIOS26Algorithm == LGIOS26IconAlgorithmAppleMitigated
        ? LGIOS26AppleMitigatedIconImage(original,
                                         LGIOS26UsesDarkAppearance(),
                                         sLGIOS26PreservesSubjectColor)
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
    UIImage *providerOriginal = LGIOS26ProviderOriginalImageForImage(image);
    if (providerOriginal.CGImage) return providerOriginal;
    UIImage *original = objc_getAssociatedObject(image, kLGIOS26StaticOriginalImageKey);
    return original.CGImage ? original : image;
}

static UIImage *LGIOS26FolderMiniFinishedImage(UIImage *image) {
    if (!image.CGImage || !LGIOS26Enabled()
        || !LGIOS26ProviderProcessingEnabled()
        || sLGIOS26Mode != LGIOS26IconModeClear) return image;

    UIImage *original = objc_getAssociatedObject(
        image, kLGIOS26FolderMiniOriginalImageKey);
    if (original.CGImage) image = original;
    NSString *signature = [LGIOS26StaticImageSignature()
        stringByAppendingString:@"-folder-mini-edge-v1"];
    UIImage *cached = objc_getAssociatedObject(
        image, kLGIOS26FolderMiniProcessedImageKey);
    NSString *cachedSignature = objc_getAssociatedObject(
        image, kLGIOS26FolderMiniSignatureKey);
    if (cached.CGImage && [cachedSignature isEqualToString:signature]) {
        return cached;
    }

    CGSize size = image.size;
    if (!isfinite(size.width) || !isfinite(size.height)
        || size.width <= 0.0 || size.height <= 0.0) return image;
    CGFloat scale = image.scale > 0.0 ? image.scale : UIScreen.mainScreen.scale;
    CGFloat pixel = 1.0 / MAX(scale, 1.0);
    CGRect bounds = (CGRect){CGPointZero, size};
    CGFloat radius = MIN(size.width, size.height) * 0.225;

    UIGraphicsBeginImageContextWithOptions(size, NO, scale);
    [image drawInRect:bounds];

    BOOL darkAppearance = LGIOS26UsesDarkAppearance();
    UIColor *outerColor = darkAppearance
        ? [UIColor colorWithWhite:1.0 alpha:0.46]
        : [UIColor colorWithWhite:0.0 alpha:0.16];
    UIColor *innerColor = darkAppearance
        ? [UIColor colorWithWhite:0.0 alpha:0.14]
        : [UIColor colorWithWhite:1.0 alpha:0.38];
    UIBezierPath *outer = [UIBezierPath bezierPathWithRoundedRect:
        CGRectInset(bounds, pixel * 0.5, pixel * 0.5)
                                                          cornerRadius:radius];
    outer.lineWidth = pixel;
    [outerColor setStroke];
    [outer stroke];

    UIBezierPath *inner = [UIBezierPath bezierPathWithRoundedRect:
        CGRectInset(bounds, pixel * 1.5, pixel * 1.5)
                                                          cornerRadius:MAX(0.0, radius - pixel)];
    inner.lineWidth = pixel;
    [innerColor setStroke];
    [inner stroke];

    UIImage *processed = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (!processed.CGImage) return image;
    objc_setAssociatedObject(image,
                             kLGIOS26FolderMiniProcessedImageKey,
                             processed,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(image,
                             kLGIOS26FolderMiniSignatureKey,
                             signature,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(processed,
                             kLGIOS26FolderMiniOriginalImageKey,
                             image,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(processed,
                             kLGIOS26FolderMiniSignatureKey,
                             signature,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    return processed;
}

static CGFloat LGIOS26ProviderScale(id imageObject) {
    SEL selector = NSSelectorFromString(@"scale");
    if (![imageObject respondsToSelector:selector]) return 1.0;
    CGFloat scale = ((CGFloat (*)(id, SEL))objc_msgSend)(imageObject, selector);
    return isfinite(scale) && scale > 0.0 ? scale : 1.0;
}

static CGSize LGIOS26ProviderSize(id imageObject, CGImageRef image) {
    for (NSString *selectorName in @[@"iconSize", @"size"]) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![imageObject respondsToSelector:selector]) continue;
        CGSize size = ((CGSize (*)(id, SEL))objc_msgSend)(imageObject, selector);
        if (isfinite(size.width) && isfinite(size.height)
            && size.width > 0.0 && size.height > 0.0) return size;
    }
    CGFloat scale = LGIOS26ProviderScale(imageObject);
    return CGSizeMake(CGImageGetWidth(image) / scale,
                      CGImageGetHeight(image) / scale);
}

static BOOL LGIOS26ProviderImageIsEligible(id imageObject, CGImageRef image) {
    if (!imageObject || !image || !LGIOS26Enabled()
        || !LGIOS26ProviderProcessingEnabled()) return NO;
    SEL placeholderSelector = NSSelectorFromString(@"placeholder");
    if ([imageObject respondsToSelector:placeholderSelector]
        && ((BOOL (*)(id, SEL))objc_msgSend)(imageObject, placeholderSelector)) {
        return NO;
    }
    CGSize size = LGIOS26ProviderSize(imageObject, image);
    CGFloat shortest = MIN(size.width, size.height);
    CGFloat longest = MAX(size.width, size.height);
    return shortest >= 12.0 && longest <= 256.0
        && fabs(size.width - size.height) <= MAX(2.0, shortest * 0.08);
}

static CGImageRef LGIOS26ProviderProcessedCGImage(id imageObject,
                                                  CGImageRef original) {
    if (!LGIOS26ProviderImageIsEligible(imageObject, original)) return original;
    NSString *signature = LGIOS26StaticImageSignature();
    id cachedOriginal = objc_getAssociatedObject(
        imageObject, kLGIOS26ProviderOriginalCGImageKey);
    UIImage *cachedProcessed = objc_getAssociatedObject(
        imageObject, kLGIOS26ProviderProcessedImageKey);
    NSString *cachedSignature = objc_getAssociatedObject(
        imageObject, kLGIOS26ProviderSignatureKey);
    if ((__bridge CGImageRef)cachedOriginal == original
        && cachedProcessed.CGImage
        && [cachedSignature isEqualToString:signature]) {
        // The provider retains this result longer than the shared NSCache may.
        // Restore its provenance before a consumer can process it a second time.
        if (!LGIOS26ProviderOriginalImageForImage(cachedProcessed).CGImage) {
            UIImage *source = [UIImage imageWithCGImage:original
                scale:LGIOS26ProviderScale(imageObject) orientation:UIImageOrientationUp];
            LGIOS26RegisterProviderImage(source, cachedProcessed, signature);
        }
        return cachedProcessed.CGImage;
    }

    CGFloat scale = LGIOS26ProviderScale(imageObject);
    UIImage *source = [UIImage imageWithCGImage:original
                                          scale:scale
                                    orientation:UIImageOrientationUp];
    UIImage *processed = LGIOS26CachedProviderImage(source, signature);
    if (!processed.CGImage) {
        processed = LGIOS26StaticImageForCurrentMode(source);
    }
    if (!processed.CGImage) return original;
    objc_setAssociatedObject(imageObject,
                             kLGIOS26ProviderOriginalCGImageKey,
                             (__bridge id)original,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(imageObject,
                             kLGIOS26ProviderProcessedImageKey,
                             processed,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(imageObject,
                             kLGIOS26ProviderSignatureKey,
                             signature,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    LGIOS26RegisterProviderImage(source, processed, signature);
    return processed.CGImage;
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
    CALayer *layer = iconView.layer;
    if (style) {
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
    }
    CALayer *contentsLayer = LGIOS26ContentsLayer(iconView);
    NSNumber *originalContentsOpacity = objc_getAssociatedObject(
        iconView, kLGIOS26LibraryOriginalContentsOpacityKey);
    if (contentsLayer && originalContentsOpacity) {
        contentsLayer.opacity = originalContentsOpacity.floatValue;
    }
    CAGradientLayer *rimLayer = objc_getAssociatedObject(
        iconView, kLGIOS26LibraryRimLayerKey);
    [rimLayer removeFromSuperlayer];
    LGLiveBackdropView *glass = objc_getAssociatedObject(
        iconView, kLGIOS26LibraryGlassKey);
    [glass removeFromSuperview];
    id originalHostContents = objc_getAssociatedObject(
        iconView, kLGIOS26LibraryOriginalHostContentsKey);
    if (originalHostContents) layer.contents = originalHostContents;
    objc_setAssociatedObject(iconView,
                             kLGIOS26LibraryOriginalContentsOpacityKey,
                             nil,
                             OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(iconView,
                             kLGIOS26LibraryRimLayerKey,
                             nil,
                             OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(iconView,
                             kLGIOS26LibraryGlassKey,
                             nil,
                             OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(iconView,
                             kLGIOS26LibraryOriginalHostContentsKey,
                             nil,
                             OBJC_ASSOCIATION_ASSIGN);
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
    if (sLGIOS26Mode == LGIOS26IconModeTinted) {
        fillColor = [UIColor colorWithHue:sLGIOS26TintHue
                               saturation:0.52
                               brightness:0.96
                                    alpha:0.16 + 0.08 * sLGIOS26TintIntensity];
        edgeColor = [UIColor colorWithHue:sLGIOS26TintHue
                               saturation:0.28
                               brightness:1.0
                                    alpha:0.46];
    } else if (LGIOS26UsesDarkAppearance()) {
        fillColor = UIColor.clearColor;
        edgeColor = [UIColor colorWithWhite:1.0 alpha:0.48];
    } else {
        fillColor = UIColor.clearColor;
        edgeColor = [UIColor colorWithWhite:1.0 alpha:0.28];
    }
    layer.backgroundColor = fillColor.CGColor;
    layer.borderColor = edgeColor.CGColor;
    layer.borderWidth = 0.65;
    layer.cornerRadius = LGIOS26CornerRadiusForIconView(iconView);
    if (@available(iOS 13.0, *)) layer.cornerCurve = kCACornerCurveContinuous;
    layer.masksToBounds = YES;

    if (!LGIOS26ProviderProcessingEnabled()) return;
    CALayer *contentsLayer = LGIOS26ContentsLayer(iconView);
    if (contentsLayer) {
        if (!objc_getAssociatedObject(
                iconView, kLGIOS26LibraryOriginalContentsOpacityKey)) {
            objc_setAssociatedObject(iconView,
                                     kLGIOS26LibraryOriginalContentsOpacityKey,
                                     @(contentsLayer.opacity),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        contentsLayer.opacity = LGIOS26UsesDarkAppearance() ? 0.70f : 0.58f;
    }

    UIView *parent = iconView.superview;
    LGLiveBackdropView *glass = objc_getAssociatedObject(
        iconView, kLGIOS26LibraryGlassKey);
    if (!glass && parent && iconView.window) {
        glass = LGCreateRegisteredGlass(iconView.frame, nil, @"IOS26Icons");
        if (glass) {
            glass.userInteractionEnabled = NO;
            glass.autoresizingMask = UIViewAutoresizingNone;
            glass.backgroundColor = UIColor.clearColor;
            objc_setAssociatedObject(iconView,
                                     kLGIOS26LibraryGlassKey,
                                     glass,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            lgTrackGlass(glass, @"IOS26Icons", nil);
        }
    }
    if (glass && parent) {
        if (glass.superview != parent) {
            [glass removeFromSuperview];
            [parent insertSubview:glass belowSubview:iconView];
        }
        glass.frame = iconView.frame;
        CGFloat glassRadius = LGIOS26CornerRadiusForIconView(iconView);
        glass.layer.cornerRadius = glassRadius;
        if (@available(iOS 13.0, *)) {
            glass.layer.cornerCurve = kCACornerCurveContinuous;
        }
        glass.layer.masksToBounds = YES;
    }

    CAGradientLayer *rimLayer = objc_getAssociatedObject(
        iconView, kLGIOS26LibraryRimLayerKey);
    if (!rimLayer) {
        rimLayer = [CAGradientLayer layer];
        rimLayer.startPoint = CGPointMake(0.08, 0.04);
        rimLayer.endPoint = CGPointMake(0.92, 0.96);
        rimLayer.locations = @[@0.0, @0.48, @1.0];
        rimLayer.zPosition = 1000.0;
        rimLayer.actions = @{
            @"bounds": NSNull.null,
            @"position": NSNull.null,
            @"path": NSNull.null,
            @"colors": NSNull.null,
        };
        objc_setAssociatedObject(iconView,
                                 kLGIOS26LibraryRimLayerKey,
                                 rimLayer,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    rimLayer.colors = LGIOS26UsesDarkAppearance()
        ? @[
            (id)[UIColor colorWithWhite:1.0 alpha:0.72].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.28].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.10].CGColor,
        ]
        : @[
            (id)[UIColor colorWithWhite:1.0 alpha:0.58].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.18].CGColor,
            (id)[UIColor colorWithWhite:0.0 alpha:0.14].CGColor,
        ];
    rimLayer.frame = iconView.bounds;
    CGFloat scale = iconView.window.screen.scale;
    if (scale <= 0.0) scale = UIScreen.mainScreen.scale;
    CGFloat lineWidth = MAX(1.5 / MAX(scale, 1.0), 0.55);
    CGFloat inset = MAX(1.15, lineWidth * 1.75);
    CGFloat radius = MAX(0.0, LGIOS26CornerRadiusForIconView(iconView) - inset);
    CAShapeLayer *rimMask = [CAShapeLayer layer];
    rimMask.frame = iconView.bounds;
    rimMask.fillColor = UIColor.clearColor.CGColor;
    rimMask.strokeColor = UIColor.whiteColor.CGColor;
    rimMask.lineWidth = lineWidth;
    rimMask.path = [UIBezierPath bezierPathWithRoundedRect:
        CGRectInset(iconView.bounds, inset, inset)
                                                   cornerRadius:radius].CGPath;
    rimLayer.mask = rimMask;
    if (rimLayer.superlayer != layer) {
        [rimLayer removeFromSuperlayer];
        [layer addSublayer:rimLayer];
    }
}

static void LGClearIOS26LibraryImages(SBIconImageView *iconView) {
    LGRestoreIOS26LibraryChicletStyle(iconView);
    objc_setAssociatedObject(iconView, kLGIOS26LibraryOriginalImageKey,
                             nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(iconView, kLGIOS26LibraryProcessedImageKey,
                             nil, OBJC_ASSOCIATION_ASSIGN);
}

static void LGSetIOS26LibraryRenderedImage(SBIconImageView *iconView,
                                           UIImage *image) {
    if (!iconView || !image.CGImage) return;
    CALayer *contentsLayer = LGIOS26ContentsLayer(iconView);
    CGFloat scale = image.scale > 0.0 ? image.scale : UIScreen.mainScreen.scale;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (contentsLayer) {
        id hostContents = iconView.layer.contents;
        if (hostContents
            && hostContents != (__bridge id)image.CGImage
            && !objc_getAssociatedObject(
                iconView, kLGIOS26LibraryOriginalHostContentsKey)) {
            objc_setAssociatedObject(iconView,
                                     kLGIOS26LibraryOriginalHostContentsKey,
                                     hostContents,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        contentsLayer.contents = (__bridge id)image.CGImage;
        contentsLayer.contentsScale = scale;
        iconView.layer.contents = nil;
    } else {
        iconView.layer.contents = (__bridge id)image.CGImage;
        iconView.layer.contentsScale = scale;
    }
    [CATransaction commit];
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
        LGSetIOS26LibraryRenderedImage(iconView, renderImage);
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

static UIView *LGIOS26DockCardSubview(UIView *card, const char *name) {
    Ivar ivar = class_getInstanceVariable(card.class, name);
    id value = ivar ? object_getIvar(card, ivar) : nil;
    return [value isKindOfClass:UIView.class] ? value : nil;
}

static void LGRestoreIOS26DockLibraryCard(UIView *card) {
    LGIOS26DockLibraryCardState *state = objc_getAssociatedObject(
        card, &kLGIOS26DockLibraryCardKey);
    if (!state) return;
    state.material.hidden = state.materialHidden;
    state.tint.hidden = state.tintHidden;
    [state.glass removeFromSuperview];
    [state.rim removeFromSuperlayer];
    objc_setAssociatedObject(card, &kLGIOS26DockLibraryCardKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
}

static void LGRestoreIOS26CrossfadeCard(UIView *card) {
    LGIOS26CrossfadeCardState *state = objc_getAssociatedObject(
        card, &kLGIOS26CrossfadeCardKey);
    if (!state) return;
    state.material.hidden = state.materialHidden;
    state.tint.hidden = state.tintHidden;
    objc_setAssociatedObject(card, &kLGIOS26CrossfadeCardKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
}

static void LGApplyIOS26CrossfadeCard(UIView *card) {
    if (!isExactClass(card, @"_SBHLibraryCategoryStackViewBackgroundView")) return;
    BOOL eligible = LGIOS26Enabled() && card.window
        && hasAncestorOfClassName(card, @"SBHLibraryPodCrossfadeView");
    if (!eligible) {
        LGRestoreIOS26CrossfadeCard(card);
        return;
    }
    UIView *tint = LGIOS26DockCardSubview(card, "_tintingView");
    UIView *material = LGIOS26DockCardSubview(card, "_materialView");
    if (!tint && !material) return;
    LGIOS26CrossfadeCardState *state = objc_getAssociatedObject(
        card, &kLGIOS26CrossfadeCardKey);
    if (state && (state.tint != tint || state.material != material)) {
        LGRestoreIOS26CrossfadeCard(card);
        state = nil;
    }
    if (!state) {
        state = [LGIOS26CrossfadeCardState new];
        state.tint = tint;
        state.material = material;
        state.tintHidden = tint.hidden;
        state.materialHidden = material.hidden;
        objc_setAssociatedObject(card, &kLGIOS26CrossfadeCardKey, state,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    tint.hidden = YES;
    material.hidden = YES;
    [CATransaction commit];
}

static void LGApplyIOS26CrossfadeCardsInView(UIView *view) {
    if (!view) return;
    LGApplyIOS26CrossfadeCard(view);
    for (UIView *subview in view.subviews) {
        LGApplyIOS26CrossfadeCardsInView(subview);
    }
}

static void LGApplyIOS26DockLibraryCard(UIView *card) {
    if (!isExactClass(card, @"_SBHLibraryCategoryStackViewBackgroundView")) return;
    if (!LGIOS26Enabled() || !card.window
        || !hasAncestorOfClassName(card, @"SBFloatingDockPlatterView")) {
        LGRestoreIOS26DockLibraryCard(card);
        return;
    }
    if (CGRectIsEmpty(card.bounds)) return;
    UIView *tint = LGIOS26DockCardSubview(card, "_tintingView");
    UIView *material = LGIOS26DockCardSubview(card, "_materialView");
    if (!tint && !material) return;
    LGIOS26DockLibraryCardState *state = objc_getAssociatedObject(
        card, &kLGIOS26DockLibraryCardKey);
    if (state && (state.tint != tint || state.material != material)) {
        LGRestoreIOS26DockLibraryCard(card);
        state = nil;
    }
    if (!state) {
        // AppIcons is a registered filter family; IOS26Icons is only an enable key.
        LGLiveBackdropView *glass = LGCreateRegisteredGlass(card.bounds, nil, @"AppIcons");
        if (!glass) return;
        state = [LGIOS26DockLibraryCardState new];
        state.glass = glass;
        state.tint = tint;
        state.material = material;
        state.tintHidden = tint.hidden;
        state.materialHidden = material.hidden;
        glass.userInteractionEnabled = NO;
        glass.backgroundColor = UIColor.clearColor;
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        lgTrackGlass(glass, @"IOS26Icons", nil);
        state.rim = [CAGradientLayer layer];
        state.rim.startPoint = CGPointMake(0.05, 0.0);
        state.rim.endPoint = CGPointMake(0.95, 1.0);
        state.rim.locations = @[@0, @0.5, @1];
        state.rim.mask = [CAShapeLayer layer];
        objc_setAssociatedObject(card, &kLGIOS26DockLibraryCardKey, state,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!sLGIOS26DockLibraryCards) sLGIOS26DockLibraryCards = [NSHashTable weakObjectsHashTable];
        [sLGIOS26DockLibraryCards addObject:card];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    tint.hidden = YES;
    material.hidden = YES;
    if (state.glass.superview != card) [card insertSubview:state.glass atIndex:0];
    state.glass.frame = card.bounds;
    CGFloat radius = card.layer.cornerRadius;
    if (radius <= 0) radius = MIN(card.bounds.size.width, card.bounds.size.height) * 0.225;
    state.glass.layer.cornerRadius = radius;
    state.glass.layer.cornerCurve = kCACornerCurveContinuous;
    state.glass.layer.masksToBounds = YES;
    state.rim.frame = card.bounds;
    BOOL dark = card.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    state.rim.colors = @[
        (id)[UIColor colorWithWhite:1 alpha:dark ? 0.68 : 0.52].CGColor,
        (id)[UIColor colorWithWhite:1 alpha:0.12].CGColor,
        (id)[UIColor colorWithWhite:dark ? 1 : 0 alpha:dark ? 0.26 : 0.20].CGColor,
    ];
    CGFloat scale = MAX(card.window.screen.scale, 1.0);
    CGFloat line = MAX(1.0 / scale, 0.55);
    CAShapeLayer *mask = (CAShapeLayer *)state.rim.mask;
    mask.frame = card.bounds;
    mask.fillColor = UIColor.clearColor.CGColor;
    mask.strokeColor = UIColor.whiteColor.CGColor;
    mask.lineWidth = line;
    mask.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(card.bounds, line / 2, line / 2)
                                         cornerRadius:MAX(0.0, radius - line / 2)].CGPath;
    if (state.rim.superlayer != card.layer) [card.layer addSublayer:state.rim];
    [CATransaction commit];
}

static void LGApplyIOS26LibraryCategoryStackView(UIView *view) {
    LGApplyIOS26DockLibraryCard(view);
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
    UIImage *providerOriginal = LGIOS26ProviderOriginalImageForImage(candidate);
    BOOL receivedProviderProcessed = providerOriginal.CGImage != nil;
    BOOL receivedProcessed = candidate.CGImage && previousProcessed.CGImage
        && candidate.CGImage == previousProcessed.CGImage;
    BOOL receivedOriginal = candidate.CGImage && original.CGImage
        && candidate.CGImage == original.CGImage;
    if (receivedProviderProcessed) {
        original = providerOriginal;
        objc_setAssociatedObject(iconView,
                                 kLGIOS26LegacyOriginalImageKey,
                                 original,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (candidate.CGImage && !receivedProcessed && !receivedOriginal) {
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
    UIImage *processed = receivedProviderProcessed
        ? candidate
        : (receivedOriginal
            && [processedSignature isEqualToString:LGIOS26StaticImageSignature()]
            ? previousProcessed : LGIOS26StaticImageForCurrentMode(original));
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
    UIImage *providerOriginal = LGIOS26ProviderOriginalImageForImage(effectiveImage);
    BOOL imageIsProcessed = providerOriginal.CGImage != nil;
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

    if (!CGRectEqualToRect(effectView.frame, iconView.bounds)) {
        effectView.frame = iconView.bounds;
    }
    [effectView updateWithImage:effectiveImage
                   cornerRadius:LGIOS26CornerRadiusForIconView(iconView)
                            mode:sLGIOS26Mode
                       algorithm:sLGIOS26Algorithm
                  darkAppearance:LGIOS26UsesDarkAppearance()
                         tintHue:sLGIOS26TintHue
                   tintIntensity:sLGIOS26TintIntensity
           preservesSubjectColor:sLGIOS26PreservesSubjectColor
                imageIsProcessed:imageIsProcessed];

    CALayer *contentsLayer = LGIOS26ContentsLayer(iconView);
    if (contentsLayer) {
        if (!objc_getAssociatedObject(iconView, kLGIOS26OriginalContentsOpacityKey)) {
            objc_setAssociatedObject(iconView,
                                     kLGIOS26OriginalContentsOpacityKey,
                                     @(contentsLayer.opacity),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (contentsLayer.opacity != 0.0f) contentsLayer.opacity = 0.0f;
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

static void LGRestoreIOS26FolderView(UIView *folderView) {
    LGRestoreIOS26FolderMiniLayer(folderView.layer, 0);
}

static void LGTrackIOS26FolderView(UIView *folderView) {
    if (!sLGIOS26FolderViews) sLGIOS26FolderViews = [NSHashTable weakObjectsHashTable];
    if (folderView) [sLGIOS26FolderViews addObject:folderView];
}

static void LGRefreshIOS26FolderPresentation(UIView *folderView) {
    if (!folderView.layer) return;
    LGTrackIOS26FolderView(folderView);
    if (!LGIOS26Enabled()) {
        LGRestoreIOS26FolderView(folderView);
        return;
    }
    LGProcessIOS26FolderMiniLayer(folderView.layer, 0);
}

static void LGApplyIOS26LibraryGridAppearance(UIView *view) {
    if (!view.layer) return;
    if (!LGIOS26Enabled()) {
        LGRestoreIOS26FolderMiniLayer(view.layer, 0);
        return;
    }
    if (LGIOS26ProviderProcessingEnabled()) {
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
    for (UIView *card in sLGIOS26DockLibraryCards.allObjects) {
        LGApplyIOS26DockLibraryCard(card);
    }
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
    if (LGIOS26ProviderProcessingEnabled()) {
        return LGIOS26FolderMiniFinishedImage(image);
    }
    return LGIOS26Enabled()
        ? LGIOS26StaticImageForCurrentMode(image)
        : LGIOS26OriginalStaticImage(image);
}

%end

%hook SBFolderIconImageCache

- (UIImage *)gridCellImageForIcon:(id)icon {
    UIImage *image = %orig;
    if (LGIOS26ProviderProcessingEnabled()) {
        return LGIOS26FolderMiniFinishedImage(image);
    }
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
    if (LGIOS26ProviderProcessingEnabled()) {
        return LGIOS26FolderMiniFinishedImage(cellImage);
    }
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
    if (LGIOS26ProviderProcessingEnabled()) {
        return LGIOS26FolderMiniFinishedImage(cellImage);
    }
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
    if (LGIOS26ProviderProcessingEnabled()) {
        return LGIOS26FolderMiniFinishedImage(cellImage);
    }
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
    LGSetIOS26LibraryRenderedImage((SBIconImageView *)self, renderImage);
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

%hook _SBHLibraryCategoryStackViewBackgroundView

- (void)layoutSubviews {
    %orig;
    LGApplyIOS26DockLibraryCard((UIView *)self);
    LGApplyIOS26CrossfadeCard((UIView *)self);
}

- (void)didMoveToWindow {
    %orig;
    LGApplyIOS26DockLibraryCard((UIView *)self);
    LGApplyIOS26CrossfadeCard((UIView *)self);
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    %orig(previous);
    LGApplyIOS26DockLibraryCard((UIView *)self);
    LGApplyIOS26CrossfadeCard((UIView *)self);
}

%end

%hook SBHLibraryPodCrossfadeView

- (void)layoutSubviews {
    %orig;
    LGApplyIOS26CrossfadeCardsInView((UIView *)self);
}

- (void)didMoveToWindow {
    %orig;
    LGApplyIOS26CrossfadeCardsInView((UIView *)self);
}

- (void)setSourceViewCrossfadeFraction:(CGFloat)fraction {
    %orig(fraction);
    LGApplyIOS26CrossfadeCardsInView((UIView *)self);
}

- (void)setPodIconViewCrossfadeFraction:(CGFloat)fraction {
    %orig(fraction);
    LGApplyIOS26CrossfadeCardsInView((UIView *)self);
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
    UIView *folderView = (UIView *)self;
    LGRefreshIOS26FolderPresentation(folderView);
    __weak UIView *weakFolderView = folderView;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *strongFolderView = weakFolderView;
        if (!strongFolderView || !strongFolderView.window) return;
        LGRefreshIOS26FolderPresentation(strongFolderView);
    });
}

- (void)fulfillGridLayerForPageElement:(id)element {
    %orig;
    LGRefreshIOS26FolderPresentation((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    LGRefreshIOS26FolderPresentation((UIView *)self);
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
    if (LGIOS26ProviderProcessingEnabled()) {
        return LGIOS26FolderMiniFinishedImage(image);
    }
    if (!LGIOS26Enabled()) return LGIOS26OriginalStaticImage(image);
    return LGIOS26StaticImageForCurrentMode(image);
}

%end

%group LGIOS26ProviderLifecycle

%hook IFConcreteImage

- (CGImageRef)CGImage {
    CGImageRef original = %orig;
    return LGIOS26ProviderProcessedCGImage(self, original);
}

%end

%end

%ctor {
    %init;
    LGReloadIOS26Mode();
    dlopen("/System/Library/PrivateFrameworks/IconFoundation.framework/IconFoundation",
           RTLD_LAZY | RTLD_LOCAL);
    Class providerImageClass = NSClassFromString(@"IFConcreteImage");
    if (class_getInstanceMethod(providerImageClass,
                                NSSelectorFromString(@"CGImage"))) {
        %init(LGIOS26ProviderLifecycle);
        sLGIOS26ProviderPipelineActive = YES;
    }
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
