#!/usr/bin/env python3.11
"""Run the production bitmap functions on macOS; no SpringBoard/CA-filter simulation.

The UIImage shim only owns a CGImage. The pixel code is copied verbatim from the
production source and compiled against Foundation/CoreGraphics, so these checks
exercise the actual algorithm rather than a Python reimplementation.
"""

import argparse
import math
from pathlib import Path
import subprocess
import tempfile


PREFIX = r'''
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <math.h>
#import <stdint.h>
#import <stdlib.h>
typedef NS_ENUM(NSInteger, LGIOS26IconMode) { LGIOS26IconModeClear, LGIOS26IconModeTinted };
typedef NSInteger UIImageOrientation;
static const NSInteger UIImageOrientationUp = 0;
@interface UIImage : NSObject { CGImageRef _image; }
@property(nonatomic, readonly) CGImageRef CGImage;
@property(nonatomic) CGFloat scale;
+ (instancetype)imageWithCGImage:(CGImageRef)image scale:(CGFloat)scale orientation:(UIImageOrientation)orientation;
@end
@implementation UIImage
+ (instancetype)imageWithCGImage:(CGImageRef)image scale:(CGFloat)scale orientation:(UIImageOrientation)orientation {
    UIImage *result = [UIImage new];
    result->_image = CGImageRetain(image);
    result.scale = scale;
    return result;
}
- (CGImageRef)CGImage { return _image; }
- (void)dealloc { CGImageRelease(_image); }
@end
'''

MAIN = r'''
int main(int argc, const char **argv) { @autoreleasepool {
    if (argc != 7) return 2;
    size_t w = strtoul(argv[3], NULL, 10), h = strtoul(argv[4], NULL, 10);
    NSData *data = [NSData dataWithContentsOfFile:@(argv[1])];
    if (!w || !h || data.length != w * h * 4) return 3;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGImageRef input = CGImageCreate(w, h, 8, 32, w * 4, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big,
        provider, NULL, NO, kCGRenderingIntentDefault);
    UIImage *source = [UIImage imageWithCGImage:input scale:3 orientation:UIImageOrientationUp];
    BOOL dark = atoi(argv[5]), fresh = atoi(argv[6]);
    UIImage *processed = LGIOS26AppleMitigatedIconImage(source, dark, fresh);
    if (processed.CGImage != LGIOS26AppleMitigatedIconImage(source, dark, fresh).CGImage) return 4;
    void *bytes = calloc(h, w * 4);
    CGContextRef ctx = CGBitmapContextCreate(bytes, w, h, 8, w * 4, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGContextSetBlendMode(ctx, kCGBlendModeCopy);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), processed.CGImage);
    BOOL saved = [[NSData dataWithBytes:bytes length:w * h * 4] writeToFile:@(argv[2]) atomically:YES];
    NSURL *url = [NSURL fileURLWithPath:[@(argv[2]) stringByAppendingString:@".png"]];
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(dst, processed.CGImage, NULL);
    saved = CGImageDestinationFinalize(dst) && saved;
    CFRelease(dst);
    CGContextRelease(ctx);
    free(bytes);
    CGImageRelease(input);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(cs);
    if (!saved) return 5;
} return 0; }
'''


def fixture(name, size):
    pixels = bytearray(size * size * 4)
    for y in range(size):
        for x in range(size):
            u, v = x / size, y / size
            rgb = [30, 120, 210]
            if name == "gradient":
                rgb = [round(30 + 22 * v), round(110 + 28 * v), round(200 + 30 * v)]
            elif name == "diagonal-gradient":
                t = (u + v) * 0.5
                rgb = [round(30 + 22 * t), round(110 + 28 * t), round(200 + 30 * t)]
            if name == "complex":
                rgb = [int(127 + 115 * math.sin(u * 22.8 + v * 13.2 + c * 2.1))
                       for c in range(3)]
            elif name in ("red", "green", "blue"):
                rgb = [240, 240, 240]
            inside = 0.29 <= u < 0.71 and 0.25 <= v < 0.75
            alpha = 255
            if inside:
                rgb = [240, 240, 240]
                if name == "internal" and 0.44 <= u < 0.57 and 0.36 <= v < 0.64:
                    rgb = [40, 40, 40]
                elif name == "lowcontrast":
                    rgb = [50, 140, 230]
                elif name == "alpha":
                    alpha = 128
                elif name in ("red", "green", "blue"):
                    rgb = [20, 20, 20]
                    rgb[("red", "green", "blue").index(name)] = 230
            if name == "transparent":
                alpha = 0
            offset = (y * size + x) * 4
            pixels[offset:offset + 4] = bytes([round(c * alpha / 255) for c in rgb] + [alpha])
    return pixels


def pixel(data, size, x, y):
    offset = (int(y * size) * size + int(x * size)) * 4
    return data[offset:offset + 4]


def check(name, size, dark, fresh, source, output):
    center = pixel(output, size, 0.50, 0.50)
    body = pixel(output, size, 0.36, 0.50)
    background = pixel(output, size, 0.15, 0.50)
    errors = []
    if len(source) != len(output):
        return ["dimensions changed"]
    if any(max(output[i:i + 3]) > output[i + 3] or output[i + 3] > source[i + 3]
           for i in range(0, len(source), 4)):
        errors.append("invalid premultiplied RGBA or increased source coverage")
    if name == "transparent":
        if any(output):
            errors.append("transparent input became visible")
        return errors
    if name not in ("lowcontrast", "alpha") and center[3] < 175:
        errors.append(f"glyph interior too faint: alpha {center[3]}")
    if name != "complex" and background[3] > 30:
        errors.append(f"coherent background became opaque: alpha {background[3]}")
    if name in ("solid", "internal", "red", "green", "blue"):
        outside = pixel(output, size, (math.ceil(0.29 * size) - 1) / size, 0.50)
        if outside[3] > 30:
            errors.append(f"edge detection painted an opaque outer halo: alpha {outside[3]}")
    if name == "solid":
        inside = pixel(output, size, math.ceil(0.29 * size) / size, 0.50)
        if abs(inside[0] / max(1, inside[3]) - body[0] / max(1, body[3])) > 0.10:
            errors.append("subject bevel is an excessively dark second outline")
    if name in ("gradient", "diagonal-gradient"):
        background_alpha = [pixel(output, size, 0.15, y / size)[3] for y in range(size)]
        if max(background_alpha) - min(background_alpha) > 8 or max(background_alpha) > 30:
            errors.append("background gradient became visible stripes")
    if name == "complex" and center[3] - background[3] < 60:
        errors.append("glyph interior does not stand out from textured background")
    if name == "internal" and body[0] / body[3] - center[0] / max(1, center[3]) < 0.14:
        errors.append("internal dark detail flattened into the white glyph")
    if name == "lowcontrast" and center[3] < 90:
        errors.append(f"low-contrast subject lost: alpha {center[3]}")
    if name == "alpha" and not 90 <= center[3] <= 128:
        errors.append(f"half-alpha glyph coverage incorrect: {center[3]}")
    if name in ("red", "green", "blue") and fresh:
        channel = ("red", "green", "blue").index(name)
        if center[channel] - max(center[c] for c in range(3) if c != channel) < 100:
            errors.append("fresh subject lost its original color")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path,
                        default=Path(__file__).resolve().parents[1] / "Shared/LGIOS26IconView.m")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    output = args.output or Path(tempfile.mkdtemp(prefix="liquidass-icon-pixels-"))
    output.mkdir(parents=True, exist_ok=True)
    text = args.source.read_text()
    helpers = text[text.index("static CGFloat LGIOS26Clamp"):text.index("static id LGIOS26NewFilter")]
    pixels = text[text.index("static void LGIOS26ReadPixel"):text.index("UIImage *LGIOS26GrayscaleIconImage")]
    harness = output / "pixels.m"
    harness.write_text(PREFIX + helpers + pixels + MAIN)
    binary = output / "pixels"
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-O2", "-framework", "Foundation",
                    "-framework", "CoreGraphics", "-framework", "ImageIO", str(harness),
                    "-o", str(binary)], check=True)
    failures, cases = [], 0
    for size in (60, 120, 180):
        for name in ("solid", "complex", "internal", "lowcontrast", "alpha", "gradient", "diagonal-gradient",
                     "red", "green", "blue", "transparent"):
            source = fixture(name, size)
            source_path = output / f"{name}-{size}.rgba"
            source_path.write_bytes(source)
            for dark in (0, 1):
                for fresh in (0, 1):
                    label = f"{name}-{size}-dark{dark}-fresh{fresh}"
                    destination = output / f"{label}.rgba"
                    subprocess.run([str(binary), str(source_path), str(destination),
                                    str(size), str(size), str(dark), str(fresh)], check=True)
                    errors = check(name, size, dark, fresh, source, destination.read_bytes())
                    failures.extend(f"{label}: {error}" for error in errors)
                    cases += 1
    for failure in failures:
        print("FAIL", failure)
    print(f"{'FAIL' if failures else 'PASS'} {cases} bitmap cases; artifacts: {output}")
    print("Scope: production CPU pixels and cache reuse; UIKit/CA filters and device appearance require device testing.")
    raise SystemExit(bool(failures))


if __name__ == "__main__":
    main()
