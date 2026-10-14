#!/usr/bin/env python3.11
"""Exercise production activity scope, native color ABI and backing restoration."""
from pathlib import Path
import re
import subprocess
import tempfile
from test_widget_host import function

ROOT = Path(__file__).resolve().parents[1]
SUPPORT = r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "LGWidgetCompatibility.h"
#include <assert.h>
#include <string.h>
COLOR_TYPE
static BOOL sRWBIsChronod=YES, kActivityEnabled=YES, sActivityColorSupported=YES;
static NSHashTable *sActivityLayers;
static char kActivityLayerStateKey;
static __thread NSUInteger sApplyingActivityColor;
@interface Session:NSObject
@property(copy) NSString *role,*persistentIdentifier;
@end
@implementation Session @end
@interface Scene:NSObject
@property(strong) Session *session;
@property(copy) NSString *nativeIdentifier;
-(id)_sceneIdentifier;
@end
@implementation Scene
-(id)_sceneIdentifier{return self.nativeIdentifier;}
@end
@interface UIWindowScene:Scene @end
@implementation UIWindowScene @end
@interface UIWindow:NSObject
@property(strong) UIWindowScene *windowScene;
@end
@implementation UIWindow @end
@interface UIView:NSObject
@property(strong) UIWindow *window;
@end
@implementation UIView @end
@interface RBLayer:NSObject { LGActivityClearColor _clearColor; }
@property BOOL opaque;
@property(strong) id delegate,contents;
@property LGActivityClearColor clearColor;
@property NSUInteger invalidations;
-(void)nativeSetClearColor:(LGActivityClearColor)color;
-(void)setNeedsDisplay;
@end
static void RWBPublishActivityStatus(RBLayer *layer, LGActivityClearColor color){}
static void RWBPrepareActivityHostingAncestors(UIView *view){}
static void RWBRestoreActivityHostingLayers(void){}
static void RWBRestoreActivityHostingBackground(RBLayer *layer){}
static void RWBPublishHostingStatus(id view,id color,id layerColor,BOOL opaque){}
'''
IMPLEMENTATION = r'''
@implementation RBLayer
-(LGActivityClearColor)clearColor{return _clearColor;}
-(void)nativeSetClearColor:(LGActivityClearColor)color{_clearColor=color;}
-(void)setNeedsDisplay{self.invalidations++;}
COLOR_SETTER
@end
typedef struct { double c0,c1,c2,c3; } WrongColor;
@interface WrongLayer:NSObject
@property WrongColor clearColor;
@end
@implementation WrongLayer @end
static BOOL zero(LGActivityClearColor c){return c.c0==0&&c.c1==0&&c.c2==0&&c.c3==0;}
static BOOL same(LGActivityClearColor a,LGActivityClearColor b){return memcmp(&a,&b,sizeof(a))==0;}
'''
CHECKS = r'''
int main(){@autoreleasepool{
 assert(sizeof(LGActivityClearColor)==16);
 assert(RWBActivityColorABICompatible(RBLayer.class));
 assert(!RWBActivityColorABICompatible(WrongLayer.class));
 assert(!RWBActivityColorABICompatible(NSObject.class));
 assert(RWBActivitySceneMatches(@"UIWindowSceneSessionRoleSystemAperture",nil));
 assert(RWBActivitySceneMatches(nil,@"activity:sample"));
 assert(!RWBActivitySceneMatches(@"UIWindowSceneSessionRoleApplication",@"widget:sample"));
 assert(!RWBActivitySceneMatches(nil,nil));
 sActivityLayers=[NSHashTable weakObjectsHashTable];
 UIWindowScene *scene=[UIWindowScene new];scene.session=[Session new];
 scene.session.role=@"SystemAperture";
 UIWindow *window=[UIWindow new];window.windowScene=scene;
 UIView *view=[UIView new];view.window=window;
 RBLayer *layer=[RBLayer new];layer.delegate=view;layer.opaque=YES;
 const unsigned char pixels[]={0,0,0,255,255,128,0,255,20,80,240,160};
 NSData *content=[NSData dataWithBytes:pixels length:sizeof(pixels)];layer.contents=content;
 LGActivityClearColor black={0,0,0,1},changed={.2,.3,.4,.7};
 [layer nativeSetClearColor:black];
 assert(RWBActivityLayerMatches(layer));RWBPrepareActivityLayer(layer);
 assert(zero(layer.clearColor)&&!layer.opaque&&layer.contents==content);
 assert([layer.contents isEqualToData:content]);
 layer.clearColor=changed;assert(zero(layer.clearColor));
 view.window=nil;assert(RWBActivityLayerMatches(layer));
 kActivityEnabled=NO;RWBRestoreActivityLayers();
 assert(same(layer.clearColor,changed)&&layer.opaque&&layer.contents==content);
 assert(!objc_getAssociatedObject(layer,&kActivityLayerStateKey));
 assert(sActivityLayers.count==0);
 kActivityEnabled=YES;view.window=window;RWBPrepareActivityLayer(layer);
 scene.session.role=@"UIWindowSceneSessionRoleApplication";
 scene.session.persistentIdentifier=@"widget:sample";
 assert(!RWBActivityLayerMatches(layer));
 layer.clearColor=black;assert(same(layer.clearColor,black)&&layer.opaque);
 assert(!objc_getAssociatedObject(layer,&kActivityLayerStateKey));
 scene.session.persistentIdentifier=nil;scene.nativeIdentifier=@"activity:sample";
 assert(RWBActivityLayerMatches(layer));
 sRWBIsChronod=NO;assert(!RWBActivityLayerMatches(layer));
 sRWBIsChronod=YES;sActivityColorSupported=NO;assert(!RWBActivityLayerMatches(layer));
 layer.clearColor=changed;assert(same(layer.clearColor,changed)&&layer.contents==content);
 puts("PASS activity-only backing alpha, native content bytes preserved, new native color restored, scene migration, disable and ABI guards");
}return 0;}
'''


def main():
    source = (ROOT / 'LiquidAssRWB/Tweak.x').read_text()
    color_type = re.search(r'typedef struct \{ float c0, c1, c2, c3; \} LGActivityClearColor;', source).group()
    code = SUPPORT.replace('COLOR_TYPE', color_type)
    for signature in ['static BOOL RWBActivitySceneMatches(', 'static BOOL RWBActivityLayerMatches(',
                      'static void RWBCaptureActivityLayer(', 'static void RWBPrepareActivityLayer(',
                      'static void RWBRestoreActivityLayer(', 'static void RWBRestoreActivityLayers(void) {',
                      'static BOOL RWBFourFloatColorType(', 'static BOOL RWBActivityColorABICompatible(']:
        code += function(source, signature) + '\n'
    setter = function(source, '- (void)setClearColor:(LGActivityClearColor)color {')
    setter = setter.replace('%orig((LGActivityClearColor){0});', '[self nativeSetClearColor:(LGActivityClearColor){0}];')
    setter = setter.replace('%orig(color);', '[self nativeSetClearColor:color];')
    code += IMPLEMENTATION.replace('COLOR_SETTER', setter) + CHECKS
    display = function(source[source.index('%hook RBLayer'):], '- (void)display {')
    activity_branch = display[display.index('if (RWBActivityLayerMatches'):display.index('RWBRestoreActivityLayer(self);')]
    assert '%orig;' in activity_branch and 'return;' in activity_branch
    assert 'threadDict' not in activity_branch and 'contents =' not in activity_branch
    with tempfile.TemporaryDirectory(prefix='liquidass-activity-background-') as tmp:
        src, exe = Path(tmp) / 'test.m', Path(tmp) / 'test'
        src.write_text(code)
        subprocess.run(['xcrun','clang','-fobjc-arc','-framework','Foundation',
                        '-I'+str(ROOT/'Shared'),str(src),'-o',str(exe)], check=True)
        subprocess.run([str(exe)], check=True)


if __name__ == '__main__':
    main()
