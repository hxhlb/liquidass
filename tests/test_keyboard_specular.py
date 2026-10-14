#!/usr/bin/env python3.11
"""Exercise the production keyboard override block against its existing switch."""
from pathlib import Path
import argparse
import subprocess
import tempfile
from test_widget_host import function

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--revision')
    args = parser.parse_args()
    source = (subprocess.check_output(['git', 'show', args.revision + ':Hooks/Keyboard.x'],
                                     cwd=ROOT, text=True)
              if args.revision else (ROOT / 'Hooks/Keyboard.x').read_text())
    update = function(source, 'static void LGUpdateKeyboardGlass(UIView *stock) {')
    assert 'glass.lgSpecularEnabledOverride = @NO;' not in update, 'keyboard ignores its advertised specular switch'
    start = update.index('id specular = LGGlassPreferenceValue(@"Keyboard.SpecularEnabled");')
    end = update.index('glass.frame = mergedFrame;', start)
    block = update[start:end]
    assert start > update.index('} else if (glass.superview != container)'), 'existing glass must update on preference reload'
    code = r'''
#import <Foundation/Foundation.h>
#include <assert.h>
static id preference;
static id LGGlassPreferenceValue(NSString *key) { assert([key isEqual:@"Keyboard.SpecularEnabled"]); return preference; }
@interface Glass:NSObject
@property(copy) NSNumber *lgSpecularEnabledOverride;
@end
@implementation Glass @end
static void update(Glass *glass) { BLOCK }
int main(){@autoreleasepool{
 Glass *glass=[Glass new];
 preference=nil;update(glass);assert(glass.lgSpecularEnabledOverride.boolValue);
 preference=@NO;update(glass);assert(!glass.lgSpecularEnabledOverride.boolValue);
 preference=@YES;update(glass);assert(glass.lgSpecularEnabledOverride.boolValue);
 preference=@"invalid";update(glass);assert(glass.lgSpecularEnabledOverride.boolValue);
 preference=@NO;update(glass);assert(!glass.lgSpecularEnabledOverride.boolValue);
 puts("PASS keyboard specular default/on/off/invalid values and updates on an existing glass; advertised switch is no longer forced off");
}return 0;}
'''.replace('BLOCK', block)
    with tempfile.TemporaryDirectory(prefix='liquidass-keyboard-specular-') as tmp:
        test, binary = Path(tmp) / 'test.m', Path(tmp) / 'test'
        test.write_text(code)
        subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-framework', 'Foundation',
                        str(test), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == '__main__':
    main()
