#!/usr/bin/env python3.11
"""Exercise real folder recovery traversal while filter creation is unavailable."""
from pathlib import Path
import argparse
import subprocess
import tempfile
from test_widget_host import function

ROOT = Path(__file__).resolve().parents[1]
SUPPORT = r'''
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#include <assert.h>
static void *kGlassKey=&kGlassKey;
static BOOL filterReady=YES;
static NSUInteger installs;
@interface FixtureLayer:NSObject
@property(strong) NSArray *filters;
-(void)setNeedsDisplay;
@end
@implementation FixtureLayer
-(void)setNeedsDisplay{}
@end
@interface UIView:NSObject
@property(strong) id window;
@property(strong) NSArray *subviews;
@property(strong) FixtureLayer *layer;
@property CGRect bounds;
@property CGAffineTransform transform;
@end
@implementation UIView @end
@interface MTMaterialView:UIView @end
@implementation MTMaterialView @end
@interface LGLiveBackdropView:UIView {
@public BOOL _parameterRefreshVariant,_filterAttached;
}
-(void)applyFilters;
-(void)lgInvalidateFilterContents;
@end
@implementation LGLiveBackdropView
-(void)applyFilters {
 if(filterReady){self.layer.filters=@[[_parameterRefreshVariant?@"refresh":@"base" copy]];_filterAttached=YES;}
}
INVALIDATE_METHOD
@end
@interface CATransaction:NSObject
+(void)begin;+(void)commit;+(void)setDisableActions:(BOOL)value;
@end
@implementation CATransaction
+(void)begin{} +(void)commit{} +(void)setDisableActions:(BOOL)value{}
@end
static BOOL isExactClass(id view,NSString *name){return [NSStringFromClass([view class]) isEqual:name];}
static BOOL isOpenFolderMaterial(UIView *view){return view.bounds.size.width>=200&&view.bounds.size.height>=200;}
static void injectOpenFolder(UIView *view){installs++;}
'''
CHECKS = r'''
int main(){@autoreleasepool{
 UIView *root=[UIView new];root.window=[NSObject new];
 MTMaterialView *material=[MTMaterialView new];material.bounds=CGRectMake(0,0,400,400);
 LGLiveBackdropView *glass=[LGLiveBackdropView new];glass.layer=[FixtureLayer new];
 NSObject *original=[NSObject new];glass.layer.filters=@[original];glass->_filterAttached=YES;
 objc_setAssociatedObject(material,kGlassKey,glass,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
 root.subviews=@[material];
 for(NSNumber *scale in @[@1.0,@1.2,@1.5]){
  root.transform=CGAffineTransformMakeScale(scale.doubleValue,scale.doubleValue);
  CGAffineTransform transform=root.transform;NSArray *active=glass.layer.filters;
  filterReady=NO;refreshOpenFolderHierarchy(root,YES);
  assert(glass.layer.filters==active&&glass.layer.filters.count==1);
  assert(!glass->_filterAttached); // bounded retry must remain eligible
  assert(CGAffineTransformEqualToTransform(root.transform,transform));
  filterReady=YES;refreshOpenFolderHierarchy(root,YES);
  assert(glass.layer.filters.count==1&&glass.layer.filters!=active);
 }
 NSUInteger before=installs;root.window=nil;refreshOpenFolderHierarchy(root,YES);assert(installs==before);
 root.window=[NSObject new];material.bounds=CGRectMake(0,0,60,60);
 refreshOpenFolderHierarchy(root,YES);assert(installs==before);
 material.bounds=CGRectMake(0,0,400,400);filterReady=NO;
 NSArray *active=glass.layer.filters;refreshOpenFolderHierarchy(root,NO);
 assert(glass.layer.filters==active); // regular layouts do not force a rebuild
 puts("PASS folder recovery keeps the active filter until replacement succeeds, preserves scaled ancestors, ignores detached/icon-size materials, and retains forced recovery");
}return 0;}
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--revision')
    args = parser.parse_args()
    folder = (subprocess.check_output(['git', 'show', args.revision + ':Hooks/Folder.x'],
                                     cwd=ROOT, text=True)
              if args.revision else (ROOT / 'Hooks/Folder.x').read_text())
    backdrop = (ROOT / 'Shared/LGLiveBackdropView.m').read_text()
    code = SUPPORT.replace('INVALIDATE_METHOD', function(backdrop, '- (void)lgInvalidateFilterContents {'))
    code += function(folder, 'static void refreshOpenFolderHierarchy(UIView *root, BOOL forceFilterRefresh) {')
    code += CHECKS
    code = code.replace('CATransaction', 'FixtureTransaction')
    with tempfile.TemporaryDirectory(prefix='liquidass-folder-recovery-') as tmp:
        source, binary = Path(tmp) / 'test.m', Path(tmp) / 'test'
        source.write_text(code)
        subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-framework', 'Foundation',
                        '-framework', 'CoreGraphics', str(source), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == '__main__':
    main()
