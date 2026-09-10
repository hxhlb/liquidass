#!/usr/bin/env python3.11
"""Exercise the production switch installer and enabled hook without caller layout."""
from pathlib import Path
import argparse
import subprocess
import tempfile
from test_clock_icon_ownership import function

ROOT = Path(__file__).resolve().parents[1]
SUPPORT = r'''
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
enum { UIViewAutoresizingFlexibleWidth=1, UIViewAutoresizingFlexibleHeight=2,
       UIControlEventValueChanged=64, LGControlsDiagnosticSwitch=0 };
@interface Layer : NSObject
@property BOOL masksToBounds;
@end
@implementation Layer @end
@interface UIView : NSObject
@property CGRect frame;
@property CGRect bounds;
@property BOOL clipsToBounds;
@property BOOL ownPrefs;
@property NSUInteger autoresizingMask;
@property(strong) UIView *window;
@property(weak) UIView *parent;
@property(strong) Layer *layer;
@property(strong) NSMutableArray *children;
- (instancetype)initWithFrame:(CGRect)frame;
- (void)addSubview:(UIView *)view;
- (void)removeFromSuperview;
- (void)bringSubviewToFront:(UIView *)view;
@end
@implementation UIView
- (instancetype)initWithFrame:(CGRect)f { self=[super init]; if(self){_frame=_bounds=f;_layer=[Layer new];_children=[NSMutableArray new];}return self; }
- (void)addSubview:(UIView *)v { [_children addObject:v];v.parent=self;v.window=self.window; }
- (void)removeFromSuperview { [self.parent.children removeObject:self];self.parent=nil;self.window=nil; }
- (void)bringSubviewToFront:(UIView *)v {}
@end
@interface UIAction : NSObject
@property(weak) id sender;
@property(copy) void (^handler)(UIAction *);
+ (instancetype)actionWithHandler:(void (^)(UIAction *))handler;
@end
@implementation UIAction
+ (instancetype)actionWithHandler:(void (^)(UIAction *))h { UIAction *a=[UIAction new];a.handler=h;return a; }
@end
@interface UIControl : UIView
@property(getter=isEnabled) BOOL enabled;
@property(getter=isOn) BOOL on;
@property NSUInteger events;
@property(strong) NSMutableArray<UIAction *> *actions;
- (void)addAction:(UIAction *)action forControlEvents:(NSUInteger)events;
- (void)sendActionsForControlEvents:(NSUInteger)events;
- (void)setOn:(BOOL)on animated:(BOOL)animated;
- (void)simulateTap;
@end
@implementation UIControl
- (void)addAction:(UIAction *)a forControlEvents:(NSUInteger)e { if(!_actions)_actions=[NSMutableArray new];[_actions addObject:a]; }
- (void)sendActionsForControlEvents:(NSUInteger)e { _events++;for(UIAction *a in _actions){a.sender=self;a.handler(a);} }
- (void)setOn:(BOOL)on animated:(BOOL)animated { _on=on; }
- (void)simulateTap { if(self.enabled){self.on=!self.on;[self sendActionsForControlEvents:UIControlEventValueChanged];} }
@end
@interface UISwitch : UIControl @end
@interface LGPrefsLiquidSwitch : UISwitch @end
static NSUInteger creations, installs;
@implementation LGPrefsLiquidSwitch
- (instancetype)initWithFrame:(CGRect)f { self=[super initWithFrame:f];if(self)creations++;return self; }
@end
static BOOL gLGSwitchControlsEnabled=YES, gLGControlsDiagnosticsEnabled=NO;
static void *kLGSettingsSwitchOverlayKey=&kLGSettingsSwitchOverlayKey;
static void *kLGSettingsSwitchOwnerStateKey=&kLGSettingsSwitchOwnerStateKey;
static BOOL LGInsideLiquidAssPrefs(UIView *v) { return v.ownPrefs; }
static void LGHideStockControlContents(UIView *v, UIView *overlay) {}
static void LGRestoreStockControlContents(UIView *v, UIView *overlay) {}
typedef double CFTimeInterval;
static CFTimeInterval CACurrentMediaTime(void) { return 0; }
#define LGRecordControlsDiagnostic(...) do {} while (0)
#define LGLog(...) do {} while (0)
#define CHECK(c,m) do { if(!(c)){puts("FAIL " m);return 1;} } while(0)
'''
CHECKS = r'''
int main(void) { @autoreleasepool {
    UISwitch *owner=[[UISwitch alloc] initWithFrame:CGRectMake(0,0,51,31)];
    owner.enabled=NO;owner.on=YES;owner.window=[UIView new];
    __block NSUInteger nativeCallbacks=0;
    [owner addAction:[UIAction actionWithHandler:^(UIAction *a){nativeCallbacks++;}]
        forControlEvents:UIControlEventValueChanged];
    LGInstallSettingsSwitch(owner);
    LGPrefsLiquidSwitch *overlay=objc_getAssociatedObject(owner,kLGSettingsSwitchOverlayKey);
    CHECK(overlay && !overlay.enabled, "initial disabled state not copied");
    __block BOOL completed=NO;
    dispatch_async(dispatch_get_main_queue(), ^{owner.enabled=YES;completed=YES;});
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:1];
    while(!completed && deadline.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:deadline];
    CHECK(completed && owner.enabled && overlay.enabled, "async enable left overlay disabled");
    CHECK(owner.on && overlay.on && !owner.events, "enabled update changed on/valueChanged");
    owner.enabled=NO;
    CHECK(!overlay.enabled, "disable left overlay enabled");
    [overlay simulateTap];CHECK(!nativeCallbacks, "disabled control delivered action");
    for(int i=0;i<100;i++)owner.enabled=(i%2)==0;
    owner.enabled=YES;
    CHECK(creations==1 && owner.children.count==1 && overlay.actions.count==1,
          "duplicate overlay or action binding");
    CHECK(owner.actions.count==1 && !owner.events, "native targets or events changed");
    [overlay simulateTap];
    CHECK(nativeCallbacks==1 && owner.events==1 && !owner.on,
          "one action did not forward exactly once");
    NSUInteger previous=installs;overlay.enabled=NO;
    CHECK(installs==previous, "overlay enabled setter recursively installed controls");
    UISwitch *detached=[[UISwitch alloc] initWithFrame:CGRectMake(0,0,51,31)];
    detached.enabled=YES;CHECK(!objc_getAssociatedObject(detached,kLGSettingsSwitchOverlayKey), "detached owner gained overlay");
    detached.window=[UIView new];detached.ownPrefs=YES;detached.enabled=NO;
    CHECK(!objc_getAssociatedObject(detached,kLGSettingsSwitchOverlayKey), "own preferences filter ignored");
    detached.ownPrefs=NO;gLGSwitchControlsEnabled=NO;detached.enabled=YES;
    CHECK(!objc_getAssociatedObject(detached,kLGSettingsSwitchOverlayKey), "disabled global feature gained overlay");
    puts("PASS async NO/YES sync, on preservation, one event, no recursion/duplicate overlay, filters");
    return 0;
} }
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--revision")
    args = parser.parse_args()
    source = (subprocess.check_output(["git", "show", args.revision + ":Hooks/Controls.x"], cwd=ROOT, text=True)
              if args.revision else (ROOT / "Hooks/Controls.x").read_text())
    hook = source.split("%hook UISwitch\n", 1)[1].split("%end", 1)[0]
    enabled = (function(hook, "- (void)setEnabled:(BOOL)enabled").replace("%orig;", "[super setEnabled:enabled];")
               if "- (void)setEnabled:" in hook else "")
    code = SUPPORT + function(source, "static void LGRemoveSettingsSwitch(")
    code += function(source, "static void LGInstallSettingsSwitch(")
    profiled = function(source, "static void LGProfiledInstallSettingsSwitch(")
    code += profiled.replace("{", "{ installs++;", 1)
    code += "\n@implementation UISwitch\n" + enabled + "\n@end\n" + CHECKS
    with tempfile.TemporaryDirectory(prefix="liquidass-switch-enabled-") as tmp:
        test, binary = Path(tmp)/"test.m", Path(tmp)/"test"
        test.write_text(code)
        subprocess.run(["xcrun", "clang", "-fobjc-arc", "-framework", "Foundation",
                        "-framework", "CoreGraphics", str(test), "-o", str(binary)], check=True)
        return subprocess.run([str(binary)]).returncode


if __name__ == "__main__":
    raise SystemExit(main())
