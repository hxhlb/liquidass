#!/usr/bin/env python3.11
"""Exercise the observed legacy volume hierarchy using actual lifecycle helpers."""
from pathlib import Path
import subprocess,tempfile
from test_clock_icon_ownership import function
ROOT=Path(__file__).resolve().parents[1]
SUPPORT=r'''
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#include <assert.h>
#include <stdio.h>
@interface UIResponder : NSObject
@property(strong) UIResponder *nextResponder;
@end
@implementation UIResponder @end
@interface UIViewController : UIResponder @end
@implementation UIViewController @end
@interface SBElasticVolumeViewController : UIViewController @end
@implementation SBElasticVolumeViewController @end
@interface SBElasticBrightnessViewController : UIViewController @end
@implementation SBElasticBrightnessViewController @end
@interface TestLayer : NSObject
@property CGFloat cornerRadius;
@property(copy) NSString *cornerCurve;
@end
@implementation TestLayer @end
@interface UIView : UIResponder
@property(strong) UIView *window;
@property(strong) UIView *superview;
@property(strong) NSMutableArray *subviews;
@property(strong) NSDictionary *fields;
@property(strong) TestLayer *layer;
@property CGRect frame;
@property CGRect bounds;
@property BOOL hidden;
@property BOOL clipsToBounds;
- (void)removeFromSuperview;
- (void)insertSubview:(UIView *)view atIndex:(NSInteger)index;
@end
@implementation UIView
- (instancetype)init {if((self=[super init])){_subviews=[NSMutableArray new];_layer=[TestLayer new];}return self;}
- (id)valueForKey:(NSString *)key {if([key hasPrefix:@"_"])return self.fields[key];return [super valueForKey:key];}
- (void)removeFromSuperview {[self.superview.subviews removeObject:self];self.superview=nil;}
- (void)insertSubview:(UIView *)view atIndex:(NSInteger)index {view.superview=self;[self.subviews insertObject:view atIndex:index];}
@end
static void LGUpdateLegacyVolumeHUDGlass(UIView *slider);
static BOOL enabled=YES, ready=NO, failCreate=NO, reenter=NO;
static NSUInteger creates, applies;
static UIView *callbackSlider;
@interface LGLiveBackdropView : UIView
@property BOOL lgFilterAttached;
- (void)applyFilters;
@end
@implementation LGLiveBackdropView
- (void)applyFilters {applies++;self.lgFilterAttached=ready;if(reenter)LGUpdateLegacyVolumeHUDGlass(callbackSlider);}
@end
static BOOL LGVolumeHUDEnabled(void){return enabled;}
static LGLiveBackdropView *LGCreateRegisteredGlass(CGRect frame,id group,NSString *prefix){
 if(failCreate)return nil;creates++;LGLiveBackdropView *g=[LGLiveBackdropView new];g.frame=frame;return g;
}
static void lgTrackGlass(id glass,id prefix,id material){}
static NSHashTable<UIView *> *sLGLegacyVolumeSliders;
static const void *kLGVolumeHUDGlassKey=&kLGVolumeHUDGlassKey;
static const void *kLGLegacyVolumeUpdatingKey=&kLGLegacyVolumeUpdatingKey;
static const void *kLGVolumeHUDMaterialHiddenKey=&kLGVolumeHUDMaterialHiddenKey;
'''
MAIN=r'''
int main(void){@autoreleasepool {
 sLGLegacyVolumeSliders=[NSHashTable weakObjectsHashTable];
 UIView *slider=[UIView new],*container=[UIView new],*background=[UIView new],*base=[UIView new],*cap=[UIView new],*shadow=[UIView new],*fill=[UIView new],*glyph=[UIView new];
 slider.nextResponder=[SBElasticVolumeViewController new];slider.window=[UIView new];
 slider.fields=@{@"_elasticContentView":container,@"_backgroundView":background,@"_baseMaterialView":base,@"_captureOnlyMaterialView":cap,@"_shadowView":shadow,@"_backgroundFillView":fill};
 container.bounds=CGRectMake(0,0,47,148);container.layer.cornerRadius=15;
 [container.subviews addObject:glyph];shadow.hidden=YES;callbackSlider=slider;
 failCreate=YES;LGUpdateLegacyVolumeHUDGlass(slider);assert(!base.hidden&&!background.hidden);
 failCreate=NO;LGUpdateLegacyVolumeHUDGlass(slider);
 LGLiveBackdropView *g=objc_getAssociatedObject(slider,kLGVolumeHUDGlassKey);
 assert(g && g.hidden && !base.hidden&&!background.hidden&&!cap.hidden&&shadow.hidden);
 ready=YES;reenter=YES;LGUpdateLegacyVolumeHUDGlass(slider);reenter=NO;
 assert(!g.hidden && base.hidden&&background.hidden&&cap.hidden&&shadow.hidden);
 assert(g.superview==container && container.subviews.firstObject==g && creates==1);
 assert(!fill.hidden&&!glyph.hidden&&g.layer.cornerRadius==15);
 container.bounds=CGRectMake(0,0,58,170);LGUpdateLegacyVolumeHUDGlass(slider);
 assert(CGRectEqualToRect(g.frame,container.bounds)&&creates==1);
 enabled=NO;LGUpdateLegacyVolumeHUDGlass(slider);
 assert(!base.hidden&&!cap.hidden&&!background.hidden&&shadow.hidden&&!g.superview);
 assert(!objc_getAssociatedObject(slider,kLGVolumeHUDGlassKey));
 enabled=YES;slider.nextResponder=[SBElasticBrightnessViewController new];
 LGUpdateLegacyVolumeHUDGlass(slider);assert(creates==1&&!base.hidden);
 slider.nextResponder=[SBElasticVolumeViewController new];LGUpdateLegacyVolumeHUDGlass(slider);assert(creates==2);
 slider.window=nil;LGUpdateLegacyVolumeHUDGlass(slider);
 assert(!base.hidden&&!background.hidden&&shadow.hidden&&!objc_getAssociatedObject(slider,kLGVolumeHUDGlassKey));
 assert(!objc_getAssociatedObject(slider,kLGLegacyVolumeUpdatingKey));
 puts("PASS volume-only scope, delayed filter readiness, geometry, fill/glyph preservation, disable/detach restoration and reentry");
}return 0;}
'''
def main():
 text=(ROOT/'Hooks/VolumeHUD.x').read_text();code=SUPPORT
 for sig in ['static UIView *LGVolumeHUDViewForKey(', 'static BOOL LGVolumeHUDIsVolumeSlider(', 'static void LGVolumeHUDSetNativeViewHidden(', 'static void LGUpdateLegacyVolumeHUDGlass(']:code+=function(text,sig)+'\n'
 with tempfile.TemporaryDirectory(prefix='liquidass-volume-test-') as td:
  src=Path(td)/'test.m';exe=Path(td)/'test';src.write_text(code+MAIN)
  subprocess.run(['xcrun','clang','-fobjc-arc','-framework','Foundation','-framework','CoreGraphics',str(src),'-o',str(exe)],check=True)
  subprocess.run([str(exe)],check=True)
if __name__=='__main__':main()
