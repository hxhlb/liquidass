#!/usr/bin/env python3.11
"""Execute the production Logos constructor against runtime capability fixtures.

This checks hook selection, not iOS rendering or SpringBoard view hierarchy.
"""
from pathlib import Path
import re
import subprocess
import tempfile

from test_clock_icon_ownership import function

ROOT = Path(__file__).resolve().parents[1]
SUPPORT = r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdio.h>
static BOOL springboard = YES, enabled = YES, sLGIslandProxyGainMaps, sLGIslandNeedsNativeGainMap;
static double version;
static NSMutableDictionary<NSString *, Class> *classes;
static NSMutableSet<NSString *> *groups;
static NSUInteger observers;
static BOOL LGIsSpringBoardProcess(void) { return springboard; }
static BOOL LGIslandEnabled(void) { return enabled; }
static void LGRefreshAllIslands(void) {}
static void lgObservePreferenceReload(void (^block)(void)) { observers++; }
static Class lookup(NSString *name) { return classes[name]; }
static void noOp(id self, SEL selector) {}
#define NSClassFromString lookup
#define CHECK(condition, message) do { if (!(condition)) { puts("FAIL " message); return 1; } } while (0)
static Class fixture(NSString *missing) {
    static NSUInteger sequence;
    Class c = objc_allocateClassPair(NSObject.class,
        [[NSString stringWithFormat:@"IslandFixture%lu", (unsigned long)sequence++] UTF8String], 0);
    for (NSString *key in @[@"_blobEnablingBlackFillView", @"_gainMapView",
                            @"_backgroundGroupingView", @"_contentClippingView"]) {
        if (![key isEqualToString:missing]) class_addIvar(c, key.UTF8String, sizeof(id), 3, "@");
    }
    objc_registerClassPair(c);
    return c;
}
static void reset(double osVersion, Class container) {
    version = osVersion; springboard = YES; enabled = YES;
    sLGIslandProxyGainMaps = NO; sLGIslandNeedsNativeGainMap = NO; observers = 0;
    groups = [NSMutableSet new]; classes = [NSMutableDictionary new];
    if (container) classes[@"SBSystemApertureContainerView"] = container;
}
'''
MAIN = r'''
int main(void) { @autoreleasepool {
    Class full = fixture(nil);
    for (NSNumber *os in @[@16.0, @16.3, @16.7, @17.0, @18.0]) {
        reset(os.doubleValue, full); runConstructor();
        CHECK([groups containsObject:@"LGDynamicIslandLifecycle"], "supported OS skipped island hooks");
        CHECK([groups containsObject:@"LGIslandNativeGainMapLifecycle"] == (os.doubleValue >= 17), "wrong native gain-map policy for OS");
        CHECK(observers == 1, "preference reload observer missing");
        CHECK(groups.count == (os.doubleValue >= 17 ? 2 : 1), "absent optional class was hooked");
    }
    for (NSString *missing in @[@"_blobEnablingBlackFillView", @"_gainMapView",
                                @"_backgroundGroupingView", @"_contentClippingView"]) {
        reset(16.3, fixture(missing)); runConstructor();
        CHECK(groups.count == 0 && observers == 0, "incomplete layout enabled destructive background hooks");
    }
    reset(16.3, nil); runConstructor();
    CHECK(groups.count == 0, "absent container enabled hooks");
    reset(15.8, full); runConstructor();
    CHECK(groups.count == 0, "pre-island OS enabled hooks");
    reset(16.3, full); springboard = NO; runConstructor();
    CHECK(groups.count == 0, "non-SpringBoard process enabled hooks");
    reset(16.3, full); enabled = NO; runConstructor();
    CHECK([groups containsObject:@"LGDynamicIslandLifecycle"] && observers == 1,
          "disabled setting lost lifecycle/reload support");
    CHECK(!sLGIslandProxyGainMaps && ![groups containsObject:@"LGIslandNativeGainMapLifecycle"],
          "disabled setting enabled gain-map proxy");
    Class shadow = fixture(nil);
    class_addMethod(shadow, @selector(_configureTransitionShadowViewIfNecessary), (IMP)noOp, "v@:");
    class_addMethod(shadow, @selector(viewDidLayoutSubviews), (IMP)noOp, "v@:");
    reset(16.3, full); classes[@"SAUILayoutSpecifyingElementViewController"] = shadow;
    runConstructor();
    CHECK([groups containsObject:@"LGIslandTransitionShadowLifecycle"], "iOS16 shadow creation hook skipped");
    CHECK([groups containsObject:@"LGIslandLegacyTransitionShadowLayoutLifecycle"], "iOS16 shadow layout hook skipped");
    CHECK(![groups containsObject:@"LGIslandTransitionShadowLayoutLifecycle"], "missing private layout method hooked");
    class_addMethod(shadow, @selector(_layoutTransitionShadowView), (IMP)noOp, "v@:");
    reset(17.0, full); classes[@"SAUILayoutSpecifyingElementViewController"] = shadow;
    runConstructor();
    CHECK([groups containsObject:@"LGIslandTransitionShadowLifecycle"]
          && [groups containsObject:@"LGIslandTransitionShadowLayoutLifecycle"], "modern shadow hooks changed");
    CHECK(![groups containsObject:@"LGIslandLegacyTransitionShadowLayoutLifecycle"], "modern shadow got extra legacy hook");
    puts("PASS iOS16/17/18 hook selection; missing-layout, absent-class, iOS15, process and preference guards");
} return 0; }
'''


def main():
    source = (ROOT / "Hooks/DynamicIsland.x").read_text()
    ctor = function(source, "%ctor {").replace("%ctor", "static void runConstructor(void)", 1)
    ctor = re.sub(r"@available\(iOS ([0-9.]+), \*\)", r"version >= \1", ctor)
    ctor = re.sub(r"%init\((\w+)\);", r'[groups addObject:@"\1"];', ctor)
    with tempfile.TemporaryDirectory(prefix="liquidass-island-compat-") as tmp:
        path = Path(tmp) / "test.m"
        exe = Path(tmp) / "test"
        path.write_text(SUPPORT + ctor + MAIN)
        subprocess.run(["xcrun", "clang", "-fobjc-arc", "-framework", "Foundation",
                        str(path), "-o", str(exe)], check=True)
        subprocess.run([str(exe)], check=True)


if __name__ == "__main__":
    main()
