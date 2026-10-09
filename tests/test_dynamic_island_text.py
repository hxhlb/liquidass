#!/usr/bin/env python3.11
"""Run the production text-state codec and allocation bounds on the host."""
from pathlib import Path
import subprocess
import tempfile
from test_clock_icon_ownership import function

ROOT = Path(__file__).resolve().parents[1]


def main():
    source = (ROOT / "Hooks/DynamicIslandContent.x").read_text()
    code = r'''
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <math.h>
#include <stdint.h>
#include <assert.h>
enum {UIUserInterfaceStyleUnspecified, UIUserInterfaceStyleLight, UIUserInterfaceStyleDark};
static const uint64_t kLGIslandTextMagic = UINT64_C(0x4c47495400010000);
'''
    for signature in ("static uint64_t LGIslandTextEncode(", "static NSInteger LGIslandTextDecode(", "static BOOL LGIslandTextRectIsUsable("):
        code += function(source, signature) + "\n"
    code += r'''
int main(void) {
    assert(LGIslandTextDecode(LGIslandTextEncode(1,YES))==1);
    assert(LGIslandTextDecode(LGIslandTextEncode(2,YES))==2);
    assert(LGIslandTextDecode(LGIslandTextEncode(1,NO))==0);
    assert(LGIslandTextDecode(LGIslandTextEncode(2,NO))==0);
    assert(LGIslandTextDecode(0)==0);
    assert(LGIslandTextDecode(kLGIslandTextMagic|7)==0);
    assert(LGIslandTextDecode(kLGIslandTextMagic|0x103)==0);
    assert(LGIslandTextEncode(0,YES)==0 && LGIslandTextEncode(3,YES)==0);
    assert(LGIslandTextRectIsUsable(CGRectMake(10,8,400,80),3));
    assert(!LGIslandTextRectIsUsable(CGRectZero,3));
    assert(!LGIslandTextRectIsUsable(CGRectMake(NAN,0,10,10),3));
    assert(!LGIslandTextRectIsUsable(CGRectMake(0,0,INFINITY,10),3));
    assert(!LGIslandTextRectIsUsable(CGRectMake(0,0,4000,4000),3));
    assert(!LGIslandTextRectIsUsable(CGRectMake(0,0,10000,1),1));
    assert(!LGIslandTextRectIsUsable(CGRectMake(0,0,100,30),0));
    puts("PASS enabled/disabled Light/Dark host-state protocol, invalid state fallback and glyph bitmap allocation bounds");
    return 0;
}
'''
    with tempfile.TemporaryDirectory(prefix="liquidass-island-text-") as tmp:
        src = Path(tmp) / "test.m"
        exe = Path(tmp) / "test"
        src.write_text(code)
        subprocess.run(["xcrun", "clang", "-fobjc-arc", "-framework", "Foundation", "-framework", "CoreGraphics", str(src), "-o", str(exe)], check=True)
        subprocess.run([str(exe)], check=True)


if __name__ == "__main__":
    main()
