#!/usr/bin/env python3.11
"""Exercise real engine defaults, routing, UI keys and preset/reset operations."""
from pathlib import Path
import subprocess,tempfile,re
from test_clock_icon_ownership import function
ROOT=Path(__file__).resolve().parents[1]
SUPPORT=r'''
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <simd/simd.h>
#include <unordered_map>
#include <unordered_set>
#include <assert.h>
#include <stdio.h>
#import "LGHostRegistry.h"
#import "LGBezelGeometry.h"
#import "LGRendererPreferences.h"
static NSMutableDictionary *stored;
static bool g_enhancedRenderer, gLGBackboardDebugLogging;
static id LGUnscopedPreferenceValue(NSString *key){return stored[key];}
static NSDictionary *lgReadHostPreferences(void){return stored;}
static id LGReadPreferenceObject(NSString *key,id fallback){return stored[key] ?: fallback;}
static NSNumber *LGReadPreference(NSString *key,NSNumber *fallback){id v=stored[key];return [v isKindOfClass:NSNumber.class]?v:fallback;}
static void LGWritePreferenceObject(NSString *key,id value){stored[key]=value;}
static void LGRemovePreference(NSString *key){[stored removeObjectForKey:key];}
static NSString *LGLocalized(NSString *key){return key;}
static NSString *LGCurrentPrefsLanguageCode(void){return @"en";}
static void LGSetCurrentPrefsLanguageCode(NSString *code){}
static NSString *kLGPrefsUIRefreshNotification=@"profile-test-refresh";
static NSString *kLGPrefsLanguageChangedNotification=@"profile-test-language";
static NSString *kLGDynamicDefaultPrefix=@"__dynamic_default.";
#define lglog(...) do {} while(0)
@interface UIScreen : NSObject
+ (instancetype)mainScreen;
@property CGRect bounds;
@end
@implementation UIScreen
+ (instancetype)mainScreen{UIScreen *s=[UIScreen new];s.bounds=CGRectMake(0,0,428,926);return s;}
@end
'''
MAIN=r'''
static NSDictionary *item(NSArray *items,NSString *key){for(NSDictionary *i in items)if([i[@"key"] isEqual:key])return i;return nil;}
static NSArray *keys(NSArray *items){NSMutableArray *a=[NSMutableArray new];for(NSDictionary *i in items)if(i[@"key"])[a addObject:i[@"key"]];return a;}
int main(int argc,char **argv){@autoreleasepool{
    for(size_t i=0;i<LGHostIdentifierCount;i++) {
        const LGHostDefinition *d=LGHostDefinitionForProfile(kLGHostRegistry[i].preferencePrefix,YES);
        assert(d && LGHostIdentifierForDefinition(d)==i);
    }
    NSMutableDictionary *all=[NSMutableDictionary new];
    for(NSString *key in LGRendererPreferenceKeyMap()) {
        all[key]=@1;all[LGRendererPreferenceKey(key,YES)]=@2;
    }
    NSDictionary *oldGroup=LGRendererPreferenceValues(all,NO),*newGroup=LGRendererPreferenceValues(all,YES);
    for(NSString *key in LGRendererPreferenceKeyMap()) {
        assert([oldGroup[key] isEqual:@1] && [newGroup[key] isEqual:@2]);
    }
    BOOL runningEnhanced=strcmp(argv[1],"enhanced")==0;
    stored=[@{@"Renderer.Profile":runningEnhanced?@"enhanced":@"classic",
              @"Dock.GlassThickness":@27,@"Enhanced.Dock.GlassThickness":@133,
              @"Global.Enabled":@YES,@"Dock.Enabled":@YES} mutableCopy];
    assert([LGPreferenceValue(@"Dock.GlassThickness") isEqual:runningEnhanced?@133:@27]);
    assert(LGHasExplicitPreferenceValue(@"Dock.GlassThickness"));
    stored[@"Renderer.Profile"]=runningEnhanced?@"classic":@"enhanced";
    assert([LGPreferenceValue(@"Dock.GlassThickness") isEqual:runningEnhanced?@133:@27]); // runtime latched until restart
    assert([LGPreferenceValue(@"Global.Enabled") boolValue]);
    assert(LGPreferenceValue(@"Clock.VariableFont.SizeScale")==nil);
    assert([LGRendererPreferenceKey(@"Clock.VariableFont.SizeScale",YES) isEqual:@"Clock.VariableFont.SizeScale"]);
    assert([LGRendererPreferenceKey(@"Dock.Enabled",YES) isEqual:@"Dock.Enabled"]);
    assert([LGRendererPreferenceKey(@"Enhanced.Dock.Blur",YES) isEqual:@"Enhanced.Dock.Blur"]);
    assert(LGRendererPreferenceKey(nil,YES)==nil);

    g_enhancedRenderer=false;lgReloadHostPrefs();
    assert(g_hostParams[LGHostIdentifierDock].glassThickness==27);
    stored[@"Enhanced.Dock.GlassThickness"]=@144;lgReloadHostPrefs();
    assert(g_hostParams[LGHostIdentifierDock].glassThickness==27);
    stored[@"Dock.GlassThickness"]=@108;lgReloadHostPrefs();
    assert(g_hostParams[LGHostIdentifierDock].glassThickness==18); // preserve Classic legacy preset behavior at reload only
    g_enhancedRenderer=true;lgReloadHostPrefs();
    assert(g_hostParams[LGHostIdentifierDock].glassThickness==144);
    assert(g_hostParams[LGHostIdentifierAssistiveTouch].glassThickness==18);
    assert(g_hostParams[LGHostIdentifierVolumeHUD].glassThickness==280);
    assert(g_hostParams[LGHostIdentifierClock].glassThickness==120);
    stored[@"Notification.GlassThickness"]=@99;
    stored[@"Enhanced.Notification.GlassThickness"]=@222;lgReloadHostPrefs();
    assert(g_hostParams[LGHostIdentifierClock].glassThickness==120); // no Enhanced clock/notification alias
    [stored removeObjectForKey:@"Enhanced.Dock.GlassThickness"];lgReloadHostPrefs();
    assert(g_hostParams[LGHostIdentifierDock].glassThickness==120); // upstream, never legacy 108
    assert(g_hostParams[LGHostIdentifierDock].pointBezel);
    assert(g_hostParams[LGHostIdentifierDock].bezelWidthPoints==17.5f);
    g_enhancedRenderer=false;lgReloadHostPrefs();assert(!g_hostParams[LGHostIdentifierDock].pointBezel);

    stored[@"Renderer.Profile"]=@"classic";
    NSArray *classic=LGRendererItemsForHostPrefix(@"Dock");
    assert([item(classic,@"Dock.GlassThickness")[@"default"] doubleValue]==20);
    assert(item(classic,@"Dock.BezelRatio") && !item(classic,@"Enhanced.Dock.BezelWidth"));
    LGWritePreferenceObject(item(classic,@"Dock.GlassThickness")[@"key"],@31);
    stored[@"Renderer.Profile"]=@"enhanced";
    NSArray *enhanced=LGRendererItemsForHostPrefix(@"Dock");
    assert([item(enhanced,@"Enhanced.Dock.GlassThickness")[@"default"] doubleValue]==120);
    assert(item(enhanced,@"Enhanced.Dock.BezelWidth") && !item(enhanced,@"Dock.BezelRatio"));
    assert(item(enhanced,@"Dock.Enabled"));
    LGWritePreferenceObject(item(enhanced,@"Enhanced.Dock.GlassThickness")[@"key"],@155);
    assert([stored[@"Dock.GlassThickness"] isEqual:@31]);
    assert([stored[@"Enhanced.Dock.GlassThickness"] isEqual:@155]);
    NSDictionary *motion=LGSwitchSetting(@"Specular.Motion.Enabled",@"motion",nil,NO);
    assert([motion[@"key"] isEqual:@"Enhanced.Specular.Motion.Enabled"]);

    NSString *json=LGExportPreferencesJSONString();
    assert([json containsString:@"Enhanced.Dock.GlassThickness"] && [json containsString:@"Dock.GlassThickness"]);
    NSMutableDictionary *saved=[stored mutableCopy];[stored removeAllObjects];
    NSError *error=nil;assert(LGImportPreferencesJSONString(json,&error));
    assert([stored[@"Dock.GlassThickness"] isEqual:@31] && [stored[@"Enhanced.Dock.GlassThickness"] isEqual:@155]);
    LGResetPreferencesForKeys(keys(enhanced));
    assert([stored[@"Dock.GlassThickness"] isEqual:@31] && !stored[@"Enhanced.Dock.GlassThickness"]);
    stored[@"Enhanced.Dock.GlassThickness"]=@155;LGResetPreferencesForKeys(keys(classic));
    assert(!stored[@"Dock.GlassThickness"] && [stored[@"Enhanced.Dock.GlassThickness"] isEqual:@155]);
    assert([stored[@"Global.Enabled"] boolValue]);
    NSString *legacy=@"{\"format\":\"liquidass-prefs\",\"version\":\"1\",\"preferences\":{\"Dock.GlassThickness\":22}}";
    assert(LGImportPreferencesJSONString(legacy,&error));
    assert([stored[@"Dock.GlassThickness"] isEqual:@22] && [stored[@"Enhanced.Dock.GlassThickness"] isEqual:@155]);
    (void)saved;
    printf("PASS %s runtime, raw defaults, independent edits, profile UI keys, two-group export/import and isolated surface reset\n",argv[1]);
}return 0;}
'''
def definition(src,sig):return function(src[src.rindex(sig):],sig)
def main():
 back=(ROOT/'LiquidAssBackboardd/Tweak.mm').read_text();data=(ROOT/'LiquidAssPrefs/LGPrefsDataSupport.m').read_text();shared=(ROOT/'Shared/LGSharedSupport.m').read_text()
 a=back.index('typedef struct {\n    const char *typeName;');b=back.index('static NSDictionary *lgReadHostPreferences',a)
 code=SUPPORT+back[a:b]
 code+='static bool lgDecodeTintColor(NSString *hex, simd_float4 *out);\n'
 for sig in ['static void lgApplyHistoricalTintDefault(', 'static bool lgDecodeTintColor(', 'static void lgReloadHostPrefs(']:code+=definition(back,sig)+'\n'
 for sig in ['BOOL LGRendererUsesEnhancedAtLaunch(', 'id LGPreferenceValue(', 'BOOL LGHasExplicitPreferenceValue(']:code+=definition(shared,sig)+'\n'
 code+=definition(data,'static BOOL LGSelectedRendererEnhanced(')+'\n'
 code+='''static const CGFloat kLGUniversalBlurMax=50,kLGUniversalThicknessMax=500,kLGUniversalRefractiveIndexMax=5,kLGUniversalRefractionMax=5,kLGUniversalDispersionMax=10,kLGCoverSheetCornerRadiusPoints=64;\n'''
 for sig in ['NSDictionary *LGSwitchSetting(', 'NSDictionary *LGSliderSetting(', 'NSDictionary *LGMenuSetting(', 'static NSDictionary *LGSettingControlledByKey(', 'NSDictionary *LGGlassEnabledSetting(', 'static CGFloat LGDefaultBezelRatioForHost(', 'static NSDictionary *LGGlassThicknessSetting(', 'static NSDictionary *LGGlassRefractionSetting(', 'static NSDictionary *LGGlassRefractiveIndexSetting(', 'static NSDictionary *LGGlassSpecularSetting(', 'static NSDictionary *LGGlassBlurSetting(', 'NSArray<NSDictionary *> *LGRendererItemsForHostPrefix(']:code+=definition(data,sig)+'\n'
 code+='''static NSArray *LGAllSurfaceItems(void){return LGRendererItemsForHostPrefix(@"Dock");}
static NSArray *LGMoreOptionsItems(void){return @[@{@"key":@"Renderer.Profile"},@{@"key":@"Global.Enabled"}];}
static NSArray *LGPrefsSettingsItems(void){return @[];}\n'''
 for sig in ['static NSArray<NSString *> *LGExportablePreferenceKeys(', 'NSString *LGExportPreferencesJSONString(', 'BOOL LGImportPreferencesJSONString(', 'void LGResetPreferencesForKeys(']:code+=definition(data,sig)+'\n'
 assert 'canonicalThickness' not in back and 'hp->glassThickness / 6.0f' not in back
 assert 'lu.glassThickness = hp->glassThickness;' in back
 # The Enhanced source table must match the imported upstream values exactly.
 upstream=subprocess.check_output(['git','show','9b7c5eb:Shared/LGHostRegistry.h'],cwd=ROOT,text=True)
 rows=lambda t:[m.group(1).replace(' ','') for m in re.finditer(r'^\s*X\((.*)\)\s*\\?$',t,re.M)]
 assert rows((ROOT/'Shared/LGUpstreamHostDefaults.h').read_text())==rows(upstream)
 with tempfile.TemporaryDirectory(prefix='liquidass-profiles-') as td:
  src=Path(td)/'test.mm';exe=Path(td)/'test';src.write_text(code+MAIN)
  subprocess.run(['xcrun','clang++','-std=c++17','-fobjc-arc','-I'+str(ROOT/'Shared'),'-framework','Foundation','-framework','CoreGraphics',str(src),'-o',str(exe)],check=True)
  for profile in ['classic','enhanced']:subprocess.run([str(exe),profile],check=True)
 print('PASS upstream table exact match; Enhanced raw values and Classic legacy compatibility')
if __name__=='__main__':main()
