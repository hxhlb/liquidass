#!/usr/bin/env python3.11
"""Exercise blur routing and overlay ownership with production code and UI doubles."""
from pathlib import Path
import subprocess
import tempfile
from test_clock_icon_ownership import function

ROOT = Path(__file__).resolve().parents[1]

PRELUDE = r'''
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <assert.h>
#include <math.h>
#include <stdio.h>
#import "LGHostRegistry.h"
#import "LGBezelGeometry.h"
static NSDictionary *prefs;
static BOOL enhancedAtLaunch;
static id LGGlassPreferenceValue(NSString *key) { return prefs[key]; }
static id LGReadPreferenceObject(NSString *key, id fallback) { return prefs[key] ?: fallback; }
static BOOL LGEnhancedRendererProfileAtLaunch(void) { return enhancedAtLaunch; }
static const LGHostDefinition *LGActiveHostDefinitionForPrefix(NSString *prefix) {
 return LGHostDefinitionForProfile(prefix.UTF8String, enhancedAtLaunch);
}
#define CALayer TestLayer
#define CATransaction TestTransaction
@interface CALayer : NSObject
@property CGFloat cornerRadius;
@property(copy) NSString *cornerCurve;
@property(copy) NSString *groupName;
@property(copy) NSArray *filters;
@end
@implementation CALayer @end
@interface CATransaction : NSObject
+ (void)begin; + (void)commit; + (void)setDisableActions:(BOOL)value;
@end
@implementation CATransaction
+ (void)begin {} + (void)commit {} + (void)setDisableActions:(BOOL)value {}
@end
@interface UIView : NSObject
@property(strong) UIView *superview;
@property(strong) CALayer *layer;
@property CGRect frame;
@property CGRect bounds;
@property BOOL clipsToBounds;
- (void)insertSubview:(UIView *)view atIndex:(NSInteger)index;
- (void)removeFromSuperview;
@end
@implementation UIView
- (instancetype)init { if((self=[super init])) _layer=[CALayer new]; return self; }
- (void)insertSubview:(UIView *)view atIndex:(NSInteger)index { view.superview=self; }
- (void)removeFromSuperview { self.superview=nil; }
@end
@interface LGAdjustableBlurView : UIView
@property CGFloat blurRadius;
@property CGFloat qualityScale;
@property CGFloat cornerRadius;
- (instancetype)initWithFrame:(CGRect)frame blurRadius:(CGFloat)radius;
- (void)applyFilters;
@end
@implementation LGAdjustableBlurView
- (instancetype)initWithFrame:(CGRect)frame blurRadius:(CGFloat)radius {
 if((self=[super init])) { self.frame=frame; _blurRadius=radius; } return self;
}
- (void)applyFilters {}
@end
@interface LGLiveBackdropView : UIView {
    LGAdjustableBlurView *_nativeBlurView;
    CGRect _lgShapeRect;
    CGFloat _lgShapeCornerRadius;
}
- (void)updateNativeBlurOverlayWithRadius:(CGFloat)radius;
- (void)setShape:(CGRect)rect radius:(CGFloat)radius;
- (LGAdjustableBlurView *)overlay;
@end
@implementation LGLiveBackdropView
- (instancetype)init { if((self=[super init])) _lgShapeRect=CGRectNull; return self; }
- (void)setShape:(CGRect)rect radius:(CGFloat)radius { _lgShapeRect=rect; _lgShapeCornerRadius=radius; }
- (LGAdjustableBlurView *)overlay { return _nativeBlurView; }
'''

MAIN = r'''
int main(void) { @autoreleasepool {
    NSDictionary *item=@{@"requires_enhanced_renderer":@YES};
    prefs=@{}; assert(!LGUsesSystemBlurOverlay() && !LGPrefsItemIsEnabled(item));
    prefs=@{@"Renderer.Profile":@"enhanced",@"Renderer.BlurMode":@"system",@"Dock.Blur":@7};
    assert(LGPrefsItemIsEnabled(item) && !LGUsesSystemBlurOverlay()); // selected, restart still pending
    enhancedAtLaunch=YES;
    assert(LGUsesSystemBlurOverlay());
    assert(LGNativeBlurRadiusForFilterType(@"dylv.liquidglass.dock.r4.dark.refresh")==7);
    prefs=@{@"Renderer.Profile":@"classic",@"Renderer.BlurMode":@"system"};
    assert(!LGUsesSystemBlurOverlay() && !LGPrefsItemIsEnabled(item));
    assert(LGNativeBlurRadiusForFilterType(@"dylv.liquidglass.dock")==0);
    assert([prefs[@"Renderer.BlurMode"] isEqual:@"system"]); // disabling doesn't erase choice
    prefs=@{@"Renderer.Profile":@"enhanced",@"Renderer.BlurMode":@"unknown"};
    assert(LGUsesSystemBlurOverlay()); // Unknown values use the upstream default.
    assert(LGPrefsItemIsEnabled(@{}));
    for(NSNumber *value in @[@0,@(-1),@999,@(NAN)]) {
        prefs=@{@"Renderer.Profile":@"enhanced",@"Renderer.BlurMode":@"system",@"Dock.Blur":value};
        CGFloat radius=LGNativeBlurRadiusForFilterType(@"dylv.liquidglass.dock");
        assert(isfinite(radius) && radius>=0 && radius<=50);
    }
    LGLiveBackdropView *glass=[LGLiveBackdropView new];
    glass.bounds=CGRectMake(0,0,300,600); glass.layer.cornerRadius=20;
    [glass updateNativeBlurOverlayWithRadius:5];
    LGAdjustableBlurView *overlay=glass.overlay;
    assert(overlay.superview==glass && overlay.blurRadius==5 && overlay.clipsToBounds);
    assert(CGRectEqualToRect(overlay.frame,glass.bounds) && overlay.cornerRadius==20);
    [glass setShape:CGRectMake(20,30,200,100) radius:12];
    [glass updateNativeBlurOverlayWithRadius:8];
    assert(glass.overlay==overlay && overlay.blurRadius==8);
    assert(CGRectEqualToRect(overlay.frame,CGRectMake(20,30,200,100)) && overlay.cornerRadius==12);
    [glass updateNativeBlurOverlayWithRadius:0];
    assert(!glass.overlay && !overlay.superview);
    [glass updateNativeBlurOverlayWithRadius:0];
    [glass updateNativeBlurOverlayWithRadius:5];
    assert(glass.overlay && glass.overlay!=overlay);
    puts("PASS Enhanced UI/runtime gates, pending restart, default/invalid modes, radius bounds and overlay lifecycle/geometry");
} return 0; }
'''

ROUTE_MAIN = r'''
int main(void) { @autoreleasepool {
    for(int i=0;i<kHostCount;i++) g_hostParams[i]=kHostDefaults[i];
    lgRegisterSystemBlurVariants((void *)1);
    assert(!registered.empty());
    for (int i=0; i<kHostCount; i++) {
        NSString *base=[NSString stringWithUTF8String:kHostDefaults[i].typeName];
        int last=lgUsesDynamicRadiusRoute(i) ? 16 : -1;
        for(int step=-1;step<=last;step++) for(int dark=0;dark<=1;dark++) for(int refresh=0;refresh<=1;refresh++) {
            NSString *name=step<0 ? base : [base stringByAppendingFormat:@".r%d",step];
            if(dark) name=[name stringByAppendingString:@".dark"];
            if(refresh) name=[name stringByAppendingString:@".refresh"];
            name=[name stringByAppendingString:@".systemBlur"];
            uint32_t atom=g_internAtom(name.UTF8String);
            assert(registered.count(atom));
            bool routedDark=false;
            auto *params=lgHostParamsForAtom(atom,&routedDark);
            assert(strcmp(params->prefPrefix,kHostDefaults[i].prefPrefix)==0 && routedDark==(dark!=0));
            if(step>=0) assert(fabs(params->radiusRatio-step/32.0)<1e-6);
            assert(!lgUsesOwnedBlur(true,atom));
            assert(!lgUsesOwnedBlur(false,atom));
        }
    }
    uint32_t nativeClock=g_internAtom("dylv.liquidglass.clock.nativeMask");
    assert(!registered.count(nativeClock) && lgUsesOwnedBlur(true,nativeClock));
    assert(lgUsesOwnedBlur(true,g_internAtom("dylv.liquidglass.dock")));
    assert(!lgUsesOwnedBlur(false,0));
    printf("PASS %zu blur-owner routes, host/dark/radius preservation, no duplicate Metal blur and native-clock isolation\n",registered.size());
} return 0; }
'''


def main():
    live=(ROOT/'Shared/LGLiveBackdropView.m').read_text()
    prefs=(ROOT/'LiquidAssPrefs/LGPrefsDataSupport.m').read_text()
    backend=(ROOT/'LiquidAssBackboardd/Tweak.mm').read_text()
    source=PRELUDE+function(live,'- (void)updateNativeBlurOverlayWithRadius:(CGFloat)radius {')+'\n@end\n'
    for sig in ('static BOOL LGUsesSystemBlurOverlay(', 'static CGFloat LGNativeBlurRadiusForFilterType('):
        source+=function(live,sig)+'\n'
    source+=function(prefs,'static BOOL LGSelectedRendererEnhanced(')+'\n'
    source+=function(prefs,'BOOL LGPrefsItemIsEnabled(')+MAIN
    routes='''#import <Foundation/Foundation.h>\n#import <os/lock.h>\n#include <unordered_map>\n#include <unordered_set>\n#include <string>\n#include <assert.h>\n#include <math.h>\n#import "LGHostRegistry.h"\n'''
    # Copy the production host table and routing implementation unchanged.
    a=backend.index('typedef struct {\n    const char *typeName;')
    b=backend.index('static NSDictionary *lgReadHostPreferences',a)
    routes+=backend[a:b]
    routes+='''
static std::unordered_set<uint32_t> g_systemBlurAtoms, registered;
static os_unfair_lock g_customAtomsLock=OS_UNFAIR_LOCK_INIT;
static std::unordered_map<std::string,uint32_t> names;
static uint32_t g_internAtom(const char *name) {
 auto result=names.emplace(name,(uint32_t)names.size()+1); return result.first->second;
}
static void lgRegisterCustomAtom(uint32_t atom, void *descriptor) { assert(descriptor); registered.insert(atom); }
'''
    routes+=function(backend,'static bool lgUsesOwnedBlur(')+'\n'
    routes+=function(backend,'static void lgRegisterSystemBlurVariants(')+ROUTE_MAIN
    assert 'lgUsesOwnedBlur(enhancedPipeline, ftype)' in backend
    assert 'type = [type stringByAppendingString:@".systemBlur"]' in live
    assert 'rendererProfile[@"reload_on_change"] = @YES' in prefs
    assert 'blurMode[@"requires_enhanced_renderer"] = @YES' in prefs
    with tempfile.TemporaryDirectory(prefix='liquidass-blur-') as tmp:
        for name,text in [('overlay.m',source),('routes.mm',routes)]:
            src=Path(tmp)/name;exe=src.with_suffix('');src.write_text(text)
            cmd=['xcrun','clang','-fobjc-arc','-I'+str(ROOT/'Shared'),'-framework','Foundation']
            if name.endswith('.mm'): cmd+=['-std=c++17','-lc++']
            else: cmd+=['-framework','CoreGraphics']
            subprocess.run(cmd+[str(src),'-o',str(exe)],check=True)
            subprocess.run([str(exe)],check=True)


if __name__=='__main__': main()
