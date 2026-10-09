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
    if (previous.userInterfaceStyle != self.traitCollection.userInterfaceStyle)
        LGRefreshIslandContent(self);
}
%end
%end

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
    if (!dladdr(header, &image) || !image.dli_fname
        || !strstr(image.dli_fname, "/SpringBoardUIServices.framework/")) return;
    // Avoid Objective-C/runtime work under dyld's image-loading callback.
    dispatch_async(dispatch_get_main_queue(), ^{ LGInstallIslandContentHooks(); });
}

%ctor {
    if (@available(iOS 16.0, *)) {
        LGInstallIslandContentHooks();
        _dyld_register_func_for_add_image(LGIslandContentImageAdded);
    }
}
