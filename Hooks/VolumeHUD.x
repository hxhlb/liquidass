#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGSharedSupport.h"

@interface MTMaterialView : UIView
@end

@interface CCUIContinuousSliderView : UIControl
@end

@interface SBElasticSliderView : CCUIContinuousSliderView
@end

@interface SBElasticVolumeSliderView : SBElasticSliderView
@end

@interface SBElasticSliderMaterialWrapperView : UIView {
    MTMaterialView *_captureOnlyMaterialView;
    MTMaterialView *_baseMaterialView;
    UIView *_shadowView;
    UIView *_sliderWrapperView;
    UIView *_maskView;
    SBElasticVolumeSliderView *_sliderView;
}
- (void)_setContinuousCornerRadius:(double)radius;
@end

@interface LGVolumeHUDVibranceView : UIView
@end

@implementation LGVolumeHUDVibranceView

+ (Class)layerClass {
    return NSClassFromString(@"CABackdropLayer") ?: [CALayer class];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
        self.autoresizingMask = UIViewAutoresizingNone;
        [self applyVibranceFilters];
    }
    return self;
}

- (void)applyVibranceFilters {
    @try {
        CALayer *layer = self.layer;
        if (![layer isKindOfClass:NSClassFromString(@"CABackdropLayer")]) return;

        Class filterCls = NSClassFromString(@"CAFilter");
        if (!filterCls) return;

        NSMutableArray *filters = [NSMutableArray array];

        id satFilter = ((id (*)(Class, SEL, NSString *))objc_msgSend)(
            filterCls, NSSelectorFromString(@"filterWithType:"), @"colorSaturate");
        if (satFilter) {
            @try { [satFilter setValue:@(1.85) forKey:@"inputAmount"]; } @catch (...) {}
            [filters addObject:satFilter];
        }

        id contrastFilter = ((id (*)(Class, SEL, NSString *))objc_msgSend)(
            filterCls, NSSelectorFromString(@"filterWithType:"), @"colorContrast");
        if (contrastFilter) {
            @try { [contrastFilter setValue:@(1.06) forKey:@"inputAmount"]; } @catch (...) {}
            [filters addObject:contrastFilter];
        }

        layer.filters = filters;
    } @catch (NSException *e) {}
}

@end

static const void * const kLGVolumeHUDGlassKey = &kLGVolumeHUDGlassKey;
static const void * const kLGVolumeHUDVibranceKey = &kLGVolumeHUDVibranceKey;
static const void * const kLGVolumeHUDMaterialHiddenKey = &kLGVolumeHUDMaterialHiddenKey;
static const void * const kLGVolumeHUDProbePendingKey = &kLGVolumeHUDProbePendingKey;

static BOOL LGVolumeHUDEnabled(void) {
    return lgHostEnabled(@"VolumeHUD");
}

static BOOL LGVolumeHUDNeedsLegacyMaterialWorkaround(void) {
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 16;
}

static UIView *LGVolumeHUDDescendant(UIView *view, Class targetClass) {
    if ([view isKindOfClass:targetClass]) return view;
    for (UIView *subview in view.subviews) {
        UIView *found = LGVolumeHUDDescendant(subview, targetClass);
        if (found) return found;
    }
    return nil;
}

static void LGSetVolumeHUDBackgroundMaterialsHidden(UIView *view, BOOL hidden) {
    if ([view isKindOfClass:NSClassFromString(@"MTMaterialView")] &&
        [view.superview isKindOfClass:NSClassFromString(@"MTMaterialShadowView")]) {
        NSNumber *original = objc_getAssociatedObject(view, kLGVolumeHUDMaterialHiddenKey);
        if (hidden) {
            if (!original)
                objc_setAssociatedObject(view, kLGVolumeHUDMaterialHiddenKey, @(view.hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            view.hidden = YES;
        } else if (original) {
            view.hidden = original.boolValue;
            objc_setAssociatedObject(view, kLGVolumeHUDMaterialHiddenKey, nil, OBJC_ASSOCIATION_ASSIGN);
        }
    }
    for (UIView *subview in view.subviews) LGSetVolumeHUDBackgroundMaterialsHidden(subview, hidden);
}

static void LGAppendVolumeHUDMaterialRows(UIView *view, NSString *path,
                                          NSMutableArray<NSString *> *rows) {
    NSString *nextPath = [path stringByAppendingFormat:@"/%@", NSStringFromClass(view.class)];
    if ([view isKindOfClass:NSClassFromString(@"MTMaterialView")])
        [rows addObject:[NSString stringWithFormat:@"%@ frame=%@ hidden=%d alpha=%.2f radius=%.2f",
            nextPath, NSStringFromCGRect(view.frame), view.hidden, view.alpha, view.layer.cornerRadius]];
    for (UIView *subview in view.subviews) LGAppendVolumeHUDMaterialRows(subview, nextPath, rows);
}

static void LGScheduleVolumeHUDProbe(UIView *wrapper) {
    if (!LGDebugLoggingEnabled() || [objc_getAssociatedObject(wrapper, kLGVolumeHUDProbePendingKey) boolValue]) return;
    objc_setAssociatedObject(wrapper, kLGVolumeHUDProbePendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        objc_setAssociatedObject(wrapper, kLGVolumeHUDProbePendingKey, nil, OBJC_ASSOCIATION_ASSIGN);
        if (!wrapper.window) return;
        NSMutableArray<NSString *> *rows = [NSMutableArray array];
        LGAppendVolumeHUDMaterialRows(wrapper, @"", rows);
        LGLog(@"[VolumeHUD probe] wrapper=%@ bounds=%@ materials=[%@]",
              NSStringFromClass(wrapper.class), NSStringFromCGRect(wrapper.bounds),
              [rows componentsJoinedByString:@" | "]);
    });
}

static void LGUpdateVolumeHUDGlass(SBElasticSliderMaterialWrapperView *self) {
    if (!self) return;

    MTMaterialView *base = nil;
    MTMaterialView *cap = nil;
    UIView *shadow = nil;
    UIView *sliderWrapper = nil;
    UIView *sliderView = nil;
    @try {
        base = [self valueForKey:@"_baseMaterialView"];
        cap = [self valueForKey:@"_captureOnlyMaterialView"];
        shadow = [self valueForKey:@"_shadowView"];
        sliderWrapper = [self valueForKey:@"_sliderWrapperView"];
        sliderView = [self valueForKey:@"_sliderView"];
    } @catch (...) {}
    if (!sliderView)
        sliderView = LGVolumeHUDDescendant(self, NSClassFromString(@"SBElasticVolumeSliderView"));

    if (!LGVolumeHUDEnabled()) {
        LGLiveBackdropView *existing = objc_getAssociatedObject(self, kLGVolumeHUDGlassKey);
        if (existing) existing.hidden = YES;
        LGVolumeHUDVibranceView *existingVib = objc_getAssociatedObject(self, kLGVolumeHUDVibranceKey);
        if (existingVib) existingVib.hidden = YES;
        if (base) base.hidden = NO;
        if (cap) cap.hidden = NO;
        if (shadow) shadow.hidden = NO;
        LGSetVolumeHUDBackgroundMaterialsHidden(self, NO);
        return;
    }

    if (base) base.hidden = YES;
    if (cap) cap.hidden = YES;
    if (shadow) shadow.hidden = YES;
    LGSetVolumeHUDBackgroundMaterialsHidden(self, YES);

    LGVolumeHUDVibranceView *vibrance = objc_getAssociatedObject(self, kLGVolumeHUDVibranceKey);
    if (!vibrance) {
        vibrance = [[LGVolumeHUDVibranceView alloc] initWithFrame:self.bounds];
        if (vibrance) {
            objc_setAssociatedObject(self, kLGVolumeHUDVibranceKey, vibrance, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (sliderWrapper) {
                [self insertSubview:vibrance belowSubview:sliderWrapper];
            } else {
                [self addSubview:vibrance];
            }
        }
    }

    LGLiveBackdropView *glass = objc_getAssociatedObject(self, kLGVolumeHUDGlassKey);
    if (!glass) {
        glass = LGCreateRegisteredGlass(self.bounds, nil, @"VolumeHUD");
        if (!glass) return;
        objc_setAssociatedObject(self, kLGVolumeHUDGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        lgTrackGlass(glass, @"VolumeHUD", self);

        [self insertSubview:glass atIndex:0];
    }

    CGFloat radius = MIN(self.bounds.size.width, self.bounds.size.height) * 0.5f;

    glass.hidden = NO;
    glass.frame = self.bounds;
    glass.layer.cornerRadius = radius;
    if (@available(iOS 13.0, *)) {
        glass.layer.cornerCurve = kCACornerCurveContinuous;
    }
    glass.layer.masksToBounds = YES;
    [glass applyFilters];

    if (vibrance) {
        vibrance.hidden = NO;
        vibrance.frame = self.bounds;
        vibrance.layer.cornerRadius = radius;
        if (@available(iOS 13.0, *)) {
            vibrance.layer.cornerCurve = kCACornerCurveContinuous;
        }
        vibrance.layer.masksToBounds = YES;
    }

    self.layer.cornerRadius = radius;
    if (@available(iOS 13.0, *)) {
        self.layer.cornerCurve = kCACornerCurveContinuous;
    }

    if (sliderWrapper) {
        sliderWrapper.layer.cornerRadius = radius;
        if (@available(iOS 13.0, *)) {
            sliderWrapper.layer.cornerCurve = kCACornerCurveContinuous;
        }
        sliderWrapper.layer.masksToBounds = YES;
    }

    if (sliderView) {
        sliderView.layer.cornerRadius = radius;
        if (@available(iOS 13.0, *)) {
            sliderView.layer.cornerCurve = kCACornerCurveContinuous;
        }
        sliderView.layer.masksToBounds = YES;
        if (LGVolumeHUDNeedsLegacyMaterialWorkaround()) {
            for (UIView *subview in sliderView.subviews) {
                if (![subview isKindOfClass:NSClassFromString(@"MTMaterialView")]) continue;
                subview.layer.cornerRadius = radius;
                subview.layer.cornerCurve = kCACornerCurveContinuous;
                subview.layer.masksToBounds = YES;
            }
        }
    }
    LGScheduleVolumeHUDProbe(self);
}

// iOS 17 (and earlier elastic HUDs) owns the materials directly on the
// slider. The wrapper class used above does not exist on that hierarchy.
static NSHashTable<UIView *> *sLGLegacyVolumeSliders;
static const void * const kLGLegacyVolumeUpdatingKey = &kLGLegacyVolumeUpdatingKey;

static UIView *LGVolumeHUDViewForKey(UIView *owner, NSString *key) {
    @try {
        id view = [owner valueForKey:key];
        return [view isKindOfClass:UIView.class] ? view : nil;
    } @catch (__unused NSException *exception) { return nil; }
}

static BOOL LGVolumeHUDIsVolumeSlider(UIView *view) {
    Class controllerClass = NSClassFromString(@"SBElasticVolumeViewController");
    if (!controllerClass) return NO;
    for (UIResponder *responder = view; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:controllerClass]) return YES;
        if ([responder isKindOfClass:UIViewController.class]) return NO;
    }
    return NO;
}

static void LGVolumeHUDSetNativeViewHidden(UIView *view, BOOL hidden) {
    if (!view) return;
    NSNumber *original = objc_getAssociatedObject(view, kLGVolumeHUDMaterialHiddenKey);
    if (hidden) {
        if (!original) objc_setAssociatedObject(view, kLGVolumeHUDMaterialHiddenKey,
            @(view.hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        view.hidden = YES;
    } else if (original) {
        view.hidden = original.boolValue;
        objc_setAssociatedObject(view, kLGVolumeHUDMaterialHiddenKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
}

static void LGUpdateLegacyVolumeHUDGlass(UIView *slider) {
    if (!slider || [objc_getAssociatedObject(slider, kLGLegacyVolumeUpdatingKey) boolValue]) return;
    LGLiveBackdropView *glass = objc_getAssociatedObject(slider, kLGVolumeHUDGlassKey);
    BOOL isVolume = LGVolumeHUDIsVolumeSlider(slider);
    if (!isVolume && !glass) return;
    [sLGLegacyVolumeSliders addObject:slider];
    objc_setAssociatedObject(slider, kLGLegacyVolumeUpdatingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @try {
        UIView *container = LGVolumeHUDViewForKey(slider, @"_elasticContentView");
        UIView *background = LGVolumeHUDViewForKey(slider, @"_backgroundView");
        BOOL enabled = isVolume && LGVolumeHUDEnabled() && slider.window &&
                       container && background && !CGRectIsEmpty(container.bounds);
        if (enabled) {
            if (!glass) {
                glass = LGCreateRegisteredGlass(container.bounds, nil, @"VolumeHUD");
                objc_setAssociatedObject(slider, kLGVolumeHUDGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                if (glass) lgTrackGlass(glass, @"VolumeHUD", slider);
            }
            if (glass && glass.superview != container) {
                [glass removeFromSuperview];
                [container insertSubview:glass atIndex:0];
            }
            glass.frame = container.bounds;
            glass.layer.cornerRadius = container.layer.cornerRadius;
            glass.layer.cornerCurve = container.layer.cornerCurve;
            glass.clipsToBounds = YES;
            [glass applyFilters];
        }
        BOOL ready = enabled && glass.lgFilterAttached;
        glass.hidden = !ready;
        // Keep the value clipping view, fill material and glyphs untouched.
        for (NSString *key in @[@"_baseMaterialView", @"_captureOnlyMaterialView",
                                @"_backgroundView", @"_shadowView"]) {
            LGVolumeHUDSetNativeViewHidden(LGVolumeHUDViewForKey(slider, key), ready);
        }
        if (!enabled) {
            [glass removeFromSuperview];
            objc_setAssociatedObject(slider, kLGVolumeHUDGlassKey, nil, OBJC_ASSOCIATION_ASSIGN);
        }
    } @finally {
        objc_setAssociatedObject(slider, kLGLegacyVolumeUpdatingKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
}

%group LGLegacyVolumeHUDHooks
%hook SBElasticSliderView
- (void)layoutElasticContentViews {
    %orig;
    LGUpdateLegacyVolumeHUDGlass((UIView *)self);
}
- (void)didMoveToWindow {
    %orig;
    LGUpdateLegacyVolumeHUDGlass((UIView *)self);
}
%end
%end

%group LGVolumeHUDHooks

%hook SBElasticSliderMaterialWrapperView

- (instancetype)initWithFrame:(CGRect)frame {
    self = %orig;
    if (self) {
        LGUpdateVolumeHUDGlass(self);
    }
    return self;
}

- (instancetype)initWithSliderView:(id)sliderView {
    self = %orig;
    if (self) {
        LGUpdateVolumeHUDGlass(self);
    }
    return self;
}

- (void)layoutSubviews {
    %orig;
    LGUpdateVolumeHUDGlass(self);
}

- (void)_setContinuousCornerRadius:(double)radius {
    if (LGVolumeHUDEnabled()) {
        CGFloat pillRadius = MIN(self.bounds.size.width, self.bounds.size.height) * 0.5f;
        %orig((double)pillRadius);
        LGLiveBackdropView *glass = objc_getAssociatedObject(self, kLGVolumeHUDGlassKey);
        if (glass) {
            glass.layer.cornerRadius = pillRadius;
            if (@available(iOS 13.0, *)) {
                glass.layer.cornerCurve = kCACornerCurveContinuous;
            }
        }
        LGVolumeHUDVibranceView *vibrance = objc_getAssociatedObject(self, kLGVolumeHUDVibranceKey);
        if (vibrance) {
            vibrance.layer.cornerRadius = pillRadius;
            if (@available(iOS 13.0, *)) {
                vibrance.layer.cornerCurve = kCACornerCurveContinuous;
            }
        }
    } else {
        %orig;
    }
}

%end

%end

%ctor {
    if (!LGIsSpringBoardProcess()) return;
    if (NSClassFromString(@"SBElasticSliderMaterialWrapperView")) {
        %init(LGVolumeHUDHooks);
    } else if (NSClassFromString(@"SBElasticSliderView")) {
        sLGLegacyVolumeSliders = [NSHashTable weakObjectsHashTable];
        %init(LGLegacyVolumeHUDHooks);
        [[NSNotificationCenter defaultCenter]
            addObserverForName:@"LGLiveBackdropViewFilterDidAttach" object:nil
            queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                for (UIView *slider in sLGLegacyVolumeSliders.allObjects) {
                    if (objc_getAssociatedObject(slider, kLGVolumeHUDGlassKey) == note.object)
                        LGUpdateLegacyVolumeHUDGlass(slider);
                }
            }];
    }
    lgObservePreferenceReload(^{
        for (UIView *slider in sLGLegacyVolumeSliders.allObjects)
            LGUpdateLegacyVolumeHUDGlass(slider);
        LGLog(@"VolumeHUD: Preferences reloaded");
    });
}
