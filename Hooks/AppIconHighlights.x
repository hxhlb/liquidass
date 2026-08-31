#import <UIKit/UIKit.h>
#import <CoreMotion/CoreMotion.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import <objc/runtime.h>

static void *kLGAppIconHighlightKey = &kLGAppIconHighlightKey;
static NSHashTable<UIView *> *sLGAppIconExViews;
static NSHashTable<UIView *> *sLGAppIconExHighlights;
static CMMotionManager *sLGAppIconExMotionManager;
static BOOL sLGAppIconExMotionRunning;
static BOOL sLGAppIconExMotionEnabled;
static CGFloat sLGAppIconExMotionSensitivity = 2.0;
static CGFloat sLGAppIconExAngle = -M_PI_4;

@interface LGAppIconHighlightView : UIView
@property (nonatomic, strong) CAGradientLayer *rimLayer;
@property (nonatomic, strong) CAShapeLayer *rimMask;
@property (nonatomic, strong) CAGradientLayer *rimBloomLayer;
@property (nonatomic, strong) CAShapeLayer *rimBloomMask;
@property (nonatomic, strong) CAGradientLayer *glossLayer;
@property (nonatomic, strong) CAShapeLayer *glossMask;
@property (nonatomic, assign) CGFloat cornerRadius;
@property (nonatomic, assign) CGFloat intensity;
- (void)applyAngle:(CGFloat)angle;
@end

@implementation LGAppIconHighlightView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.userInteractionEnabled = NO;
    self.backgroundColor = UIColor.clearColor;
    self.opaque = NO;

    _rimLayer = [CAGradientLayer layer];
    _rimLayer.type = kCAGradientLayerConic;
    _rimLayer.colors = @[
        (id)UIColor.clearColor.CGColor,
        (id)UIColor.clearColor.CGColor,
        (id)[UIColor colorWithRed:0.88 green:0.97 blue:1.0 alpha:0.82].CGColor,
        (id)[UIColor colorWithRed:1.0 green:0.94 blue:0.82 alpha:0.28].CGColor,
        (id)UIColor.clearColor.CGColor,
        (id)UIColor.clearColor.CGColor,
        (id)[UIColor colorWithWhite:0.0 alpha:0.08].CGColor,
        (id)UIColor.clearColor.CGColor,
        (id)UIColor.clearColor.CGColor,
    ];
    _rimLayer.locations = @[@0.0, @0.10, @0.16, @0.24, @0.34,
                            @0.56, @0.64, @0.76, @1.0];
    _rimMask = [CAShapeLayer layer];
    _rimMask.fillColor = UIColor.clearColor.CGColor;
    _rimMask.strokeColor = UIColor.whiteColor.CGColor;
    _rimMask.lineWidth = 0.65;
    _rimLayer.mask = _rimMask;
    _rimLayer.compositingFilter = @"overlayBlendMode";
    [self.layer addSublayer:_rimLayer];

    _rimBloomLayer = [CAGradientLayer layer];
    _rimBloomLayer.type = kCAGradientLayerConic;
    _rimBloomLayer.colors = @[
        (id)UIColor.clearColor.CGColor,
        (id)UIColor.clearColor.CGColor,
        (id)[UIColor colorWithRed:0.55 green:0.90 blue:1.0 alpha:0.42].CGColor,
        (id)[UIColor colorWithRed:1.0 green:0.82 blue:0.58 alpha:0.14].CGColor,
        (id)UIColor.clearColor.CGColor,
        (id)UIColor.clearColor.CGColor,
        (id)UIColor.clearColor.CGColor,
        (id)UIColor.clearColor.CGColor,
        (id)UIColor.clearColor.CGColor,
    ];
    _rimBloomLayer.locations = _rimLayer.locations;
    _rimBloomMask = [CAShapeLayer layer];
    _rimBloomMask.fillColor = UIColor.clearColor.CGColor;
    _rimBloomMask.strokeColor = UIColor.whiteColor.CGColor;
    _rimBloomMask.lineWidth = 2.8;
    _rimBloomLayer.mask = _rimBloomMask;
    _rimBloomLayer.compositingFilter = @"screenBlendMode";
    [self.layer insertSublayer:_rimBloomLayer below:_rimLayer];

    _glossLayer = [CAGradientLayer layer];
    _glossLayer.colors = @[
        (id)[UIColor colorWithWhite:1.0 alpha:0.20].CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:0.06].CGColor,
        (id)UIColor.clearColor.CGColor,
    ];
    _glossLayer.locations = @[@0.0, @0.18, @0.42];
    _glossLayer.compositingFilter = @"softLightBlendMode";
    _glossMask = [CAShapeLayer layer];
    _glossMask.fillColor = UIColor.whiteColor.CGColor;
    _glossLayer.mask = _glossMask;
    [self.layer addSublayer:_glossLayer];

    self.intensity = 0.65;
    [self applyAngle:sLGAppIconExAngle];
    return self;
}

- (void)setIntensity:(CGFloat)intensity {
    _intensity = fmin(1.0, fmax(0.0, intensity));
    CGFloat response = sqrt(_intensity);
    self.rimLayer.opacity = 0.68 * response;
    self.rimBloomLayer.opacity = 0.55 * response;
    self.glossLayer.opacity = 0.45 * response;
}

- (void)applyAngle:(CGFloat)angle {
    CGFloat dx = cos(angle) * 0.5;
    CGFloat dy = sin(angle) * 0.5;
    CGPoint start = CGPointMake(0.5 + dx, 0.5 + dy);
    CGPoint end = CGPointMake(0.5 - dx, 0.5 - dy);
    self.rimLayer.startPoint = CGPointMake(0.5, 0.5);
    // Conic gradients use a coordinate origin rotated 90 degrees relative to
    // the linear highlight used by LGLiveBackdropView. Compensate so both
    // surfaces share the same visible top-right to bottom-left light axis.
    self.rimLayer.endPoint = CGPointMake(0.5 - dy, 0.5 + dx);
    self.rimBloomLayer.startPoint = self.rimLayer.startPoint;
    self.rimBloomLayer.endPoint = self.rimLayer.endPoint;
    self.glossLayer.startPoint = start;
    self.glossLayer.endPoint = end;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.rimLayer.frame = self.bounds;
    self.rimBloomLayer.frame = self.bounds;
    self.glossLayer.frame = self.bounds;
    self.rimMask.frame = self.bounds;
    self.rimBloomMask.frame = self.bounds;
    self.glossMask.frame = self.bounds;
    CGFloat rimInset = self.rimMask.lineWidth * 0.5 + 0.15;
    CGRect rimRect = CGRectInset(self.bounds, rimInset, rimInset);
    self.rimMask.path = [UIBezierPath bezierPathWithRoundedRect:rimRect
                                                   cornerRadius:MAX(0.0, self.cornerRadius - rimInset)].CGPath;
    CGFloat bloomInset = self.rimBloomMask.lineWidth * 0.5 + 0.15;
    CGRect bloomRect = CGRectInset(self.bounds, bloomInset, bloomInset);
    self.rimBloomMask.path = [UIBezierPath bezierPathWithRoundedRect:bloomRect
                                                        cornerRadius:MAX(0.0, self.cornerRadius - bloomInset)].CGPath;
    self.glossMask.path = [UIBezierPath bezierPathWithRoundedRect:self.bounds
                                                      cornerRadius:self.cornerRadius].CGPath;
    [CATransaction commit];
}

@end


static BOOL LGIsAppIconExImageView(UIView *view) {
    static Class iconImageViewClass;
    static Class iconViewClass;
    if (!iconImageViewClass) iconImageViewClass = NSClassFromString(@"SBIconImageView");
    if (!iconViewClass) iconViewClass = NSClassFromString(@"SBIconView");
    if (!view || !iconImageViewClass || ![view isKindOfClass:iconImageViewClass]) return NO;

    CGSize size = view.bounds.size;
    CGFloat shortest = MIN(size.width, size.height);
    CGFloat longest = MAX(size.width, size.height);
    if (!isfinite(size.width) || !isfinite(size.height) ||
        shortest < 40.0 || longest > 96.0 ||
        fabs(size.width - size.height) > 2.0) return NO;

    // SpringBoard inserts different wrapper views across iOS releases. Walk up
    // to the owning icon instead of requiring the iOS 17 two-level hierarchy.
    // App Library pods inherit from SBIconView, so reject them before accepting
    // a generic icon ancestor and leave their existing upstream surface intact.
    UIView *ancestor = view.superview;
    for (NSInteger depth = 0; ancestor && depth < 6; depth++, ancestor = ancestor.superview) {
        NSString *className = NSStringFromClass(ancestor.class);
        if ([className containsString:@"Library"] ||
            [className containsString:@"AppLibrary"]) return NO;
        if (iconViewClass && [ancestor isKindOfClass:iconViewClass]) return YES;
    }
    return NO;
}

static CGFloat LGAppIconExIntensity(void) {
    id value = LGGlassPreferenceValue(@"AppIconsEx.Intensity");
    CGFloat intensity = [value respondsToSelector:@selector(doubleValue)]
        ? [value doubleValue] : 0.65;
    return fmin(1.0, fmax(0.0, intensity));
}

static void LGReloadAppIconExMotionPreferences(void) {
    id enabled = LGGlassPreferenceValue(@"AppIconsEx.Motion.Enabled");
    id sensitivity = LGGlassPreferenceValue(@"Specular.Motion.Sensitivity");
    sLGAppIconExMotionEnabled = [enabled respondsToSelector:@selector(boolValue)]
        ? [enabled boolValue] : NO;
    CGFloat value = [sensitivity respondsToSelector:@selector(doubleValue)]
        ? [sensitivity doubleValue] : 2.0;
    sLGAppIconExMotionSensitivity = fmin(8.0, fmax(0.0, value));
}

static void LGApplyAppIconExAngle(CGFloat angle) {
    sLGAppIconExAngle = angle;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (LGAppIconHighlightView *highlight in sLGAppIconExHighlights.allObjects) {
        if (!highlight.window) continue;
        [highlight applyAngle:angle];
    }
    [CATransaction commit];
}

static void LGRefreshAppIconExMotion(void) {
    if (!sLGAppIconExMotionManager) sLGAppIconExMotionManager = [CMMotionManager new];
    BOOL shouldRun = sLGAppIconExMotionEnabled && sLGAppIconExHighlights.count > 0 &&
        sLGAppIconExMotionManager.deviceMotionAvailable;
    if (!shouldRun) {
        if (sLGAppIconExMotionRunning) [sLGAppIconExMotionManager stopDeviceMotionUpdates];
        sLGAppIconExMotionRunning = NO;
        LGApplyAppIconExAngle(-M_PI_4);
        return;
    }
    if (sLGAppIconExMotionRunning) return;

    sLGAppIconExMotionManager.deviceMotionUpdateInterval = 1.0 / 10.0;
    sLGAppIconExMotionRunning = YES;
    [sLGAppIconExMotionManager startDeviceMotionUpdatesToQueue:NSOperationQueue.mainQueue
                                                  withHandler:^(CMDeviceMotion *motion, NSError *error) {
        if (!motion || error || !sLGAppIconExMotionEnabled) return;
        CGFloat base = motion.attitude.yaw + motion.attitude.roll * 0.65 +
            motion.attitude.pitch * 0.35;
        CGFloat target = -M_PI_4 + base * (sLGAppIconExMotionSensitivity / 2.0);
        CGFloat delta = atan2(sin(target - sLGAppIconExAngle),
                              cos(target - sLGAppIconExAngle));
        if (fabs(delta) < 0.035) return;
        LGApplyAppIconExAngle(sLGAppIconExAngle + delta * 0.35);
    }];
}

static void LGRemoveAppIconExHighlight(UIView *iconView) {
    LGAppIconHighlightView *highlight =
        objc_getAssociatedObject(iconView, kLGAppIconHighlightKey);
    if (!highlight) return;
    [sLGAppIconExHighlights removeObject:highlight];
    [highlight removeFromSuperview];
    objc_setAssociatedObject(iconView, kLGAppIconHighlightKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
    LGRefreshAppIconExMotion();
}

static void LGInstallAppIconExHighlight(UIView *iconView) {
    if (!LGIsAppIconExImageView(iconView) || !iconView.window ||
        !lgHostEnabled(@"AppIconsEx")) {
        LGRemoveAppIconExHighlight(iconView);
        return;
    }
    if (!sLGAppIconExHighlights) sLGAppIconExHighlights = [NSHashTable weakObjectsHashTable];

    LGAppIconHighlightView *highlight =
        objc_getAssociatedObject(iconView, kLGAppIconHighlightKey);
    if (!highlight) {
        highlight = [[LGAppIconHighlightView alloc] initWithFrame:iconView.bounds];
        highlight.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [iconView addSubview:highlight];
        objc_setAssociatedObject(iconView, kLGAppIconHighlightKey, highlight,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [sLGAppIconExHighlights addObject:highlight];
    } else if (highlight.superview != iconView) {
        [highlight removeFromSuperview];
        [iconView addSubview:highlight];
    } else if (iconView.subviews.lastObject != highlight) {
        [iconView bringSubviewToFront:highlight];
    }

    if (!CGRectEqualToRect(highlight.frame, iconView.bounds)) highlight.frame = iconView.bounds;
    CGFloat radius = iconView.layer.cornerRadius;
    if (!isfinite(radius) || radius <= 0.0) radius = CGRectGetWidth(iconView.bounds) * 0.225;
    highlight.cornerRadius = radius;
    highlight.intensity = LGAppIconExIntensity();
    [highlight setNeedsLayout];
    [highlight applyAngle:sLGAppIconExAngle];
    LGRefreshAppIconExMotion();
}

static void LGReloadAppIconExHighlights(void) {
    LGReloadAppIconExMotionPreferences();
    for (UIView *iconView in sLGAppIconExViews.allObjects) {
        LGInstallAppIconExHighlight(iconView);
    }
    LGRefreshAppIconExMotion();
}

%hook SBIconImageView

- (void)didMoveToWindow {
    %orig;
    if (!sLGAppIconExViews) sLGAppIconExViews = [NSHashTable weakObjectsHashTable];
    [sLGAppIconExViews addObject:(UIView *)self];
    LGInstallAppIconExHighlight((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    if (!sLGAppIconExViews) sLGAppIconExViews = [NSHashTable weakObjectsHashTable];
    [sLGAppIconExViews addObject:(UIView *)self];
    LGInstallAppIconExHighlight((UIView *)self);
}

%end

%ctor {
    LGReloadAppIconExMotionPreferences();
    lgObservePreferenceReload(^{
        LGReloadAppIconExHighlights();
    });
}
