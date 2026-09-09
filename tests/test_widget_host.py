#!/usr/bin/env python3.11
"""Exercise the production widget host checks against old/new view hierarchies."""
from pathlib import Path
import argparse
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def function(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    end, depth = opening + 1, 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


SUPPORT = r'''
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <stdio.h>
@interface UIResponder : NSObject
@property(strong) UIResponder *nextResponder;
@end
@implementation UIResponder @end
@interface UIView : UIResponder
@property CGRect bounds;
@property(strong) UIView *superview;
@property(strong) NSArray<UIView *> *subviews;
@end
@implementation UIView @end
@interface UIViewController : UIResponder
@property(strong) UIView *view;
@end
@implementation UIViewController @end
@interface SBHWidgetStackViewController : UIViewController @end
@implementation SBHWidgetStackViewController @end
@interface SBFTouchPassThroughView : UIView @end
@implementation SBFTouchPassThroughView @end
@interface SBHTouchPassThroughView : UIView @end
@implementation SBHTouchPassThroughView @end
@interface SBIconView : UIView @end
@implementation SBIconView @end
@interface BSUIScrollView : UIView @end
@implementation BSUIScrollView @end
@interface SBHWidgetContainerView : UIView @end
@implementation SBHWidgetContainerView @end
@interface ObservedView : UIView @end
@implementation ObservedView
- (Class)class { return UIView.class; }
@end
static BOOL isExactClass(UIView *view, NSString *name) {
    return view && [NSStringFromClass(view.class) isEqualToString:name];
}
static UIView *host(Class touchClass) {
    UIView *v = [ObservedView new]; v.bounds = CGRectMake(0, 0, 155, 155);
    UIView *touch = [touchClass new]; touch.superview = [SBIconView new];
    v.superview = touch;
    SBHWidgetStackViewController *vc = [SBHWidgetStackViewController new];
    v.nextResponder = vc; vc.view = v;
    UIView *inner = [UIView new]; BSUIScrollView *scroll = [BSUIScrollView new];
    scroll.subviews = @[[SBHWidgetContainerView new]];
    inner.subviews = @[scroll]; v.subviews = @[inner];
    return v;
}
#define CHECK(c, msg) do { if (!(c)) { puts("FAIL " msg); return 1; } } while (0)
'''

CHECKS = r'''
int main(void) { @autoreleasepool {
    UIView *old = host(SBFTouchPassThroughView.class);
    UIView *modern = host(SBHTouchPassThroughView.class);
    CHECK(isWidgetGlassHostContainer(old), "old widget host rejected");
    CHECK(isWidgetGlassHostContainer(modern), "iOS 18 widget host rejected");
    modern.superview.superview = [UIView new];
    CHECK(!isWidgetGlassHostContainer(modern), "host outside Home Screen accepted");
    modern = host(SBHTouchPassThroughView.class); modern.nextResponder = nil;
    CHECK(!isWidgetGlassHostContainer(modern), "host without widget controller accepted");
    modern = host(SBHTouchPassThroughView.class); modern.subviews = @[];
    CHECK(!isWidgetGlassHostContainer(modern), "host without widget content accepted");
    modern = host(SBHTouchPassThroughView.class); modern.bounds = CGRectMake(0,0,30,30);
    CHECK(!isWidgetGlassHostContainer(modern), "small control accepted as widget");
    modern = host(SBHTouchPassThroughView.class);
    for (int i=0; i<8; i++) { UIView *wrapper=[UIView new]; wrapper.superview=modern.superview; modern.superview=wrapper; }
    CHECK(!isWidgetGlassHostContainer(modern), "ancestor depth limit ignored");
    puts("PASS old/iOS18 widget hosts, KVO class reporting, and scope exclusions");
    return 0;
} }
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--revision")
    args = parser.parse_args()
    source = (subprocess.check_output(
        ["git", "show", f"{args.revision}:Hooks/Widgets.x"], cwd=ROOT, text=True)
        if args.revision else (ROOT / "Hooks/Widgets.x").read_text())
    text = SUPPORT
    for signature in ["static UIViewController *widgetNearestStackController(",
                      "static BOOL widgetHasAncestorNamedWithinDepth(",
                      "static BOOL widgetSubtreeContainsClass(",
                      "static UIView *widgetFindDescendantNamed(",
                      "static BOOL isWidgetGlassHostContainer("]:
        text += function(source, signature)
    with tempfile.TemporaryDirectory(prefix="liquidass-widget-host-") as tmp:
        test, binary = Path(tmp)/"test.m", Path(tmp)/"test"
        test.write_text(text + CHECKS)
        subprocess.run(["xcrun", "clang", "-fobjc-arc", "-framework", "Foundation",
                        "-framework", "CoreGraphics", str(test), "-o", str(binary)], check=True)
        return subprocess.run([str(binary)]).returncode


if __name__ == "__main__":
    raise SystemExit(main())
