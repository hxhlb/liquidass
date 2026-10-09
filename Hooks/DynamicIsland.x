#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <math.h>
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGSharedSupport.h"
#import "../Shared/LGLiveBackdropView.h"

static char kLGIslandDriverKey;
static NSHashTable<UIView *> *sLGIslandContainers;
static NSMapTable<UIView *, NSMutableDictionary *> *sLGIslandCurtains;
static BOOL sLGIslandUpdatingCurtains;
static NSMapTable<UIView *, NSNumber *> *sLGIslandTransitionShadows;
static BOOL sLGIslandProxyGainMaps;
static BOOL sLGIslandCreatingNativeGainMap;
static UIView *sLGIslandNativeGainMap;

@interface CALayer (LGIslandGainMapSupport)
@property (nonatomic) NSUInteger disableUpdateMask;
@end

@interface LGIslandGainMapLayer : CALayer
@property (nonatomic, copy) NSString *renderMode;
@end
@implementation LGIslandGainMapLayer
@end

// Liquidify keeps geometry/layout updates separate from its display-link
// observer. Do the same locally without changing every LGLiveBackdropView.
@interface LGIslandBackdropView : LGLiveBackdropView
@property (nonatomic) BOOL lgIslandLayoutEnabled;
- (void)lgAttachRimLayersToCarrier:(CALayer *)carrier;
- (void)lgSetRimRenderingSuppressed:(BOOL)suppressed;
@end

@implementation LGIslandBackdropView
{
    BOOL _lgRimRenderingSuppressed;
    NSMapTable<CALayer *, NSNumber *> *_lgRimOriginalOpacities;
    NSArray<CAGradientLayer *> *_lgIslandRimLayers;
}
- (void)layoutSubviews {
    if (self.lgIslandLayoutEnabled) [super layoutSubviews];
}

- (void)lgAttachRimLayersToCarrier:(CALayer *)carrier {
    if (!carrier) return;
    NSMutableArray<CAGradientLayer *> *layers = [NSMutableArray array];
    for (CALayer *layer in self.layer.sublayers.copy) {
        if ([layer isKindOfClass:CAGradientLayer.class]) {
            [layers addObject:(CAGradientLayer *)layer];
        }
    }
    for (CAGradientLayer *layer in _lgIslandRimLayers) {
        if (layer && ![layers containsObject:layer]) [layers addObject:layer];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (CAGradientLayer *layer in layers) {
        if (layer.superlayer != carrier) [carrier addSublayer:layer];
    }
    [CATransaction commit];
    _lgIslandRimLayers = layers.copy;
}

- (void)lgSetRimRenderingSuppressed:(BOOL)suppressed {
    if (_lgRimRenderingSuppressed == suppressed) return;
    _lgRimRenderingSuppressed = suppressed;
    if (!_lgRimOriginalOpacities) {
        _lgRimOriginalOpacities = [NSMapTable weakToStrongObjectsMapTable];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    NSArray<CALayer *> *layers = _lgIslandRimLayers.count
        ? (NSArray<CALayer *> *)_lgIslandRimLayers
        : self.layer.sublayers.copy;
    for (CALayer *layer in layers) {
        if (![layer isKindOfClass:CAGradientLayer.class]) continue;
        NSNumber *original = [_lgRimOriginalOpacities objectForKey:layer];
        if (suppressed) {
            if (!original) {
                [_lgRimOriginalOpacities setObject:@(layer.opacity) forKey:layer];
            }
            layer.opacity = 0.0;
        } else {
            layer.opacity = original ? original.floatValue : 1.0;
            [_lgRimOriginalOpacities removeObjectForKey:layer];
        }
    }
    [CATransaction commit];
}
@end

static void LGRefreshAllIslands(void);
extern void LGIslandPublishTextAppearance(UIWindow *window, BOOL glassActive);

static UIView *LGIslandViewIvar(id host, const char *name) {
    Ivar ivar = class_getInstanceVariable([host class], name);
    id value = ivar ? object_getIvar(host, ivar) : nil;
    return [value isKindOfClass:UIView.class] ? value : nil;
}

static BOOL LGIslandEnabled(void) {
    return LG_globalEnabled() && LG_prefBool(@"DynamicIsland.Enabled", NO);
}

static void LGInstallIslandNativeGainMap(void) {
    if (!sLGIslandProxyGainMaps || sLGIslandNativeGainMap) return;
    UIWindow *rootWindow = nil;
    Class rootClass = NSClassFromString(@"SBRootSceneWindow");
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (rootClass && [window isKindOfClass:rootClass]) {
            rootWindow = window;
            break;
        }
    }
    Class viewClass = NSClassFromString(@"_SBGainMapView");
    if (!rootWindow || !viewClass) return;
    UIView *keepalive = nil;
    sLGIslandCreatingNativeGainMap = YES;
    @try {
        keepalive = [[viewClass alloc] initWithFrame:CGRectMake(-2, -2, 1, 1)];
    } @finally {
        sLGIslandCreatingNativeGainMap = NO;
    }
    if (!keepalive) return;
    keepalive.backgroundColor = UIColor.clearColor;
    keepalive.userInteractionEnabled = NO;
    keepalive.accessibilityElementsHidden = YES;
    if ([keepalive.layer respondsToSelector:@selector(setDisableUpdateMask:)]) {
        keepalive.layer.disableUpdateMask |= 18;
    }
    sLGIslandNativeGainMap = keepalive;
    [rootWindow addSubview:keepalive];
}

static BOOL LGIslandFollowsSystemIdleState(void) {
    return LG_prefBool(@"DynamicIsland.HideWhenInactive", YES);
}

static NSMutableDictionary *LGIslandCurtainState(UIView *view) {
    if (!sLGIslandCurtains) {
        sLGIslandCurtains = [NSMapTable weakToStrongObjectsMapTable];
    }
    NSMutableDictionary *state = [sLGIslandCurtains objectForKey:view];
    if (!state) {
        state = [@{@"hidden": @(view.hidden), @"alpha": @(view.alpha)} mutableCopy];
        [sLGIslandCurtains setObject:state forKey:view];
    }
    return state;
}

static void LGApplyIslandCurtain(UIView *view) {
    if (!view) return;
    NSMutableDictionary *state = LGIslandCurtainState(view);
    BOOL enabled = LGIslandEnabled();
    sLGIslandUpdatingCurtains = YES;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    view.hidden = enabled ? YES : [state[@"hidden"] boolValue];
    view.alpha = enabled ? 0.0 : [state[@"alpha"] doubleValue];
    [CATransaction commit];
    sLGIslandUpdatingCurtains = NO;
}

static BOOL LGIslandLayerIsSettled(CALayer *model) {
    if (!model) return YES;
    CALayer *visible = model.presentationLayer;
    if (model.animationKeys.count > 0) return NO;
    if (!visible) return YES;
    CGRect a = visible.bounds, b = model.bounds;
    CGPoint p = visible.position, q = model.position;
    if (fabs(a.origin.x - b.origin.x) > 0.05
        || fabs(a.origin.y - b.origin.y) > 0.05
        || fabs(a.size.width - b.size.width) > 0.05
        || fabs(a.size.height - b.size.height) > 0.05
        || fabs(p.x - q.x) > 0.05 || fabs(p.y - q.y) > 0.05
        || fabs(visible.cornerRadius - model.cornerRadius) > 0.05) return NO;
    CATransform3D x = visible.transform, y = model.transform;
    const CGFloat *vx = (const CGFloat *)&x, *vy = (const CGFloat *)&y;
    for (NSUInteger i = 0; i < 16; i++) {
        if (fabs(vx[i] - vy[i]) > 0.0001) return NO;
    }
    return YES;
}

@class LGIslandGlassDriver;
@interface LGIslandDisplayTarget : NSObject
@property (nonatomic, weak) LGIslandGlassDriver *driver;
- (void)tick:(CADisplayLink *)link;
@end

@interface LGIslandGlassDriver : NSObject
@property (nonatomic, weak) UIView *container;
@property (nonatomic, weak) UIView *clipHost;
@property (nonatomic, weak) UIView *fill;
@property (nonatomic, weak) UIView *gainMap;
@property (nonatomic) BOOL fillHidden;
@property (nonatomic) BOOL gainMapHidden;
@property (nonatomic) CGFloat fillAlpha;
@property (nonatomic) CGFloat gainMapAlpha;
@property (nonatomic, strong) LGIslandBackdropView *glass;
@property (nonatomic, strong) UIView *rimHost;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic) NSUInteger settledFrames;
@property (nonatomic) NSUInteger minimumTrackingFrames;
@property (nonatomic) CGRect targetBounds;
@property (nonatomic) CGFloat targetRadius;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *stockEdges;
- (void)refresh;
- (void)tick;
- (void)restore;
- (void)suppressStockEdges;
- (void)restoreStockEdges;
@end

@implementation LGIslandDisplayTarget
- (void)tick:(CADisplayLink *)link {
    LGIslandGlassDriver *driver = self.driver;
    if (driver) [driver tick];
    else [link invalidate];
}
@end

@implementation LGIslandGlassDriver

- (void)restoreStockEdges {
    for (NSDictionary *entry in self.stockEdges.allValues) {
        UIView *view = entry[@"view"];
        view.hidden = [entry[@"hidden"] boolValue];
    }
    [self.stockEdges removeAllObjects];
}

- (void)suppressStockEdges {
    if (!self.stockEdges) self.stockEdges = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"_lightBkgKeyLineView", @"_darkBkgKeyLineView", @"_shadowView"]) {
        UIView *view = LGIslandViewIvar(self.container, key.UTF8String);
        NSDictionary *saved = self.stockEdges[key];
        if (saved[@"view"] != view) {
            UIView *previous = saved[@"view"];
            previous.hidden = [saved[@"hidden"] boolValue];
            [self.stockEdges removeObjectForKey:key];
            if (view) {
                self.stockEdges[key] = @{@"view": view, @"hidden": @(view.hidden)};
            }
        }
        view.hidden = YES;
    }
}

- (void)restore {
    [self.displayLink invalidate];
    self.displayLink = nil;
    self.fill.hidden = self.fillHidden;
    self.gainMap.hidden = self.gainMapHidden;
    self.fill.alpha = self.fillAlpha;
    self.gainMap.alpha = self.gainMapAlpha;
    self.clipHost = nil;
    self.fill = nil;
    self.gainMap = nil;
    [self restoreStockEdges];
    [self.glass removeFromSuperview];
    self.glass = nil;
    [self.rimHost removeFromSuperview];
    self.rimHost = nil;
    self.targetBounds = CGRectNull;
}

- (void)dealloc {
    [_displayLink invalidate];
    _fill.hidden = _fillHidden;
    _gainMap.hidden = _gainMapHidden;
    _fill.alpha = _fillAlpha;
    _gainMap.alpha = _gainMapAlpha;
    for (NSDictionary *entry in _stockEdges.allValues) {
        UIView *view = entry[@"view"];
        view.hidden = [entry[@"hidden"] boolValue];
    }
    [_rimHost removeFromSuperview];
    [_glass removeFromSuperview];
}

- (void)refresh {
    UIView *container = self.container;
    UIView *fill = LGIslandViewIvar(container, "_blobEnablingBlackFillView");
    UIView *gain = LGIslandViewIvar(container, "_gainMapView");
    UIView *group = LGIslandViewIvar(container, "_backgroundGroupingView");
    UIView *clip = LGIslandViewIvar(container, "_contentClippingView");
    if (!LGIslandEnabled() || !container.window || !fill || !gain || !group || !clip
        || fill.superview != group || ![clip isDescendantOfView:container]
        || CGRectIsEmpty(clip.bounds)) {
        [self restore];
        return;
    }
    if (self.fill != fill || self.gainMap != gain || self.clipHost != clip
        || self.glass.superview != clip || self.rimHost.superview != group) {
        [self restore];
        NSString *filterType = LGFilterTypeForHostPrefix(@"DynamicIsland");
        LGIslandBackdropView *glass = filterType.length
            ? [[LGIslandBackdropView alloc] initWithFrame:clip.bounds
                                               groupName:nil
                                              filterType:filterType]
            : nil;
        if (!glass) return;
        self.clipHost = clip;
        self.fill = fill;
        self.gainMap = gain;
        self.fillHidden = fill.hidden;
        self.gainMapHidden = gain.hidden;
        self.fillAlpha = fill.alpha;
        self.gainMapAlpha = gain.alpha;
        self.glass = glass;
        UIView *rimHost = [[UIView alloc] initWithFrame:CGRectZero];
        rimHost.userInteractionEnabled = NO;
        rimHost.accessibilityElementsHidden = YES;
        rimHost.backgroundColor = UIColor.clearColor;
        self.rimHost = rimHost;
        self.targetBounds = CGRectNull;
        glass.userInteractionEnabled = NO;
        glass.accessibilityElementsHidden = YES;
        glass.backgroundColor = UIColor.clearColor;
        glass.lgIslandLayoutEnabled = YES;
        [clip insertSubview:glass atIndex:0];
        [group addSubview:rimHost];
        [glass setNeedsLayout];
        [glass layoutIfNeeded];
        glass.lgIslandLayoutEnabled = NO;
        [glass lgAttachRimLayersToCarrier:rimHost.layer];
        lgTrackGlass(glass, @"DynamicIsland", nil);
    }

    CGFloat radius = MAX(0.0, MIN(fill.layer.cornerRadius,
        MIN(CGRectGetWidth(clip.bounds), CGRectGetHeight(clip.bounds)) * 0.5));
    BOOL geometryChanged = !CGRectEqualToRect(self.targetBounds, clip.bounds)
        || fabs(self.targetRadius - radius) > 0.05;
    if (geometryChanged) [self.glass lgSetRimRenderingSuppressed:YES];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.glass.frame = clip.bounds;
    self.glass.bounds = clip.bounds;
    self.glass.layer.cornerRadius = radius;
    self.glass.layer.cornerCurve = fill.layer.cornerCurve;
    self.glass.layer.masksToBounds = YES;
    fill.hidden = YES;
    fill.alpha = 0.0;
    gain.hidden = YES;
    gain.alpha = 0.0;
    [self suppressStockEdges];
    CGRect rimFrame = [group convertRect:clip.bounds fromView:clip];
    self.rimHost.frame = rimFrame;
    self.rimHost.bounds = clip.bounds;
    self.rimHost.layer.cornerRadius = radius;
    [CATransaction commit];
    if (geometryChanged) {
        self.targetBounds = clip.bounds;
        self.targetRadius = radius;
        self.settledFrames = 0;
    }
    if (!self.displayLink) {
        LGIslandDisplayTarget *target = [LGIslandDisplayTarget new];
        target.driver = self;
        self.displayLink = [CADisplayLink displayLinkWithTarget:target selector:@selector(tick:)];
        self.displayLink.preferredFramesPerSecond = 60;
        [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
    self.displayLink.paused = NO;
    [self tick];
}

- (void)tick {
    UIView *container = self.container;
    UIView *fill = self.fill;
    UIView *clip = self.clipHost;
    UIView *group = LGIslandViewIvar(container, "_backgroundGroupingView");
    if (!LGIslandEnabled() || !container.window || !fill.superview || !clip.superview
        || !group.superview || self.glass.superview != clip
        || self.rimHost.superview != group) {
        [self restore];
        return;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    fill.hidden = YES;
    fill.alpha = 0.0;
    self.gainMap.hidden = YES;
    self.gainMap.alpha = 0.0;
    [self suppressStockEdges];
    BOOL rimHidden = NO;
    CGFloat rimOpacity = 1.0;
    for (UIView *ancestor = group; ancestor; ancestor = ancestor.superview) {
        rimHidden = rimHidden || ancestor.hidden;
        CALayer *visibleAncestor = ancestor.layer.presentationLayer ?: ancestor.layer;
        rimOpacity *= visibleAncestor.opacity;
    }
    if (LGIslandFollowsSystemIdleState()) {
        rimHidden = rimHidden || clip.hidden;
        CALayer *visibleClip = clip.layer.presentationLayer ?: clip.layer;
        rimOpacity *= visibleClip.opacity;
    }
    self.glass.hidden = NO;
    self.glass.layer.opacity = 1.0;
    self.rimHost.hidden = rimHidden;
    self.rimHost.layer.opacity = rimOpacity;
    [CATransaction commit];
    BOOL moving = !LGIslandLayerIsSettled(group.layer)
        || !LGIslandLayerIsSettled(clip.layer)
        || !LGIslandLayerIsSettled(fill.layer)
        || !LGIslandLayerIsSettled(container.layer);
    if (moving) {
        self.settledFrames = 0;
        return;
    }
    if (self.minimumTrackingFrames > 0) self.minimumTrackingFrames--;
    self.settledFrames++;
    if (self.settledFrames == 4) {
        self.glass.lgIslandLayoutEnabled = YES;
        [self.glass setNeedsLayout];
        [self.glass layoutIfNeeded];
        self.glass.lgIslandLayoutEnabled = NO;
        [self.glass lgAttachRimLayersToCarrier:self.rimHost.layer];
        [self.glass lgSetRimRenderingSuppressed:NO];
    }
    if (self.settledFrames < 4 || self.minimumTrackingFrames > 0) return;

    self.displayLink.paused = YES;
}

@end

static void LGRefreshIsland(UIView *container) {
    if (!container) return;
    LGInstallIslandNativeGainMap();
    if (!sLGIslandContainers) sLGIslandContainers = [NSHashTable weakObjectsHashTable];
    [sLGIslandContainers addObject:container];
    LGIslandGlassDriver *driver = objc_getAssociatedObject(container, &kLGIslandDriverKey);
    if (!driver && LGIslandEnabled() && container.window) {
        driver = [LGIslandGlassDriver new];
        driver.container = container;
        objc_setAssociatedObject(container, &kLGIslandDriverKey, driver,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [driver refresh];
    UIWindow *window = container.window;
    BOOL glassActive = NO;
    for (UIView *known in sLGIslandContainers.allObjects) {
        LGIslandGlassDriver *knownDriver = objc_getAssociatedObject(known, &kLGIslandDriverKey);
        if (known.window && knownDriver.glass.superview) {
            window = known.window;
            glassActive = YES;
            break;
        }
    }
    LGIslandPublishTextAppearance(window, LGIslandEnabled() && glassActive);
}

static void LGRefreshAllIslands(void) {
    LGInstallIslandNativeGainMap();
    for (UIView *curtain in sLGIslandCurtains.keyEnumerator.allObjects) {
        LGApplyIslandCurtain(curtain);
    }
    for (UIView *container in sLGIslandContainers.allObjects) {
        LGRefreshIsland(container);
    }
    if (!LGIslandEnabled()) {
        for (UIView *shadow in sLGIslandTransitionShadows.keyEnumerator.allObjects) {
            shadow.hidden = [[sLGIslandTransitionShadows objectForKey:shadow] boolValue];
        }
        [sLGIslandTransitionShadows removeAllObjects];
    }
}

static void LGWakeIslandVisibilityTracking(void) {
    LGRefreshAllIslands();
    for (UIView *container in sLGIslandContainers.allObjects) {
        LGIslandGlassDriver *driver = objc_getAssociatedObject(
            container, &kLGIslandDriverKey);
        if (!driver.displayLink) continue;
        driver.minimumTrackingFrames = MAX(driver.minimumTrackingFrames, 90);
        driver.displayLink.paused = NO;
    }
}

static void LGUpdateIslandTransitionShadow(UIViewController *controller) {
    UIView *shadow = LGIslandViewIvar(controller, "_contentsTransitionShadowView");
    if (!shadow) return;
    if (!LGIslandEnabled() || !controller.isViewLoaded
        || !hasAncestorOfClassName(controller.view, @"SBSystemApertureContainerView")) {
        NSNumber *original = [sLGIslandTransitionShadows objectForKey:shadow];
        if (original) shadow.hidden = original.boolValue;
        [sLGIslandTransitionShadows removeObjectForKey:shadow];
        return;
    }
    if (!sLGIslandTransitionShadows) {
        sLGIslandTransitionShadows = [NSMapTable weakToStrongObjectsMapTable];
    }
    if (![sLGIslandTransitionShadows objectForKey:shadow]) {
        [sLGIslandTransitionShadows setObject:@(shadow.hidden) forKey:shadow];
    }
    shadow.hidden = YES;
}

%group LGIslandTransitionShadowLifecycle
%hook SAUILayoutSpecifyingElementViewController
- (void)_configureTransitionShadowViewIfNecessary {
    %orig;
    LGUpdateIslandTransitionShadow((UIViewController *)self);
}
%end
%end

%group LGIslandTransitionShadowLayoutLifecycle
%hook SAUILayoutSpecifyingElementViewController
- (void)_layoutTransitionShadowView {
    %orig;
    LGUpdateIslandTransitionShadow((UIViewController *)self);
}
%end
%end

%group LGIslandLegacyTransitionShadowLayoutLifecycle
%hook SAUILayoutSpecifyingElementViewController
- (void)viewDidLayoutSubviews {
    %orig;
    LGUpdateIslandTransitionShadow((UIViewController *)self);
}
%end
%end

static BOOL LGIslandGainMapIsBackground(UIView *view) {
    return hasAncestorOfClassName(view, @"_SBSystemApertureMagiciansCurtainView")
        || hasAncestorOfClassName(view, @"_SBSystemApertureGainMapView");
}

%group LGIslandActivityWakeLifecycle
%hook SBSystemApertureController
- (void)systemApertureViewController:(id)controller containsAnyContent:(BOOL)containsContent {
    %orig(controller, containsContent);
    void (^wake)(void) = ^{
        LGWakeIslandVisibilityTracking();
    };
    if (NSThread.isMainThread) wake();
    else dispatch_async(dispatch_get_main_queue(), wake);
}
%end
%end

%group LGIslandCurtainLifecycle
%hook _SBSystemApertureMagiciansCurtainView
- (void)didMoveToWindow {
    %orig;
    LGApplyIslandCurtain((UIView *)self);
}
- (void)layoutSubviews {
    %orig;
    LGApplyIslandCurtain((UIView *)self);
}
- (void)setHidden:(BOOL)hidden {
    if (!sLGIslandUpdatingCurtains) {
        LGIslandCurtainState((UIView *)self)[@"hidden"] = @(hidden);
    }
    %orig(LGIslandEnabled() ? YES : hidden);
}
- (void)setAlpha:(CGFloat)alpha {
    if (!sLGIslandUpdatingCurtains) {
        LGIslandCurtainState((UIView *)self)[@"alpha"] = @(alpha);
    }
    %orig(LGIslandEnabled() ? 0.0 : alpha);
}
%end
%end

%group LGIslandGainMapLifecycle
%hook _SBGainMapView
+ (Class)layerClass {
    if (sLGIslandProxyGainMaps && !sLGIslandCreatingNativeGainMap) {
        return LGIslandGainMapLayer.class;
    }
    return %orig;
}
- (void)didMoveToSuperview {
    %orig;
    if (LGIslandGainMapIsBackground((UIView *)self)) {
        LGApplyIslandCurtain((UIView *)self);
    }
}
- (void)layoutSubviews {
    %orig;
    if (LGIslandGainMapIsBackground((UIView *)self)) {
        LGApplyIslandCurtain((UIView *)self);
    }
}
- (void)setHidden:(BOOL)hidden {
    BOOL tracked = LGIslandGainMapIsBackground((UIView *)self);
    if (tracked && !sLGIslandUpdatingCurtains) {
        LGIslandCurtainState((UIView *)self)[@"hidden"] = @(hidden);
    }
    %orig(tracked && LGIslandEnabled() ? YES : hidden);
}
- (void)setAlpha:(CGFloat)alpha {
    BOOL tracked = LGIslandGainMapIsBackground((UIView *)self);
    if (tracked && !sLGIslandUpdatingCurtains) {
        LGIslandCurtainState((UIView *)self)[@"alpha"] = @(alpha);
    }
    %orig(tracked && LGIslandEnabled() ? 0.0 : alpha);
}
%end
%end

%group LGIslandNativeGainMapLifecycle
%hook SpringBoard
- (void)applicationDidFinishLaunching:(UIApplication *)application {
    %orig(application);
    LGInstallIslandNativeGainMap();
}
%end
%end

%group LGDynamicIslandLifecycle
%hook SBSystemApertureContainerView
- (void)didMoveToWindow {
    %orig;
    LGRefreshIsland((UIView *)self);
}
- (void)layoutSubviews {
    %orig;
    LGRefreshIsland((UIView *)self);
}
- (void)setHidden:(BOOL)hidden {
    %orig(hidden);
    LGRefreshIsland((UIView *)self);
}
- (void)setAlpha:(CGFloat)alpha {
    %orig(alpha);
    LGRefreshIsland((UIView *)self);
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    %orig(previous);
    LGRefreshIsland((UIView *)self);
}
%end
%end

%ctor {
    if (!LGIsSpringBoardProcess()) return;
    // iOS 16.3 (20D47) already has this container and all four backing views.
    // Keep capability checks: an incomplete layout must not hide native gain maps.
    if (@available(iOS 16.0, *)) {
        Class containerClass = NSClassFromString(@"SBSystemApertureContainerView");
        if (containerClass
            && class_getInstanceVariable(containerClass, "_blobEnablingBlackFillView")
            && class_getInstanceVariable(containerClass, "_gainMapView")
            && class_getInstanceVariable(containerClass, "_backgroundGroupingView")
            && class_getInstanceVariable(containerClass, "_contentClippingView")) {
            sLGIslandProxyGainMaps = LGIslandEnabled();
            %init(LGDynamicIslandLifecycle);
            if (sLGIslandProxyGainMaps) {
                %init(LGIslandNativeGainMapLifecycle);
            }
            Class shadowController = NSClassFromString(@"SAUILayoutSpecifyingElementViewController");
            if (class_getInstanceMethod(shadowController,
                    @selector(_configureTransitionShadowViewIfNecessary))) {
                %init(LGIslandTransitionShadowLifecycle);
                if (class_getInstanceMethod(shadowController,
                        @selector(_layoutTransitionShadowView))) {
                    %init(LGIslandTransitionShadowLayoutLifecycle);
                } else if (class_getInstanceMethod(shadowController,
                        @selector(viewDidLayoutSubviews))) {
                    // iOS 16 has no dedicated shadow-layout selector.
                    %init(LGIslandLegacyTransitionShadowLayoutLifecycle);
                }
            }
            if (NSClassFromString(@"_SBSystemApertureMagiciansCurtainView")) {
                %init(LGIslandCurtainLifecycle);
            }
            if (NSClassFromString(@"_SBGainMapView")) {
                %init(LGIslandGainMapLifecycle);
            }
            Class controllerClass = NSClassFromString(@"SBSystemApertureController");
            if (class_getInstanceMethod(controllerClass,
                    @selector(systemApertureViewController:containsAnyContent:))) {
                %init(LGIslandActivityWakeLifecycle);
            }
            lgObservePreferenceReload(^{
                LGRefreshAllIslands();
            });
        }
    }
}
