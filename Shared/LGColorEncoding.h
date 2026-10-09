#pragma once
#import <Foundation/Foundation.h>
#include <stdint.h>

// Settings, renderer uniforms and the clock pull overlay share RGBA ordering.
static inline BOOL LGReadRGBAHex(NSString *hex, uint32_t *rgba) {
    if (![hex isKindOfClass:NSString.class] || !rgba) return NO;
    NSString *value = [hex stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([value hasPrefix:@"#"]) value = [value substringFromIndex:1];
    if (value.length != 6 && value.length != 8) return NO;
    unsigned parsed = 0;
    NSScanner *scanner = [NSScanner scannerWithString:value];
    scanner.charactersToBeSkipped = nil;
    if (![scanner scanHexInt:&parsed] || !scanner.isAtEnd) return NO;
    *rgba = value.length == 6 ? (parsed << 8) | 0xff : parsed;
    return YES;
}
