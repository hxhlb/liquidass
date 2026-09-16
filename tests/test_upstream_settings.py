#!/usr/bin/env python3.11
"""Exercise imported exclusion editing and reachable clock mode settings."""
from pathlib import Path
import subprocess
import tempfile
from test_clock_icon_ownership import function

ROOT = Path(__file__).resolve().parents[1]
SUPPORT = r'''
#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdio.h>
@interface PSSpecifier : NSObject
@property(copy) NSDictionary *properties;
- (id)propertyForKey:(NSString *)key;
@end
@implementation PSSpecifier
- (id)propertyForKey:(NSString *)key { return self.properties[key]; }
@end
static id stored;
static NSDictionary *prefs;
static id LGGlassPreferenceValue(NSString *key) { return prefs[key]; }
static id LGReadPreferenceObject(NSString *key, id fallback) { return stored ?: fallback; }
static void LGWritePreferenceObject(NSString *key, id value) { stored=value; }
@interface Editor : NSObject
- (id)readAppExclusions:(PSSpecifier *)specifier;
- (void)setAppExclusions:(NSArray *)value specifier:(PSSpecifier *)specifier;
@end
'''
UI_SUPPORT = r'''
@interface UIScreen : NSObject
+ (instancetype)mainScreen;
@property NSInteger maximumFramesPerSecond;
@end
@implementation UIScreen
+ (instancetype)mainScreen { UIScreen *s=[UIScreen new]; s.maximumFramesPerSecond=120; return s; }
@end
static NSString *LGLocalized(NSString *key) { return key; }
static NSArray *LGRendererItemsForHostPrefix(NSString *prefix) { return @[@{@"key":@"Clock.Enabled"}]; }
static NSDictionary *LGSliderSetting(NSString *key, NSString *title, NSString *subtitle, CGFloat value, CGFloat min, CGFloat max, NSInteger decimals) {
 return @{@"key":key,@"default":@(value),@"max":@(max)};
}
static NSArray *LGClockVariableFontItems(void) { return @[@{@"key":@"Clock.VariableFont.Enabled"}]; }
static NSArray *LGClockDateFormatItems(void) { return @[@{@"key":@"Lockscreen.Clock.DateFormat.Enabled"}]; }
static NSArray *LGJoinItemGroups(NSArray *groups) {
 NSMutableArray *a=[NSMutableArray new]; for(NSArray *g in groups) [a addObjectsFromArray:g]; return a;
}
'''
CHECKS = r'''
int main(void) { @autoreleasepool {
    PSSpecifier *spec=[PSSpecifier new];
    spec.properties=@{@"key":@"GlobalControls.Exclusions",@"default":@[]};
    assert(!lgHostEnabled(@"AssistiveTouch"));
    prefs=@{@"Global.Enabled":@YES}; assert(lgHostEnabled(@"AssistiveTouch"));
    prefs=@{@"Global.Enabled":@YES,@"AssistiveTouch.Enabled":@NO}; assert(!lgHostEnabled(@"AssistiveTouch"));
    prefs=@{@"Global.Enabled":@NO,@"AssistiveTouch.Enabled":@YES}; assert(!lgHostEnabled(@"AssistiveTouch"));
    Editor *editor=[Editor new];
    NSString *process=NSProcessInfo.processInfo.processName;
    stored=[NSString stringWithFormat:@"Filza; %@\ncom.example.app\n#comment",process];
    NSArray *read=[editor readAppExclusions:spec];
    assert([read containsObject:@"com.tigisoftware.Filza"]);
    assert([read containsObject:process] && [read containsObject:@"com.example.app"]);
    [editor setAppExclusions:@[@"com.example.other"] specifier:spec];
    assert([stored containsObject:process] && [stored containsObject:@"com.example.other"]);
    assert(![stored containsObject:@"com.tigisoftware.Filza"]);
    assert(LGProcessMatchesExclusionList(stored));
    assert(LGProcessMatchesExclusionList(process.uppercaseString));
    assert(!LGProcessMatchesExclusionList(@[@42,@"not-the-current-process"]));
    assert(!LGProcessMatchesExclusionList(@42));
    NSArray *items=LGClockItems();
    assert([items[0][@"key"] isEqual:@"Clock.Enabled"]);
    NSDictionary *mode=items[1];
    assert([mode[@"key"] isEqual:@"Clock.RenderingMode"]);
    assert([mode[@"default"] isEqual:@"native"]);
    assert([mode[@"choices"] count]==2);
    assert([mode[@"choices"][0][@"value"] isEqual:@"native"]);
    assert([mode[@"choices"][1][@"value"] isEqual:@"custom"]);
    assert([items[2][@"key"] isEqual:@"Clock.FPS"] && [items[2][@"max"] integerValue]==120);
    assert([items[3][@"key"] isEqual:@"Clock.VariableFont.Enabled"]);
    assert([items[4][@"key"] isEqual:@"Lockscreen.Clock.DateFormat.Enabled"]);
    puts("PASS AssistiveTouch master gate, exclusion migration/save/matching, clock mode menu/default/shared settings");
} return 0; }
'''


def main():
    surface=(ROOT/'LiquidAssPrefs/LGPSurfaceController.m').read_text()
    data=(ROOT/'LiquidAssPrefs/LGPrefsDataSupport.m').read_text()
    kit=(ROOT/'Shared/LGGlassKit.x').read_text()
    source=SUPPORT+'\n@implementation Editor\n'
    source+=function(surface,'- (id)readAppExclusions:')+'\n'
    source+=function(surface,'- (void)setAppExclusions:')+'\n@end\n'
    source+=function(kit,'BOOL LGProcessMatchesExclusionList(')+'\n'
    source+=function(kit,'BOOL lgHostEnabled(')+'\n'+UI_SUPPORT
    source+=function(data,'NSDictionary *LGMenuSetting(')+'\n'
    source+=function(data,'NSArray<NSDictionary *> *LGClockItems(')+'\n'+CHECKS
    catalog=(ROOT/'LiquidAssPrefs/LGPrefsSurfaceCatalog.m').read_text()
    for host in ('Clock','AssistiveTouch','VolumeHUD','PillHUD','DynamicIsland','IOS26Icons'):
        assert '@"surface_identifier": LGPrefsSurface'+host in catalog
        assert 'if ([identifier isEqualToString:LGPrefsSurface'+host+'])' in catalog
    chinese=(ROOT/'LiquidAssPrefs/Resources/zh-Hans.lproj/Localizable.strings').read_text()
    assert '"prefs.clock.mode.native" = "原生修改";' in chinese
    assert '"prefs.clock.mode.custom" = "自定义层";' in chinese
    with tempfile.TemporaryDirectory(prefix='liquidass-settings-') as tmp:
        src, exe=Path(tmp)/'settings.m', Path(tmp)/'settings'
        src.write_text(source)
        subprocess.run(['xcrun','clang','-fobjc-arc','-framework','Foundation',str(src),'-o',str(exe)],check=True)
        subprocess.run([str(exe)],check=True)


if __name__=='__main__':
    main()
