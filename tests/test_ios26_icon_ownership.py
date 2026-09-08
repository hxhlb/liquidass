#!/usr/bin/env python3.11
"""Exercise the production provider/consumer routing with an evicted registry.

Uses real CoreGraphics images and the production function bodies. Rendering and
the evictable provenance registry are test doubles; bitmap rendering is covered
by test_ios26_icon_pixels.py. No device or UIKit lifecycle is simulated here.
"""

from pathlib import Path
import subprocess
import tempfile

from test_ios26_icon_pixels import PREFIX


def function(text, name):
    start = text.index("static ", text.rfind("\n\n", 0, text.index(name)))
    opening = text.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        if text[end] == "{":
            depth += 1
        elif text[end] == "}":
            depth -= 1
        end += 1
    return text[start:end]


STUBS = r'''
#import <objc/runtime.h>
#import <assert.h>
static BOOL globalProvider;
static NSUInteger renders, registrations;
static char originalKey, processedKey, signatureKey;
static void *kLGIOS26ProviderOriginalCGImageKey = &originalKey;
static void *kLGIOS26ProviderProcessedImageKey = &processedKey;
static void *kLGIOS26ProviderSignatureKey = &signatureKey;
static BOOL LGIOS26ProviderProcessingEnabled(void) { return globalProvider; }
static NSString *LGIOS26StaticImageSignature(void) { return @"clear-soft-dark"; }
static BOOL LGIOS26ProviderImageIsEligible(id object, CGImageRef image) {
    return globalProvider && object && image;
}
static CGFloat LGIOS26ProviderScale(id object) { return 3; }
// Simulate missing pointer provenance throughout, including a provider cache hit.
static UIImage *LGIOS26ProviderOriginalImageForImage(UIImage *image) { return nil; }
static UIImage *LGIOS26CachedProviderImage(UIImage *image, NSString *signature) { return nil; }
static void LGIOS26RegisterProviderImage(UIImage *original, UIImage *processed, NSString *signature) {
    registrations++;
}
static UIImage *makeImage(CGImageRef input) {
    uint8_t bytes[16] = {40, 80, 120, 255};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(bytes, 2, 2, 8, 8, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (input) CGContextDrawImage(ctx, CGRectMake(0, 0, 2, 2), input);
    CGImageRef cg = CGBitmapContextCreateImage(ctx);
    UIImage *result = [UIImage imageWithCGImage:cg scale:3 orientation:UIImageOrientationUp];
    CGImageRelease(cg); CGContextRelease(ctx); CGColorSpaceRelease(cs);
    return result;
}
static UIImage *LGIOS26RenderImageForCurrentMode(UIImage *input) {
    renders++;
    return makeImage(input.CGImage);
}
'''

MAIN = r'''
int main(void) { @autoreleasepool {
    UIImage *raw = makeImage(NULL);
    NSObject *provider = [NSObject new];
    globalProvider = YES;
    CGImageRef supplied = LGIOS26ProviderProcessedCGImage(provider, raw.CGImage);
    assert(renders == 1 && supplied != raw.CGImage);
    UIImage *copy = makeImage(supplied);
    assert(copy.CGImage != supplied);
    for (int i = 0; i < 1000; i++) {
        assert(LGIOS26StaticImageForCurrentMode(copy) == copy);
    }
    assert(renders == 1); // Copying/losing provenance must not cause a second pass.
    assert(LGIOS26ProviderProcessedCGImage(provider, raw.CGImage) == supplied);
    assert(renders == 1 && registrations == 2);
    globalProvider = NO;
    assert(LGIOS26ProviderProcessedCGImage(provider, raw.CGImage) == raw.CGImage);
    assert(LGIOS26StaticImageForCurrentMode(raw) != raw);
    assert(renders == 2); // Local-only mode still performs conversion.
    assert(LGIOS26StaticImageForCurrentMode(raw) != raw);
    assert(renders == 3);
    puts("PASS global provider converts once; copied images survive 1000 consumer calls; registry eviction and local-only routing checked");
} return 0; }
'''


def main():
    root = Path(__file__).resolve().parents[1]
    text = (root / "Hooks/IOS26Icons.x").read_text()
    consumer = function(text, "LGIOS26StaticImageForCurrentMode(UIImage *image)")
    provider = function(text, "LGIOS26ProviderProcessedCGImage(id imageObject")
    with tempfile.TemporaryDirectory(prefix="liquidass-icon-ownership-") as directory:
        source = Path(directory) / "ownership.m"
        binary = Path(directory) / "ownership"
        source.write_text(PREFIX + STUBS + consumer + provider + MAIN)
        subprocess.run(["xcrun", "clang", "-fobjc-arc", "-O2", "-framework", "Foundation",
                        "-framework", "CoreGraphics", str(source), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    main()
