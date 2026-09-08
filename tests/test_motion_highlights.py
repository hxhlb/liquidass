#!/usr/bin/env python3.11
"""Verify the production motion policy and actual Core Animation setter counts.

Compiles the real angle-update method with instrumented CAGradientLayers on macOS.
This checks redundant-write suppression and visual coordinates, not device FPS.
"""

from pathlib import Path
import subprocess
import tempfile


def method(text, signature):
    start = text.index(signature + " {")
    opening = text.index("{", start)
    end, depth = opening + 1, 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


SUPPORT = r'''
@interface CountedGradient : CAGradientLayer
@property(nonatomic) NSUInteger writes;
@end
@implementation CountedGradient
- (void)setStartPoint:(CGPoint)value { _writes++; [super setStartPoint:value]; }
- (void)setEndPoint:(CGPoint)value { _writes++; [super setEndPoint:value]; }
@end
@interface LGLiveBackdropView : NSObject {
    CountedGradient *_specular, *_specularBoost, *_specularDark;
    BOOL _hasAppliedSpecularAngle;
    CGFloat _appliedSpecularAngle;
}
- (void)applySpecularAngle:(CGFloat)angle;
- (NSUInteger)writes;
- (void)setHighlightHidden:(BOOL)hidden;
- (CGPoint)highlightStart;
@end
@implementation LGLiveBackdropView
- (instancetype)init {
    if ((self = [super init])) {
        _specular = [CountedGradient new];
        _specularBoost = [CountedGradient new];
        _specularDark = [CountedGradient new];
    }
    return self;
}
- (NSUInteger)writes { return _specular.writes + _specularBoost.writes + _specularDark.writes; }
- (void)setHighlightHidden:(BOOL)hidden { _specular.hidden = hidden; }
- (CGPoint)highlightStart { return _specular.startPoint; }
'''

MAIN = r'''
@end
int main(void) { @autoreleasepool {
    assert(LGMotionFrameRate(0, 0) == 5);
    assert(LGMotionFrameRate(kLGMotionAngleEpsilon * 0.25, 0) == 5);
    assert(LGMotionFrameRate(0.1, 0) == 30);
    assert(LGMotionFrameRate(2 * M_PI, 0) == 5);
    LGLiveBackdropView *view = [LGLiveBackdropView new];
    [view applySpecularAngle:0];
    assert(view.writes == 6); // Three layers, two points each.
    assert(fabs(view.highlightStart.x - 1.0) < 1e-9);
    for (int i = 0; i < 10000; i++) [view applySpecularAngle:0];
    for (int i = 0; i < 10000; i++) [view applySpecularAngle:kLGMotionAngleEpsilon * 0.25];
    [view applySpecularAngle:2 * M_PI];
    [view applySpecularAngle:NAN];
    assert(view.writes == 6);
    [view applySpecularAngle:0.1];
    assert(view.writes == 12);
    assert(fabs(view.highlightStart.x - (0.5 + cos(0.1) * 0.5)) < 1e-6);
    assert(fabs(view.highlightStart.y - (0.5 + sin(0.1) * 0.5)) < 1e-6);
    [view setHighlightHidden:YES];
    [view applySpecularAngle:0.4];
    assert(view.writes == 12);
    [view setHighlightHidden:NO];
    [view applySpecularAngle:0.4];
    assert(view.writes == 18);
    LGLiveBackdropView *newView = [LGLiveBackdropView new];
    [newView applySpecularAngle:0.4];
    assert(newView.writes == 6);
    puts("PASS 20000 unchanged/subpixel updates produced zero extra layer writes; real motion, wraparound, visibility restoration, new layers, and 5/30 FPS policy checked");
} return 0; }
'''


def main():
    root = Path(__file__).resolve().parents[1]
    text = (root / "Shared/LGLiveBackdropView.m").read_text()
    policy = text[text.index("static const CGFloat kLGMotionAngleEpsilon"):
                  text.index("static void LGApplyMotionHighlightAngle")]
    update = method(text, "- (void)applySpecularAngle:(CGFloat)angle")
    with tempfile.TemporaryDirectory(prefix="liquidass-motion-test-") as directory:
        source, binary = Path(directory) / "motion.m", Path(directory) / "motion"
        source.write_text("#import <Foundation/Foundation.h>\n#import <QuartzCore/QuartzCore.h>\n"
                          "#include <math.h>\n#include <assert.h>\n" + policy + SUPPORT + update + MAIN)
        subprocess.run(["xcrun", "clang", "-fobjc-arc", "-O2", "-framework", "Foundation",
                        "-framework", "QuartzCore", str(source), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    main()
