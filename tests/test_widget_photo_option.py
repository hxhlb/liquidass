#!/usr/bin/env python3.11
"""Validate the shipped widget menu and shared default-off preference."""
from pathlib import Path
import subprocess
import tempfile
from test_widget_host import function

ROOT = Path(__file__).resolve().parents[1]
SUPPORT = r'''
#import <Foundation/Foundation.h>
#import "LGRendererPreferences.h"
#include <assert.h>
static BOOL enhanced;
static BOOL LGSelectedRendererEnhanced(void){return enhanced;}
static NSString *LGLocalized(NSString *key){return key;}
static NSArray *LGRendererItemsForHostPrefix(NSString *prefix){return @[];}
static NSArray *LGJoinItemGroups(NSArray *groups){
 NSMutableArray *result=[NSMutableArray new];
 for(NSArray *group in groups)[result addObjectsFromArray:group];
 return result;
}
'''
CHECKS = r'''
int main(){@autoreleasepool{
 for(NSNumber *mode in @[@NO,@YES]){
  enhanced=mode.boolValue;
  NSDictionary *photo=nil;
  for(NSDictionary *item in LGWidgetItems())
   if([item[@"key"] isEqual:@"Widgets.ExcludePhotos.Enabled"])photo=item;
  assert(photo&&![photo[@"default"] boolValue]);
  assert([photo[@"requires_backboard_restart"] boolValue]);
  assert([photo[@"enabled_key"] isEqual:@"Widgets.Enabled"]);
  assert([photo[@"title"] isEqual:@"prefs.widgets.exclude_photos.title"]);
 }
 puts("PASS: photo option defaults off, remains shared across renderers, depends on Widgets and requests restart");
}return 0;}
'''


def main():
    data = (ROOT / 'LiquidAssPrefs/LGPrefsDataSupport.m').read_text()
    source = SUPPORT
    for signature in ['NSDictionary *LGSwitchSetting(', 'NSDictionary *LGSectionSetting(',
                      'static NSDictionary *LGSettingControlledByKey(', 'NSArray<NSDictionary *> *LGWidgetItems(']:
        source += function(data, signature) + '\n'
    for locale in ['', 'zh-Hans.lproj/', 'zh-Hant-TW.lproj/']:
        path = ROOT / ('LiquidAssPrefs/Resources/' + locale + 'Localizable.strings')
        text = path.read_text()
        for key in ('prefs.widgets.exclude_photos.title', 'prefs.widgets.exclude_photos.subtitle'):
            assert text.count('"' + key + '" =') == 1, (path, key)
        subprocess.run(['plutil', '-lint', str(path)], check=True)
    with tempfile.TemporaryDirectory(prefix='liquidass-widget-photo-option-') as tmp:
        src, exe = Path(tmp) / 'test.m', Path(tmp) / 'test'
        src.write_text(source + CHECKS)
        subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-I' + str(ROOT / 'Shared'),
                        '-framework', 'Foundation', str(src), '-o', str(exe)], check=True)
        subprocess.run([str(exe)], check=True)


if __name__ == '__main__':
    main()
