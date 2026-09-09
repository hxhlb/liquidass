#!/usr/bin/env python3.11
"""Test native widget material restoration and Maps policy in both processes."""
from pathlib import Path
import subprocess
import tempfile
from test_widget_host import ROOT, SUPPORT, function

support = SUPPORT.replace("#include <stdio.h>", "#include <stdio.h>\n#import <objc/runtime.h>")
support = support.replace("@property CGRect bounds;", """@property CGRect bounds;
@property CGRect frame;
@property BOOL hidden;
@property(strong) UIView *window;""")
support = support.replace("@interface BSUIScrollView : UIView", """@interface UIScrollView : UIView @end
@implementation UIScrollView @end
@interface BSUIScrollView : UIScrollView""")
support += r'''
@interface MTMaterialView : UIView @end
@implementation MTMaterialView @end
@interface CHSWidget : NSObject
@property(copy) NSString *extensionBundleIdentifier;
@end
@implementation CHSWidget @end
@interface CHUISWidgetHostViewController : UIViewController
@property(strong) CHSWidget *widget;
@end
@implementation CHUISWidgetHostViewController @end
@interface UIWindowScene : NSObject @end
@implementation UIWindowScene @end
@interface CHUISWidgetScene : UIWindowScene
@property(strong) CHSWidget *widget;
@end
@implementation CHUISWidgetScene @end
@interface UIWindow : UIView
@property(strong) UIWindowScene *windowScene;
@property(strong) NSNumber *rwb_shouldHideBackground;
@end
@implementation UIWindow @end
static BOOL removalEnabled = YES, kIsEnabled = YES, kIsEnabledForSystemWidgets = YES;
static BOOL widgetBackgroundRemovalEnabled(void) { return removalEnabled; }
static void *kWidgetContentBackgroundHiddenKey = &kWidgetContentBackgroundHiddenKey;
static CHSWidget *widget(NSString *identifier) {
    CHSWidget *w = [CHSWidget new]; w.extensionBundleIdentifier = identifier; return w;
}
'''

checks = r'''
int main(void) { @autoreleasepool {
    UIView *root = host(SBHTouchPassThroughView.class);
    UIView *inner = root.subviews.firstObject;
    BSUIScrollView *scroll = (id)inner.subviews.firstObject;
    UIView *container = scroll.subviews.firstObject;
    inner.superview = root; scroll.superview = inner; container.superview = scroll;
    scroll.bounds = container.frame = CGRectMake(0,0,155,155);
    CHUISWidgetHostViewController *vc = [CHUISWidgetHostViewController new];
    vc.widget = widget(@"com.apple.Batteries.BatteriesAvocadoWidgetExtension");
    container.nextResponder = vc;
    MTMaterialView *material = [MTMaterialView new];
    material.superview = container; material.window = [UIView new];
    container.subviews = @[material];
    CHECK(isWidgetContentBackgroundMaterial(material), "native widget material not recognized");
    updateWidgetContentBackground(material);
    CHECK(material.hidden, "battery material remains visible");
    updateWidgetContentBackground(material);
    removalEnabled = NO; updateWidgetContentBackground(material);
    CHECK(!material.hidden, "disabling removal failed to restore visible material");
    CHECK(!objc_getAssociatedObject(material,kWidgetContentBackgroundHiddenKey), "restore state leaked");
    removalEnabled = YES; material.hidden = YES; updateWidgetContentBackground(material);
    removalEnabled = NO; updateWidgetContentBackground(material);
    CHECK(material.hidden, "originally hidden material was incorrectly revealed");
    material.hidden = NO; removalEnabled = YES;
    updateWidgetContentBackground(material);
    material.superview = [UIView new]; updateWidgetContentBackground(material);
    CHECK(!material.hidden, "moving out of widget failed to restore material");
    material.superview = container;
    vc.widget = widget(@"com.apple.Maps.GeneralMapsWidget");
    updateWidgetContentBackground(material);
    CHECK(!material.hidden, "Maps native material was removed");
    CHECK(!widgetBackgroundRemovalEnabledForIdentifier(vc.widget.extensionBundleIdentifier),
          "SpringBoard did not exclude Maps");
    UIView *cachedMap = [SBHWidgetContainerView new];
    cachedMap.frame = CGRectMake(0,-155,155,155); cachedMap.superview = scroll;
    CHUISWidgetHostViewController *mapVC = [CHUISWidgetHostViewController new];
    mapVC.widget = widget(@"com.apple.Maps.GeneralMapsWidget"); cachedMap.nextResponder = mapVC;
    vc.widget = widget(@"com.apple.weather.widget");
    scroll.subviews = @[cachedMap,container];
    CHECK([widgetIdentifierInView(root) isEqualToString:@"com.apple.weather.widget"],
          "offscreen Maps entry disabled current weather glass");
    scroll.bounds = cachedMap.frame;
    CHECK(LGWidgetRequiresSystemBackground(widgetIdentifierInView(root)),
          "active Maps entry was not selected");
    UIWindow *window = [UIWindow new]; window.rwb_shouldHideBackground = @YES;
    CHUISWidgetScene *scene = [CHUISWidgetScene new]; window.windowScene = scene;
    scene.widget = mapVC.widget;
    CHECK(!RWBShouldHideWindowBackground(window), "renderer removed Maps drawing despite exclusion");
    scene.widget = vc.widget;
    CHECK(RWBShouldHideWindowBackground(window), "renderer stopped handling weather");
    kIsEnabledForSystemWidgets = NO;
    CHECK(!RWBShouldHideWindowBackground(window), "system widget preference ignored");
    scene.widget = widget(@"org.example.widget");
    CHECK(RWBShouldHideWindowBackground(window), "third-party widget incorrectly excluded");
    scene.widget = nil;
    CHECK(!RWBShouldHideWindowBackground(window), "unknown scene cleared before identification");
    window.windowScene = nil;
    CHECK(RWBShouldHideWindowBackground(window), "legacy window flag ignored");
    kIsEnabled = NO;
    CHECK(!RWBShouldHideWindowBackground(window), "disabled renderer still removes backgrounds");
    CHECK(!LGWidgetRequiresSystemBackground(@"com.apple.MapsOther.widget"), "Maps prefix is too broad");
    puts("PASS material lifecycle/restore, visible widget selection, Maps exclusion, renderer preferences");
    return 0;
} }
'''


def main():
    source = support + function((ROOT / "Shared/LGSharedSupport.m").read_text(),
                                "BOOL LGWidgetRequiresSystemBackground(")
    widgets = (ROOT / "Hooks/Widgets.x").read_text()
    for signature in ["static BOOL widgetBackgroundRemovalEnabledForIdentifier(",
                      "static NSString *widgetIdentifierInView(",
                      "static UIViewController *widgetNearestStackController(",
                      "static BOOL widgetHasAncestorNamedWithinDepth(",
                      "static BOOL widgetSubtreeContainsClass(",
                      "static UIView *widgetFindDescendantNamed(",
                      "static BOOL isWidgetGlassHostContainer(",
                      "static UIView *widgetAncestorContainerHost(",
                      "static BOOL isWidgetContentBackgroundMaterial(",
                      "static void updateWidgetContentBackground("]:
        source += function(widgets, signature)
    rwb = (ROOT / "LiquidAssRWB/Tweak.x").read_text()
    source += function(rwb, "static BOOL ShouldHandleWidget(")
    source += function(rwb, "static BOOL RWBShouldHideWindowBackground(")
    with tempfile.TemporaryDirectory(prefix="liquidass-widget-background-") as tmp:
        test, binary = Path(tmp)/"test.m", Path(tmp)/"test"
        test.write_text(source + checks)
        subprocess.run(["xcrun", "clang", "-fobjc-arc", "-framework", "Foundation",
                        "-framework", "CoreGraphics", str(test), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    main()
