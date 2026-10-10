#!/usr/bin/env python3.11
"""Test widget material restoration and photo protection on host and renderer paths."""
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
support += '#import "LGWidgetCompatibility.h"\n'
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
static char kWidgetPhotoContentKey;
static char kLegacyWidgetBackgroundOriginalHiddenKey;
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
    material.superview = container; material.nextResponder = container; material.window = [UIView new];
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
    vc.widget=widget(@"com.apple.mobileslideshow.PhotosReliveWidget");
    updateWidgetContentBackground(material);
    CHECK(!material.hidden, "Photos background was removed");
    CHECK(!ShouldHandleWidget(vc.widget.extensionBundleIdentifier), "RWB claimed Photos");
    UIWindow *window=[UIWindow new];CHUISWidgetScene *scene=[CHUISWidgetScene new];
    scene.widget=vc.widget;window.windowScene=scene;window.rwb_shouldHideBackground=@YES;
    CHECK(RWBWindowPreservesPhotoContent(window), "renderer window bypassed Photos protection");
    CHECK(ShouldHandleWidget(@"com.apple.Batteries.BatteriesAvocadoWidgetExtension"), "ordinary widget was excluded");
    CHECK(ShouldHandleWidget(@"com.example.photos.widget"), "third-party widget was mistaken for system Photos");
    for(NSString *identifier in @[@"com.apple.PhotosWidget",@"com.apple.mobileslideshow.Widget",@"com.apple.memories.widget"])
        CHECK(LGWidgetPreservesPhotoContent(identifier), "system photo identity missed");
    vc.widget=widget(@"com.apple.Batteries.BatteriesAvocadoWidgetExtension");
    updateWidgetContentBackground(material);CHECK(material.hidden,"ordinary widget no longer hides its background");
    UIView *legacy=[UIView new];legacy.hidden=YES;
    widgetSetLegacyBackgroundSuppressed(legacy,NO);CHECK(legacy.hidden,"untouched legacy background revealed");
    widgetSetLegacyBackgroundSuppressed(legacy,YES);widgetSetLegacyBackgroundSuppressed(legacy,YES);
    widgetSetLegacyBackgroundSuppressed(legacy,NO);CHECK(legacy.hidden,"hidden legacy state lost");
    legacy.hidden=NO;widgetSetLegacyBackgroundSuppressed(legacy,YES);widgetSetLegacyBackgroundSuppressed(legacy,NO);
    CHECK(!legacy.hidden,"visible legacy state lost");
    puts("PASS native/legacy widget restore, photo exclusion in host/RWB, and ordinary/third-party widget preservation");
    return 0;
} }
'''


def main():
    source = support
    widgets = (ROOT / "Hooks/Widgets.x").read_text()
    for signature in ["static BOOL widgetViewPreservesPhotoContent(",
                      "static void widgetSetLegacyBackgroundSuppressed(",
                      "static UIViewController *widgetNearestStackController(",
                      "static BOOL widgetHasAncestorNamedWithinDepth(",
                      "static BOOL widgetSubtreeContainsClass(",
                      "static UIView *widgetFindDescendantNamed(",
                      "static BOOL isWidgetGlassHostContainer(",
                      "static UIView *widgetAncestorContainerHost(",
                      "static BOOL isWidgetContentBackgroundMaterial(",
                      "static void updateWidgetContentBackground("]:
        source += function(widgets, signature)
    rwb=(ROOT / "LiquidAssRWB/Tweak.x").read_text()
    source += function(rwb, "static BOOL ShouldHandleWidget(")
    source += function(rwb, "static BOOL RWBWindowPreservesPhotoContent(")
    with tempfile.TemporaryDirectory(prefix="liquidass-widget-background-") as tmp:
        test, binary = Path(tmp)/"test.m", Path(tmp)/"test"
        test.write_text(source + checks)
        subprocess.run(["xcrun", "clang", "-fobjc-arc", "-framework", "Foundation",
                        "-framework", "CoreGraphics", "-I"+str(ROOT/"Shared"), str(test), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    main()
