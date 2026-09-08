#!/usr/bin/env python3.11
"""Run production ownership callbacks with small Foundation-backed UI doubles."""
from pathlib import Path
import argparse
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def function(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


PRELUDE = r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <string.h>
@interface UIFont : NSObject
@property(copy) NSString *fontName;
@property double pointSize;
@end
@implementation UIFont @end
@interface UIView : NSObject
@property(strong) UIView *superview;
@property(strong) UIView *window;
@end
@implementation UIView @end
@interface UILabel : UIView
@property(strong) UIFont *font;
@property(copy) NSString *text;
@property(copy) NSAttributedString *attributedText;
@property double alpha;
@property BOOL hidden;
@end
@implementation UILabel @end
@interface LGClockState : NSObject
@property(strong) UILabel *sourceLabel;
@property(strong) UIFont *originalFont;
@property BOOL applying;
@property(strong) UIView *glassView;
@end
@implementation LGClockState @end
static UIView *host;
static LGClockState *state;
static void *kLGClockOriginalFontKey = &kLGClockOriginalFontKey;
static BOOL LGClockIsHost(UIView *view) { return view == host; }
static BOOL LGClockEnabled(void) { return YES; }
static BOOL LGDebugLoggingEnabled(void) { return NO; }
static UIFont *LGClockAttributedFont(UILabel *label) { return nil; }
static BOOL LGClockIsOurFont(UIFont *font) {
    return [font.fontName containsString:@"SFAdaptiveSoftNumeric"];
}
static LGClockState *LGClockStateForHost(UIView *view, BOOL create) { return state; }
#define LGClockLog(...) do {} while (0)
@interface UIImage : NSObject
@property void *CGImage;
@end
@implementation UIImage @end
static NSCache *registry;
static BOOL providerEnabled = YES;
static NSUInteger renderCalls;
static UIImage *renderResult;
static NSCache *LGIOS26ProviderImageRegistry(void) { return registry; }
static BOOL LGIOS26ProviderProcessingEnabled(void) { return providerEnabled; }
static NSString *LGIOS26StaticImageSignature(void) { return @"clear-current"; }
static UIImage *LGIOS26RenderImageForCurrentMode(UIImage *image) {
    renderCalls++;
    return renderResult;
}
static UIFont *font(double size) {
    UIFont *f = [UIFont new]; f.fontName = @"System"; f.pointSize = size; return f;
}
static UIImage *image(uintptr_t identity) {
    UIImage *i = [UIImage new]; i.CGImage = (void *)identity; return i;
}
#define CHECK(c, message) do { if (!(c)) { puts("FAIL " message); return 1; } } while (0)
'''

CHECKS = r'''
int main(int argc, char **argv) { @autoreleasepool {
    if (strcmp(argv[1], "clock") == 0) {
        host = [UIView new]; state = [LGClockState new];
        UILabel *time = [UILabel new]; time.superview = host;
        UILabel *date = [UILabel new]; date.superview = host;
        UIFont *timeFont = font(90), *dateFont = font(22);
        state.sourceLabel = time; state.originalFont = timeFont;
        LGClockSourceFontDidChange(date, dateFont, @"date-update");
        CHECK(state.originalFont == timeFont, "date font overwrote selected clock font");
        CHECK(objc_getAssociatedObject(date, kLGClockOriginalFontKey) == dateFont,
              "date label lost its own original font");
        LGClockSourceFontDidChange(time, font(17), @"late-default");
        CHECK(state.originalFont == timeFont, "late default replaced captured time font");
        state = [LGClockState new];
        UILabel *pending = [UILabel new]; pending.superview = host;
        LGClockSourceFontDidChange(pending, timeFont, @"before-selection");
        CHECK(state.originalFont == nil, "unselected label took ownership of clock font");
        CHECK(objc_getAssociatedObject(pending, kLGClockOriginalFontKey) == timeFont,
              "initial font unavailable when selecting source later");
        UILabel *selected = [UILabel new]; selected.superview = host;
        state.sourceLabel = selected;
        LGClockSourceFontDidChange(selected, timeFont, @"selected-time");
        CHECK(state.originalFont == timeFont, "selected time could not capture its font");
        puts("PASS clock font ownership and per-label capture");
    } else {
        registry = [NSCache new];
        UIImage *original = image(1), *processed = image(2), *unknownCopy = image(3);
        NSDictionary *entry = @{@"original":original, @"processed":processed,
                                @"signature":@"clear-current"};
        [registry setObject:entry forKey:[NSValue valueWithPointer:original.CGImage]];
        [registry setObject:entry forKey:[NSValue valueWithPointer:processed.CGImage]];
        CHECK(LGIOS26StaticImageForCurrentMode(original) == processed,
              "legacy original did not reuse provider result");
        CHECK(LGIOS26StaticImageForCurrentMode(processed) == processed,
              "processed image changed again");
        CHECK(LGIOS26StaticImageForCurrentMode(unknownCopy) == unknownCopy,
              "unrecognized provider copy was reprocessed");
        CHECK(renderCalls == 0, "global mode ran consumer conversion");
        [registry setObject:@{@"original":original, @"processed":processed,
                             @"signature":@"old-mode"}
                     forKey:[NSValue valueWithPointer:original.CGImage]];
        CHECK(LGIOS26StaticImageForCurrentMode(original) == original,
              "stale appearance cache was reused");
        CHECK(LGIOS26StaticImageForCurrentMode(nil) == nil, "nil image changed");
        providerEnabled = NO; renderResult = processed;
        CHECK(LGIOS26StaticImageForCurrentMode(original) == processed && renderCalls == 1,
              "non-global conversion path changed");
        puts("PASS provider reuse, no duplicate conversion, and stale cache handling");
    }
    return 0;
} }
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--revision", help="Read callbacks from a Git revision")
    args = parser.parse_args()

    def read(path):
        if args.revision:
            return subprocess.check_output(
                ["git", "show", f"{args.revision}:{path}"], cwd=ROOT, text=True)
        return (ROOT / path).read_text()

    clock = read("Hooks/Clock.x")
    icons = read("Hooks/IOS26Icons.x")
    source = PRELUDE + function(clock, "static void LGClockSourceFontDidChange(")
    source += function(icons, "static UIImage *LGIOS26CachedProviderImage(")
    source += function(icons, "static UIImage *LGIOS26StaticImageForCurrentMode(") + CHECKS
    with tempfile.TemporaryDirectory(prefix="liquidass-ownership-") as tmp:
        test = Path(tmp) / "test.m"
        binary = Path(tmp) / "test"
        test.write_text(source)
        subprocess.run(["xcrun", "clang", "-fobjc-arc", "-framework", "Foundation",
                        "-Wno-unused-variable", str(test), "-o", str(binary)], check=True)
        results = [subprocess.run([str(binary), case]).returncode for case in ("clock", "icons")]
        return int(any(results))


if __name__ == "__main__":
    raise SystemExit(main())
