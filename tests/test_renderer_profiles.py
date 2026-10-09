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
#import "LGRendererDiagnostics.h"
#import "LGColorEncoding.h"
static NSMutableDictionary *stored;
static bool g_enhancedRenderer, gLGBackboardDebugLogging;
static id LGUnscopedPreferenceValue(NSString *key){return stored[key];}
static NSDictionary *lgReadHostPreferences(void){return stored;}
static bool lastReadOK;
static void lgPublishHostPrefsDiagnostics(NSDictionary *prefs,bool readOK){lastReadOK=readOK;}
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
@property NSInteger maximumFramesPerSecond;
@end
@implementation UIScreen
+ (instancetype)mainScreen{UIScreen *s=[UIScreen new];s.bounds=CGRectMake(0,0,428,926);s.maximumFramesPerSecond=60;return s;}
@end
'''
MAIN=r'''
static NSDictionary *item(NSArray *items,NSString *key){for(NSDictionary *i in items)if([i[@"key"] isEqual:key])return i;return nil;}
static NSArray *keys(NSArray *items){NSMutableArray *a=[NSMutableArray new];for(NSDictionary *i in items)if(i[@"key"])[a addObject:i[@"key"]];return a;}
int main(int argc,char **argv){@autoreleasepool{
    stored=nil;g_hostParamsInit=false;assert(!lgReloadHostPrefs() && g_hostParamsInit);
    for(int i=0;i<kHostCount;i++)assert(strcmp(g_hostParams[i].prefPrefix,kHostDefaults[i].prefPrefix)==0);
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

    // Read errors preserve the applied state; a valid empty domain is a reset.
    NSMutableDictionary *beforeFailure=stored;
    float oldThickness=g_hostParams[LGHostIdentifierDock].glassThickness;
    stored=nil;assert(!lgReloadHostPrefs() && !lastReadOK);
    assert(g_hostParams[LGHostIdentifierDock].glassThickness==oldThickness);
    stored=[NSMutableDictionary new];assert(lgReloadHostPrefs() && lastReadOK);
    assert(g_hostParams[LGHostIdentifierDock].glassThickness==kHostDefaults[LGHostIdentifierDock].glassThickness);
    stored=beforeFailure;lgReloadHostPrefs();

    simd_float4 decoded;
    uint32_t rgba;
    assert(LGReadRGBAHex(@"#112233",&rgba) && rgba==0x112233FF);
    assert(LGReadRGBAHex(@"11223344",&rgba) && rgba==0x11223344);
    assert(!LGReadRGBAHex(@"FF#0000",&rgba));
    assert(lgDecodeTintColor(@"#112233",&decoded) && decoded.w==1);
    assert(!lgDecodeTintColor(@"#12ZZZZ",&decoded));
    assert(!lgDecodeTintColor(@"#FF0000ZZ",&decoded));
    assert(!lgDecodeTintColor(@"# 10000",&decoded));
    NSUInteger colorCases=0;
    for(int mode=0;mode<2;mode++) {
        g_enhancedRenderer=mode;
        stored[@"Renderer.Profile"]=mode?@"enhanced":@"classic";
        NSDictionary *toggle=item(LGClockItems(),LGRendererPreferenceKey(@"Clock.AdaptiveTint.Enabled",mode));
        assert(toggle && [toggle[@"default"] boolValue]==!mode);
        for(int host=0;host<kHostCount;host++) {
            NSString *prefix=@(kHostDefaults[host].prefPrefix);
            NSString *light=LGRendererPreferenceKey([prefix stringByAppendingString:@".LightTintColor"],mode);
            NSString *dark=LGRendererPreferenceKey([prefix stringByAppendingString:@".DarkTintColor"],mode);
            NSMutableDictionary *saved=stored;stored=[NSMutableDictionary new];
            stored[light]=@"#FF0000FF";stored[dark]=@"#00FF00FF";
            // The other engine's blue must never override this engine's red.
            stored[LGRendererPreferenceKey([prefix stringByAppendingString:@".LightTintColor"],!mode)]=@"#0000FFFF";
            assert(lgReloadHostPrefs());auto p=g_hostParams[host];
            assert(g_clockAdaptiveTint==!mode);
            NSString *adaptive=LGRendererPreferenceKey(@"Clock.AdaptiveTint.Enabled",mode);
            stored[adaptive]=@YES;assert(lgReloadHostPrefs() && g_clockAdaptiveTint);
            stored[adaptive]=@NO;assert(lgReloadHostPrefs() && !g_clockAdaptiveTint);
            assert(LGRendererDiagRGBA(p.tintR,p.tintG,p.tintB,p.tintStrength)==0xFF0000FF);
            assert(LGRendererDiagRGBA(p.darkTintR,p.darkTintG,p.darkTintB,p.darkTintStrength)==0x00FF00FF);
            stored[light]=@"#00000000";assert(lgReloadHostPrefs());assert(g_hostParams[host].tintStrength==0);
            [stored removeObjectForKey:light];
            for(NSString *field in @[@"TintR",@"TintG",@"TintB",@"TintStrength"])
                stored[LGRendererPreferenceKey([prefix stringByAppendingFormat:@".%@",field],mode)]=[field isEqual:@"TintStrength"]?@0.5:@0.25;
            assert(lgReloadHostPrefs());p=g_hostParams[host];
            assert(p.tintR==0.25f && p.tintG==0.25f && p.tintB==0.25f && p.tintStrength==0.5f);
            stored[light]=@"#FF0000FF";assert(lgReloadHostPrefs());assert(g_hostParams[host].tintR==1 && g_hostParams[host].tintG==0);
            stored=saved;colorCases+=5;
        }
    }
    printf("PASS %lu all-host color cases: engines, Light/Dark, alpha-zero, legacy values and modern precedence\n",(unsigned long)colorCases);
    auto manual=clockTintForTest(false,false,"Clock");
    assert(manual.x==1 && manual.y==0 && manual.w==1);
    auto automatic=clockTintForTest(true,false,"Clock");
    assert(automatic.y>0 && automatic.w<1);
    auto other=clockTintForTest(true,false,"Dock");assert(other.x==1 && other.y==0 && other.w==1);
    wallpaperAvailable=false;automatic=clockTintForTest(true,true,"Clock");
    assert(automatic.x==1 && fabs(automatic.w-0.12f)<1e-6);

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
 for sig in ['static void lgApplyHistoricalTintDefault(', 'static bool lgDecodeTintColor(', 'static bool lgReloadHostPrefs(']:code+=definition(back,sig)+'\n'
 for sig in ['BOOL LGRendererUsesEnhancedAtLaunch(', 'id LGPreferenceValue(', 'BOOL LGHasExplicitPreferenceValue(']:code+=definition(shared,sig)+'\n'
 code+=definition(data,'static BOOL LGSelectedRendererEnhanced(')+'\n'
 code+='''static const CGFloat kLGUniversalBlurMax=50,kLGUniversalThicknessMax=500,kLGUniversalRefractiveIndexMax=5,kLGUniversalRefractionMax=5,kLGUniversalDispersionMax=10,kLGCoverSheetCornerRadiusPoints=64;\n'''
 for sig in ['NSDictionary *LGSwitchSetting(', 'NSDictionary *LGSliderSetting(', 'NSDictionary *LGMenuSetting(', 'static NSDictionary *LGSettingControlledByKey(', 'NSDictionary *LGGlassEnabledSetting(', 'static CGFloat LGDefaultBezelRatioForHost(', 'static NSDictionary *LGGlassThicknessSetting(', 'static NSDictionary *LGGlassRefractionSetting(', 'static NSDictionary *LGGlassRefractiveIndexSetting(', 'static NSDictionary *LGGlassSpecularSetting(', 'static NSDictionary *LGGlassBlurSetting(', 'NSArray<NSDictionary *> *LGRendererItemsForHostPrefix(']:code+=definition(data,sig)+'\n'
 code+='''static NSArray *LGClockVariableFontItems(void){return @[];}
static NSArray *LGClockDateFormatItems(void){return @[];}\n'''
 code+=definition(data,'static NSArray<NSDictionary *> *LGJoinItemGroups(')+'\n'
 code+=definition(data,'NSArray<NSDictionary *> *LGClockItems(')+'\n'
 code+='''
struct LGSpatialClockColorState { unsigned appearance; float contrast; bool depthActive; };
struct LGClockColorSelection { bool valid; simd_float3 color; };
static bool wallpaperAvailable=true;
static bool lgReadSpatialClockColor(LGSpatialClockColorState *s){s->appearance=1;s->contrast=0.2;s->depthActive=false;return wallpaperAvailable;}
static LGClockColorSelection lgSelectSpatialClockColor(const LGSpatialClockColorState *s){return {true,simd_make_float3(0,1,0)};}
static simd_float4 clockTintForTest(bool adaptive,bool darkTint,const char *prefix){
 g_clockAdaptiveTint=adaptive;LGHostParams host={};host.prefPrefix=prefix;const LGHostParams *hp=&host;
 struct {simd_float4 tintColor;} lu={simd_make_float4(1,0,0,1)};
'''
 code+=function(back,'if (!strcmp(hp->prefPrefix, "Clock") && g_clockAdaptiveTint)')
 code+='\nreturn lu.tintColor;}\n'
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
