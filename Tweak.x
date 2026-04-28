#import "LiquidGlass.h"
#import <dlfcn.h>
#import <objc/runtime.h>
#import <fcntl.h>
#import <unistd.h>
#import "Runtime/LGLiquidGlassRuntime.h"
#import "Runtime/LGSnapshotCaptureSupport.h"
#if LIQUIDASS_STANDALONE_UI
#import "LiquidAssPrefs/LGPRootListController.h"
extern NSString * const kLGStandaloneSettingsDismissedNotification;
#endif

static BOOL LG_isAtLeastiOS16(void);
static CFStringRef const LGInvalidateSnapshotCachesNotification = CFSTR("love.litten.liquidass/InvalidateSnapshotCaches");
void LGRefreshLockSnapshotAfterDelay(NSTimeInterval delay);

typedef NS_OPTIONS(NSUInteger, SBSRelaunchActionOptions) {
    SBSRelaunchActionOptionsNone = 0,
    SBSRelaunchActionOptionsRestartRenderServer = 1 << 0,
    SBSRelaunchActionOptionsSnapshotTransition = 1 << 1,
    SBSRelaunchActionOptionsFadeToBlackTransition = 1 << 2,
};

@interface SBSRelaunchAction : NSObject
+ (instancetype)actionWithReason:(NSString *)reason options:(SBSRelaunchActionOptions)options targetURL:(NSURL *)targetURL;
@end

@interface FBSSystemService : NSObject
+ (instancetype)sharedService;
- (void)sendActions:(NSSet *)actions withResult:(id)result;
@end

@interface UIView (LGHierarchyCapture)
- (BOOL)drawHierarchyInRect:(CGRect)rect afterScreenUpdates:(BOOL)afterUpdates;
@end

@interface PBUISnapshotReplicaView : UIView
@end

#if LIQUIDASS_STANDALONE_UI
@interface LGStandaloneButtonWindow : UIWindow
@property (nonatomic, weak) UIView *interactiveView;
@end

@implementation LGStandaloneButtonWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *targetView = self.interactiveView;
    if (!targetView || self.hidden || !self.userInteractionEnabled) {
        return nil;
    }
    CGPoint convertedPoint = [targetView convertPoint:point fromView:self];
    UIView *hitView = [targetView hitTest:convertedPoint withEvent:event];
    return hitView ?: nil;
}

@end

@interface LGStandaloneMenuButton : UIButton
@property (nonatomic, copy) void (^tapHandler)(void);
@end

@implementation LGStandaloneMenuButton {
    CGPoint _dragStartCenter;
    CGPoint _dragStartPoint;
    BOOL _dragging;
    LiquidGlassView *_glassView;
    UIView *_tintView;
    UIView *_rimView;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.backgroundColor = UIColor.clearColor;
    self.layer.cornerRadius = CGRectGetWidth(frame) * 0.5;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.masksToBounds = NO;
    self.layer.shadowColor = [UIColor.blackColor colorWithAlphaComponent:0.28].CGColor;
    self.layer.shadowOpacity = 1.0;
    self.layer.shadowRadius = 18.0;
    self.layer.shadowOffset = CGSizeMake(0.0, 10.0);

    CGPoint backdropOrigin = CGPointZero;
    UIImage *backdrop = LG_getHomescreenSnapshot(&backdropOrigin);
    if (!backdrop) {
        backdrop = LG_getWallpaperImage(&backdropOrigin);
    }

    _glassView = [[LiquidGlassView alloc] initWithFrame:self.bounds wallpaper:backdrop wallpaperOrigin:backdropOrigin];
    _glassView.userInteractionEnabled = NO;
    _glassView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _glassView.cornerRadius = CGRectGetWidth(frame) * 0.5;
    _glassView.bezelWidth = 12.0;
    _glassView.glassThickness = 42.0;
    _glassView.refractionScale = 1.35;
    _glassView.refractiveIndex = 1.45;
    _glassView.specularOpacity = 0.16;
    _glassView.blur = 2.0;
    _glassView.wallpaperScale = 1.0;
    _glassView.releasesWallpaperAfterUpload = NO;
    if (_glassView) {
        [self insertSubview:_glassView atIndex:0];
    }

    _tintView = [[UIView alloc] initWithFrame:CGRectZero];
    _tintView.userInteractionEnabled = NO;
    _tintView.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull trait) {
        if (trait.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithWhite:1.0 alpha:0.07];
        }
        return [UIColor colorWithWhite:1.0 alpha:0.13];
    }];
    [self addSubview:_tintView];

    _rimView = [[UIView alloc] initWithFrame:CGRectZero];
    _rimView.userInteractionEnabled = NO;
    _rimView.backgroundColor = UIColor.clearColor;
    _rimView.layer.cornerCurve = kCACornerCurveContinuous;
    _rimView.layer.borderWidth = 0.75;
    _rimView.layer.borderColor = [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull trait) {
        if (trait.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithWhite:1.0 alpha:0.26];
        }
        return [UIColor colorWithWhite:1.0 alpha:0.62];
    }].CGColor;
    [self addSubview:_rimView];

    self.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightHeavy];
    self.titleLabel.numberOfLines = 2;
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.titleLabel.minimumScaleFactor = 0.55;
    self.contentEdgeInsets = UIEdgeInsetsMake(10.0, 8.0, 10.0, 8.0);
    [self setTitle:@"Liquid\nAss" forState:UIControlStateNormal];
    [self setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    [self addTarget:self action:@selector(handleTouchUpInside) forControlEvents:UIControlEventTouchUpInside];
    return self;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self refreshGlassBackdrop];
}

- (void)refreshGlassBackdrop {
    if (!_glassView || !self.window) return;
    CGPoint backdropOrigin = CGPointZero;
    UIImage *backdrop = LG_getHomescreenSnapshot(&backdropOrigin);
    if (!backdrop) {
        backdrop = LG_getWallpaperImage(&backdropOrigin);
    }
    if (backdrop) {
        _glassView.wallpaperImage = backdrop;
        _glassView.wallpaperOrigin = backdropOrigin;
    }
    [_glassView updateOrigin];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat radius = CGRectGetWidth(self.bounds) * 0.5;
    self.layer.cornerRadius = radius;
    self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:radius].CGPath;

    _glassView.frame = self.bounds;
    _glassView.cornerRadius = radius;
    _glassView.bezelWidth = 12.0;
    _glassView.glassThickness = 42.0;
    _glassView.refractionScale = 1.35;
    _glassView.refractiveIndex = 1.45;
    _glassView.specularOpacity = 0.16;
    _glassView.blur = 2.0;
    [_glassView updateOrigin];

    _tintView.frame = self.bounds;
    _tintView.layer.cornerRadius = radius;
    _tintView.layer.cornerCurve = kCACornerCurveContinuous;

    CGFloat inset = 1.0;
    _rimView.frame = CGRectInset(self.bounds, inset, inset);
    _rimView.layer.cornerRadius = MAX(0.0, radius - inset);

    [self sendSubviewToBack:_glassView];
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    _tintView.alpha = highlighted ? 0.70 : 1.0;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    UITouch *touch = touches.anyObject;
    if (!touch) return;
    _dragging = NO;
    _dragStartCenter = self.center;
    _dragStartPoint = [touch locationInView:self.window];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesMoved:touches withEvent:event];
    UITouch *touch = touches.anyObject;
    if (!touch) return;
    CGPoint currentPoint = [touch locationInView:self.window];
    CGFloat deltaX = currentPoint.x - _dragStartPoint.x;
    CGFloat deltaY = currentPoint.y - _dragStartPoint.y;
    if (!_dragging && hypot(deltaX, deltaY) > 6.0) {
        _dragging = YES;
    }
    if (!_dragging) return;
    self.center = CGPointMake(_dragStartCenter.x + deltaX, _dragStartCenter.y + deltaY);
    [_glassView updateOrigin];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    if (_dragging) {
        [self snapToEdgeAnimated:YES];
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    if (_dragging) {
        [self snapToEdgeAnimated:YES];
    }
}

- (void)handleTouchUpInside {
    if (_dragging) return;
    if (self.tapHandler) self.tapHandler();
}

- (void)snapToEdgeAnimated:(BOOL)animated {
    UIWindow *window = self.window;
    if (!window) return;
    CGRect bounds = window.bounds;
    UIEdgeInsets insets = window.safeAreaInsets;
    CGFloat margin = 18.0;
    CGFloat halfWidth = CGRectGetWidth(self.bounds) * 0.5;
    CGFloat halfHeight = CGRectGetHeight(self.bounds) * 0.5;
    CGFloat minX = insets.left + margin + halfWidth;
    CGFloat maxX = CGRectGetWidth(bounds) - insets.right - margin - halfWidth;
    CGFloat minY = insets.top + margin + halfHeight;
    CGFloat maxY = CGRectGetHeight(bounds) - insets.bottom - margin - halfHeight;
    CGPoint targetCenter = self.center;
    targetCenter.x = (targetCenter.x <= CGRectGetMidX(bounds)) ? minX : maxX;
    targetCenter.y = fmax(minY, fmin(maxY, targetCenter.y));
    void (^animations)(void) = ^{
        self.center = targetCenter;
        [self->_glassView updateOrigin];
    };
    if (animated) {
        [UIView animateWithDuration:0.22 delay:0.0 usingSpringWithDamping:0.9 initialSpringVelocity:0.0 options:UIViewAnimationOptionCurveEaseOut animations:animations completion:nil];
    } else {
        animations();
    }
}

@end

@interface LGStandalonePresentationObserver : NSObject <UIAdaptivePresentationControllerDelegate>
@property (nonatomic, copy) dispatch_block_t onDismiss;
@end

@implementation LGStandalonePresentationObserver

- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    (void)presentationController;
    if (self.onDismiss) self.onDismiss();
}

@end

@interface LGStandalonePanelHostController : UIViewController
@end

@implementation LGStandalonePanelHostController

- (void)loadView {
    UIView *view = [[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    view.backgroundColor = UIColor.clearColor;
    self.view = view;
}

@end

static LGStandaloneButtonWindow *sLGStandaloneButtonWindow = nil;
static UIWindow *sLGStandalonePanelWindow = nil;
static LGStandalonePanelHostController *sLGStandalonePanelHostController = nil;
static LGStandaloneMenuButton *sLGStandaloneMenuButton = nil;
static LGStandalonePresentationObserver *sLGStandalonePresentationObserver = nil;
static __weak UIViewController *sLGStandalonePresentedController = nil;
#define LG_STANDALONE_BUTTON_WINDOW_LEVEL (UIWindowLevelAlert + 500.0)
#define LG_STANDALONE_PANEL_WINDOW_LEVEL (UIWindowLevelAlert + 600.0)

static UIWindowScene *LG_activeStandaloneScene(void) {
    static Class sceneClass;
    if (!sceneClass) sceneClass = [UIWindowScene class];
    UIWindowScene *fallbackScene = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:sceneClass]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (!fallbackScene) fallbackScene = windowScene;
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            return windowScene;
        }
    }
    return fallbackScene;
}

static void LG_showStandaloneMenuButton(void);

static void LG_restoreStandaloneMenuButton(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (sLGStandalonePanelWindow) {
            sLGStandalonePanelWindow.hidden = YES;
            sLGStandalonePanelWindow.rootViewController = nil;
            sLGStandalonePanelWindow = nil;
            sLGStandalonePanelHostController = nil;
        }
        if (!sLGStandaloneButtonWindow) return;
        sLGStandaloneButtonWindow.hidden = NO;
        sLGStandaloneButtonWindow.userInteractionEnabled = YES;
        [sLGStandaloneButtonWindow makeKeyAndVisible];
        [sLGStandaloneButtonWindow resignKeyWindow];
    });
}

static void LG_hideStandaloneMenuButton(void) {
    if (!sLGStandaloneButtonWindow) return;
    sLGStandaloneButtonWindow.userInteractionEnabled = NO;
    [sLGStandaloneButtonWindow resignKeyWindow];
    sLGStandaloneButtonWindow.hidden = YES;
}

static void LG_presentStandaloneSettings(void) {
    UIWindowScene *scene = LG_activeStandaloneScene();
    if (!scene || sLGStandalonePresentedController) {
        return;
    }

    LG_hideStandaloneMenuButton();

    if (sLGStandalonePanelWindow) {
        sLGStandalonePanelWindow.hidden = YES;
        sLGStandalonePanelWindow.rootViewController = nil;
        sLGStandalonePanelWindow = nil;
        sLGStandalonePanelHostController = nil;
    }

    sLGStandalonePanelWindow = [[UIWindow alloc] initWithWindowScene:scene];
    sLGStandalonePanelWindow.backgroundColor = UIColor.clearColor;
    sLGStandalonePanelWindow.windowLevel = LG_STANDALONE_PANEL_WINDOW_LEVEL;
    sLGStandalonePanelHostController = [LGStandalonePanelHostController new];
    sLGStandalonePanelWindow.rootViewController = sLGStandalonePanelHostController;
    [sLGStandalonePanelWindow makeKeyAndVisible];

    LGPRootListController *rootPrefsController = [[LGPRootListController alloc] init];
    UINavigationController *navigationController = [[UINavigationController alloc] initWithRootViewController:rootPrefsController];
    navigationController.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = navigationController.sheetPresentationController;
        if (sheet) {
            sheet.detents = @[[UISheetPresentationControllerDetent mediumDetent], [UISheetPresentationControllerDetent largeDetent]];
            sheet.prefersGrabberVisible = YES;
            sheet.preferredCornerRadius = 30.0;
        }
    }

    sLGStandalonePresentationObserver = [LGStandalonePresentationObserver new];
    sLGStandalonePresentationObserver.onDismiss = ^{
        sLGStandalonePresentedController = nil;
        sLGStandalonePresentationObserver = nil;
        LG_restoreStandaloneMenuButton();
    };
    navigationController.presentationController.delegate = sLGStandalonePresentationObserver;
    sLGStandalonePresentedController = navigationController;
    [sLGStandalonePanelHostController presentViewController:navigationController animated:YES completion:nil];
}

static void LG_configureStandaloneMenuButtonFrame(void) {
    if (!sLGStandaloneButtonWindow || !sLGStandaloneMenuButton) return;
    CGRect bounds = sLGStandaloneButtonWindow.bounds;
    UIEdgeInsets insets = sLGStandaloneButtonWindow.safeAreaInsets;
    CGFloat size = 64.0;
    CGFloat x = CGRectGetWidth(bounds) - insets.right - size - 18.0;
    CGFloat y = insets.top + 120.0;
    sLGStandaloneMenuButton.frame = CGRectMake(x, y, size, size);
    [sLGStandaloneMenuButton snapToEdgeAnimated:NO];
}

static void LG_showStandaloneMenuButton(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindowScene *scene = LG_activeStandaloneScene();
        if (!scene) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                LG_showStandaloneMenuButton();
            });
            return;
        }
        if (!sLGStandaloneButtonWindow) {
            sLGStandaloneButtonWindow = [[LGStandaloneButtonWindow alloc] initWithWindowScene:scene];
            sLGStandaloneButtonWindow.backgroundColor = UIColor.clearColor;
            sLGStandaloneButtonWindow.windowLevel = LG_STANDALONE_BUTTON_WINDOW_LEVEL;

            sLGStandaloneMenuButton = [[LGStandaloneMenuButton alloc] initWithFrame:CGRectMake(0.0, 0.0, 64.0, 64.0)];
            sLGStandaloneMenuButton.tapHandler = ^{
                LG_presentStandaloneSettings();
            };
            [sLGStandaloneButtonWindow addSubview:sLGStandaloneMenuButton];
            sLGStandaloneButtonWindow.interactiveView = sLGStandaloneMenuButton;
        } else if (sLGStandaloneButtonWindow.windowScene != scene) {
            sLGStandaloneButtonWindow.hidden = YES;
            sLGStandaloneButtonWindow = [[LGStandaloneButtonWindow alloc] initWithWindowScene:scene];
            sLGStandaloneButtonWindow.backgroundColor = UIColor.clearColor;
            sLGStandaloneButtonWindow.windowLevel = LG_STANDALONE_BUTTON_WINDOW_LEVEL;
            [sLGStandaloneButtonWindow addSubview:sLGStandaloneMenuButton];
            sLGStandaloneButtonWindow.interactiveView = sLGStandaloneMenuButton;
        }
        LG_configureStandaloneMenuButtonFrame();
        sLGStandaloneButtonWindow.hidden = NO;
        sLGStandaloneButtonWindow.userInteractionEnabled = YES;
        [sLGStandaloneButtonWindow makeKeyAndVisible];
        [sLGStandaloneButtonWindow resignKeyWindow];
    });
}

static void LG_installStandaloneMenuButtonIfNeeded(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        LG_showStandaloneMenuButton();
        [[NSNotificationCenter defaultCenter] addObserverForName:kLGStandaloneSettingsDismissedNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
            sLGStandalonePresentedController = nil;
            sLGStandalonePresentationObserver = nil;
            LG_restoreStandaloneMenuButton();
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:UISceneDidActivateNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
            if (sLGStandalonePresentedController) return;
            LG_showStandaloneMenuButton();
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
            if (sLGStandalonePresentedController) return;
            LG_showStandaloneMenuButton();
        }];
    });
}
#endif

static const NSInteger kLGMaxViewTraversalDepth = 96;

static UIView *LG_findSubviewOfClassImpl(UIView *root, Class cls, NSInteger depth) {
    if (!root || !cls || depth > kLGMaxViewTraversalDepth) return nil;
    if ([root isKindOfClass:cls]) return root;
    for (UIView *sub in root.subviews) {
        UIView *found = LG_findSubviewOfClassImpl(sub, cls, depth + 1);
        if (found) return found;
    }
    return nil;
}


UIView *LG_findSubviewOfClass(UIView *root, Class cls) {
    return LG_findSubviewOfClassImpl(root, cls, 0);
}

static void LG_updateAllGlassViewsInTreeImpl(UIView *root, int depth) {
    if (!root || depth > kLGMaxViewTraversalDepth) return;
    if (root.hidden || root.alpha <= 0.01f || root.layer.opacity <= 0.01f) return;
    static Class glassClass;
    if (!glassClass) glassClass = [LiquidGlassView class];
    if ([root isKindOfClass:glassClass]) {
        [(LiquidGlassView *)root updateOrigin];
        return;
    }
    NSArray *subviews = root.subviews;
    for (UIView *sub in subviews)
        LG_updateAllGlassViewsInTreeImpl(sub, depth + 1);
}

void LG_updateAllGlassViewsInTree(UIView *root) {
    LG_updateAllGlassViewsInTreeImpl(root, 0);
}

static NSHashTable *sRegisteredGlassViews[LGUpdateGroupWidgets + 1] = { nil };

void LG_registerGlassView(UIView *view, LGUpdateGroup group) {
    LGAssertMainThread();
    if (!view) return;
    if (group <= LGUpdateGroupAll || group > LGUpdateGroupWidgets) return;
    if (!sRegisteredGlassViews[group])
        sRegisteredGlassViews[group] = [NSHashTable weakObjectsHashTable];
    [sRegisteredGlassViews[group] addObject:view];
}

void LG_unregisterGlassView(UIView *view, LGUpdateGroup group) {
    LGAssertMainThread();
    if (group <= LGUpdateGroupAll || group > LGUpdateGroupWidgets) return;
    [sRegisteredGlassViews[group] removeObject:view];
}

static void LG_updateGlassHashTable(NSHashTable *table) {
    if (!table.count) return;
    CGRect screenBounds = UIScreen.mainScreen.bounds;
    for (LiquidGlassView *glass in table) {
        if (!glass.superview) continue;
        if (!glass.window) continue;
        if (glass.hidden || glass.alpha <= 0.01f || glass.layer.opacity <= 0.01f) continue;
        if (CGRectIsEmpty(glass.bounds)) continue;
        if (glass.updateGroup != LGUpdateGroupLockscreen) {
            CGRect approxRect = [glass convertRect:glass.bounds toView:nil];
            if (!CGRectIntersectsRect(CGRectInset(screenBounds, -64.0, -64.0), approxRect)) continue;
        }
        [glass updateOrigin];
    }
}

void LG_updateRegisteredGlassViews(LGUpdateGroup group) {
    LGAssertMainThread();
    if (group == LGUpdateGroupAll) {
        for (NSInteger i = LGUpdateGroupDock; i <= LGUpdateGroupWidgets; i++)
            LG_updateGlassHashTable(sRegisteredGlassViews[i]);
        return;
    }
    if (group <= LGUpdateGroupAll || group > LGUpdateGroupWidgets) return;
    LG_updateGlassHashTable(sRegisteredGlassViews[group]);
}

UIWindow *LG_getHomescreenWindow(void) {
    static __weak UIWindow *sCachedWindow = nil;
    static Class sceneCls, homeCls;
    UIWindow *cached = sCachedWindow;
    if (cached.windowScene) return cached;

    if (!sceneCls) sceneCls = [UIWindowScene class];
    if (!homeCls) homeCls = NSClassFromString(@"SBHomeScreenWindow");

    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:sceneCls]) continue;
        for (UIWindow *win in ((UIWindowScene *)sc).windows) {
            if ([win isKindOfClass:homeCls]) {
                sCachedWindow = win;
                return win;
            }
        }
    }
    return nil;
}

BOOL LG_isFullScreenDevice(void) {
    static BOOL sCached = NO;
    static BOOL sResult = NO;
    if (!sCached) {
        for (UIWindow *window in LGApplicationWindows(UIApplication.sharedApplication)) {
            if (window.safeAreaInsets.top > 20.0) {
                sResult = YES;
                break;
            }
        }
        if (!sResult) {
            CGFloat h = UIScreen.mainScreen.bounds.size.height;
            CGFloat w = UIScreen.mainScreen.bounds.size.width;
            CGFloat longerSide = MAX(h, w);
            sResult = (longerSide >= 812.0);
        }
        sCached = YES;
    }
    return sResult;
}

static UIWindow *LG_getWallpaperWindow(BOOL secureOnly) {
    static Class wCls, wsCls2, sceneCls;
    if (!sceneCls) sceneCls = [UIWindowScene class];
    if (!wCls)    wCls    = NSClassFromString(@"_SBWallpaperWindow");
    if (!wsCls2)  wsCls2  = NSClassFromString(@"_SBWallpaperSecureWindow");
    UIWindow *secureFallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:sceneCls]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (secureOnly) {
                if ([w isKindOfClass:wsCls2]) return w;
            } else {
                if ([w isKindOfClass:wCls]) return w;
                if (!secureFallback && [w isKindOfClass:wsCls2]) secureFallback = w;
            }
        }
    }
    return secureOnly ? nil : secureFallback;
}

static BOOL LG_viewMatchesHierarchyClass(UIView *view, Class cls) {
    if (!view || !cls) return NO;
    UIView *v = view;
    while (v) {
        if ([v isKindOfClass:cls]) return YES;
        v = v.superview;
    }
    UIResponder *r = view.nextResponder;
    while (r) {
        if ([r isKindOfClass:cls]) return YES;
        r = r.nextResponder;
    }
    return NO;
}

static UIImageView *LG_findImageViewInTree(UIView *root) {
    if (!root) return nil;
    if ([root isKindOfClass:[UIImageView class]] && ((UIImageView *)root).image)
        return (UIImageView *)root;
    for (UIView *sub in root.subviews) {
        UIImageView *found = LG_findImageViewInTree(sub);
        if (found) return found;
    }
    return nil;
}

static void LG_collectViewsOfClass(UIView *root, Class cls, NSMutableArray<UIView *> *results, NSInteger depth) {
    if (!root || !cls || !results || depth > kLGMaxViewTraversalDepth) return;
    if ([root isKindOfClass:cls]) [results addObject:root];
    for (UIView *sub in root.subviews)
        LG_collectViewsOfClass(sub, cls, results, depth + 1);
}

static UIImageView *LG_getWallpaperImageView(UIWindow *win, BOOL lockscreen) {
    static Class replicaCls, staticWpCls, homePosterVCCls, lockPosterVCCls;
    if (!replicaCls)  replicaCls  = NSClassFromString(@"PBUISnapshotReplicaView");
    if (!staticWpCls) staticWpCls = NSClassFromString(@"SBFStaticWallpaperImageView");
    if (!homePosterVCCls) homePosterVCCls = NSClassFromString(@"PBUIPosterHomeViewController");
    if (!lockPosterVCCls) lockPosterVCCls = NSClassFromString(@"PBUIPosterLockViewController");

    Class targetPosterVCCls = lockscreen ? lockPosterVCCls : homePosterVCCls;
    NSMutableArray<UIView *> *replicas = [NSMutableArray array];
    LG_collectViewsOfClass(win, replicaCls, replicas, 0);
    for (UIView *replica in replicas) {
        if (targetPosterVCCls && !LG_viewMatchesHierarchyClass(replica, targetPosterVCCls))
            continue;
        UIImageView *iv = LG_findImageViewInTree(replica);
        if (iv.image) {
            CGRect screenRect = [iv convertRect:iv.bounds toView:nil];
            LGDebugLog(@"%@ wallpaper imageView source=%@ rect=%@ match=%@",
                       lockscreen ? @"lockscreen" : @"homescreen",
                       NSStringFromClass(iv.class),
                       NSStringFromCGRect(screenRect),
                       NSStringFromClass(targetPosterVCCls));
            return iv;
        }
    }

    if (!LG_isAtLeastiOS16()) {
        UIView *replica = LG_findSubviewOfClass(win, replicaCls);
        if (replica) {
            UIImageView *iv = LG_findImageViewInTree(replica);
            if (iv.image) {
                CGRect screenRect = [iv convertRect:iv.bounds toView:nil];
                LGDebugLog(@"%@ wallpaper imageView source=%@ rect=%@",
                           lockscreen ? @"lockscreen" : @"homescreen",
                           NSStringFromClass(iv.class),
                           NSStringFromCGRect(screenRect));
                return iv;
            }
        }
    }
    UIImageView *iv = (UIImageView *)LG_findSubviewOfClass(win, staticWpCls);
    if (iv.image) {
        CGRect screenRect = [iv convertRect:iv.bounds toView:nil];
        LGDebugLog(@"%@ wallpaper imageView source=%@ rect=%@",
                   lockscreen ? @"lockscreen" : @"homescreen",
                   NSStringFromClass(iv.class),
                   NSStringFromCGRect(screenRect));
        return iv;
    }
    return nil;
}

static CGPoint LG_centeredWallpaperOriginForImage(UIImage *image) {
    if (!image) return CGPointZero;
    CGSize screenSize = UIScreen.mainScreen.bounds.size;
    return CGPointMake((screenSize.width - image.size.width) * 0.5,
                       (screenSize.height - image.size.height) * 0.5);
}

static CGRect LG_imageViewDisplayedImageRect(UIImageView *imageView) {
    if (!imageView || !imageView.image) return CGRectZero;
    CGRect bounds = imageView.bounds;
    CGSize imageSize = imageView.image.size;
    if (CGRectIsEmpty(bounds) || imageSize.width <= 0.0 || imageSize.height <= 0.0) return CGRectZero;

    UIViewContentMode mode = imageView.contentMode;
    if (mode == UIViewContentModeScaleToFill) return bounds;

    CGFloat scaleX = bounds.size.width / imageSize.width;
    CGFloat scaleY = bounds.size.height / imageSize.height;
    CGFloat scale = 1.0;

    switch (mode) {
        case UIViewContentModeScaleAspectFit:
            scale = MIN(scaleX, scaleY);
            break;
        case UIViewContentModeScaleAspectFill:
        default:
            scale = MAX(scaleX, scaleY);
            break;
    }

    CGSize fitted = CGSizeMake(imageSize.width * scale, imageSize.height * scale);
    CGFloat originX = (bounds.size.width - fitted.width) * 0.5;
    CGFloat originY = (bounds.size.height - fitted.height) * 0.5;
    return CGRectMake(originX, originY, fitted.width, fitted.height);
}

static CGPoint LG_getHomescreenWallpaperOriginForImage(UIImage *image) {
    return LG_centeredWallpaperOriginForImage(image);
}

static UIImage *sCachedSnapshot = nil;
static UIImage *sCachedContextMenuSnapshot = nil;
static UIImage *sCachedFolderSnapshot = nil;
static UIImage *sCachedSpringBoardHomeImage = nil;
static UIImage *sCachedSpringBoardLockImage = nil;
static NSDate *sCachedSpringBoardHomeMTime = nil;
static NSDate *sCachedSpringBoardLockMTime = nil;
static NSString *sCachedSpringBoardHomePath = nil;
static NSString *sCachedSpringBoardLockPath = nil;
static NSDate *sObservedLegacyHomeAssetMTime = nil;
static NSDate *sObservedLegacyLockAssetMTime = nil;
static NSString *sObservedLegacyHomeAssetPath = nil;
static NSString *sObservedLegacyLockAssetPath = nil;
static dispatch_source_t sLegacyWallpaperWatcher = nil;
static int sLegacyWallpaperWatcherFD = -1;
static BOOL sLegacyWallpaperRescanScheduled = NO;
static NSUInteger sPendingHomescreenWallpaperRefreshToken = 0;
static NSUInteger sPendingLockscreenWallpaperRefreshToken = 0;
static BOOL sSnapshotRetryScheduled = NO;
static void LG_trySnapshotWithRetry(void);
static void LG_scheduleHomescreenWallpaperRefresh(NSString *reason, UIImage *image);
static void LG_scheduleLockscreenWallpaperRefresh(NSString *reason);
static void LG_handlePrefsChanged(void);
static void LG_handleMemoryWarning(void);
static void LG_requestRespring(void);
static void LG_startLegacyWallpaperWatcher(void);
static void LGScheduleBlockAfterDelay(NSTimeInterval delay, dispatch_block_t block);

static BOOL LG_isAtLeastiOS16(void) {
    static BOOL sCachedResult = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sCachedResult = [[NSProcessInfo processInfo]
            isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){16, 0, 0}];
    });
    return sCachedResult;
}

static NSString *LG_springBoardWallpaperDirectory(void) {
    static NSString *sResolved = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray<NSString *> *candidates = [NSMutableArray array];
        [candidates addObject:@"/var/mobile/Library/SpringBoard"];

        NSString *home = NSHomeDirectory();
        if (home.length) {
            [candidates addObject:[home stringByAppendingPathComponent:@"Library/SpringBoard"]];

            NSRange containersRange = [home rangeOfString:@"/data/Containers/"];
            if (containersRange.location != NSNotFound) {
                NSString *deviceDataRoot = [home substringToIndex:containersRange.location + @"/data".length];
                [candidates addObject:[deviceDataRoot stringByAppendingPathComponent:@"Library/SpringBoard"]];
            }
        }

        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *path in candidates) {
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:path isDirectory:&isDir] && isDir) {
                sResolved = [path copy];
                break;
            }
        }
    });
    return sResolved;
}

static NSArray<NSString *> *LG_springBoardWallpaperCandidatePaths(BOOL lockscreen) {
    NSString *root = LG_springBoardWallpaperDirectory();
    if (LG_isAtLeastiOS16()) {
        return @[];
    }
    if (lockscreen) {
        return @[
            [root stringByAppendingPathComponent:@"LockBackground.cpbitmap"],
            [root stringByAppendingPathComponent:@"LockBackgroundThumbnail.jpg"],
        ];
    }
    return @[
        [root stringByAppendingPathComponent:@"HomeBackground.cpbitmap"],
        [root stringByAppendingPathComponent:@"HomeBackgroundThumbnail.jpg"],
    ];
}

static NSString *LG_preferredSpringBoardWallpaperPath(BOOL lockscreen) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in LG_springBoardWallpaperCandidatePaths(lockscreen)) {
        if ([fm fileExistsAtPath:path]) return path;
    }
    return nil;
}

static BOOL LG_equalMaybeNilObjects(id a, id b) {
    if (a == b) return YES;
    if (!a || !b) return NO;
    return [a isEqual:b];
}

static BOOL LG_noteLegacyWallpaperAssetChange(BOOL lockscreen) {
    if (LG_isAtLeastiOS16()) return NO;

    NSString *path = LG_preferredSpringBoardWallpaperPath(lockscreen);
    NSDate *mtime = nil;
    if (path.length) {
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        mtime = attrs[NSFileModificationDate];
    }

    NSDate * __strong *observedMTime = lockscreen ? &sObservedLegacyLockAssetMTime : &sObservedLegacyHomeAssetMTime;
    NSString * __strong *observedPath = lockscreen ? &sObservedLegacyLockAssetPath : &sObservedLegacyHomeAssetPath;

    BOOL hadBaseline = (*observedPath != nil) || (*observedMTime != nil);
    BOOL changed = hadBaseline &&
        (!LG_equalMaybeNilObjects(*observedPath, path) || !LG_equalMaybeNilObjects(*observedMTime, mtime));

    *observedPath = [path copy];
    *observedMTime = mtime;
    return changed;
}

static void LG_checkLegacyWallpaperAssetChanges(void) {
    if (!LG_globalEnabled()) return;
    if (LG_isAtLeastiOS16()) return;

    BOOL homeChanged = LG_noteLegacyWallpaperAssetChange(NO);
    BOOL lockChanged = LG_noteLegacyWallpaperAssetChange(YES);

    if (homeChanged)
        LG_scheduleHomescreenWallpaperRefresh(@"legacy-home-asset", nil);
    if (lockChanged)
        LG_scheduleLockscreenWallpaperRefresh(@"legacy-lock-asset");
}

static void LG_startLegacyWallpaperWatcher(void) {
    if (LG_isAtLeastiOS16()) return;
    if (sLegacyWallpaperWatcher) return;
    NSString *dir = LG_springBoardWallpaperDirectory();
    if (!dir.length) return;

    sLegacyWallpaperWatcherFD = open(dir.fileSystemRepresentation, O_EVTONLY);
    if (sLegacyWallpaperWatcherFD < 0) return;

    dispatch_queue_t queue = dispatch_get_main_queue();
    unsigned long mask = DISPATCH_VNODE_WRITE | DISPATCH_VNODE_DELETE | DISPATCH_VNODE_EXTEND |
                         DISPATCH_VNODE_ATTRIB | DISPATCH_VNODE_LINK | DISPATCH_VNODE_RENAME |
                         DISPATCH_VNODE_REVOKE;
    sLegacyWallpaperWatcher = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE,
                                                     (uintptr_t)sLegacyWallpaperWatcherFD,
                                                     mask,
                                                     queue);
    if (!sLegacyWallpaperWatcher) {
        close(sLegacyWallpaperWatcherFD);
        sLegacyWallpaperWatcherFD = -1;
        return;
    }

    dispatch_source_set_event_handler(sLegacyWallpaperWatcher, ^{
        if (sLegacyWallpaperRescanScheduled) return;
        sLegacyWallpaperRescanScheduled = YES;
        LGScheduleBlockAfterDelay(0.20, ^{
            sLegacyWallpaperRescanScheduled = NO;
            LG_checkLegacyWallpaperAssetChanges();
        });
    });
    dispatch_source_set_cancel_handler(sLegacyWallpaperWatcher, ^{
        if (sLegacyWallpaperWatcherFD >= 0) {
            close(sLegacyWallpaperWatcherFD);
            sLegacyWallpaperWatcherFD = -1;
        }
    });
    dispatch_resume(sLegacyWallpaperWatcher);

    // establish the baseline once the watcher is armed
    LG_checkLegacyWallpaperAssetChanges();
}

BOOL LG_hasHomescreenWallpaperAsset(void) {
    return LG_preferredSpringBoardWallpaperPath(NO) != nil;
}

static UIImage *LG_decodeCPBitmapAtPath(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (![data isKindOfClass:[NSData class]] || data.length < 24) return nil;

    const uint8_t *bytes = data.bytes;
    NSUInteger length = data.length;

    uint32_t widthLE = 0;
    uint32_t heightLE = 0;
    memcpy(&widthLE, bytes + length - (4 * 5), sizeof(uint32_t));
    memcpy(&heightLE, bytes + length - (4 * 4), sizeof(uint32_t));
    size_t width = CFSwapInt32LittleToHost(widthLE);
    size_t height = CFSwapInt32LittleToHost(heightLE);
    if (width == 0 || height == 0 || width > 10000 || height > 10000) return nil;

    static const size_t kAlignments[] = { 16, 8, 4 };
    size_t payloadBytes = 0;
    size_t chosenAlignment = 0;
    for (size_t i = 0; i < sizeof(kAlignments) / sizeof(kAlignments[0]); i++) {
        size_t align = kAlignments[i];
        size_t lineSize = ((width + align - 1) / align) * align;
        size_t bytesNeeded = lineSize * height * 4;
        if (bytesNeeded <= length - 20) {
            payloadBytes = bytesNeeded;
            chosenAlignment = align;
            break;
        }
    }
    if (payloadBytes == 0 || chosenAlignment == 0) return nil;

    NSMutableData *rgba = [NSMutableData dataWithLength:width * height * 4];
    uint8_t *dst = rgba.mutableBytes;
    size_t lineSize = ((width + chosenAlignment - 1) / chosenAlignment) * chosenAlignment;

    for (size_t y = 0; y < height; y++) {
        for (size_t x = 0; x < width; x++) {
            size_t srcOffset = (x * 4) + (y * lineSize * 4);
            size_t dstOffset = (x * 4) + (y * width * 4);
            if (srcOffset + 4 > payloadBytes) return nil;
            // cpbitmap stores BGRA; UIKit wants RGBA here.
            dst[dstOffset + 0] = bytes[srcOffset + 2];
            dst[dstOffset + 1] = bytes[srcOffset + 1];
            dst[dstOffset + 2] = bytes[srcOffset + 0];
            dst[dstOffset + 3] = bytes[srcOffset + 3];
        }
    }

    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)rgba);
    if (!provider) return nil;
    CGColorSpaceRef colorSpace = LGSharedRGBColorSpace();
    CGImageRef cgImage = CGImageCreate(width,
                                       height,
                                       8,
                                       32,
                                       width * 4,
                                       colorSpace,
                                       kCGBitmapByteOrderDefault | kCGImageAlphaLast,
                                       provider,
                                       NULL,
                                       NO,
                                       kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    if (!cgImage) return nil;

    CGFloat screenScale = UIScreen.mainScreen.scale ?: 1.0;
    UIImage *image = [UIImage imageWithCGImage:cgImage scale:screenScale orientation:UIImageOrientationUp];
    CGImageRelease(cgImage);
    return image;
}

static UIImage *LG_decodeSpringBoardWallpaperPath(NSString *path) {
    if (!path.length) return nil;
    if ([[path pathExtension].lowercaseString isEqualToString:@"jpg"] ||
        [[path pathExtension].lowercaseString isEqualToString:@"jpeg"] ||
        [[path pathExtension].lowercaseString isEqualToString:@"png"]) {
        return [UIImage imageWithContentsOfFile:path];
    }
    if ([[path pathExtension].lowercaseString isEqualToString:@"cpbitmap"]) {
        return LG_decodeCPBitmapAtPath(path);
    }
    return nil;
}

static BOOL LG_isCPBitmapPath(NSString *path) {
    return [[[path pathExtension] lowercaseString] isEqualToString:@"cpbitmap"];
}

static UIImage *LG_loadSpringBoardWallpaperImage(BOOL lockscreen) {
    NSString *path = LG_preferredSpringBoardWallpaperPath(lockscreen);
    if (!path) return nil;

    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    NSDate *mtime = attrs[NSFileModificationDate];

    if (lockscreen) {
        if (sCachedSpringBoardLockImage &&
            [sCachedSpringBoardLockPath isEqualToString:path] &&
            ((!mtime && !sCachedSpringBoardLockMTime) || [sCachedSpringBoardLockMTime isEqualToDate:mtime])) {
            return sCachedSpringBoardLockImage;
        }
    } else {
        if (sCachedSpringBoardHomeImage &&
            [sCachedSpringBoardHomePath isEqualToString:path] &&
            ((!mtime && !sCachedSpringBoardHomeMTime) || [sCachedSpringBoardHomeMTime isEqualToDate:mtime])) {
            return sCachedSpringBoardHomeImage;
        }
    }

    UIImage *image = LG_decodeSpringBoardWallpaperPath(path);
    if (lockscreen) {
        sCachedSpringBoardLockImage = image;
        sCachedSpringBoardLockMTime = mtime;
        sCachedSpringBoardLockPath = [path copy];
    } else {
        sCachedSpringBoardHomeImage = image;
        sCachedSpringBoardHomeMTime = mtime;
        sCachedSpringBoardHomePath = [path copy];
    }

    if (image) {
        LGLog(@"loaded %@ wallpaper from %@", lockscreen ? @"lockscreen" : @"homescreen", path.lastPathComponent);
    }

    return image;
}

UIImage *LG_getWallpaperImage(CGPoint *outOriginInScreenPts) {
    LGAssertMainThread();
    if (!LG_globalEnabled()) {
        if (outOriginInScreenPts) *outOriginInScreenPts = CGPointZero;
        return nil;
    }
    NSString *assetPath = LG_preferredSpringBoardWallpaperPath(NO);
    UIImage *asset = LG_loadSpringBoardWallpaperImage(NO);
    if (asset) {
        if (outOriginInScreenPts) {
            *outOriginInScreenPts = LG_isCPBitmapPath(assetPath)
                ? LG_centeredWallpaperOriginForImage(asset)
                : LG_getHomescreenWallpaperOriginForImage(asset);
        }
        return asset;
    }
    UIWindow *win = LG_getWallpaperWindow(NO);
    if (!win) return nil;
    UIImageView *iv = LG_getWallpaperImageView(win, NO);
    if (!iv.image) return nil;
    if (outOriginInScreenPts)
        *outOriginInScreenPts = [iv convertPoint:CGPointZero toView:nil];
    return iv.image;
}

static UIImage *sInterceptedWallpaperImage = nil;
static void *kLGSnapshotOriginalOpacityKey = &kLGSnapshotOriginalOpacityKey;

BOOL LG_imageLooksBlack(UIImage *img) {
    if (!img) return YES;
    CGImageRef cg = img.CGImage;
    if (!cg) return YES;
    unsigned char px[9 * 4] = {0};
    CGContextRef ctx = CGBitmapContextCreate(px, 3, 3, 8, 3 * 4, LGSharedRGBColorSpace(),
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (!ctx) return YES;
    CGContextDrawImage(ctx, CGRectMake(0, 0, 3, 3), cg);
    CGContextRelease(ctx);
    int nonBlack = 0;
    for (int i = 0; i < 9; i++)
        if (px[i*4] + px[i*4+1] + px[i*4+2] > 30) nonBlack++;
    return nonBlack < 3;
}

static BOOL LG_contextSnapshotLooksIncomplete(UIImage *img) {
    if (!img) return YES;
    CGImageRef cg = img.CGImage;
    if (!cg) return YES;
    if (img.scale <= 0.0) return YES;
    if (img.size.width <= 0.0 || img.size.height <= 0.0) return YES;
    if (CGImageGetWidth(cg) == 0 || CGImageGetHeight(cg) == 0) return YES;
    return NO;
}

static void LG_drawWallpaperImageInContext(UIImage *image, CGPoint origin) {
    if (!image) return;
    [image drawInRect:CGRectMake(origin.x, origin.y, image.size.width, image.size.height)];
}

static BOOL LG_drawHomescreenWallpaperInContext(CGSize screenSize) {
    CGRect bounds = CGRectMake(0, 0, screenSize.width, screenSize.height);
    NSString *assetPath = LG_preferredSpringBoardWallpaperPath(NO);
    UIImage *asset = LG_loadSpringBoardWallpaperImage(NO);
    if (asset) {
        CGPoint origin = LG_isCPBitmapPath(assetPath)
            ? LG_centeredWallpaperOriginForImage(asset)
            : LG_getHomescreenWallpaperOriginForImage(asset);
        LG_drawWallpaperImageInContext(asset, origin);
        return YES;
    }

    if (sInterceptedWallpaperImage) {
        [sInterceptedWallpaperImage drawInRect:bounds];
        return YES;
    }

    UIWindow *win = LG_getWallpaperWindow(NO);
    if (!win) return NO;
    UIImageView *iv = LG_getWallpaperImageView(win, NO);
    if (iv.image) {
        return LGDrawViewHierarchyIntoCurrentContext(win, bounds, NO);
    }

    static Class secureCls;
    if (!secureCls) secureCls = NSClassFromString(@"_SBWallpaperSecureWindow");
    if (![win isKindOfClass:secureCls]) {
        [win.layer renderInContext:UIGraphicsGetCurrentContext()];
        return YES;
    }

    return LGDrawViewHierarchyIntoCurrentContext(win, bounds, NO);
}

static BOOL LG_drawLockscreenWallpaperInContext(CGSize screenSize) {
    CGRect bounds = CGRectMake(0, 0, screenSize.width, screenSize.height);
    UIWindow *win = LG_getWallpaperWindow(YES);
    if (!win) return NO;
    UIImageView *iv = LG_getWallpaperImageView(win, YES);
    if (LG_isAtLeastiOS16()) {
        if (iv.image) {
            CGRect displayedRect = LG_imageViewDisplayedImageRect(iv);
            CGRect screenRect = [iv convertRect:displayedRect toView:nil];
            [iv.image drawInRect:screenRect];
            return YES;
        }
        BOOL drew = LGDrawViewHierarchyIntoCurrentContext(win, bounds, NO);
        return drew;
    }
    return LGDrawViewHierarchyIntoCurrentContext(win, bounds, NO);
}

void LG_refreshHomescreenSnapshot(void) {
    LGAssertMainThread();
    if (!LG_globalEnabled()) {
        sCachedSnapshot = nil;
        return;
    }
    UIImage *asset = LG_loadSpringBoardWallpaperImage(NO);
    if (asset) {
        UIWindow *win = LG_getWallpaperWindow(NO);
        UIImageView *iv = win ? LG_getWallpaperImageView(win, NO) : nil;
        LGDebugLog(@"refresh homescreen snapshot source=asset file=%@ imageView=%d screen=%@ image=%@ scale=%.2f orientation=%ld",
                   LG_preferredSpringBoardWallpaperPath(NO).lastPathComponent ?: @"(unknown)",
                   iv ? 1 : 0,
                   NSStringFromCGSize(UIScreen.mainScreen.bounds.size),
                   NSStringFromCGSize(asset.size),
                   asset.scale,
                   (long)asset.imageOrientation);
        sCachedSnapshot = asset;
        return;
    }

    CGSize screenSize = UIScreen.mainScreen.bounds.size;
    CGFloat scale     = UIScreen.mainScreen.scale;

    UIGraphicsBeginImageContextWithOptions(screenSize, YES, scale);
    LGDebugLog(@"refresh homescreen snapshot source=live-window");
    BOOL ok = LG_drawHomescreenWallpaperInContext(screenSize);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    if (!ok || LG_imageLooksBlack(img)) return;
    LGDebugLog(@"refresh homescreen snapshot live result image=%@ scale=%.2f orientation=%ld",
               NSStringFromCGSize(img.size),
               img.scale,
               (long)img.imageOrientation);
    sCachedSnapshot = img;
}

static void hideGlassViews(UIView *root, NSMutableArray *list) {
    if ([root isKindOfClass:[LiquidGlassView class]]) {
        objc_setAssociatedObject(root, kLGSnapshotOriginalOpacityKey,
                                 @(root.layer.opacity),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        root.layer.opacity = 0.0f;
        [CATransaction commit];
        [list addObject:root];
        return;
    }
    for (UIView *sub in root.subviews) hideGlassViews(sub, list);
}

static BOOL LGWindowContainsContextMenuViews(UIWindow *window) {
    if (!window) return NO;
    static Class containerCls, listCls;
    if (!containerCls) containerCls = NSClassFromString(@"_UIContextMenuContainerView");
    if (!listCls) listCls = NSClassFromString(@"_UIContextMenuListView");
    if ((containerCls && LG_findSubviewOfClass(window, containerCls)) ||
        (listCls && LG_findSubviewOfClass(window, listCls))) {
        return YES;
    }
    return NO;
}

static BOOL LGWindowHasContextMenuController(UIWindow *window) {
    if (!window) return NO;
    static Class actionsOnlyVCCls, menuVCCls;
    if (!actionsOnlyVCCls) actionsOnlyVCCls = NSClassFromString(@"_UIContextMenuActionsOnlyViewController");
    if (!menuVCCls) menuVCCls = NSClassFromString(@"_UIContextMenuViewController");

    UIViewController *root = window.rootViewController;
    if (!root) return NO;
    if ((actionsOnlyVCCls && [root isKindOfClass:actionsOnlyVCCls]) ||
        (menuVCCls && [root isKindOfClass:menuVCCls])) {
        return YES;
    }

    UIViewController *presented = root.presentedViewController;
    while (presented) {
        if ((actionsOnlyVCCls && [presented isKindOfClass:actionsOnlyVCCls]) ||
            (menuVCCls && [presented isKindOfClass:menuVCCls])) {
            return YES;
        }
        presented = presented.presentedViewController;
    }
    return NO;
}

static BOOL LG_isContextMenuWindow(UIWindow *window) {
    if (!window) return NO;

    static Class actionsWindowCls;
    if (!actionsWindowCls) actionsWindowCls = NSClassFromString(@"_UIContextMenuActionsWindow");
    if (actionsWindowCls && [window isKindOfClass:actionsWindowCls]) return YES;

    if (LGWindowHasContextMenuController(window)) return YES;
    if (LGWindowContainsContextMenuViews(window)) return YES;
    return NO;
}

static BOOL LG_isWallpaperWindow(UIWindow *window) {
    static Class wallpaperCls, secureCls;
    if (!wallpaperCls) wallpaperCls = NSClassFromString(@"_SBWallpaperWindow");
    if (!secureCls) secureCls = NSClassFromString(@"_SBWallpaperSecureWindow");
    return [window isKindOfClass:wallpaperCls] || [window isKindOfClass:secureCls];
}

static void LG_collectSnapshotWindows(NSMutableArray<UIWindow *> *hiddenWindows,
                                      NSMutableArray<UIWindow *> *renderWindows) {
    [hiddenWindows removeAllObjects];
    [renderWindows removeAllObjects];

    static Class sceneCls;
    if (!sceneCls) sceneCls = [UIWindowScene class];

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:sceneCls]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden || window.alpha <= 0.01f || window.layer.opacity <= 0.01f) continue;
            if (LG_isContextMenuWindow(window)) {
                window.hidden = YES;
                [hiddenWindows addObject:window];
                continue;
            }
            if (!LG_isWallpaperWindow(window))
                [renderWindows addObject:window];
        }
    }

    [renderWindows sortUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
        if (a.windowLevel < b.windowLevel) return NSOrderedAscending;
        if (a.windowLevel > b.windowLevel) return NSOrderedDescending;
        return NSOrderedSame;
    }];
}

static void LG_hideGlassViewsInWindows(NSArray<UIWindow *> *windows, NSMutableArray<UIView *> *hiddenViews) {
    [hiddenViews removeAllObjects];
    for (UIWindow *window in windows)
        hideGlassViews(window, hiddenViews);
}

static void LG_restoreSnapshotVisibility(NSArray<UIView *> *hiddenViews, NSArray<UIWindow *> *hiddenWindows) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (UIView *view in hiddenViews) {
        NSNumber *originalOpacity = objc_getAssociatedObject(view, kLGSnapshotOriginalOpacityKey);
        view.layer.opacity = originalOpacity ? (float)[originalOpacity doubleValue] : 1.0f;
        objc_setAssociatedObject(view, kLGSnapshotOriginalOpacityKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
    [CATransaction commit];
    for (UIWindow *window in hiddenWindows) window.hidden = NO;
}

static UIViewController *LG_topPresentedViewController(UIViewController *controller) {
    UIViewController *top = controller;
    while (top.presentedViewController)
        top = top.presentedViewController;
    return top;
}

static BOOL sTodayViewVisible = NO;

static void LGResetHomescreenSnapshotCaches(void) {
    sCachedSnapshot = nil;
    sCachedContextMenuSnapshot = nil;
    sCachedFolderSnapshot = nil;
    sCachedSpringBoardHomeImage = nil;
    sCachedSpringBoardHomeMTime = nil;
    sCachedSpringBoardHomePath = nil;
    LGClearGlassTextureCache();
}

static void LGResetLockscreenSnapshotCaches(void) {
    sCachedSpringBoardLockImage = nil;
    sCachedSpringBoardLockMTime = nil;
    sCachedSpringBoardLockPath = nil;
    LGInvalidateLockscreenSnapshotCache();
}

static void LGScheduleBlockAfterDelay(NSTimeInterval delay, dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(0.0, delay) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(),
                   block);
}

static void LGWarmTransientSnapshotsAfterDelay(NSTimeInterval delay) {
    LGScheduleBlockAfterDelay(delay, ^{
        if (!LG_globalEnabled()) return;
        if (!LG_getFolderSnapshot()) LG_cacheFolderSnapshot();
        if (!LG_getStrictCachedContextMenuSnapshot()) LG_cacheContextMenuSnapshot();
    });
}

static BOOL LG_isTodayViewControllerVisible(void) {
    if (sTodayViewVisible) return YES;

    static Class todayCls;
    if (!todayCls) todayCls = NSClassFromString(@"SBTodayViewController");
    if (!todayCls) return NO;

    UIApplication *app = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window.hidden || window.alpha <= 0.01f) continue;
                UIViewController *root = window.rootViewController;
                if (!root) continue;
                UIViewController *top = LG_topPresentedViewController(root);
                if ([top isKindOfClass:todayCls]) return YES;
            }
        }
        return NO;
    }

    for (UIWindow *window in LGApplicationWindows(app)) {
        if (window.hidden || window.alpha <= 0.01f) continue;
        UIViewController *root = window.rootViewController;
        if (!root) continue;
        UIViewController *top = LG_topPresentedViewController(root);
        if ([top isKindOfClass:todayCls]) return YES;
    }
    return NO;
}

static UIView *LG_contextSnapshotTargetView(UIWindow *homescreenWindow) {
    if (!homescreenWindow) return nil;
    static Class rootFolderCls, homeScreenCls, folderContainerCls;
    if (!rootFolderCls) rootFolderCls = NSClassFromString(@"SBRootFolderView");
    if (!homeScreenCls) homeScreenCls = NSClassFromString(@"SBHomeScreenView");
    if (!folderContainerCls) folderContainerCls = NSClassFromString(@"SBFolderContainerView");

    UIView *rootFolderView = rootFolderCls ? LG_findSubviewOfClass(homescreenWindow, rootFolderCls) : nil;
    if (rootFolderView) return rootFolderView;
    UIView *homeScreenView = homeScreenCls ? LG_findSubviewOfClass(homescreenWindow, homeScreenCls) : nil;
    if (homeScreenView) return homeScreenView;
    return folderContainerCls ? LG_findSubviewOfClass(homescreenWindow, folderContainerCls) : nil;
}

static UIImage *LG_captureTargetViewSnapshot(UIView *targetView, CGSize screenSize, CGFloat scale) {
    if (!targetView || !targetView.window) return nil;

    CGRect targetRect = [targetView.window convertRect:targetView.bounds fromView:targetView];
    UIImage *snapshot = LGCaptureViewHierarchySnapshot(targetView, targetRect, screenSize, scale, NO);
    if ((!snapshot || LG_imageLooksBlack(snapshot)) && targetView.window) {
        snapshot = LGCaptureViewHierarchySnapshot(targetView, targetRect, screenSize, scale, YES);
    }
    if (!snapshot || LG_imageLooksBlack(snapshot)) return nil;
    return snapshot;
}

static UIImage *LG_captureWindowSnapshot(UIWindow *window, CGSize screenSize, CGFloat scale) {
    if (!window) return nil;

    UIImage *snapshot = LGCaptureViewHierarchySnapshot(window, window.bounds, screenSize, scale, NO);
    if ((!snapshot || LG_imageLooksBlack(snapshot)) && window) {
        snapshot = LGCaptureViewHierarchySnapshot(window, window.bounds, screenSize, scale, YES);
    }
    if (!snapshot || LG_imageLooksBlack(snapshot)) return nil;
    return snapshot;
}

static UIImage *LG_composeHomescreenWallpaperAndIcons(UIImage *iconsSnapshot, CGSize screenSize, CGFloat scale) {
    if (!iconsSnapshot) return nil;

    CGPoint wallpaperOrigin = CGPointZero;
    UIImage *wallpaper = LG_getHomescreenSnapshot(&wallpaperOrigin);
    if (!wallpaper) return nil;

    UIGraphicsBeginImageContextWithOptions(screenSize, YES, scale);
    LG_drawWallpaperImageInContext(wallpaper, wallpaperOrigin);
    [iconsSnapshot drawAtPoint:CGPointZero];
    UIImage *composite = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return composite;
}

static UIImage *LG_captureBroadContextComposite(NSArray<UIWindow *> *renderWindows, CGSize screenSize, CGFloat scale) {
    UIGraphicsBeginImageContextWithOptions(screenSize, YES, scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    LG_drawHomescreenWallpaperInContext(screenSize);
    for (UIWindow *window in renderWindows)
        [window.layer renderInContext:ctx];
    UIImage *snapshot = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return snapshot;
}

static UIImage *LG_captureTodayViewComposite(UIWindow *homescreenWindow,
                                             NSArray<UIWindow *> *renderWindows,
                                             CGSize screenSize,
                                             CGFloat scale) {
    UIImage *base = LG_captureWindowSnapshot(homescreenWindow, screenSize, scale);
    if (!base) return nil;

    UIGraphicsBeginImageContextWithOptions(screenSize, NO, scale);
    [base drawAtPoint:CGPointZero];
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    for (UIWindow *window in renderWindows) {
        if (window == homescreenWindow) continue;
        [window.layer renderInContext:ctx];
    }
    UIImage *snapshot = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return snapshot;
}

static BOOL LG_contextSnapshotIsUsable(UIImage *snapshot) {
    if (!snapshot) return NO;
    if (LG_imageLooksBlack(snapshot)) return NO;
    if (!LG_hasHomescreenWallpaperAsset() && LG_contextSnapshotLooksIncomplete(snapshot)) return NO;
    return YES;
}

static UIImage *LG_captureContextMenuSnapshotWithHiddenGlass(BOOL hideGlass) {
    if (!LG_globalEnabled()) return nil;
    CFTimeInterval start = CACurrentMediaTime();

    CGSize screenSize = UIScreen.mainScreen.bounds.size;
    CGFloat scale     = UIScreen.mainScreen.scale;

    static NSMutableArray *hiddenViews   = nil;
    static NSMutableArray *hiddenWindows = nil;
    static NSMutableArray *renderWindows = nil;
    if (!hiddenViews)   hiddenViews   = [NSMutableArray array];
    if (!hiddenWindows) hiddenWindows = [NSMutableArray array];
    if (!renderWindows) renderWindows = [NSMutableArray array];
    LG_collectSnapshotWindows(hiddenWindows, renderWindows);
    if (hideGlass) {
        LG_hideGlassViewsInWindows(renderWindows, hiddenViews);
    } else {
        [hiddenViews removeAllObjects];
    }

    UIImage *snap = nil;
    BOOL todayViewVisible = LG_isTodayViewControllerVisible();
    NSString *mode = todayViewVisible ? @"today" : @"homescreen";
    if (todayViewVisible) {
        UIWindow *homescreenWindow = LG_getHomescreenWindow();
        if (homescreenWindow) {
            snap = LG_captureTodayViewComposite(homescreenWindow, renderWindows, screenSize, scale);
        }
    } else {
        UIWindow *homescreenWindow = LG_getHomescreenWindow();
        UIView *targetView = LG_contextSnapshotTargetView(homescreenWindow);
        if (targetView && targetView.window) {
            UIImage *iconsSnap = LG_captureTargetViewSnapshot(targetView, screenSize, scale);
            snap = LG_composeHomescreenWallpaperAndIcons(iconsSnap, screenSize, scale);
        }
    }

    if (!snap) {
        NSMutableArray<NSString *> *windowNames = [NSMutableArray array];
        for (UIWindow *window in renderWindows) {
            [windowNames addObject:NSStringFromClass(window.class)];
        }
        LGDebugLog(@"snapshot capture fallback hideGlass=%d mode=%@ windows=%@", hideGlass, mode, windowNames);
        snap = LG_captureBroadContextComposite(renderWindows, screenSize, scale);
    }

    if (hideGlass || hiddenWindows.count > 0)
        LG_restoreSnapshotVisibility(hiddenViews, hiddenWindows);
    CFTimeInterval elapsedMs = (CACurrentMediaTime() - start) * 1000.0;
    LGDebugLog(@"snapshot capture done hideGlass=%d mode=%@ ok=%d usable=%d elapsed=%.1fms size=%@",
               hideGlass,
               mode,
               snap ? 1 : 0,
               LG_contextSnapshotIsUsable(snap) ? 1 : 0,
               elapsedMs,
               snap ? NSStringFromCGSize(snap.size) : @"(null)");
    return snap;
}

void LG_cacheContextMenuSnapshot(void) {
    LGAssertMainThread();
    if (!LG_globalEnabled()) return;
    if (sCachedContextMenuSnapshot) return;
    // hold a menu-safe snapshot only while the menu is coming in
    UIImage *snapshot = LG_captureContextMenuSnapshotWithHiddenGlass(YES);
    if (LG_contextSnapshotIsUsable(snapshot)) {
        sCachedContextMenuSnapshot = snapshot;
    }
}

void LG_invalidateContextMenuSnapshot(void) {
    LGAssertMainThread();
    sCachedContextMenuSnapshot = nil;
}

UIImage *LG_getCachedContextMenuSnapshot(void) {
    if (!LG_globalEnabled()) return nil;
    if (sCachedContextMenuSnapshot) return sCachedContextMenuSnapshot;
    return sCachedSnapshot ?: LG_getContextMenuSnapshot();
}

UIImage *LG_getStrictCachedContextMenuSnapshot(void) {
    if (!LG_globalEnabled()) return nil;
    return sCachedContextMenuSnapshot;
}

UIImage *LG_getContextMenuSnapshot(void) {
    LGAssertMainThread();
    if (!LG_globalEnabled()) return nil;
    return LG_captureContextMenuSnapshotWithHiddenGlass(YES);
}

UIImage *LG_getHomescreenSnapshot(CGPoint *outOriginInScreenPts) {
    LGAssertMainThread();
    if (!LG_globalEnabled()) {
        if (outOriginInScreenPts) *outOriginInScreenPts = CGPointZero;
        return nil;
    }
    if (!sCachedSnapshot) LG_refreshHomescreenSnapshot();
    UIImage *asset = LG_loadSpringBoardWallpaperImage(NO);
    if (asset && outOriginInScreenPts) {
        *outOriginInScreenPts = LG_isCPBitmapPath(LG_preferredSpringBoardWallpaperPath(NO))
            ? LG_centeredWallpaperOriginForImage(asset)
            : LG_getHomescreenWallpaperOriginForImage(asset);
    } else if (outOriginInScreenPts) {
        *outOriginInScreenPts = CGPointZero;
    }
    return sCachedSnapshot;
}

void LG_cacheFolderSnapshot(void) {
    LGAssertMainThread();
    if (!LG_globalEnabled()) return;
    CFTimeInterval start = CACurrentMediaTime();
    LGDebugLog(@"folder snapshot cache begin");
    UIImage *snapshot = LG_captureContextMenuSnapshotWithHiddenGlass(NO);
    sCachedFolderSnapshot = LG_contextSnapshotIsUsable(snapshot) ? snapshot : nil;
    CFTimeInterval elapsedMs = (CACurrentMediaTime() - start) * 1000.0;
    LGDebugLog(@"folder snapshot cache end success=%d elapsed=%.1fms size=%@",
               sCachedFolderSnapshot ? 1 : 0,
               elapsedMs,
               sCachedFolderSnapshot ? NSStringFromCGSize(sCachedFolderSnapshot.size) : @"(null)");
}

void LG_invalidateFolderSnapshot(void) {
    LGAssertMainThread();
    LGDebugLog(@"folder snapshot invalidated");
    sCachedFolderSnapshot = nil;
    LG_invalidateContextMenuSnapshot();
}

UIImage *LG_getFolderSnapshot(void) {
    if (!LG_globalEnabled()) return nil;
    return sCachedFolderSnapshot;
}

UIImage *LG_getLockscreenSnapshot(void) {
    if (!LG_globalEnabled()) return nil;
    if (!LG_isAtLeastiOS16()) {
        UIImage *asset = LG_loadSpringBoardWallpaperImage(YES);
        if (asset) return asset;

        UIWindow *win = LG_getWallpaperWindow(YES);
        UIImageView *iv = win ? LG_getWallpaperImageView(win, YES) : nil;
        if (iv.image) {
            LGLog(@"loaded lockscreen wallpaper from imageView fallback");
            return iv.image;
        }
    }

    CGSize screenSize = UIScreen.mainScreen.bounds.size;
    CGFloat scale     = UIScreen.mainScreen.scale;

    UIGraphicsBeginImageContextWithOptions(screenSize, YES, scale);
    BOOL ok = LG_drawLockscreenWallpaperInContext(screenSize);
    UIImage *snap = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    LGLog(@"lockscreen snapshot result ok=%d size=%@ scale=%.2f",
          ok ? 1 : 0,
          snap ? NSStringFromCGSize(snap.size) : @"(null)",
          snap ? snap.scale : 0.0);
    return snap;
}

UIImage *LG_getRawLockscreenWallpaperImage(void) {
    if (!LG_globalEnabled()) return nil;

    if (!LG_isAtLeastiOS16()) {
        UIImage *asset = LG_loadSpringBoardWallpaperImage(YES);
        if (asset) return asset;
    }

    UIWindow *win = LG_getWallpaperWindow(YES);
    UIImageView *iv = win ? LG_getWallpaperImageView(win, YES) : nil;
    if (iv.image)
        return iv.image;

    return nil;
}

CGPoint LG_getLockscreenWallpaperOrigin(void) {
    if (!LG_globalEnabled()) return CGPointZero;
    if (LG_isAtLeastiOS16()) {
        return CGPointZero;
    }
    UIImage *asset = LG_loadSpringBoardWallpaperImage(YES);
    if (asset) {
        return LG_centeredWallpaperOriginForImage(asset);
    }
    UIWindow *win = LG_getWallpaperWindow(YES);
    UIImageView *iv = win ? LG_getWallpaperImageView(win, YES) : nil;
    if (iv.image) {
        CGRect displayedRect = LG_imageViewDisplayedImageRect(iv);
        CGRect screenRect = [iv convertRect:displayedRect toView:nil];
        return screenRect.origin;
    }
    return CGPointZero;
}

static void LG_preferencesChanged(CFNotificationCenterRef center,
                                  void *observer,
                                  CFStringRef name,
                                  const void *object,
                                  CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        LG_handlePrefsChanged();
    });
}

static void LG_respringRequested(CFNotificationCenterRef center,
                                 void *observer,
                                 CFStringRef name,
                                 const void *object,
                                 CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        LG_requestRespring();
    });
}

static void LG_invalidateSnapshotCachesRequested(CFNotificationCenterRef center,
                                                 void *observer,
                                                 CFStringRef name,
                                                 const void *object,
                                                 CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        LGLog(@"snapshot cache invalidation requested");
        sCachedSnapshot = nil;
        LG_invalidateFolderSnapshot();
        LG_invalidateContextMenuSnapshot();
        LGInvalidateLockscreenSnapshotCache();
        LG_trySnapshotWithRetry();
        if (!LG_getFolderSnapshot()) LG_cacheFolderSnapshot();
        LGRefreshLockSnapshotAfterDelay(0.0);
    });
}

static void LG_requestRespring(void) {
    dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);

    Class actionClass = objc_getClass("SBSRelaunchAction");
    Class serviceClass = objc_getClass("FBSSystemService");
    if (!actionClass || !serviceClass) {
        return;
    }

    SBSRelaunchAction *restartAction =
        [actionClass actionWithReason:@"LiquidAssPrefs"
                              options:(SBSRelaunchActionOptionsRestartRenderServer |
                                       SBSRelaunchActionOptionsFadeToBlackTransition)
                            targetURL:nil];
    if (!restartAction) {
        return;
    }

    LGLog(@"respring requested");
    [[serviceClass sharedService] sendActions:[NSSet setWithObject:restartAction] withResult:nil];
}

%ctor {
    if (!LGIsSpringBoardProcess()) return;

    LGReloadPreferences();
    LGLog(@"loaded into %@", LGMainBundleIdentifier() ?: @"(unknown)");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        LGPrewarmPipelines();
    });
    dispatch_async(dispatch_get_main_queue(), ^{
        LG_startLegacyWallpaperWatcher();
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
            LG_handleMemoryWarning();
        }];
#if LIQUIDASS_STANDALONE_UI
        LG_installStandaloneMenuButtonIfNeeded();
#endif
    });
    LGObservePreferenceChanges(^{
        LG_preferencesChanged(NULL, NULL, NULL, NULL, NULL);
    });
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    LG_respringRequested,
                                    LGPrefsRespringNotification,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    LG_invalidateSnapshotCachesRequested,
                                    LGInvalidateSnapshotCachesNotification,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}

static void LG_pushWallpaperToTree(UIView *root) {
    static Class glassClass;
    if (!glassClass) glassClass = [LiquidGlassView class];
    if ([root isKindOfClass:glassClass]) {
        LiquidGlassView *glass = (LiquidGlassView *)root;
        CGPoint wallpaperOrigin = CGPointZero;
        if (sCachedSnapshot) (void)LG_getHomescreenSnapshot(&wallpaperOrigin);
        glass.wallpaperImage = nil;
        glass.wallpaperImage = sCachedSnapshot;
        glass.wallpaperOrigin = wallpaperOrigin;
        [glass updateOrigin];
        return;
    }
    for (UIView *sub in root.subviews) LG_pushWallpaperToTree(sub);
}

static void LG_pushConfiguredBackdropToTree(UIView *root, LGUpdateGroup group, UIImage *image) {
    if (!root || !image) return;
    static Class glassClass;
    if (!glassClass) glassClass = [LiquidGlassView class];
    if ([root isKindOfClass:glassClass]) {
        LiquidGlassView *glass = (LiquidGlassView *)root;
        if (glass.updateGroup == group) {
            glass.wallpaperImage = nil;
            glass.wallpaperImage = image;
            if (group == LGUpdateGroupLockscreen)
                glass.wallpaperOrigin = LG_getLockscreenWallpaperOrigin();
            [glass updateOrigin];
        }
        return;
    }
    for (UIView *sub in root.subviews)
        LG_pushConfiguredBackdropToTree(sub, group, image);
}

static void LG_pushSnapshotToAllGlassViews(void) {
    if (!sCachedSnapshot) return;
    static Class sceneCls;
    if (!sceneCls) sceneCls = [UIWindowScene class];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:sceneCls]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows)
            LG_pushWallpaperToTree(window);
    }
}

static void LG_pushLockscreenSnapshotToAllGlassViews(void) {
    if (!LG_globalEnabled()) return;
    UIImage *lockImage = LG_getLockscreenSnapshot();
    if (!lockImage) return;

    static Class sceneCls;
    if (!sceneCls) sceneCls = [UIWindowScene class];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:sceneCls]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows)
            LG_pushConfiguredBackdropToTree(window, LGUpdateGroupLockscreen, lockImage);
    }
}

static void LG_scheduleHomescreenWallpaperRefresh(NSString *reason, UIImage *image) {
    if (!LG_globalEnabled()) return;
    if (image) sInterceptedWallpaperImage = image;
    LGResetHomescreenSnapshotCaches();
    NSUInteger token = ++sPendingHomescreenWallpaperRefreshToken;
    LGDebugLog(@"homescreen wallpaper refresh scheduled reason=%@", reason ?: @"(unknown)");
    LGScheduleBlockAfterDelay(0.30, ^{
        if (!LG_globalEnabled()) return;
        if (token != sPendingHomescreenWallpaperRefreshToken) return;
        LGDebugLog(@"homescreen wallpaper refresh begin reason=%@", reason ?: @"(unknown)");
        LG_refreshHomescreenSnapshot();
        if (sCachedSnapshot) {
            LG_pushSnapshotToAllGlassViews();
            LGWarmTransientSnapshotsAfterDelay(0.12);
        } else {
            LG_trySnapshotWithRetry();
        }
    });
}

static void LG_scheduleLockscreenWallpaperRefresh(NSString *reason) {
    if (!LG_globalEnabled()) return;
    LGResetLockscreenSnapshotCaches();
    NSUInteger token = ++sPendingLockscreenWallpaperRefreshToken;
    LGDebugLog(@"lockscreen wallpaper refresh scheduled reason=%@", reason ?: @"(unknown)");
    static const NSTimeInterval kLockscreenRefreshDelays[] = { 0.18, 0.40, 0.85, 1.60 };
    for (NSUInteger i = 0; i < sizeof(kLockscreenRefreshDelays) / sizeof(kLockscreenRefreshDelays[0]); i++) {
        NSTimeInterval delay = kLockscreenRefreshDelays[i];
        LGScheduleBlockAfterDelay(delay, ^{
            if (!LG_globalEnabled()) return;
            if (token != sPendingLockscreenWallpaperRefreshToken) return;
            LGDebugLog(@"lockscreen wallpaper refresh begin reason=%@ delay=%.2f",
                       reason ?: @"(unknown)",
                       delay);
            LGResetLockscreenSnapshotCaches();
            LG_pushLockscreenSnapshotToAllGlassViews();
            LG_updateRegisteredGlassViews(LGUpdateGroupLockscreen);
        });
    }
}

static void LG_handlePrefsChanged(void) {
    LGAssertMainThread();
    LGReloadPreferences();
    LGLog(@"preferences changed");
    LGResetHomescreenSnapshotCaches();
    sInterceptedWallpaperImage = nil;
    LGResetLockscreenSnapshotCaches();

    if (!LG_globalEnabled()) return;

    LG_refreshHomescreenSnapshot();
    if (sCachedSnapshot) {
        LG_pushSnapshotToAllGlassViews();
    } else {
        LG_trySnapshotWithRetry();
    }
    LG_pushLockscreenSnapshotToAllGlassViews();
    LG_updateRegisteredGlassViews(LGUpdateGroupLockscreen);
    LG_updateRegisteredGlassViews(LGUpdateGroupWidgets);
    LG_updateRegisteredGlassViews(LGUpdateGroupDock);
    LG_updateRegisteredGlassViews(LGUpdateGroupFolderIcon);
    LG_updateRegisteredGlassViews(LGUpdateGroupAppLibrary);
}

static void LG_handleMemoryWarning(void) {
    LGAssertMainThread();
    LGLog(@"memory warning clearing caches");
    LGResetHomescreenSnapshotCaches();
    LGResetLockscreenSnapshotCaches();
    sInterceptedWallpaperImage = nil;
}

static void LG_trySnapshotWithRetry(void) {
    LGAssertMainThread();
    if (!LG_globalEnabled()) return;
    if (sCachedSnapshot) return;
    if (sSnapshotRetryScheduled) return;
    LG_refreshHomescreenSnapshot();
    if (sCachedSnapshot) {
        LG_pushSnapshotToAllGlassViews();
        return;
    }
    sSnapshotRetryScheduled = YES;
    LGScheduleBlockAfterDelay(2.0, ^{
        sSnapshotRetryScheduled = NO;
        LG_trySnapshotWithRetry();
    });
}

static void *kLGReplicaObservedImageKey = &kLGReplicaObservedImageKey;

static void LGHandleWallpaperReplicaView(UIView *replicaView) {
    if (!LG_globalEnabled() || !replicaView.window) return;
    UIImageView *imageView = LG_findImageViewInTree(replicaView);
    UIImage *image = imageView.image;
    if (!image) return;
    CGSize screen = UIScreen.mainScreen.bounds.size;
    if (image.size.width < screen.width * 0.5) return;

    static Class replicaCls, homePosterVCCls, lockPosterVCCls;
    if (!replicaCls) replicaCls = NSClassFromString(@"PBUISnapshotReplicaView");
    if (!homePosterVCCls) homePosterVCCls = NSClassFromString(@"PBUIPosterHomeViewController");
    if (!lockPosterVCCls) lockPosterVCCls = NSClassFromString(@"PBUIPosterLockViewController");
    if (!LG_viewMatchesHierarchyClass(replicaView, replicaCls)) return;

    UIImage *lastImage = objc_getAssociatedObject(replicaView, kLGReplicaObservedImageKey);
    if (LG_viewMatchesHierarchyClass(replicaView, homePosterVCCls)) {
        BOOL sameImage = (sInterceptedWallpaperImage == image);
        if (lastImage != image || !sameImage || !sCachedSnapshot) {
            LG_scheduleHomescreenWallpaperRefresh(@"poster-home-image", image);
        }
        objc_setAssociatedObject(replicaView, kLGReplicaObservedImageKey, image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if (LG_viewMatchesHierarchyClass(replicaView, lockPosterVCCls)) {
        if (lastImage != image || !sCachedSpringBoardLockImage) {
            LG_scheduleLockscreenWallpaperRefresh(@"poster-lock-image");
        }
        objc_setAssociatedObject(replicaView, kLGReplicaObservedImageKey, image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
}

%hook PBUISnapshotReplicaView

- (void)didMoveToWindow {
    %orig;
    if (!((UIView *)self).window) {
        objc_setAssociatedObject(self, kLGReplicaObservedImageKey, nil, OBJC_ASSOCIATION_ASSIGN);
        return;
    }
    LGHandleWallpaperReplicaView((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    LGHandleWallpaperReplicaView((UIView *)self);
}

%end

%hook SBHomeScreenViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!LG_globalEnabled()) return;
    LG_invalidateFolderSnapshot();
    LG_trySnapshotWithRetry();
    NSArray<NSNumber *> *delays = @[@0.12, @0.28, @0.55];
    for (NSNumber *delayNumber in delays) {
        LGScheduleBlockAfterDelay(delayNumber.doubleValue, ^{
            if (!LG_globalEnabled()) return;
            if (!LG_getFolderSnapshot())
                LG_cacheFolderSnapshot();
        });
    }
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id)coordinator {
    UIViewController *vc = (UIViewController *)self;
    UIInterfaceOrientation beforeOrientation = UIInterfaceOrientationUnknown;
    if (@available(iOS 13.0, *)) {
        if (vc.view.window.windowScene)
            beforeOrientation = vc.view.window.windowScene.interfaceOrientation;
    }
    LGDebugLog(@"homescreen rotation will size=%@ beforeOrientation=%ld screen=%@ snapshot=%@",
               NSStringFromCGSize(size),
               (long)beforeOrientation,
               NSStringFromCGSize(UIScreen.mainScreen.bounds.size),
               sCachedSnapshot ? NSStringFromCGSize(sCachedSnapshot.size) : @"(null)");
    %orig;
    if (![coordinator respondsToSelector:@selector(animateAlongsideTransition:completion:)]) return;
    [coordinator animateAlongsideTransition:^(__unused id context) {
        UIInterfaceOrientation duringOrientation = UIInterfaceOrientationUnknown;
        if (@available(iOS 13.0, *)) {
            if (vc.view.window.windowScene)
                duringOrientation = vc.view.window.windowScene.interfaceOrientation;
        }
        LGDebugLog(@"homescreen rotation alongside orientation=%ld screen=%@",
                   (long)duringOrientation,
                   NSStringFromCGSize(UIScreen.mainScreen.bounds.size));
    } completion:^(__unused id context) {
        if (LG_globalEnabled()) {
            sCachedSnapshot = nil;
            LG_invalidateFolderSnapshot();
            LG_invalidateContextMenuSnapshot();
            LG_refreshHomescreenSnapshot();
            if (sCachedSnapshot) {
                LG_pushSnapshotToAllGlassViews();
            } else {
                LG_trySnapshotWithRetry();
            }
        }
        UIInterfaceOrientation afterOrientation = UIInterfaceOrientationUnknown;
        if (@available(iOS 13.0, *)) {
            if (vc.view.window.windowScene)
                afterOrientation = vc.view.window.windowScene.interfaceOrientation;
        }
        CGPoint origin = CGPointZero;
        UIImage *snapshot = LG_getHomescreenSnapshot(&origin);
        LGDebugLog(@"homescreen rotation done orientation=%ld screen=%@ snapshot=%@ origin=%@",
                   (long)afterOrientation,
                   NSStringFromCGSize(UIScreen.mainScreen.bounds.size),
                   snapshot ? NSStringFromCGSize(snapshot.size) : @"(null)",
                   NSStringFromCGPoint(origin));
    }];
}
%end

%hook SBTodayViewController
- (void)viewWillAppear:(BOOL)animated {
    sTodayViewVisible = YES;
    %orig;
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    sTodayViewVisible = YES;
    if (!LG_globalEnabled()) return;
    LG_invalidateFolderSnapshot();
    LG_invalidateContextMenuSnapshot();
    LGScheduleBlockAfterDelay(0.10, ^{
        if (!LG_globalEnabled()) return;
        LG_cacheFolderSnapshot();
        LG_cacheContextMenuSnapshot();
    });
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    sTodayViewVisible = NO;
    if (!LG_globalEnabled()) return;
    LG_invalidateFolderSnapshot();
    LG_invalidateContextMenuSnapshot();
    LGScheduleBlockAfterDelay(0.10, ^{
        if (!LG_globalEnabled()) return;
        LG_trySnapshotWithRetry();
        if (!LG_getFolderSnapshot())
            LG_cacheFolderSnapshot();
    });
}
%end

static BOOL LG_shouldCacheSnapshotsForLongPress(UIGestureRecognizer *gesture) {
    UIView *view = gesture.view;
    if (!view || !view.window) return NO;

    static Class sbIconViewCls;
    static Class sbFolderIconImageViewCls;
    static Class sbIconListViewCls;
    if (!sbIconViewCls) sbIconViewCls = NSClassFromString(@"SBIconView");
    if (!sbFolderIconImageViewCls) sbFolderIconImageViewCls = NSClassFromString(@"SBFolderIconImageView");
    if (!sbIconListViewCls) sbIconListViewCls = NSClassFromString(@"SBIconListView");

    UIView *v = view;
    BOOL foundIconishView = NO;
    while (v) {
        if ((sbIconViewCls && [v isKindOfClass:sbIconViewCls]) ||
            (sbFolderIconImageViewCls && [v isKindOfClass:sbFolderIconImageViewCls])) {
            foundIconishView = YES;
        }
        if (foundIconishView && sbIconListViewCls && [v isKindOfClass:sbIconListViewCls])
            return YES;
        v = v.superview;
    }
    return NO;
}

%hook UILongPressGestureRecognizer
- (void)setState:(UIGestureRecognizerState)state {
    %orig;
    if (state != UIGestureRecognizerStateBegan) return;
    if (!LG_shouldCacheSnapshotsForLongPress(self)) return;
    LGDebugLog(@"long press snapshot warmup");
    LG_cacheFolderSnapshot();
    LG_cacheContextMenuSnapshot();
}
%end
