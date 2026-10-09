#!/usr/bin/env python3.11
"""Run production island content ownership and scoped trait routing on Foundation.

These doubles check lifecycle/trait preservation, not UIKit/SwiftUI rendering.
"""
from pathlib import Path
import subprocess
import tempfile
from test_clock_icon_ownership import function

ROOT = Path(__file__).resolve().parents[1]
SUPPORT = r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdio.h>
typedef NSInteger UIUserInterfaceStyle;
enum {UIUserInterfaceStyleUnspecified, UIUserInterfaceStyleLight, UIUserInterfaceStyleDark};
@interface UITraitCollection : NSObject
@property UIUserInterfaceStyle userInterfaceStyle;
@property(copy) NSString *category;
@property NSInteger contrast;
+ (instancetype)traitCollectionWithUserInterfaceStyle:(UIUserInterfaceStyle)style;
+ (instancetype)traitCollectionWithTraitsFromCollections:(NSArray *)traits;
@end
@implementation UITraitCollection
+ (instancetype)traitCollectionWithUserInterfaceStyle:(UIUserInterfaceStyle)style {
    UITraitCollection *t=[self new];t.userInterfaceStyle=style;return t;
}
+ (instancetype)traitCollectionWithTraitsFromCollections:(NSArray *)traits {
    UITraitCollection *out=[self new];
    for(UITraitCollection *t in traits){
        if(t.userInterfaceStyle)out.userInterfaceStyle=t.userInterfaceStyle;
        if(t.category)out.category=t.category;
        if(t.contrast)out.contrast=t.contrast;
    }return out;
}
- (BOOL)isEqual:(id)obj {
    if(![obj isKindOfClass:UITraitCollection.class])return NO;
    UITraitCollection *t=obj;
    return self.userInterfaceStyle==t.userInterfaceStyle && self.contrast==t.contrast
        && (self.category==t.category || [self.category isEqual:t.category]);
}
@end
@interface UIScreen : NSObject
@property(strong) UITraitCollection *traitCollection;
+ (instancetype)mainScreen;
@end
@implementation UIScreen
+ (instancetype)mainScreen {static UIScreen *s;if(!s){s=[self new];s.traitCollection=[UITraitCollection new];}return s;}
@end
@class UIWindow, UIViewController;
@interface UIView : NSObject
@property(strong) UIWindow *window;
@property UIUserInterfaceStyle overrideUserInterfaceStyle;
@end
@implementation UIView @end
@interface UIWindow : UIView
@property(strong) UIScreen *screen;
@end
@implementation UIWindow @end
static void intercepted(UIViewController *self, UITraitCollection *traits, UIViewController *child);
static NSUInteger writes;
static void (^onWrite)(void);
@interface UIViewController : NSObject
@property(strong) UIView *viewIfLoaded;
@property(weak) UIViewController *parentViewController;
@property UIUserInterfaceStyle overrideUserInterfaceStyle;
@property(strong) NSMapTable *overrides;
- (UITraitCollection *)traitCollection;
- (UITraitCollection *)overrideTraitCollectionForChildViewController:(UIViewController *)child;
- (void)setOverrideTraitCollection:(UITraitCollection *)traits forChildViewController:(UIViewController *)child;
- (void)nativeSet:(UITraitCollection *)traits child:(UIViewController *)child;
@end
@implementation UIViewController
- (UITraitCollection *)traitCollection {
    UITraitCollection *base=[self.parentViewController overrideTraitCollectionForChildViewController:self]
        ?: UIScreen.mainScreen.traitCollection;
    return [UITraitCollection traitCollectionWithTraitsFromCollections:@[base,
        [UITraitCollection traitCollectionWithUserInterfaceStyle:self.overrideUserInterfaceStyle]]];
}
- (UITraitCollection *)overrideTraitCollectionForChildViewController:(UIViewController *)child {return [self.overrides objectForKey:child];}
- (void)setOverrideTraitCollection:(UITraitCollection *)traits forChildViewController:(UIViewController *)child {intercepted(self,traits,child);}
- (void)nativeSet:(UITraitCollection *)traits child:(UIViewController *)child {
    if(!self.overrides)self.overrides=[NSMapTable weakToStrongObjectsMapTable];
    if(traits)[self.overrides setObject:traits forKey:child];else[self.overrides removeObjectForKey:child];
    writes++;if(onWrite)onWrite();
}
@end
static BOOL enabled=YES;
static BOOL LG_globalEnabled(void){return enabled;}
static BOOL LG_prefBool(id key, BOOL fallback){return enabled;}
@interface TestSource : NSObject
@property(strong) UIViewController *element;
@property(strong) UIViewController *parent;
@property(copy) NSString *category;
@property NSUInteger calls;
- (void)_updateTraitCollectionForElementIfNeeded;
@end
#define CHECK(c,msg) do{if(!(c)){puts("FAIL " msg);return 1;}}while(0)
'''
MAIN = r'''
@implementation TestSource
- (UIViewController *)systemApertureElement{return self.element;}
- (UIViewController *)containerViewController{return self.parent;}
- (void)_updateTraitCollectionForElementIfNeeded {
    LGUpdateIslandContent(self, ^{
        self.calls++;
        UITraitCollection *native=[UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleDark];
        native.category=self.category;native.contrast=2;
        [self.parent setOverrideTraitCollection:native forChildViewController:self.element];
    });
}
@end
static UIViewController *element(UIViewController *parent, UIWindow *window){
    UIViewController *e=[UIViewController new];e.parentViewController=parent;
    e.viewIfLoaded=[UIView new];e.viewIfLoaded.window=window;
    e.overrideUserInterfaceStyle=2;e.viewIfLoaded.overrideUserInterfaceStyle=2;return e;
}
int main(void){@autoreleasepool {
    UIScreen.mainScreen.traitCollection.userInterfaceStyle=1;
    UIWindow *window=[UIWindow new];window.screen=UIScreen.mainScreen;
    UIViewController *retained, *parent;
    @autoreleasepool {
    TestSource *s=[TestSource new];s.parent=[UIViewController new];s.element=element(s.parent,window);s.category=@"large";
    // Stock dark traits reproduce the white semantic text despite a light screen.
    [s.parent nativeSet:[UITraitCollection traitCollectionWithUserInterfaceStyle:2] child:s.element];
    CHECK(s.element.traitCollection.userInterfaceStyle==2,"fixture did not reproduce dark content");
    [s _updateTraitCollectionForElementIfNeeded];
    CHECK(s.element.overrideUserInterfaceStyle==1 && s.element.viewIfLoaded.overrideUserInterfaceStyle==1,"light content override missing");
    UITraitCollection *traits=[s.parent overrideTraitCollectionForChildViewController:s.element];
    CHECK(traits.userInterfaceStyle==1 && [traits.category isEqual:@"large"] && traits.contrast==2,"native traits lost");
    NSUInteger baseline=writes;
    for(int i=0;i<1000;i++)[s _updateTraitCollectionForElementIfNeeded];
    CHECK(writes==baseline,"stable callbacks rewrote child traits");
    UIViewController *ordinary=[UIViewController new];
    UITraitCollection *stock=[UITraitCollection traitCollectionWithUserInterfaceStyle:2];
    [s.parent setOverrideTraitCollection:stock forChildViewController:ordinary];
    CHECK([s.parent overrideTraitCollectionForChildViewController:ordinary]==stock,"unscoped setter modified another child");
    LGIslandContentState *owned=objc_getAssociatedObject(s,&kLGIslandContentStateKey);
    sLGIslandContentUpdateState=(__bridge void *)owned;
    UIViewController *otherParent=[UIViewController new];
    [s.parent setOverrideTraitCollection:stock forChildViewController:ordinary];
    [otherParent setOverrideTraitCollection:stock forChildViewController:s.element];
    sLGIslandContentUpdateState=NULL;
    CHECK([s.parent overrideTraitCollectionForChildViewController:ordinary]==stock
          && [otherParent overrideTraitCollectionForChildViewController:s.element]==stock,"active source scope escaped exact parent/child");
    owned=nil;
    s.category=@"accessibility";onWrite=^{[s _updateTraitCollectionForElementIfNeeded];};
    NSUInteger calls=s.calls;[s _updateTraitCollectionForElementIfNeeded];onWrite=nil;
    CHECK(s.calls==calls+1,"trait change recursively entered native updater");
    CHECK([[s.parent overrideTraitCollectionForChildViewController:s.element].category isEqual:@"accessibility"],"font category change dropped");
    UIScreen.mainScreen.traitCollection.userInterfaceStyle=2;LGRefreshIslandContent(window);
    CHECK(s.element.overrideUserInterfaceStyle==2 && s.element.viewIfLoaded.overrideUserInterfaceStyle==2,"dark mode did not restore white semantic content");
    UIScreen.mainScreen.traitCollection.userInterfaceStyle=1;LGRefreshIslandContent(window);
    CHECK(s.element.traitCollection.userInterfaceStyle==1,"light-dark-light failed");
    UIViewController *old=s.element;s.element=element(s.parent,window);
    [s _updateTraitCollectionForElementIfNeeded];
    CHECK(old.overrideUserInterfaceStyle==2 && old.viewIfLoaded.overrideUserInterfaceStyle==2,"replacement left old view overridden");
    CHECK([s.parent overrideTraitCollectionForChildViewController:old].userInterfaceStyle==2,"replacement lost native child traits");
    enabled=NO;LGRefreshIslandContent(nil);
    CHECK(s.element.overrideUserInterfaceStyle==2 && s.element.viewIfLoaded.overrideUserInterfaceStyle==2,"disable did not restore stock styles");
    CHECK([s.parent overrideTraitCollectionForChildViewController:s.element].userInterfaceStyle==2,"disable did not restore stock child traits");
    enabled=YES;[s _updateTraitCollectionForElementIfNeeded];
    s.element.viewIfLoaded.window=nil;[s _updateTraitCollectionForElementIfNeeded];
    CHECK(s.element.overrideUserInterfaceStyle==2,"detach did not restore styles");
    s.element.viewIfLoaded.window=window;[s _updateTraitCollectionForElementIfNeeded];
    retained=s.element;parent=s.parent;
    s=nil;
    }
    CHECK(retained.overrideUserInterfaceStyle==2 && retained.viewIfLoaded.overrideUserInterfaceStyle==2,"source deallocation did not restore styles");
    CHECK([parent overrideTraitCollectionForChildViewController:retained].userInterfaceStyle==2,"source deallocation did not restore native child traits");
    puts("PASS island-only light/dark traits, Dynamic Type preservation, 1000 stable updates, reentry, replacement, disable, detach and deallocation");
}return 0;}
'''


def main():
    text = (ROOT / "Hooks/DynamicIslandContent.x").read_text()
    core = text[text.index("@interface NSObject"):text.index("%group LGIslandContentLifecycle")]
    method = function(text, "- (void)setOverrideTraitCollection:")
    method = method[method.index("{"):].replace("%orig(traits, child);", "[self nativeSet:traits child:child];")
    hook = "static void intercepted(UIViewController *self, UITraitCollection *traits, UIViewController *child) " + method
    with tempfile.TemporaryDirectory(prefix="liquidass-island-content-") as tmp:
        src = Path(tmp) / "test.m"
        exe = Path(tmp) / "test"
        src.write_text(SUPPORT + core + hook + MAIN)
        subprocess.run(["xcrun", "clang", "-fobjc-arc", "-framework", "Foundation", str(src), "-o", str(exe)], check=True)
        subprocess.run([str(exe)], check=True)


if __name__ == "__main__":
    main()
