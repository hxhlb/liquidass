#!/usr/bin/env python3.11
"""Test native widget material restoration and the renderer rollback."""
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
    puts("PASS native widget material lifecycle and restore");
    return 0;
} }
'''


def main():
    source = support
    widgets = (ROOT / "Hooks/Widgets.x").read_text()
    for signature in ["static UIViewController *widgetNearestStackController(",
                      "static BOOL widgetHasAncestorNamedWithinDepth(",
                      "static BOOL widgetSubtreeContainsClass(",
                      "static UIView *widgetFindDescendantNamed(",
                      "static BOOL isWidgetGlassHostContainer(",
                      "static UIView *widgetAncestorContainerHost(",
                      "static BOOL isWidgetContentBackgroundMaterial(",
                      "static void updateWidgetContentBackground("]:
        source += function(widgets, signature)
    for path in ["LiquidAssRWB/Tweak.x", "Shared/LGSharedSupport.h", "Shared/LGSharedSupport.m"]:
        baseline = subprocess.check_output(["git", "show", "3d237d6:" + path], cwd=ROOT)
        current = (ROOT / path).read_bytes()
        # The upstream process exclusion helper is independent of widget removal.
        # Strip only that addition; all pre-existing shared behavior stays locked.
        if path.endswith("LGSharedSupport.h"):
            current = current.replace(b'#import "LGHostRegistry.h"\n', b'')
            current = current.replace(b'BOOL LGRendererUsesEnhancedAtLaunch(void);\n', b'')
            current = current.replace(b'const LGHostDefinition *LGActiveHostDefinitionForPrefix(NSString *prefix);\n', b'')
            current = current.replace(b"BOOL LGIsExcludedSystemProcess(void);\n", b"")
        elif path.endswith("LGSharedSupport.m"):
            text = current.decode().replace('#import "LGRendererPreferences.h"\n', '')
            original = baseline.decode()
            start = text.index('BOOL LGRendererUsesEnhancedAtLaunch(void)')
            end = text.index('BOOL LG_prefBool(', start)
            old_start = original.index('BOOL LGHasExplicitPreferenceValue(')
            old_end = original.index('BOOL LG_prefBool(', old_start)
            text = text[:start] + original[old_start:old_end] + text[end:]
            text = text.replace('static id LGUnscopedPreferenceValue(', 'id LGPreferenceValue(', 1)
            current = text.encode()
            added = function(current.decode(), "BOOL LGIsExcludedSystemProcess(void)")
            current = current.replace((added + "\n\n").encode(), b"")
        assert current == baseline, f"rollback mismatch: {path}"
    print("PASS widget renderer and existing shared support match widgets1")
    with tempfile.TemporaryDirectory(prefix="liquidass-widget-background-") as tmp:
        test, binary = Path(tmp)/"test.m", Path(tmp)/"test"
        test.write_text(source + checks)
        subprocess.run(["xcrun", "clang", "-fobjc-arc", "-framework", "Foundation",
                        "-framework", "CoreGraphics", str(test), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    main()
