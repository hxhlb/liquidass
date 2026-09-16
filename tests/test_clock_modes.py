#!/usr/bin/env python3.11
"""Exercise production clock mode selection, container choice and restoration.

Uses Foundation UI doubles; does not claim device rendering/depth validation.
"""
from pathlib import Path
import subprocess
import tempfile
from test_clock_icon_ownership import function

ROOT = Path(__file__).resolve().parents[1]
PRELUDE = r'''
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#include <assert.h>
#include <stdio.h>
#define CALayer LGTestLayer
#define CAShapeLayer LGTestShapeLayer
#define CATransaction LGTestTransaction
@interface CALayer : NSObject
@property(copy) NSArray *filters;
@property(strong) NSNumber *scale;
@property float opacity;
@property BOOL masksToBounds;
@end
@implementation CALayer @end
@interface CAShapeLayer : CALayer @end
@implementation CAShapeLayer @end
@interface CATransaction : NSObject
+ (void)begin; + (void)commit; + (void)setDisableActions:(BOOL)value;
@end
@implementation CATransaction
+ (void)begin {} + (void)commit {} + (void)setDisableActions:(BOOL)value {}
@end
@interface UIView : NSObject
@property(strong) UIView *superview;
@property(strong) UIView *maskView;
@property(strong) CALayer *layer;
@property BOOL clipsToBounds;
@property BOOL hidden;
@property CGFloat alpha;
@property CGRect frame;
- (void)removeFromSuperview;
@end
@implementation UIView
- (instancetype)init { if ((self=[super init])) { _layer=[CALayer new]; _alpha=1; } return self; }
- (void)removeFromSuperview { self.superview=nil; }
@end
@interface CSCoverSheetView : UIView @end
@implementation CSCoverSheetView @end
@interface CSProminentDisplayView : UIView @end
@implementation CSProminentDisplayView @end
@interface SBFLockScreenDateView : UIView @end
@implementation SBFLockScreenDateView @end
@interface UIFont : NSObject @end
@implementation UIFont @end
@interface UILabel : UIView
@property(strong) UIFont *font;
@end
@implementation UILabel @end
@interface LGLiveBackdropView : UIView @end
@implementation LGLiveBackdropView @end
static NSString *modePreference;
static NSString *LG_prefString(NSString *key, NSString *fallback) { return modePreference ?: fallback; }
static NSString *LGFilterTypeForHostPrefix(NSString *prefix) { return @"dylv.liquidglass.clock"; }
static BOOL LGClockIsLegacyHost(UIView *view) { return [view isKindOfClass:SBFLockScreenDateView.class]; }
static BOOL LGDebugLoggingEnabled(void) { return NO; }
static void *kLGClockOriginalFontKey = &kLGClockOriginalFontKey;
#define LGClockLog(...) do {} while (0)
static void LGClockApplyFontToSourceLabel(UILabel *label, UIFont *font, BOOL embolden) { label.font=font; }
'''

CHECKS = r'''
@end
int main(void) { @autoreleasepool {
    assert(!LGClockUsesCustomLayer());
    modePreference=@"unknown"; assert(!LGClockUsesCustomLayer());
    modePreference=@"custom"; assert(LGClockUsesCustomLayer());
    modePreference=@"native"; assert(!LGClockUsesCustomLayer());
    UIView *host=[UIView new], *sheet=[CSCoverSheetView new];
    UIView *display=[CSProminentDisplayView new];
    host.superview=display; display.superview=sheet;
    assert(LGClockFindRenderContainer(host)==display);
    host.superview=sheet; assert(LGClockFindRenderContainer(host)==sheet);
    host.superview=nil; assert(LGClockFindRenderContainer(host)==host);
    UIView *legacy=[SBFLockScreenDateView new]; legacy.superview=display;
    assert(LGClockFindRenderContainer(legacy)==display);

    LGClockState *s=[LGClockState new];
    UILabel *label=[UILabel new]; UIView *visible=[UIView new];
    UIFont *original=[UIFont new];
    s.sourceLabel=label; s.visibleSourceView=visible; s.originalFont=original;
    s.originalLabelAlpha=.8; s.originalVisibleSourceAlpha=.6;
    s.originalVisibleSourceLayerOpacity=.7;
    s.originalLabelFrame=CGRectMake(10,20,100,90); s.directFontApplied=YES;
    s.directClipState=@[@[label,@YES,@YES]];
    label.alpha=0; label.hidden=YES; visible.hidden=YES; visible.alpha=0;
    CALayer *backdrop=[CALayer new];
    id frosting=@{@"type":@"colorMatrix"}, other=@{@"type":@"systemOther"};
    id ours=@{@"type":@"dylv.liquidglass.clock.nativeMask.refresh"};
    id later=@{@"type":@"systemLater"};
    backdrop.filters=@[other,ours,later]; backdrop.scale=@1;
    s.systemBackdropLayer=backdrop; s.systemBackdropBaseFilters=@[frosting,other];
    s.originalSystemBackdropScale=@.1;
    UIView *portal=[UIView new]; portal.layer.opacity=0;
    s.systemAnimatingPortalView=portal; s.hasOriginalSystemPortalOpacity=YES;
    s.originalSystemPortalOpacity=.9;
    LGLiveBackdropView *glass=[LGLiveBackdropView new]; glass.superview=display;
    UIView *pull=[UIView new]; pull.superview=display;
    UIView *mask=[UIView new]; pull.maskView=mask;
    s.glassView=glass; s.pullBlurView=pull; s.glyphMaskView=mask;
    s.pullBlurKnown=s.pullBlurActive=YES;
    s.renderContainer=display; s.hasRenderContainerState=YES;
    s.originalRenderContainerClipsToBounds=YES; s.originalRenderContainerMasksToBounds=YES;
    s.lastSignature=@"cached";
    [s restore];
    assert(label.font==original && CGRectEqualToRect(label.frame,CGRectMake(10,20,100,90)));
    assert(fabs(label.alpha-.8)<.001 && !label.hidden);
    assert(label.clipsToBounds && label.layer.masksToBounds);
    assert(!visible.hidden && fabs(visible.alpha-.6)<.001 && fabs(visible.layer.opacity-.7)<.001);
    assert(([backdrop.filters isEqual:@[frosting,other,later]]));
    assert([backdrop.scale isEqual:@.1] && fabs(portal.layer.opacity-.9)<.001);
    assert(!s.systemBackdropLayer && !s.originalSystemBackdropScale);
    assert(!glass.superview && !pull.superview && !pull.maskView);
    assert(!s.glassView && !s.pullBlurView && !s.glyphMaskView);
    assert(!s.pullBlurKnown && !s.pullBlurActive && !s.sourceLabel && !s.lastSignature);
    assert(display.clipsToBounds && display.layer.masksToBounds);
    [s restore]; // idempotent; must not disturb the restored system filters
    assert(([backdrop.filters isEqual:@[frosting,other,later]]));
    puts("PASS mode defaults, modern/legacy container selection, native filters/scale/font restoration, custom layer cleanup");
} return 0; }
'''


def main():
    clock = (ROOT / "Hooks/Clock.x").read_text()
    source = PRELUDE
    for sig in ["static BOOL LGClockUsesCustomLayer(", "static UIView *LGClockFindRenderContainer(",
                "static NSString *LGClockFilterObjectType(", "static BOOL LGClockFilterTypeIsOurs(",
                "static NSArray *LGClockFiltersByRemovingOurs("]:
        source += function(clock, sig) + "\n"
    start = clock.index("@interface LGClockState :")
    source += clock[start:clock.index("@end", start)+4] + "\n"
    source += function(clock, "static void LGClockRestoreDirectFontState(") + "\n"
    source += "@implementation LGClockState\n"
    source += function(clock, "- (void)restoreSystemClockRendering {") + "\n"
    source += function(clock, "- (void)restore {") + CHECKS
    # Verify the actual apply entry performs teardown before capturing the new source.
    apply = function(clock, "- (void)applyReason:(NSString *)reason {")
    assert apply.index("self.customLayerMode != customLayerMode") < apply.index("UILabel *label")
    transition = apply[apply.index("self.customLayerMode != customLayerMode"):apply.index("UILabel *label")]
    assert transition.index("[self restore]") < transition.index("self.customLayerMode = customLayerMode")
    assert "customLayerMode ? nil : LGClockSystemBackdropView(label)" in apply
    assert "if (variableFontEnabled && !customLayerMode)" in apply
    assert "customLayerMode ? renderContainer.bounds : canvasFrame" in apply
    with tempfile.TemporaryDirectory(prefix="liquidass-clock-modes-") as tmp:
        src, exe = Path(tmp)/"modes.m", Path(tmp)/"modes"
        src.write_text(source)
        subprocess.run(["xcrun", "clang", "-fobjc-arc", "-Wno-incomplete-implementation",
                        "-framework", "Foundation", "-framework", "CoreGraphics", str(src), "-o", str(exe)], check=True)
        subprocess.run([str(exe)], check=True)


if __name__ == "__main__":
    main()
