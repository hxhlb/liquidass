#pragma once
#import <Foundation/Foundation.h>
#import <notify.h>
#include <stdint.h>
#include <math.h>

// Mirror the render process's read result into the UI log without relying on
// backboardd being able to append to the UI's filesystem namespace.
enum { LGRendererDiagStatus, LGRendererDiagLight, LGRendererDiagDark, LGRendererDiagCount };
static const uint64_t kLGRendererDiagMagic = UINT64_C(0x4c47000000000000);

static inline int LGRendererDiagToken(NSUInteger index) {
    static int tokens[LGRendererDiagCount] = {-1, -1, -1};
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *names[] = {"dylv.liquidglass/renderer-read-status",
            "dylv.liquidglass/renderer-island-light", "dylv.liquidglass/renderer-island-dark"};
        for (NSUInteger i = 0; i < LGRendererDiagCount; i++)
            if (notify_register_check(names[i], &tokens[i]) != NOTIFY_STATUS_OK) tokens[i] = -1;
    });
    return tokens[index];
}

static inline uint32_t LGRendererDiagRGBA(float r, float g, float b, float a) {
    return ((uint32_t)lroundf(fminf(1, fmaxf(0, r)) * 255) << 24)
        | ((uint32_t)lroundf(fminf(1, fmaxf(0, g)) * 255) << 16)
        | ((uint32_t)lroundf(fminf(1, fmaxf(0, b)) * 255) << 8)
        | (uint32_t)lroundf(fminf(1, fmaxf(0, a)) * 255);
}

static inline void LGRendererDiagWrite(NSUInteger index, uint16_t generation, uint32_t value) {
    int token = LGRendererDiagToken(index);
    if (token >= 0) notify_set_state(token, kLGRendererDiagMagic | ((uint64_t)generation << 32) | value);
}

static inline BOOL LGRendererDiagRead(uint32_t *status, uint32_t *light, uint32_t *dark) {
    uint64_t states[LGRendererDiagCount] = {};
    for (NSUInteger i = 0; i < LGRendererDiagCount; i++) {
        int token = LGRendererDiagToken(i);
        if (token < 0 || notify_get_state(token, &states[i]) != NOTIFY_STATUS_OK
            || (states[i] & UINT64_C(0xffff000000000000)) != kLGRendererDiagMagic) return NO;
    }
    if ((states[0] >> 32) != (states[1] >> 32) || (states[0] >> 32) != (states[2] >> 32)) return NO;
    *status = (uint32_t)states[0]; *light = (uint32_t)states[1]; *dark = (uint32_t)states[2];
    return YES;
}
