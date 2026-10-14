#!/usr/bin/env python3.11
"""Run production Activity hosting helpers and setters with native-color fixtures."""
from pathlib import Path
import subprocess
import tempfile
from test_widget_host import function
ROOT = Path(__file__).resolve().parents[1]
SUPPORT = r'''
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import "LGWidgetCompatibility.h"
#import <notify.h>
#import <math.h>
#include <assert.h>
static uint32_t fixtureNotify(int token,uint64_t state){return 0;}
#define notify_set_state fixtureNotify
@interface UIColor:NSObject { CGColorRef _color; }
@property(readonly) CGColorRef CGColor;
+(instancetype)colorWithCGColor:(CGColorRef)color;
+(instancetype)clearColor;
-(instancetype)resolvedColorWithTraitCollection:(id)traits;
-(BOOL)getRed:(CGFloat*)r green:(CGFloat*)g blue:(CGFloat*)b alpha:(CGFloat*)a;
@end
@implementation UIColor
+(instancetype)colorWithCGColor:(CGColorRef)c{UIColor *v=[self new];v->_color=CGColorRetain(c);return v;}
+(instancetype)clearColor{CGColorRef c=CGColorCreateGenericRGB(0,0,0,0);id v=[self colorWithCGColor:c];CGColorRelease(c);return v;}
-(void)dealloc{if(_color)CGColorRelease(_color);}
-(CGColorRef)CGColor{return _color;}
-(instancetype)resolvedColorWithTraitCollection:(id)t{return self;}
-(BOOL)getRed:(CGFloat*)r green:(CGFloat*)g blue:(CGFloat*)b alpha:(CGFloat*)a{
 if(!_color||CGColorGetNumberOfComponents(_color)!=4)return NO;
 const CGFloat *c=CGColorGetComponents(_color);*r=c[0];*g=c[1];*b=c[2];*a=c[3];return YES;
}
@end
@interface Session:NSObject
@property(copy) NSString *role,*persistentIdentifier;
@end
@implementation Session @end
@interface UIWindowScene:NSObject
@property(strong) Session *session;
@end
@implementation UIWindowScene @end
@interface UIWindow:NSObject
@property(strong) UIWindowScene *windowScene;
@end
@implementation UIWindow @end
@interface CALayer:NSObject { CGColorRef _backgroundColor; }
@property(weak) id delegate;
@property(strong) id contents;
@property(nonatomic) BOOL opaque;
@property CGColorRef backgroundColor;
-(void)nativeSetBackgroundColor:(CGColorRef)c;
-(void)setNeedsDisplay;
@end

@interface RBLayer:CALayer @end
@interface UIView:NSObject
@property(strong) UIWindow *window;
@property(weak) UIView *superview;
@property(strong) CALayer *layer;
@property(nonatomic,strong) UIColor *backgroundColor;
@property(nonatomic) BOOL opaque;
@property(readonly) id traitCollection;
-(void)nativeSetBackgroundColor:(UIColor*)c;
-(void)nativeSetOpaque:(BOOL)o;
@end
static BOOL sRWBIsChronod=YES,kActivityEnabled=YES,sActivityColorSupported=YES;
static NSHashTable *sActivityLayers,*sActivityHostingLayers;
static char kActivityLayerStateKey,kActivityHostingStateKey;
static __thread NSUInteger sApplyingHostingBackground;
static int sHostingDiagnosticToken=-1;
static uint64_t sHostingDiagnosticState,sHostingSeenFlags,sHostingColorSample;
static void RWBPrepareActivityHostingBackground(UIView *view);
static void RWBRestoreActivityHostingBackground(CALayer *layer);
'''
IMPLEMENTATION = r'''
@implementation CALayer
-(CGColorRef)backgroundColor{return _backgroundColor;}
-(void)nativeSetBackgroundColor:(CGColorRef)c{if(c)CGColorRetain(c);if(_backgroundColor)CGColorRelease(_backgroundColor);_backgroundColor=c;}
LAYER_SETTER
-(void)dealloc{if(_backgroundColor)CGColorRelease(_backgroundColor);}
-(void)setNeedsDisplay{}
@end
@implementation UIView
-(id)traitCollection{return nil;}
-(void)nativeSetBackgroundColor:(UIColor*)c{_backgroundColor=c;self.layer.backgroundColor=c.CGColor;}
-(void)nativeSetOpaque:(BOOL)o{_opaque=o;self.layer.opaque=o;}
VIEW_SETTERS
@end
@implementation RBLayer @end
@interface FakeUIHostingView:UIView @end
@implementation FakeUIHostingView @end
@interface HostingSubclass:FakeUIHostingView @end
@implementation HostingSubclass @end
static UIColor *rgb(CGFloat r,CGFloat g,CGFloat b,CGFloat a){
 CGColorRef c=CGColorCreateGenericRGB(r,g,b,a);id value=[UIColor colorWithCGColor:c];CGColorRelease(c);return value;
}
static BOOL equal(UIColor*a,UIColor*b){return a==b||(a&&b&&CGColorEqualToColor(a.CGColor,b.CGColor));}
static BOOL transparent(CGColorRef c){return !c||CGColorGetAlpha(c)==0;}
static UIView *fixture(Class cls,NSString *identifier){
 UIView*v=[cls new];v.layer=[RBLayer new];v.layer.delegate=v;
 v.window=[UIWindow new];v.window.windowScene=[UIWindowScene new];v.window.windowScene.session=[Session new];
 v.window.windowScene.session.persistentIdentifier=identifier;return v;
}
'''
CHECKS = r'''
int main(){@autoreleasepool{
 sActivityLayers=[NSHashTable weakObjectsHashTable];
 UIColor *black=rgb(0,0,0,1),*red=rgb(1,0,0,1),*blue=rgb(0,0,1,.7);
 kActivityEnabled=NO;
 UIView *v=fixture(HostingSubclass.class,@"activity:test");
 v.layer=[CALayer new];v.layer.delegate=v;
 CALayer *l=v.layer;
 [v nativeSetBackgroundColor:black];[v nativeSetOpaque:YES];
 const unsigned char bytes[]={0,0,0,255,255,128,0,255,20,80,240,160};
 NSData *content=[NSData dataWithBytes:bytes length:sizeof(bytes)];l.contents=content;
 UIView *drawing=fixture(UIView.class,@"activity:test");drawing.superview=v;
 drawing.layer.contents=content;
 kActivityEnabled=YES;
 assert(RWBActivityLayerMatches((RBLayer*)drawing.layer));
 assert(RWBActivityHostingViewMatches(v));RWBPrepareActivityHostingAncestors(drawing);
 assert(sActivityLayers.count==0&&sActivityHostingLayers.count==1);
 CALayer *otherLayer=[CALayer new];otherLayer.delegate=v;otherLayer.backgroundColor=black.CGColor;
 assert(CGColorEqualToColor(otherLayer.backgroundColor,black.CGColor)); // never alter another layer merely sharing the delegate
 assert(drawing.layer.contents==content&&[drawing.layer.contents isEqualToData:content]);
 assert(transparent(v.backgroundColor.CGColor)&&transparent(l.backgroundColor)&&!v.opaque);
 assert(l.contents==content&&[l.contents isEqualToData:content]);
 UIWindow *originalWindow=v.window;v.window=nil;
 assert(RWBActivityHostingViewMatches(v)); // only already-captured detached hosts retain scope
 kActivityEnabled=NO;RWBRestoreActivityHostingLayers();v.window=originalWindow;
 assert(equal(v.backgroundColor,black)&&CGColorEqualToColor(l.backgroundColor,black.CGColor)&&v.opaque);
 assert(!objc_getAssociatedObject(l,&kActivityHostingStateKey)&&sActivityHostingLayers.count==0);
 kActivityEnabled=YES;RWBPrepareActivityHostingBackground(v);
 v.backgroundColor=red;assert(equal(v.backgroundColor,red));assert(CGColorEqualToColor(l.backgroundColor,red.CGColor));
 v.backgroundColor=black;assert(transparent(v.backgroundColor.CGColor));
 l.backgroundColor=black.CGColor;assert(transparent(l.backgroundColor));
 l.backgroundColor=blue.CGColor;assert(CGColorEqualToColor(l.backgroundColor,blue.CGColor));
 v.opaque=YES;assert(!v.opaque);
 kActivityEnabled=NO;RWBRestoreActivityHostingBackground(l);
 assert(equal(v.backgroundColor,black)&&CGColorEqualToColor(l.backgroundColor,blue.CGColor)&&v.opaque);
 kActivityEnabled=YES;RWBPrepareActivityHostingBackground(v);
 v.window.windowScene.session.persistentIdentifier=@"widget:ordinary";
 v.backgroundColor=red;assert(equal(v.backgroundColor,red)&&v.opaque);
 assert(!objc_getAssociatedObject(l,&kActivityHostingStateKey));
 UIView *ordinary=fixture(UIView.class,@"activity:test");[ordinary nativeSetBackgroundColor:black];
 UIView *widget=fixture(FakeUIHostingView.class,@"widget:test");[widget nativeSetBackgroundColor:black];
 assert(!RWBActivityHostingViewMatches(ordinary)&&!RWBActivityHostingViewMatches(widget));
 RWBUpdateActivityHostingBackground(ordinary);RWBUpdateActivityHostingBackground(widget);
 assert(equal(ordinary.backgroundColor,black)&&equal(widget.backgroundColor,black));
 v.window.windowScene.session.persistentIdentifier=@"activity:test";
 sRWBIsChronod=NO;v.backgroundColor=black;v.opaque=YES;
 assert(equal(v.backgroundColor,black)&&v.opaque&&!RWBActivityHostingViewMatches(v));
 sRWBIsChronod=YES;sActivityColorSupported=NO;
 assert(!RWBActivityHostingViewMatches(v));v.backgroundColor=blue;assert(equal(v.backgroundColor,blue));
 sActivityColorSupported=YES;RWBPrepareActivityHostingBackground(v);
 v.opaque=NO;
 assert(equal(v.backgroundColor,blue)); // colored content background is retained
 kActivityEnabled=NO;RWBRestoreActivityHostingBackground(l);
 assert(l.contents==content&&[l.contents isEqualToData:content]&&!v.opaque);
 kActivityEnabled=YES;RWBPrepareActivityHostingBackground(v);
 dispatch_semaphore_t done=dispatch_semaphore_create(0);
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{
   l.backgroundColor=red.CGColor;
   assert(CGColorEqualToColor(l.backgroundColor,red.CGColor)); // worker setter passes through
   dispatch_semaphore_signal(done);
 });
 dispatch_semaphore_wait(done,DISPATCH_TIME_FOREVER);
 kActivityEnabled=NO;RWBRestoreActivityHostingBackground(l);
 assert(CGColorEqualToColor(l.backgroundColor,red.CGColor)); // last native layer color survives
 kActivityEnabled=YES;
 __weak CALayer *weakLayer;
 @autoreleasepool{
   UIView *temporary=fixture(FakeUIHostingView.class,@"activity:temporary");
   temporary.backgroundColor=black;RWBPrepareActivityHostingBackground(temporary);
   weakLayer=temporary.layer;assert(weakLayer);
 }
 assert(!weakLayer); // state and registry do not retain the hosting view or layer
 sHostingDiagnosticToken=0;kActivityEnabled=YES;
 RWBPublishHostingStatus(ordinary,black,black,YES);assert((sHostingSeenFlags&~4u)==0);
 RWBPublishHostingStatus(v,black,black,YES);assert((sHostingSeenFlags&124)==124);
 kActivityEnabled=NO;RWBPublishHostingStatus(nil,nil,nil,NO);assert(sHostingSeenFlags==0&&sHostingColorSample==0);
 puts("PASS production hosting helpers/setters: black canvas cleared, foreground bytes/colors retained, latest native colors/opacity restored, migration/disable and scope guards");
}return 0;}
'''

def main():
    source=(ROOT/'LiquidAssRWB/Tweak.x').read_text()
    begin=source.index('@interface LGActivityHostingBackgroundState')
    end=source.index('@interface CHUISWidgetHostViewController',begin)
    code=SUPPORT+function(source,'static BOOL RWBActivitySceneMatches(')+'\n'
    code+=function(source,'static BOOL RWBActivityLayerMatches(')+'\n'+source[begin:end]
    setters=[]
    for signature,arg in [('- (void)setBackgroundColor:(UIColor *)color {','color'),('- (void)setOpaque:(BOOL)opaque {','opaque')]:
        body=function(source,signature)
        if arg=='color':
            body=body.replace('%orig(RWBHostingColorIsBlack(self, color) ? UIColor.clearColor : color);','[self nativeSetBackgroundColor:RWBHostingColorIsBlack(self, color) ? UIColor.clearColor : color];').replace('%orig(color);','[self nativeSetBackgroundColor:color];')
        else:
            body=body.replace('%orig(NO);','[self nativeSetOpaque:NO];').replace('%orig(opaque);','[self nativeSetOpaque:opaque];')
        assert '%orig' not in body
        setters.append(body)
    layer=function(source,'- (void)setBackgroundColor:(CGColorRef)color {')
    layer=layer.replace('%orig(RWBHostingColorIsBlack(view, state.layerColor) ? NULL : color);','[self nativeSetBackgroundColor:RWBHostingColorIsBlack(view, state.layerColor) ? NULL : color];').replace('%orig(color);','[self nativeSetBackgroundColor:color];')
    assert '%orig' not in layer
    code+=IMPLEMENTATION.replace('VIEW_SETTERS','\n'.join(setters)).replace('LAYER_SETTER',layer)+CHECKS
    code=code.replace("CALayer", "FixtureLayer")
    with tempfile.TemporaryDirectory(prefix='liquidass-hosting-background-') as tmp:
        src,exe=Path(tmp)/'test.m',Path(tmp)/'test'
        src.write_text(code)
        subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-framework','Foundation','-framework','CoreGraphics','-I'+str(ROOT/'Shared'),str(src),'-o',str(exe)],check=True)
        subprocess.run([str(exe)],check=True)

if __name__=='__main__':main()
