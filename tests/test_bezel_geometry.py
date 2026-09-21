#!/usr/bin/env python3.11
"""Verify legacy/point-width precedence and the actual settings predicates."""
from pathlib import Path
import subprocess,tempfile,re
from test_clock_icon_ownership import function
ROOT=Path(__file__).resolve().parents[1]
PRELUDE=r'''
#import <Foundation/Foundation.h>
#import "LGHostRegistry.h"
#import "LGBezelGeometry.h"
#import "LGRendererPreferences.h"
#include <assert.h>
#include <stdio.h>
static NSDictionary *prefs;
static id LGReadPreferenceObject(NSString *key,id fallback){return prefs[key] ?: fallback;}
'''
MAIN=r'''
int main(void){@autoreleasepool {
    assert(LGBezelPointWidth(nil,-1)==20);
    assert(LGBezelPointWidth(@(-2),20)==0);
    assert(LGBezelPointWidth(@99,20)==80);
    assert(LGBezelPointWidth(@(NAN),20)==20);
    assert(LGBezelPointWidth(@(INFINITY),20)==20);
    // Compatibility scales with the surface; points scale with pixel density.
    assert(fabs(LGBezelWidthPixels(NO,15,.2,100,2,34)-20)<1e-5);
    assert(fabs(LGBezelWidthPixels(NO,15,.2,300,2,34)-34)<1e-5);
    assert(fabs(LGBezelWidthPixels(YES,15,.2,100,2,34)-30)<1e-5);
    assert(fabs(LGBezelWidthPixels(YES,15,.2,300,2,34)-30)<1e-5);
    assert(fabs(LGBezelWidthPixels(YES,15,.2,300,3,34)-45)<1e-5);
    assert(fabs(LGBezelWidthPixels(YES,80,.2,20,3,34)-10)<1e-5);
    ResetHarness *h=[ResetHarness new];h.items=@[@{@"key":@"Enhanced.Dock.GlassThickness"}];
    [h handlePrefsUIRefresh:nil];assert(h.rebuilt==2 && h.animated==0);
    h=[ResetHarness new];h.items=@[@{@"key":@"Renderer.Profile"}];
    [h handlePrefsUIRefresh:nil];assert(h.rebuilt==2 && h.animated==0);
    h=[ResetHarness new];h.items=@[@{@"key":@"Clock.Enabled"}];
    [h handlePrefsUIRefresh:nil];assert(h.rebuilt==0 && h.animated==1);
    puts("PASS native point scaling/caps and selected-engine reset UI refresh");
}return 0;}
'''
def main():
 data=(ROOT/'LiquidAssPrefs/LGPrefsDataSupport.m').read_text();code=PRELUDE
 for sig in ['static BOOL LGSelectedRendererEnhanced(', 'BOOL LGPrefsItemIsEnabled(', 'BOOL LGPrefsItemIsVisible(']:code+=function(data,sig)+'\n'
 code+='''
@interface ResetHarness : NSObject
@property(copy) NSArray *items;
@property int rebuilt;
@property int animated;
@property(readonly) BOOL isViewLoaded;
- (void)reloadLocalizedContent;
- (void)reloadVisibleSettings;
- (void)animateVisibleControlsToDefaults;
- (void)handlePrefsUIRefresh:(NSNotification *)note;
@end
@implementation ResetHarness
- (BOOL)isViewLoaded{return YES;}
- (void)reloadLocalizedContent{self.rebuilt++;}
- (void)reloadVisibleSettings{self.rebuilt++;}
- (void)animateVisibleControlsToDefaults{self.animated++;}
'''
 code+=function((ROOT/'LiquidAssPrefs/LGPSurfaceController.m').read_text(),'- (void)handlePrefsUIRefresh:')+'\n@end\n'
 # Classic's shader body may gain only the shared uniform field.
 classic=(ROOT/'LiquidAssBackboardd/LGClassicShaderSource.h').read_text()
 original=subprocess.check_output(['git','show','2218a45:LiquidAssBackboardd/LGClassicShaderSource.h'],cwd=ROOT,text=True)
 assert classic.replace('    float  borderWidthPixels;\n','')==original
 # All prior host tuning remains exact; only the new width column may differ.
 def entries(text):
  return {m.group(1).split(',')[0].strip():[v.strip() for v in m.group(1).split(',')] for m in re.finditer(r'^\s*X\((.*)\)\s*\\?$',text,re.M)}
 before=entries(subprocess.check_output(['git','show','2218a45:Shared/LGHostRegistry.h'],cwd=ROOT,text=True))
 after=entries((ROOT/'Shared/LGHostRegistry.h').read_text())
 for key,fields in after.items():assert fields[:5]+fields[6:]==before[key],key
 with tempfile.TemporaryDirectory(prefix='liquidass-bezel-') as td:
  src=Path(td)/'test.m';exe=Path(td)/'test';src.write_text(code+MAIN)
  subprocess.run(['xcrun','clang','-fobjc-arc','-I'+str(ROOT/'Shared'),'-framework','Foundation',str(src),'-o',str(exe)],check=True)
  subprocess.run([str(exe)],check=True)
 print('PASS Classic shader math and prior host defaults unchanged')
if __name__=='__main__':main()
