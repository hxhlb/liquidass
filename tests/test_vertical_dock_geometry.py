#!/usr/bin/env python3.11
"""Run the vertical-only Dock adapter against production routing and geometry sync."""
from pathlib import Path
import subprocess,tempfile,re
ROOT=Path(__file__).resolve().parents[1]
def function(source,prefix,last=False):
    start=source.rindex(prefix) if last else source.index(prefix)
    brace=source.index('{',start);end=brace+1;depth=1
    while depth:
        depth+=(source[end]=='{')-(source[end]=='}');end+=1
    return source[start:end]
PRELUDE=r'''
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>
#include <assert.h>
typedef struct {CGFloat top,left,bottom,right;} UIEdgeInsets;
static UIEdgeInsets UIEdgeInsetsZero={0};
#define LGLog(...) do {} while(0)
static unsigned frameWrites,filterUpdates,rimUpdates,installs,removals;
@interface UIView : NSObject
@property (nonatomic) CGRect frame;
@property CGRect bounds;
@property BOOL hidden;
@property UIView *superview;
@property id window;
@property CALayer *layer;
- (void)removeFromSuperview;
@end
@implementation UIView
- (instancetype)init{if((self=[super init]))_layer=[CALayer layer];return self;}
- (void)setFrame:(CGRect)frame{_frame=frame;_bounds=(CGRect){{0,0},frame.size};frameWrites++;}
- (void)removeFromSuperview{self.superview=nil;removals++;}
@end
@interface MTMaterialView : UIView @end
@implementation MTMaterialView @end
@interface SBDockView : UIView @end
@implementation SBDockView @end
@interface SBFloatingDockPlatterView : UIView
@property UIView *backgroundView;
@end
@implementation SBFloatingDockPlatterView @end
@interface WrongGetter : UIView
- (double)backgroundView;
@end
@implementation WrongGetter
- (double)backgroundView{abort();return 0;}
@end
@interface LGLiveBackdropView : UIView
@property double rimRadius;
- (void)updateSpecular;
- (void)applyFilters;
@end
@implementation LGLiveBackdropView
- (void)updateSpecular{self.rimRadius=self.layer.cornerRadius;rimUpdates++;}
- (void)applyFilters{filterUpdates++;}
@end
@interface NSValue (TestInsets)
+ (instancetype)valueWithUIEdgeInsets:(UIEdgeInsets)value;
- (UIEdgeInsets)UIEdgeInsetsValue;
@end
@implementation NSValue (TestInsets)
+ (instancetype)valueWithUIEdgeInsets:(UIEdgeInsets)value{return [self value:&value withObjCType:@encode(UIEdgeInsets)];}
- (UIEdgeInsets)UIEdgeInsetsValue{UIEdgeInsets v;[self getValue:&v size:sizeof(v)];return v;}
@end
static void *kGlassKey=&kGlassKey,*kLGOutsetKey=&kLGOutsetKey,*kLGRadiusKey=&kLGRadiusKey;
static const void *kVerticalDockMaterialKey=&kVerticalDockMaterialKey;
static BOOL enabled=YES;
typedef NS_ENUM(NSInteger,LGDockMode){LGDockModeNone=0,LGDockModeRegular,LGDockModeFloating};
typedef BOOL(^LGMaterialHostMatcher)(UIView *);
typedef CGFloat(^LGMaterialHostCornerRadiusProvider)(UIView *);
typedef void(^LGMaterialHostPostInstall)(UIView *,LGLiveBackdropView *);
@interface LGMaterialHostRoute : NSObject
@property NSString *prefix;
@property LGMaterialHostMatcher matcher;
@property UIEdgeInsets outset;
@property LGMaterialHostCornerRadiusProvider cornerRadiusProvider;
@property NSString *groupName;
@property LGMaterialHostPostInstall postInstall;
@end
@implementation LGMaterialHostRoute @end
static NSArray *sMaterialHostRoutes;
static void configureDockGlass(UIView *material,LGLiveBackdropView *glass){}
'''
MAIN=r'''
static MTMaterialView *material(SBFloatingDockPlatterView *owner,double w,double h,double radius){
 MTMaterialView *m=[MTMaterialView new];m.superview=owner;m.window=owner.window;m.frame=CGRectMake(0,0,w,h);m.layer.cornerRadius=radius;owner.backgroundView=m;return m;
}
int main(void){@autoreleasepool{
 LGMaterialHostRoute *route=[LGMaterialHostRoute new];route.prefix=@"Dock";
 route.matcher=^BOOL(UIView *m){return dockModeForMaterial(m)!=LGDockModeNone;};
 route.cornerRadiusProvider=^CGFloat(UIView *m){return dockCornerRadiusForMaterial(m);};sMaterialHostRoutes=@[route];
 assert(!dockBackgroundForPlatter([UIView new]));assert(!dockBackgroundForPlatter([WrongGetter new]));
 SBFloatingDockPlatterView *owner=[SBFloatingDockPlatterView new];owner.window=[NSObject new];
 MTMaterialView *m=material(owner,400,96,36);
 assert(dockModeForMaterial(m)==LGDockModeFloating && dockCornerRadiusForMaterial(m)==-1);
 dockSyncVerticalGlassAfterLayout(owner);assert(installs==0); // Never-vertical horizontal Dock is untouched.
 lgRouteMaterialHost(m);LGLiveBackdropView *g=objc_getAssociatedObject(m,kGlassKey);assert(g && g.layer.cornerRadius==36);
 // Actual native order: frame callback first, continuous-radius write second.
 m.frame=CGRectMake(0,0,52,360);lgRouteMaterialHost(m);LGResyncGlassGeometry(m,kGlassKey);
 m.layer.cornerRadius=13;
 assert(g.layer.cornerRadius==36);
 dockSyncVerticalGlassAfterLayout(owner);
 assert(dockModeForMaterial(m)==LGDockModeFloating && g.layer.cornerRadius==13 && g.rimRadius==13);
 assert([objc_getAssociatedObject(g,kLGRadiusKey) doubleValue]==13);
 unsigned frames=frameWrites,filters=filterUpdates,rims=rimUpdates,created=installs;
 for(int i=0;i<1000;i++)dockSyncVerticalGlassAfterLayout(owner);
 assert(frameWrites==frames && filterUpdates==filters && rimUpdates==rims && installs==created);
 // A later maximum-radius/layout change must repair its own final value.
 m.layer.cornerRadius=9.5;dockSyncVerticalGlassAfterLayout(owner);assert(g.layer.cornerRadius==9.5 && g.rimRadius==9.5);
 m.layer.cornerRadius=9.75;dockSyncVerticalGlassAfterLayout(owner);assert(g.layer.cornerRadius==9.75 && g.rimRadius==9.75);
 m.layer.cornerCurve=kCACornerCurveContinuous;dockSyncVerticalGlassAfterLayout(owner);assert([g.layer.cornerCurve isEqualToString:m.layer.cornerCurve]);
 frames=frameWrites;filters=filterUpdates;rims=rimUpdates;for(int i=0;i<1000;i++)dockSyncVerticalGlassAfterLayout(owner);assert(frameWrites==frames && filterUpdates==filters && rimUpdates==rims);
 // Other materials below the platter are not the native background.
 MTMaterialView *card=[MTMaterialView new];card.superview=owner;card.frame=CGRectMake(0,0,52,360);
 assert(!dockIsVerticalFloatingMaterial(card) && dockModeForMaterial(card)==LGDockModeNone);
 MTMaterialView *regular=[MTMaterialView new];regular.superview=[SBDockView new];regular.frame=CGRectMake(0,0,390,96);
 assert(dockModeForMaterial(regular)==LGDockModeRegular && dockCornerRadiusForMaterial(regular)==-1);
 regular.frame=CGRectMake(0,0,52,360);assert(!dockIsVerticalFloatingMaterial(regular) && dockModeForMaterial(regular)==LGDockModeNone);
 // Leave the previously-owned vertical Dock and restore horizontal tracking.
 m.frame=CGRectMake(0,0,400,96);m.layer.cornerRadius=36;dockSyncVerticalGlassAfterLayout(owner);
 assert(!objc_getAssociatedObject(owner,kVerticalDockMaterialKey));assert(g.layer.cornerRadius==36);
 assert([objc_getAssociatedObject(g,kLGRadiusKey) doubleValue]==-1);
 filters=filterUpdates;created=installs;for(int i=0;i<1000;i++)dockSyncVerticalGlassAfterLayout(owner);assert(filters==filterUpdates && installs==created);
 // Replacing only the native background removes the old owned overlay.
 m.frame=CGRectMake(0,0,52,360);m.layer.cornerRadius=13;dockSyncVerticalGlassAfterLayout(owner);
 MTMaterialView *replacement=material(owner,52,360,11);dockSyncVerticalGlassAfterLayout(owner);
 assert(!objc_getAssociatedObject(m,kGlassKey) && !m.hidden && !g.superview);
 g=objc_getAssociatedObject(replacement,kGlassKey);assert(g && g.layer.cornerRadius==11 && replacement.hidden);
 // Disable still restores stock material and removes the vertical overlay.
 enabled=NO;dockSyncVerticalGlassAfterLayout(owner);assert(!objc_getAssociatedObject(replacement,kGlassKey) && !replacement.hidden);
 enabled=YES;dockSyncVerticalGlassAfterLayout(owner);assert(objc_getAssociatedObject(replacement,kGlassKey));
 owner.window=nil;replacement.window=nil;dockSyncVerticalGlassAfterLayout(owner);
 assert(!objc_getAssociatedObject(replacement,kGlassKey) && !objc_getAssociatedObject(owner,kVerticalDockMaterialKey));
 // A shape that stops being a vertical or valid horizontal Dock gets cleaned once.
 owner.window=[NSObject new];replacement.window=owner.window;dockSyncVerticalGlassAfterLayout(owner);
 replacement.frame=CGRectMake(0,0,52,52);dockSyncVerticalGlassAfterLayout(owner);
 assert(!objc_getAssociatedObject(replacement,kGlassKey));unsigned removed=removals;
 for(int i=0;i<1000;i++)dockSyncVerticalGlassAfterLayout(owner);assert(removals==removed);
 puts("PASS vertical final radius/rim, 1000 stable layouts, native-background-only scope, horizontal restoration, background replacement, disable/detach/invalid-shape cleanup");
}return 0;}
'''
def main():
    dock=(ROOT/'Hooks/Dock.x').read_text();kit=(ROOT/'Shared/LGGlassKit.x').read_text();render=(ROOT/'Shared/LGLiveBackdropView.m').read_text();code=PRELUDE
    for sig in ['BOOL hasAncestorOfClassName(', 'BOOL isExactClass(']:code+='\n'+function(kit,sig)
    for sig in ['static BOOL dockUsesIOS15DirectGlass(', 'static BOOL dockInsideCategoryStackBackground(', 'static UIView *dockBackgroundForPlatter(', 'static BOOL dockIsVerticalFloatingMaterial(', 'static CGFloat dockCornerRadiusForMaterial(', 'static LGDockMode dockModeForMaterial(']:code+='\n'+function(dock,sig)
    code+='\n'+function(render,'static CGRect LGOutsetFrame(')+'\n'+function(render,'static void LGSyncGlassGeometry(',True)+'\n'+function(render,'void LGResyncGlassGeometry(')+'\n'+function(render,'void LGRemoveGlassFromMaterial(')
    code+=r'''
static LGLiveBackdropView *LGInstallRegisteredGlassInMaterial(UIView *m,const void *key,NSString *prefix,UIEdgeInsets outset,CGFloat radius,NSString *group){
 if(!enabled){LGRemoveGlassFromMaterial(m,key);return nil;}
 LGLiveBackdropView *g=objc_getAssociatedObject(m,key);
 if(!g){installs++;g=[LGLiveBackdropView new];g.superview=m.superview;objc_setAssociatedObject(m,key,g,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}
 objc_setAssociatedObject(g,kLGOutsetKey,[NSValue valueWithUIEdgeInsets:outset],OBJC_ASSOCIATION_RETAIN_NONATOMIC);
 objc_setAssociatedObject(g,kLGRadiusKey,@(radius),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
 LGSyncGlassGeometry(m,key,outset,radius);return g;
}
'''+function(kit,'static void lgRouteMaterialHost(')+'\n'+function(dock,'static void dockSyncVerticalGlassAfterLayout(')+MAIN
    baseline=subprocess.check_output(['/opt/homebrew/bin/rtk','proxy','git','show','71d0eb0:Hooks/Dock.x'],cwd=ROOT,text=True)
    for sig in ['static BOOL dockUsesIOS15DirectGlass(', 'static BOOL dockInsideCategoryStackBackground(', 'static BOOL dockIsFullScreenPhone(', 'static void dockUpdateHomeButtonBorder(', 'static void configureDockGlass(', 'static void removeIOS15DockGlass(', 'static void installIOS15DockGlass(']:assert function(baseline,sig)==function(dock,sig),sig
    old_mode=function(baseline,'static LGDockMode dockModeForMaterial(');new_mode=function(dock,'static LGDockMode dockModeForMaterial(').replace('    if (dockIsVerticalFloatingMaterial(material)) return LGDockModeFloating;\n','');assert old_mode==new_mode
    assert re.search(r'%hook SBFloatingDockPlatterView.*?- \(void\)layoutSubviews \{\s*%orig;\s*dockSyncVerticalGlassAfterLayout',dock,re.S)
    with tempfile.TemporaryDirectory(prefix='ass-vertical-dock-') as tmp:
        p=Path(tmp);(p/'test.m').write_text(code)
        subprocess.run(['/opt/homebrew/bin/rtk','proxy','clang','-fobjc-arc','-framework','Foundation','-framework','QuartzCore','-framework','CoreGraphics',str(p/'test.m'),'-o',str(p/'test')],check=True)
        subprocess.run(['/opt/homebrew/bin/rtk','proxy',str(p/'test')],check=True)
    print('PASS original horizontal/iOS15 Dock functions preserved; post-layout hook runs after original')
if __name__=='__main__':main()
