#!/usr/bin/env python3.11
"""Validate diagnostic getter ABIs and ensure snapshots do not write rendering."""
from pathlib import Path
import re
import subprocess
import tempfile
from test_widget_host import function

ROOT = Path(__file__).resolve().parents[1]


def main():
    source = (ROOT / 'Hooks/KeyboardDiagnostics.h').read_text()
    assert not re.search(r'\b(?:view|layer|primary|window)\.\w+\s*=', source)
    assert '@"text"' not in source and '@"attributedText"' not in source
    assert 'gLGKeyboardSceneSnapshots >= 8' in source
    assert 'visited++ < 400 && views.count < 80' in source
    code = r'''
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <assert.h>
@interface Probe:NSObject
+(NSString*)label;
-(NSString*)label;-(BOOL)flag;-(double)scalar;-(float)fraction;
-(long long)integer;-(CGRect)frame;-(void)touch;-(id)withArgument:(id)value;
@property NSUInteger touches;
@end
@implementation Probe
+(NSString*)label{return @"class";}
-(NSString*)label{return @"instance";}
-(BOOL)flag{return YES;}
-(double)scalar{return 20.5;}
-(float)fraction{return .25f;}
-(long long)integer{return 3901;}
-(CGRect)frame{self.touches++;return CGRectZero;}
-(void)touch{self.touches++;}
-(id)withArgument:(id)value{self.touches++;return value;}
@end
'''
    code += function(source, 'static id LGKeyboardDiagnosticObject(')
    code += function(source, 'static NSNumber *LGKeyboardDiagnosticNumber(')
    code += r'''
int main(){@autoreleasepool{
 Probe *p=[Probe new];
 assert([LGKeyboardDiagnosticObject(p,@"label")isEqual:@"instance"]);
 assert([LGKeyboardDiagnosticObject(Probe.class,@"label")isEqual:@"class"]);
 assert(LGKeyboardDiagnosticNumber(p,@"flag").boolValue);
 assert(LGKeyboardDiagnosticNumber(p,@"scalar").doubleValue==20.5);
 assert(LGKeyboardDiagnosticNumber(p,@"fraction").floatValue==.25f);
 assert(LGKeyboardDiagnosticNumber(p,@"integer").longLongValue==3901);
 for(NSString *name in @[@"frame",@"touch",@"withArgument:",@"absent"]){
  assert(!LGKeyboardDiagnosticObject(p,name));assert(!LGKeyboardDiagnosticNumber(p,name));
 }
 assert(!LGKeyboardDiagnosticObject(nil,@"label"));
 assert(!LGKeyboardDiagnosticNumber(nil,@"scalar"));
 assert(!LGKeyboardDiagnosticObject(p,@"integer"));
 assert(!LGKeyboardDiagnosticNumber(p,@"label"));
 assert(p.touches==0);
 puts("PASS diagnostic object/meta/numeric ABIs; unsupported methods never called; rendering setters/text reads absent and collection bounded");
}return 0;}
'''
    with tempfile.TemporaryDirectory(prefix='liquidass-keyboard-scene-') as tmp:
        test, binary = Path(tmp) / 'test.m', Path(tmp) / 'test'
        test.write_text(code)
        subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-framework', 'Foundation',
                        '-framework', 'CoreGraphics', str(test), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == '__main__':
    main()
