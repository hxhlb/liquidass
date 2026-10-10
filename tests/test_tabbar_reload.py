#!/usr/bin/env python3.11
"""Exercise production exclusion, appearance/glyph capture and removal logic."""
from pathlib import Path
import re
import subprocess
import tempfile
from test_clock_icon_ownership import function

ROOT = Path(__file__).resolve().parents[1]
SUPPORT = r'''
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#include <assert.h>
static NSInteger osMajor;
static id exclusions;
static BOOL hostEnabled=YES;
static NSUInteger evaluations;
static BOOL lgHostEnabled(NSString *p){return hostEnabled;}
static id LGGlassPreferenceValue(NSString *p){return exclusions;}
static BOOL LGProcessMatchesExclusionList(id list){evaluations++;return [list containsObject:@"test.app"];}
#define CALayer LGTestLayer
@interface CALayer:NSObject
@property BOOL masksToBounds;
@property(strong) id compositingFilter;
@end
@implementation CALayer @end
@interface UIColor:NSObject
+(id)whiteColor;
@end
@implementation UIColor
+(id)whiteColor{return @"white";}
@end
static NSString *NSForegroundColorAttributeName=@"foreground";
@interface UIView:NSObject
@property CGRect frame;
@property CGAffineTransform transform;
@property BOOL hidden,clipsToBounds;
@property(strong) id backgroundColor,tintColor;
@property(strong) CALayer *layer;
@property(strong) UIView *superview;
@property(strong) NSArray *subviews;
@property NSUInteger invalidations;
-(void)removeFromSuperview;-(void)setNeedsLayout;-(void)invalidateIntrinsicContentSize;
@end
@implementation UIView
-(id)init{if((self=[super init])){_layer=[CALayer new];_subviews=@[];_transform=CGAffineTransformIdentity;}return self;}
-(void)removeFromSuperview{self.superview=nil;}
-(void)setNeedsLayout{self.invalidations++;}
-(void)invalidateIntrinsicContentSize{self.invalidations++;}
@end
@interface UILabel:UIView @property(strong) id textColor; @end
@implementation UILabel @end
@interface UIImageView:UIView @end
@implementation UIImageView @end
@interface UITabBarButtonLabel:UILabel @end
@implementation UITabBarButtonLabel @end
@interface UITabBarSwappableImageView:UIImageView @end
@implementation UITabBarSwappableImageView @end
@interface _UIBarBackground:UIView @end
@implementation _UIBarBackground @end
@interface LGNormal:NSObject<NSCopying>
@property(strong) id iconColor;
@property(copy) NSDictionary *titleTextAttributes;
@end
@implementation LGNormal
-(id)copyWithZone:(NSZone*)z{LGNormal *n=[LGNormal new];n.iconColor=self.iconColor;n.titleTextAttributes=self.titleTextAttributes;return n;}
@end
@interface LGLayout:NSObject<NSCopying> @property(strong) LGNormal *normal; @end
@implementation LGLayout
-(id)init{if((self=[super init]))_normal=[LGNormal new];return self;}
-(id)copyWithZone:(NSZone*)z{LGLayout *n=[LGLayout new];n.normal=[self.normal copy];return n;}
@end
@interface UITabBarAppearance:NSObject<NSCopying>
@property(strong) LGLayout *stackedLayoutAppearance,*inlineLayoutAppearance,*compactInlineLayoutAppearance;
@end
@implementation UITabBarAppearance
-(id)init{if((self=[super init])){_stackedLayoutAppearance=[LGLayout new];_inlineLayoutAppearance=[LGLayout new];_compactInlineLayoutAppearance=[LGLayout new];}return self;}
-(id)copyWithZone:(NSZone*)z{UITabBarAppearance *n=[UITabBarAppearance new];n.stackedLayoutAppearance=[self.stackedLayoutAppearance copy];n.inlineLayoutAppearance=[self.inlineLayoutAppearance copy];n.compactInlineLayoutAppearance=[self.compactInlineLayoutAppearance copy];return n;}
@end
@interface UITabBar:UIView
@property(strong) id barTintColor,unselectedItemTintColor,selectedItem;
@property(strong) NSArray *items,*buttons;
@property(strong) UITabBarAppearance *standardAppearance,*scrollEdgeAppearance;
@end
@implementation UITabBar @end
@interface UIViewPropertyAnimator:NSObject
@property BOOL stopped;-(void)stopAnimation:(BOOL)b;
@end
@implementation UIViewPropertyAnimator
-(void)stopAnimation:(BOOL)b{self.stopped=YES;}
@end
@interface LGTabBarMotionState:NSObject
@property BOOL active,awaitingTapDestination,awaitingRestingShape;
@property(copy) void(^onArrival)(void);-(void)stop;
@end
@implementation LGTabBarMotionState
-(void)stop{if(self.onArrival)self.onArrival();}
@end
static LGTabBarMotionState *motion;
static LGTabBarMotionState *LGTabBarMotionStateForBar(UITabBar *bar,BOOL create){return motion;}
static NSArray *LGStockTabBarButtons(UITabBar *bar){return bar.buttons;}
static BOOL LGIsStockTabBar(UITabBar *bar){return YES;}
static void LGStartTabBarLumaSampling(UITabBar *bar){}
static void LGRestoreTabBarGlyphs(UITabBar *bar);
@interface NSValue(RectFixture)
+(id)valueWithCGRect:(CGRect)r;-(CGRect)CGRectValue;
@end
@implementation NSValue(RectFixture)
+(id)valueWithCGRect:(CGRect)r{return [NSValue valueWithBytes:&r objCType:@encode(CGRect)];}
-(CGRect)CGRectValue{CGRect r;[self getValue:&r size:sizeof(r)];return r;}
@end
'''
MAIN = r'''
int main(){@autoreleasepool{
 exclusions=@[];assert(LGTabBarAllowed());exclusions=@[@"test.app"];assert(!LGTabBarAllowed());
 NSUInteger n=evaluations;assert(!LGTabBarAllowed()&&evaluations==n);
 exclusions=@[];assert(LGTabBarAllowed());
 for(NSNumber *os in @[@14,@15,@16,@17,@18]) {osMajor=os.integerValue;
  UITabBar *bar=[UITabBar new];bar.buttons=@[[UIView new]];bar.items=@[@1];
  bar.standardAppearance=[UITabBarAppearance new];bar.standardAppearance.stackedLayoutAppearance.normal.iconColor=@"nativeIcon";
  bar.unselectedItemTintColor=@"nativeUnselected";
  UIView *button=bar.buttons[0];UITabBarButtonLabel *label=[UITabBarButtonLabel new];label.textColor=@"nativeText";
  label.layer.compositingFilter=@"nativeFilter";button.subviews=@[label];
  _UIBarBackground *bg=[_UIBarBackground new];bar.subviews=@[bg,button];
  for(int cycle=0;cycle<3;cycle++){
   exclusions=@[];LGConfigureTabBarAppearance(bar);LGApplyTabBarGlyphColor(bar,(id)@"custom");
   UIView *glass=[UIView new];glass.superview=bar;
   objc_setAssociatedObject(bar,kLGTabBarGlassKey,glass,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
   objc_setAssociatedObject(bar,kLGTabBarOriginalBackgroundHiddenKey,@NO,OBJC_ASSOCIATION_RETAIN_NONATOMIC);bg.hidden=YES;
   objc_setAssociatedObject(bar,kLGTabBarOriginalClipsKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);bar.clipsToBounds=NO;
   objc_setAssociatedObject(bar,kLGTabBarOriginalMasksKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);bar.layer.masksToBounds=NO;
   objc_setAssociatedObject(button,kLGTabBarOriginalButtonFrameKey,[NSValue valueWithCGRect:CGRectMake(1,2,30,40)],OBJC_ASSOCIATION_RETAIN_NONATOMIC);
   button.frame=CGRectMake(100,100,10,10);button.transform=CGAffineTransformMakeScale(1.2,1.2);
   motion=[LGTabBarMotionState new];__block BOOL committed=NO;motion.onArrival=^{committed=YES;};
   exclusions=@[@"test.app"];assert(!LGTabBarAllowed());LGRemoveTabBarInjection(bar);
   assert(!committed&&!glass.superview&&!bg.hidden&&bar.clipsToBounds&&bar.layer.masksToBounds);
   assert([bar.standardAppearance.stackedLayoutAppearance.normal.iconColor isEqual:@"nativeIcon"]);
   assert([bar.unselectedItemTintColor isEqual:@"nativeUnselected"]&&[label.textColor isEqual:@"nativeText"]);
   assert([label.layer.compositingFilter isEqual:@"nativeFilter"]);
   assert(CGRectEqualToRect(button.frame,CGRectMake(1,2,30,40))&&CGAffineTransformIsIdentity(button.transform));
   assert(!objc_getAssociatedObject(bar,kLGTabBarAppearanceConfiguredKey));
   LGRemoveTabBarInjection(bar);assert([label.textColor isEqual:@"nativeText"]);
  }
 }
 puts("PASS exclusion cache invalidation + 3 enable/exclude cycles across iOS14-18 fixtures; restores appearance, glyphs, geometry and cancels pending selection");
}return 0;}
'''

def main():
    s=(ROOT/'Hooks/TabBar.x').read_text()
    keys='\n'.join(m.group() for m in re.finditer(r'static (?:const void \*|char )kLGTabBar\w+[\s\S]*?;',s))
    code=SUPPORT+keys
    for signature in ['static BOOL LGTabBarAllowed(', 'static void LGCollectTabBarContentViews(',
                      'static void LGApplyTabBarGlyphColor(', 'static void LGRestoreTabBarGlyphs(UITabBar *bar) {',
                      'static void LGRemoveTabBarInjection(', 'static void LGConfigureTabBarAppearance(']:
        code+=function(s,signature)+'\n'
    code=re.sub(r'@available\(iOS ([0-9]+)\.[0-9]+, \*\)',r'osMajor >= \1',code)+MAIN
    with tempfile.TemporaryDirectory(prefix='liquidass-tabbar-reload-') as d:
        src=Path(d)/'test.m';exe=Path(d)/'test';src.write_text(code)
        subprocess.run(['xcrun','clang','-fobjc-arc','-framework','Foundation','-framework','CoreGraphics',str(src),'-o',str(exe)],check=True)
        subprocess.run([str(exe)],check=True)

if __name__=='__main__':main()
