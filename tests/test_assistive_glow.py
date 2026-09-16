#!/usr/bin/env python3.11
"""Reproduce iOS 17 zero-sized bitmap assertions using production glow code."""
from pathlib import Path
import subprocess,tempfile,argparse
from test_clock_icon_ownership import function
ROOT=Path(__file__).resolve().parents[1]
SUPPORT=r'''
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <math.h>
#include <assert.h>
#include <stdio.h>
@interface UIImage : NSObject
@property CGSize size;
@end
@implementation UIImage @end
@interface UIColor : NSObject
+ (instancetype)colorWithWhite:(CGFloat)white alpha:(CGFloat)alpha;
@property CGColorRef CGColor;
@end
@implementation UIColor
+ (instancetype)colorWithWhite:(CGFloat)white alpha:(CGFloat)alpha {
 UIColor *c=[UIColor new];c.CGColor=CGColorCreateGenericRGB(white,white,white,alpha);return c;
}
- (void)dealloc { if(_CGColor)CGColorRelease(_CGColor); }
@end
static NSUInteger contextCalls;
static CGContextRef ctx;
static CGSize canvas;
static void UIGraphicsBeginImageContextWithOptions(CGSize size, BOOL opaque, CGFloat scale) {
 contextCalls++;
 if(!isfinite(size.width)||size.width<=0||!isfinite(size.height)||size.height<=0)
  [NSException raise:@"InvalidBitmapSize" format:@"iOS 17 invalid-size assertion"];
 canvas=size;CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB();
 ctx=CGBitmapContextCreate(NULL,(size_t)ceil(size.width),(size_t)ceil(size.height),8,0,cs,(CGBitmapInfo)kCGImageAlphaPremultipliedLast);
 CGColorSpaceRelease(cs);
}
static CGContextRef UIGraphicsGetCurrentContext(void){return ctx;}
static UIImage *UIGraphicsGetImageFromCurrentImageContext(void){UIImage *i=[UIImage new];i.size=canvas;return i;}
static void UIGraphicsEndImageContext(void){if(ctx)CGContextRelease(ctx);ctx=NULL;}
@interface UIImageView : NSObject
@property(strong) UIImage *image;
@property CGRect bounds;
@end
@implementation UIImageView @end
@interface ASSHeldGlassView : NSObject
@property CGRect frame;
@property(readonly) CGRect bounds;
@property(strong) UIImageView *exposureGlowView;
- (void)updateShapeForBounds:(CGRect)bounds;
- (void)updateShapeWithScale:(CGFloat)s stretchX:(CGFloat)x stretchY:(CGFloat)y shiftX:(CGFloat)dx shiftY:(CGFloat)dy;
@end
'''
MAIN=r'''
@end
int main(void){@autoreleasepool {
 @try {
  for(NSNumber *v in @[@0,@(-1),@(NAN),@(INFINITY)]) assert(CreateExposureGlowImage(v.doubleValue)==nil);
 } @catch(NSException *e){fprintf(stderr,"FAIL zero/invalid diameter reached UIKit bitmap context\n");return 1;}
 assert(contextCalls==0);
 ASSHeldGlassView *g=[ASSHeldGlassView new];g.exposureGlowView=[UIImageView new];
 [g updateShapeForBounds:CGRectZero];assert(contextCalls==0 && !g.exposureGlowView.image);
 [g updateShapeForBounds:CGRectMake(0,0,60,60)];
 assert(contextCalls==1 && g.exposureGlowView.image && fabs(g.exposureGlowView.bounds.size.width-93)<.001);
 for(int i=0;i<100;i++)[g updateShapeForBounds:CGRectMake(0,0,60,60)];assert(contextCalls==1);
 [g updateShapeForBounds:CGRectMake(0,0,80,80)];assert(contextCalls==2);
 assert(fabs(g.exposureGlowView.image.size.width-124)<.001);
 puts("PASS zero/invalid initial bounds, delayed glow creation, reuse and resize");
}return 0;}
'''
def main():
 p=argparse.ArgumentParser();p.add_argument('--revision');a=p.parse_args()
 source=subprocess.check_output(['git','show',a.revision+':Hooks/AssistiveTouch.x'],cwd=ROOT,text=True) if a.revision else (ROOT/'Hooks/AssistiveTouch.x').read_text()
 code=SUPPORT+function(source,'static UIImage *CreateExposureGlowImage(')+'\n@implementation ASSHeldGlassView\n- (CGRect)bounds{return (CGRect){CGPointZero,self.frame.size};}\n- (void)updateShapeWithScale:(CGFloat)s stretchX:(CGFloat)x stretchY:(CGFloat)y shiftX:(CGFloat)dx shiftY:(CGFloat)dy {}\n'+function(source,'- (void)updateShapeForBounds:(CGRect)bounds {')+MAIN
 with tempfile.TemporaryDirectory(prefix='liquidass-glow-') as td:
  src=Path(td)/'test.m';exe=Path(td)/'test';src.write_text(code)
  subprocess.run(['xcrun','clang','-fobjc-arc','-framework','Foundation','-framework','CoreGraphics',str(src),'-o',str(exe)],check=True)
  subprocess.run([str(exe)],check=True)
if __name__=='__main__':main()
