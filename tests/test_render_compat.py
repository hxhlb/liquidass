#!/usr/bin/env python3.11
"""Compile production render wrappers and scanner against argument/fixture probes.

The Metal body is replaced by its verbatim original-Gaussian forwarding block.
This verifies callback argument preservation, not GPU rendering on a device.
"""

from pathlib import Path
import subprocess
import tempfile


def function(text, signature):
    start = text.index(signature)
    opening = text.index("{", start)
    end, depth = opening + 1, 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


PREFIX = r'''
#include <simd/simd.h>
#include <cassert>
#include <cstdint>
#include <cstddef>
#include <cstdio>
#include <thread>
#include <cstring>
static void lglog(const char *, ...) {}
static void rlog(const char *, ...) {}
static ptrdiff_t g_filterAtomOffset = 0;
static bool custom;
static bool lgIsCustomAtom(uint32_t atom) { return custom && atom == 1; }
static thread_local bool g_inLegacyRender = false;
static thread_local simd_float2 g_legacyRenderOffset = {0, 0};
static thread_local bool g_inExtendedRender = false;
static thread_local void *g_extendedRenderShape = nullptr;
struct Capture {
    int abi;
    void *self, *filter, *layer, *ctx, *surface, *cm, *shape, *extra;
    float opacity, scale;
    bool flag;
    float *out;
    simd_float2 offset;
};
static thread_local Capture captured;
static void spy13(void *self, void *filter, void *layer, void *ctx, float opacity,
    void *surface, float scale, bool flag, void *cm, void *shape, float *out) {
    captured = {13, self, filter, layer, ctx, surface, cm, shape, nullptr, opacity, scale, flag, out, {0,0}};
    *out = 13;
}
static void spy14(void *self, void *filter, void *layer, void *ctx, float opacity,
    void *surface, float scale, simd_float2 offset, void *cm, void *shape, float *out) {
    captured = {14, self, filter, layer, ctx, surface, cm, shape, nullptr, opacity, scale, false, out, offset};
    *out = 14;
}
static void spy18(void *self, void *filter, void *layer, void *ctx, float opacity,
    void *surface, float scale, bool flag, void *cm, void *shape, void *extra, float *out) {
    captured = {18, self, filter, layer, ctx, surface, cm, shape, extra, opacity, scale, flag, out, {0,0}};
    *out = 18;
}
'''

MAIN = r'''
static void checkCommon(uint32_t *filter, float *out) {
    assert(captured.self == (void *)11 && captured.filter == filter);
    assert(captured.layer == (void *)22 && captured.ctx == (void *)33);
    assert(captured.surface == (void *)44 && captured.cm == (void *)55);
    assert(captured.shape == (void *)66 && captured.out == out);
    assert(captured.opacity == 0.75f);
    assert(captured.scale == (custom ? 0.0f : 0.5f));
}
int main() {
    uint32_t filter = 1;
    for (bool mode : {false, true}) {
        custom = mode;
        float out = -1;
        ourGaussianRenderHook((void *)11, &filter, (void *)22, (void *)33,
            0.75f, (void *)44, 0.5f, true, (void *)55, (void *)66, &out);
        checkCommon(&filter, &out); assert(captured.abi == 13 && captured.flag && out == 13);
        simd_float2 offset = {3.25f, -4.5f};
        ourGaussianRender14Hook((void *)11, &filter, (void *)22, (void *)33,
            0.75f, (void *)44, 0.5f, offset, (void *)55, (void *)66, &out);
        checkCommon(&filter, &out); assert(captured.abi == 14 && out == 14);
        assert(captured.offset[0] == offset[0] && captured.offset[1] == offset[1]);
        ourGaussianRender18Hook((void *)11, &filter, (void *)22, (void *)33,
            0.75f, (void *)44, 0.5f, true, (void *)55, (void *)66, (void *)77, &out);
        checkCommon(&filter, &out); assert(captured.abi == 18 && out == 18);
        assert(captured.flag && captured.extra == (void *)77);
        assert(!g_inExtendedRender && g_extendedRenderShape == nullptr);
    }
    custom = true;
    auto nestedScope = [&filter](uintptr_t extra) {
        float out;
        g_inExtendedRender = true;
        g_extendedRenderShape = (void *)(extra + 1);
        ourGaussianRender18Hook((void *)11, &filter, (void *)22, (void *)33,
            0.75f, (void *)44, 0.5f, false, (void *)55, (void *)66, (void *)extra, &out);
        assert(captured.extra == (void *)extra && !captured.flag && out == 18);
        assert(g_inExtendedRender && g_extendedRenderShape == (void *)(extra + 1));
    };
    std::thread first(nestedScope, 100), second(nestedScope, 200);
    first.join(); second.join();
    assert(!g_inExtendedRender && g_extendedRenderShape == nullptr);

    // Older two-float store versus the vector store observed on 18.5/22F76.
    uint32_t oldCode[80] = {0xAA0503F7, 0xAA0603F4, 0x2D0002E1, 0x39000288, 0xD65F0FFF};
    uint32_t newCode[80] = {0xD503237F, 0xAA0603F4, 0xAA0503F7, 0x0E616821,
        0x0F809020, 0xFD0002E0, 0x39000288, 0xD65F0FFF};
    uint32_t decoy[80] = {0xAA0503F7, 0xAA0603F4, 0xFD0002C0, 0x39000288, 0xD65F0FFF};
    void *table[22] = {};
    table[17] = oldCode; assert(LGResolve_EdgeInfoVtableSlot(table, 22) == 17);
    table[17] = newCode; assert(LGResolve_EdgeInfoVtableSlot(table, 22) == 17);
    table[17] = decoy; assert(LGResolve_EdgeInfoVtableSlot(table, 22) == -1);
    newCode[1] = 0; table[17] = newCode;
    assert(LGResolve_EdgeInfoVtableSlot(table, 22) == -1);
    puts("PASS old/18 render arguments, stock/custom forwarding, thread-local nested state, and old/18.5 edge-info patterns");
}
'''


def main():
    root = Path(__file__).resolve().parents[1]
    text = (root / "LiquidAssBackboardd/Tweak.mm").read_text()
    types = text[text.index("typedef void (*Render13Fn)"):text.index("typedef void     (*StopEncodersFn)")]
    original = text[text.index("    if (g_inLegacyRender && g_origGaussR14)"):
                    text.index("    uint64_t t_afterGauss")]
    forwarder = """
static Render13Fn g_origGaussR13 = spy13;
static Render14Fn g_origGaussR14 = spy14;
static Render18Fn g_origGaussR18 = spy18;
static void ourCustomRender13(void *self, void *filter, void *layer, void *ctx,
    float opacity, void *surface, float scale, bool flag, void *cm, void *shape, float *out) {
""" + original + "\n}\n"
    hooks = "\n".join(function(text, "static void " + name + "(") for name in
                      ("ourGaussianRenderHook", "ourGaussianRender18Hook", "ourGaussianRender14Hook"))
    scanner = (root / "LiquidAssBackboardd/LGSymbolResolver.mm").read_text()
    edge = function(scanner, "int LGResolve_EdgeInfoVtableSlot(")
    stubs = "void *LGSymStripCode(void *p) { return p; }\nbool LGSymAddressInQuartzCoreImage(void *p) { return p != nullptr; }\n"
    with tempfile.TemporaryDirectory(prefix="liquidass-render-compat-") as directory:
        source, binary = Path(directory) / "compat.cpp", Path(directory) / "compat"
        source.write_text(PREFIX + types + forwarder + hooks + stubs + edge + MAIN)
        subprocess.run(["xcrun", "clang++", "-std=c++17", "-O2", "-pthread", str(source), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    main()
