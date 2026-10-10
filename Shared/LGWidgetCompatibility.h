#pragma once
#import <Foundation/Foundation.h>
#import <objc/message.h>

static inline id LGWidgetObjectProperty(id object, SEL selector) {
    if (![object respondsToSelector:selector]) return nil;
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (signature.numberOfArguments != 2 || signature.methodReturnType[0] != '@') return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static inline NSString *LGWidgetIdentifierForObject(id object) {
    id widget = LGWidgetObjectProperty(object, NSSelectorFromString(@"widget"));
    id identifier = LGWidgetObjectProperty(widget, NSSelectorFromString(@"extensionBundleIdentifier"));
    return [identifier isKindOfClass:NSString.class] ? identifier : nil;
}

// Photos use background/snapshot content as the actual image. Keep it native
// in both the SpringBoard host and the separate widget render process.
static inline BOOL LGWidgetPreservesPhotoContent(NSString *identifier) {
    if (![identifier isKindOfClass:NSString.class]) return NO;
    NSString *name = identifier.lowercaseString;
    if (![name hasPrefix:@"com.apple."]) return NO;
    return [name containsString:@"photo"] || [name containsString:@"slideshow"]
        || [name containsString:@"memories"] || [name containsString:@"relive"];
}
