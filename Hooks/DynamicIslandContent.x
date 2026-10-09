#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <notify.h>
#import <math.h>
#import <stdint.h>
#import <stdatomic.h>
#import <stdlib.h>
#import <string.h>
#import "../Shared/LGSharedSupport.h"

// SpringBoard owns the glass and appearance. A content service can have its own
// forced-Dark traits/preferences, so it must not decide the island's text theme.
static const char *kLGIslandTextNotification = "dylv.liquidass/island-text-appearance";
static const uint64_t kLGIslandTextMagic = UINT64_C(0x4c47495400010000);
static int sLGIslandTextToken = -1;
static _Atomic uint64_t sLGIslandTextState;
static NSHashTable<UILabel *> *sLGIslandTextLabels;
static __thread NSUInteger sLGIslandTextDrawingDepth;

static uint64_t LGIslandTextEncode(NSInteger style, BOOL enabled) {
    if (style != UIUserInterfaceStyleLight && style != UIUserInterfaceStyleDark) return 0;
    return kLGIslandTextMagic | ((uint64_t)style << 1) | (enabled ? 1 : 0);
}

static NSInteger LGIslandTextDecode(uint64_t state) {
    if ((state & ~UINT64_C(7)) != kLGIslandTextMagic || !(state & 1)) return UIUserInterfaceStyleUnspecified;
    NSInteger style = (NSInteger)((state >> 1) & 3);
    return style == UIUserInterfaceStyleLight || style == UIUserInterfaceStyleDark
        ? style : UIUserInterfaceStyleUnspecified;
}

static void LGInvalidateIslandText(void) {
    NSArray<UILabel *> *labels;
    @synchronized (sLGIslandTextLabels) { labels = sLGIslandTextLabels.allObjects; }
    for (UILabel *label in labels) [label setNeedsDisplay];
}

void LGIslandPublishTextAppearance(UIWindow *window, BOOL glassActive) {
    if (!LGIsSpringBoardProcess() || sLGIslandTextToken < 0) return;
    NSInteger style = window.traitCollection.userInterfaceStyle;
    if (style != UIUserInterfaceStyleLight && style != UIUserInterfaceStyleDark)
        style = (NSInteger)((sLGIslandTextState >> 1) & 3);
    uint64_t next = LGIslandTextEncode(style, glassActive);
    if (next == sLGIslandTextState) return;
    if (notify_set_state(sLGIslandTextToken, next) != NOTIFY_STATUS_OK) return;
    sLGIslandTextState = next;
    LGInvalidateIslandText();
    notify_post(kLGIslandTextNotification);
}

static BOOL LGIsIslandTextLabel(UILabel *label) {
    UIWindow *window = label.window;
    NSString *role = window.windowScene.session.role;
    if (role.length && [role rangeOfString:@"SystemAperture" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    NSString *windowName = window ? NSStringFromClass(window.class) : nil;
    if ([windowName isEqualToString:@"SBSystemApertureWindow"]
        || [windowName isEqualToString:@"SBUISystemApertureSecureWindow"]) return YES;
    UIView *ancestor = label.superview;
    // Some native activity labels are rasterized before their view tree gets a
    // window. The aperture ancestor still identifies that offscreen content.
    for (NSUInteger depth = 0; ancestor && depth < 24; depth++, ancestor = ancestor.superview) {
        NSString *name = NSStringFromClass(ancestor.class);
        if ([name rangeOfString:@"SystemAperture" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

static BOOL LGIslandTextRectIsUsable(CGRect rect, CGFloat scale) {
    return isfinite(rect.origin.x) && isfinite(rect.origin.y)
        && isfinite(rect.size.width) && isfinite(rect.size.height)
        && isfinite(scale) && scale > 0.0 && scale <= 4.0
        && rect.size.width > 0.0 && rect.size.height > 0.0
        && rect.size.width * scale <= 8192.0
        && rect.size.height * scale <= 8192.0
        && rect.size.width * rect.size.height * scale * scale <= 4194304.0;
}

static void LGDrawIslandText(UILabel *label, CGRect rect, void (^nativeDraw)(void)) {
    if (sLGIslandTextDrawingDepth) { nativeDraw(); return; }
    sLGIslandTextDrawingDepth++;
    @try {
        if (!LGIsIslandTextLabel(label)) { nativeDraw(); return; }
        @synchronized (sLGIslandTextLabels) { [sLGIslandTextLabels addObject:label]; }
        NSInteger style = LGIslandTextDecode(sLGIslandTextState);
        CGFloat scale = label.contentScaleFactor;
        if (!style || !UIGraphicsGetCurrentContext() || !LGIslandTextRectIsUsable(rect, scale)) {
            nativeDraw();
            return;
        }
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
        format.opaque = NO;
        format.scale = scale;
        format.preferredRange = UIGraphicsImageRendererFormatRangeStandard;
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:rect.size format:format];
        UIImage *ink = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            CGContextRef cg = context.CGContext;
            CGContextSaveGState(cg);
            CGContextTranslateCTM(cg, -rect.origin.x, -rect.origin.y);
            nativeDraw();
            CGContextRestoreGState(cg);
            // Recolor only the native glyph raster. Keep its antialiasing/alpha,
            // layout, font, truncation and marquee result; do not mutate label data.
            UIColor *color = style == UIUserInterfaceStyleLight ? UIColor.blackColor : UIColor.whiteColor;
            CGContextSetBlendMode(cg, kCGBlendModeSourceIn);
            CGContextSetFillColorWithColor(cg, color.CGColor);
            CGContextFillRect(cg, (CGRect){CGPointZero, rect.size});
        }];
        [ink drawInRect:rect];
    } @finally {
        sLGIslandTextDrawingDepth--;
    }
}

@interface UILabel (LGIslandPrivateDrawing)
- (void)drawContentsInRect:(CGRect)rect;
- (CGRect)_drawTextInRect:(CGRect)rect;
- (void)_drawFullMarqueeTextInRect:(CGRect)rect;
@end

%group LGIslandPublicTextDrawing
%hook UILabel
- (void)drawTextInRect:(CGRect)rect {
    LGDrawIslandText(self, rect, ^{ %orig(rect); });
}
%end
%end

%group LGIslandContentsTextDrawing
%hook UILabel
- (void)drawContentsInRect:(CGRect)rect {
    LGDrawIslandText(self, rect, ^{ %orig(rect); });
}
%end
%end

%group LGIslandPrivateTextDrawing
%hook UILabel
- (CGRect)_drawTextInRect:(CGRect)rect {
    __block CGRect result = CGRectZero;
    LGDrawIslandText(self, rect, ^{ result = %orig(rect); });
    return result;
}
%end
%end

%group LGIslandMarqueeVoidDrawing
%hook UILabel
- (void)_drawFullMarqueeTextInRect:(CGRect)rect {
    LGDrawIslandText(self, rect, ^{ %orig(rect); });
}
%end
%end

%group LGIslandMarqueeRectDrawing
%hook UILabel
- (CGRect)_drawFullMarqueeTextInRect:(CGRect)rect {
    __block CGRect result = CGRectZero;
    LGDrawIslandText(self, rect, ^{ result = %orig(rect); });
    return result;
}
%end
%end

static BOOL LGIslandDrawingMethodHasReturn(SEL selector, const char *type) {
    Method method = class_getInstanceMethod(UILabel.class, selector);
    if (!method) return NO;
    char *actual = method_copyReturnType(method);
    BOOL matches = actual && strcmp(actual, type) == 0;
    free(actual);
    return matches;
}

%ctor {
    if ([NSProcessInfo.processInfo.processName isEqualToString:@"backboardd"]) return;
    if (@available(iOS 16.0, *)) {
        sLGIslandTextLabels = [NSHashTable weakObjectsHashTable];
        uint32_t status = notify_register_dispatch(kLGIslandTextNotification, &sLGIslandTextToken,
                                                   dispatch_get_main_queue(), ^(int token) {
            uint64_t state = 0;
            if (notify_get_state(token, &state) == NOTIFY_STATUS_OK && state != sLGIslandTextState) {
                sLGIslandTextState = state;
                LGInvalidateIslandText();
            }
        });
        if (status != NOTIFY_STATUS_OK) { sLGIslandTextToken = -1; return; }
        uint64_t initial = 0;
        if (notify_get_state(sLGIslandTextToken, &initial) == NOTIFY_STATUS_OK)
            sLGIslandTextState = initial;
        if (LGIslandDrawingMethodHasReturn(@selector(drawTextInRect:), @encode(void))) {
            %init(LGIslandPublicTextDrawing);
        }
        if (LGIslandDrawingMethodHasReturn(@selector(drawContentsInRect:), @encode(void))) {
            %init(LGIslandContentsTextDrawing);
        }
        if (LGIslandDrawingMethodHasReturn(@selector(_drawTextInRect:), @encode(CGRect))) {
            %init(LGIslandPrivateTextDrawing);
        }
        if (LGIslandDrawingMethodHasReturn(@selector(_drawFullMarqueeTextInRect:), @encode(CGRect))) {
            %init(LGIslandMarqueeRectDrawing);
        } else if (LGIslandDrawingMethodHasReturn(@selector(_drawFullMarqueeTextInRect:), @encode(void))) {
            %init(LGIslandMarqueeVoidDrawing);
        }
    }
}
