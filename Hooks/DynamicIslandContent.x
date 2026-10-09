#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <string.h>
#import "../Shared/LGSharedSupport.h"
#import "../Shared/LGGlassKit.h"

@interface NSObject (LGIslandContentSource)
- (UIViewController *)systemApertureElement;
- (UIViewController *)containerViewController;
- (void)_updateTraitCollectionForElementIfNeeded;
@end

// Content may be rendered in another UIKit process, not in SpringBoard.
// Only a live SBUISystemApertureElementSource grants ownership of these objects.
@interface LGIslandContentState : NSObject
@property (nonatomic, weak) UIViewController *element;
@property (nonatomic, weak) UIViewController *parent;
@property (nonatomic, weak) UIView *view;
@property (nonatomic) UIUserInterfaceStyle controllerStyle;
@property (nonatomic) UIUserInterfaceStyle viewStyle;
@property (nonatomic) UIUserInterfaceStyle appliedStyle;
@property (nonatomic, strong) UITraitCollection *nativeChildTraits;
@property (nonatomic, strong) UITraitCollection *appliedChildTraits;
@property (nonatomic) BOOL updating;
- (void)restore;
@end

@implementation LGIslandContentState
- (void)restore {
    if (self.element.overrideUserInterfaceStyle == self.appliedStyle)
        self.element.overrideUserInterfaceStyle = self.controllerStyle;
    if (self.view.overrideUserInterfaceStyle == self.appliedStyle)
        self.view.overrideUserInterfaceStyle = self.viewStyle;
    if (self.element && self.parent && self.appliedChildTraits
        && [[self.parent overrideTraitCollectionForChildViewController:self.element]
            isEqual:self.appliedChildTraits]) {
        [self.parent setOverrideTraitCollection:self.nativeChildTraits
                        forChildViewController:self.element];
    }
    self.element = nil;
    self.parent = nil;
    self.view = nil;
    self.nativeChildTraits = nil;
    self.appliedChildTraits = nil;
}
- (void)dealloc {
    [self restore];
}
@end

static char kLGIslandContentStateKey;
static NSHashTable *sLGIslandContentSources;
// Stack-scoped to the native source updater; unrelated controller calls pass through.
static __thread void *sLGIslandContentUpdateState;

static BOOL LGIslandContentEnabled(void) {
    return LG_globalEnabled() && LG_prefBool(@"DynamicIsland.Enabled", NO);
}

static UITraitCollection *LGIslandContentTraits(UITraitCollection *traits,
                                               UIUserInterfaceStyle style) {
    UITraitCollection *appearance = [UITraitCollection traitCollectionWithUserInterfaceStyle:style];
    return [UITraitCollection traitCollectionWithTraitsFromCollections:
        traits ? @[traits, appearance] : @[appearance]];
}

static void LGUpdateIslandContent(id source, void (^nativeUpdate)(void)) {
    if (!NSThread.isMainThread) { nativeUpdate(); return; }
    LGIslandContentState *state = objc_getAssociatedObject(source, &kLGIslandContentStateKey);
    if (state.updating) return;
    if (!sLGIslandContentSources) sLGIslandContentSources = [NSHashTable weakObjectsHashTable];
    [sLGIslandContentSources addObject:source];
    if (!state) {
        state = [LGIslandContentState new];
        objc_setAssociatedObject(source, &kLGIslandContentStateKey, state,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    state.updating = YES;
    void *previous = sLGIslandContentUpdateState;
    @try {
        UIViewController *element = [source systemApertureElement];
        UIViewController *parent = [source containerViewController];
        UIView *view = [element isKindOfClass:UIViewController.class] ? element.viewIfLoaded : nil;
        UIScreen *screen = view.window.screen ?: UIScreen.mainScreen;
        UIUserInterfaceStyle style = screen.traitCollection.userInterfaceStyle;
        if (!LGIslandContentEnabled() || !view.window
            || ![parent isKindOfClass:UIViewController.class]
            || element.parentViewController != parent
            || (style != UIUserInterfaceStyleLight && style != UIUserInterfaceStyleDark)) {
            [state restore];
            nativeUpdate();
            return;
        }
        if (state.element != element || state.parent != parent || state.view != view) {
            [state restore];
            state.element = element;
            state.parent = parent;
            state.view = view;
            state.controllerStyle = element.overrideUserInterfaceStyle;
            state.viewStyle = view.overrideUserInterfaceStyle;
            state.nativeChildTraits = [parent overrideTraitCollectionForChildViewController:element];
        }
        state.appliedStyle = style;
        sLGIslandContentUpdateState = (__bridge void *)state;
        // Keep Apple's layout-specific Dynamic Type calculation. The scoped setter
        // below changes only userInterfaceStyle in its resulting child traits.
        nativeUpdate();
        sLGIslandContentUpdateState = previous;
        if (element.overrideUserInterfaceStyle != style) element.overrideUserInterfaceStyle = style;
        if (view.overrideUserInterfaceStyle != style) view.overrideUserInterfaceStyle = style;
        UITraitCollection *current = [parent overrideTraitCollectionForChildViewController:element];
        UITraitCollection *desired = LGIslandContentTraits(current ?: element.traitCollection, style);
        if (![current isEqual:desired]) [parent setOverrideTraitCollection:desired forChildViewController:element];
        state.appliedChildTraits = [parent overrideTraitCollectionForChildViewController:element];
    } @finally {
        sLGIslandContentUpdateState = previous;
        state.updating = NO;
    }
}

static void LGRefreshIslandContent(UIWindow *window) {
    for (id source in sLGIslandContentSources.allObjects) {
        LGIslandContentState *state = objc_getAssociatedObject(source, &kLGIslandContentStateKey);
        if (!window || state.view.window == window) [source _updateTraitCollectionForElementIfNeeded];
    }
}

static void LGRefreshIslandMedia(UIWindow *window);
static void LGRefreshIslandHostedScenes(void);

%group LGIslandContentLifecycle
%hook SBUISystemApertureElementSource
- (void)_updateTraitCollectionForElementIfNeeded {
    LGUpdateIslandContent(self, ^{ %orig; });
}
%end

%hook UIViewController
- (void)setOverrideTraitCollection:(UITraitCollection *)traits forChildViewController:(UIViewController *)child {
    LGIslandContentState *state = (__bridge LGIslandContentState *)sLGIslandContentUpdateState;
    if (state && state.parent == self && state.element == child) {
        state.nativeChildTraits = traits;
        traits = LGIslandContentTraits(traits, state.appliedStyle);
        state.appliedChildTraits = traits;
        if ([[self overrideTraitCollectionForChildViewController:child] isEqual:traits]) return;
    }
    %orig(traits, child);
}
%end

%hook UIWindow
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    %orig(previous);
    if (previous.userInterfaceStyle != self.traitCollection.userInterfaceStyle) {
        LGRefreshIslandContent(self);
        LGRefreshIslandMedia(self);
        LGRefreshIslandHostedScenes();
    }
}
%end
%end

#pragma mark - Music island's explicit white palette

@interface MRUVisualStylingProvider : NSObject
@property (nonatomic, strong) UIColor *primaryColor;
@property (nonatomic, strong) UIColor *secondaryColor;
@property (nonatomic, strong) UIColor *tertiaryColor;
@property (nonatomic, strong) UIColor *quaternaryColor;
@property (nonatomic, strong) UIColor *separatorColor;
@property (nonatomic) BOOL supportsVibrancy;
@end

@interface MRUActivityNowPlayingView : UIView
@property (nonatomic, strong) MRUVisualStylingProvider *stylingProvider;
@end

@interface LGIslandMediaState : NSObject
@property (nonatomic, strong) MRUVisualStylingProvider *nativeProvider;
@property (nonatomic, strong) MRUVisualStylingProvider *lightProvider;
@property (nonatomic, strong) NSArray<UIColor *> *lightColors;
@property (nonatomic) BOOL applying;
@end
@implementation LGIslandMediaState @end

static char kLGIslandMediaStateKey;
static NSHashTable<MRUActivityNowPlayingView *> *sLGIslandMediaViews;

static void LGUpdateIslandMedia(MRUActivityNowPlayingView *view) {
    LGIslandMediaState *state = objc_getAssociatedObject(view, &kLGIslandMediaStateKey);
    if (state.applying) return;
    if (!sLGIslandMediaViews) sLGIslandMediaViews = [NSHashTable weakObjectsHashTable];
    [sLGIslandMediaViews addObject:view];
    UIScreen *screen = view.window.screen ?: UIScreen.mainScreen;
    BOOL light = LGIslandContentEnabled() && view.window
        && screen.traitCollection.userInterfaceStyle == UIUserInterfaceStyleLight;
    MRUVisualStylingProvider *current = view.stylingProvider;
    if (!state && (!light || !current)) return;
    if (!state) {
        state = [LGIslandMediaState new];
        objc_setAssociatedObject(view, &kLGIslandMediaStateKey, state,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (current != state.lightProvider) state.nativeProvider = current;
    state.applying = YES;
    @try {
        if (!light || !state.nativeProvider) {
            if (current && current == state.lightProvider)
                view.stylingProvider = state.nativeProvider;
            return;
        }
        if (!state.lightProvider) {
            // A private provider for this island view; never recolor a shared
            // Control Center/Lock Screen provider or the album artwork itself.
            MRUVisualStylingProvider *palette = [NSClassFromString(@"MRUVisualStylingProvider") new];
            if (!palette) return;
            UITraitCollection *traits = [UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleLight];
            state.lightColors = @[
                [UIColor.labelColor resolvedColorWithTraitCollection:traits],
                [UIColor.secondaryLabelColor resolvedColorWithTraitCollection:traits],
                [UIColor.tertiaryLabelColor resolvedColorWithTraitCollection:traits],
                [UIColor.quaternaryLabelColor resolvedColorWithTraitCollection:traits],
                [UIColor.separatorColor resolvedColorWithTraitCollection:traits]
            ];
            state.lightProvider = palette;
        }
        MRUVisualStylingProvider *palette = state.lightProvider;
        // viewDidLoad may set systemWhiteColor after assigning the provider.
        // Reconcile that write on layout, with no notifications for stable colors.
        if (![palette.primaryColor isEqual:state.lightColors[0]]) palette.primaryColor = state.lightColors[0];
        if (![palette.secondaryColor isEqual:state.lightColors[1]]) palette.secondaryColor = state.lightColors[1];
        if (![palette.tertiaryColor isEqual:state.lightColors[2]]) palette.tertiaryColor = state.lightColors[2];
        if (![palette.quaternaryColor isEqual:state.lightColors[3]]) palette.quaternaryColor = state.lightColors[3];
        if (![palette.separatorColor isEqual:state.lightColors[4]]) palette.separatorColor = state.lightColors[4];
        if (palette.supportsVibrancy) palette.supportsVibrancy = NO;
        if (current != state.lightProvider) view.stylingProvider = state.lightProvider;
    } @finally {
        state.applying = NO;
    }
}

static void LGRefreshIslandMedia(UIWindow *window) {
    for (MRUActivityNowPlayingView *view in sLGIslandMediaViews.allObjects)
        if (!window || view.window == window) LGUpdateIslandMedia(view);
}

%group LGIslandMediaLifecycle
%hook MRUActivityNowPlayingView
- (void)setStylingProvider:(MRUVisualStylingProvider *)provider {
    %orig(provider);
    LGUpdateIslandMedia((MRUActivityNowPlayingView *)self);
}
- (void)didMoveToWindow {
    %orig;
    LGUpdateIslandMedia((MRUActivityNowPlayingView *)self);
}
- (void)layoutSubviews {
    %orig;
    LGUpdateIslandMedia((MRUActivityNowPlayingView *)self);
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    %orig(previous);
    LGUpdateIslandMedia((MRUActivityNowPlayingView *)self);
}
%end
%end

#pragma mark - Authoritative appearance for remote island scenes

@interface NSObject (LGIslandHostedScene)
- (id)scene;
- (id)settings;
- (NSInteger)userInterfaceStyle;
- (void)setUserInterfaceStyle:(NSInteger)style;
- (void)updateSettingsWithBlock:(void (^)(id settings))block;
@end

@interface LGIslandSceneAppearance : NSObject
@property (nonatomic) NSInteger nativeStyle;
@property (nonatomic) NSInteger appliedStyle;
@end
@implementation LGIslandSceneAppearance @end

static NSMapTable<id, LGIslandSceneAppearance *> *sLGIslandHostedScenes;

static NSInteger LGIslandHostAppearance(void) {
    // Called only in SpringBoard. The remote service's UIScreen may itself be
    // forced Dark by its ActivitySceneSettings, even when SpringBoard is Light.
    return UIScreen.mainScreen.traitCollection.userInterfaceStyle;
}

static void LGApplyIslandHostedAppearance(id element, id settings) {
    id scene = [element scene];
    if (!scene || ![settings respondsToSelector:@selector(userInterfaceStyle)]
        || ![settings respondsToSelector:@selector(setUserInterfaceStyle:)]
        || ![scene respondsToSelector:@selector(updateSettingsWithBlock:)]) return;
    LGIslandSceneAppearance *state = [sLGIslandHostedScenes objectForKey:scene];
    NSInteger hostStyle = LGIslandHostAppearance();
    BOOL enabled = LGIslandContentEnabled()
        && (hostStyle == UIUserInterfaceStyleLight || hostStyle == UIUserInterfaceStyleDark);
    if (!enabled) {
        if (state) {
            if ([settings userInterfaceStyle] != state.nativeStyle)
                [settings setUserInterfaceStyle:state.nativeStyle];
            [sLGIslandHostedScenes removeObjectForKey:scene];
        }
        return;
    }
    NSInteger incoming = [settings userInterfaceStyle];
    if (!state) {
        if (!sLGIslandHostedScenes) sLGIslandHostedScenes = [NSMapTable weakToStrongObjectsMapTable];
        state = [LGIslandSceneAppearance new];
        state.nativeStyle = incoming;
        [sLGIslandHostedScenes setObject:state forKey:scene];
    } else if (incoming != state.appliedStyle) {
        state.nativeStyle = incoming;
    }
    state.appliedStyle = hostStyle;
    if (incoming != hostStyle) [settings setUserInterfaceStyle:hostStyle];
}

static void LGRefreshIslandHostedScenes(void) {
    if (!LGIsSpringBoardProcess() || !sLGIslandHostedScenes.count) return;
    NSInteger hostStyle = LGIslandHostAppearance();
    BOOL enabled = LGIslandContentEnabled()
        && (hostStyle == UIUserInterfaceStyleLight || hostStyle == UIUserInterfaceStyleDark);
    for (id scene in sLGIslandHostedScenes.keyEnumerator.allObjects) {
        LGIslandSceneAppearance *state = [sLGIslandHostedScenes objectForKey:scene];
        NSInteger desired = enabled ? hostStyle : state.nativeStyle;
        id current = [scene settings];
        if ([current respondsToSelector:@selector(userInterfaceStyle)]
            && [current userInterfaceStyle] != desired) {
            [scene updateSettingsWithBlock:^(id mutableSettings) {
                if ([mutableSettings respondsToSelector:@selector(setUserInterfaceStyle:)])
                    [mutableSettings setUserInterfaceStyle:desired];
            }];
        }
        if (enabled) state.appliedStyle = desired;
        else [sLGIslandHostedScenes removeObjectForKey:scene];
    }
}

%group LGIslandHostedAppearanceLifecycle
%hook SBSystemApertureSceneElement
- (void)_updateMutableSceneSettings:(id)settings withParameters:(id)parameters {
    %orig(settings, parameters);
    LGApplyIslandHostedAppearance(self, settings);
}
%end
%end

static void LGInstallIslandHostedAppearanceHooks(void) {
    if (!LGIsSpringBoardProcess()) return;
    // The iOS 16.5 startup regression is a separate open investigation.
    if (@available(iOS 17.0, *)) {
        Class element = NSClassFromString(@"SBSystemApertureSceneElement");
        if (!class_getInstanceMethod(element, @selector(_updateMutableSceneSettings:withParameters:))) return;
        %init(LGIslandHostedAppearanceLifecycle);
        lgObservePreferenceReload(^{ LGRefreshIslandHostedScenes(); });
    }
}

static void LGInstallIslandMediaHooks(void) {
    static BOOL installed;
    if (installed) return;
    Class view = NSClassFromString(@"MRUActivityNowPlayingView");
    Class provider = NSClassFromString(@"MRUVisualStylingProvider");
    if (!class_getInstanceMethod(view, @selector(stylingProvider))
        || !class_getInstanceMethod(view, @selector(setStylingProvider:))) return;
    for (NSString *name in @[@"setPrimaryColor:", @"setSecondaryColor:", @"setTertiaryColor:",
                             @"setQuaternaryColor:", @"setSeparatorColor:", @"setSupportsVibrancy:"]) {
        if (!class_getInstanceMethod(provider, NSSelectorFromString(name))) return;
    }
    installed = YES;
    %init(LGIslandMediaLifecycle);
    lgObservePreferenceReload(^{ LGRefreshIslandMedia(nil); });
}

static void LGInstallIslandContentHooks(void) {
    static BOOL installed;
    if (installed) return;
    Class source = NSClassFromString(@"SBUISystemApertureElementSource");
    if (!class_getInstanceMethod(source, @selector(_updateTraitCollectionForElementIfNeeded))
        || !class_getInstanceMethod(source, @selector(systemApertureElement))
        || !class_getInstanceMethod(source, @selector(containerViewController))) return;
    installed = YES;
    %init(LGIslandContentLifecycle);
    lgObservePreferenceReload(^{ LGRefreshIslandContent(nil); });
}

static void LGIslandContentImageAdded(const struct mach_header *header, intptr_t slide) {
    Dl_info image = {0};
    if (!dladdr(header, &image) || !image.dli_fname) return;
    BOOL content = strstr(image.dli_fname, "/SpringBoardUIServices.framework/") != NULL;
    BOOL media = strstr(image.dli_fname, "/MediaControls.framework/") != NULL;
    if (!content && !media) return;
    // Avoid Objective-C/runtime work under dyld's image-loading callback.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (content) LGInstallIslandContentHooks();
        if (media) LGInstallIslandMediaHooks();
    });
}

%ctor {
    if ([NSProcessInfo.processInfo.processName isEqualToString:@"backboardd"]) return;
    if (@available(iOS 16.0, *)) {
        LGInstallIslandContentHooks();
        LGInstallIslandMediaHooks();
        LGInstallIslandHostedAppearanceHooks();
        _dyld_register_func_for_add_image(LGIslandContentImageAdded);
    }
}
