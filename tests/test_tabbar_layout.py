#!/usr/bin/env python3.11
"""Run the production host callback against a bounded layout scheduler."""
from pathlib import Path
import re
import subprocess
import tempfile
from test_clock_icon_ownership import function

ROOT = Path(__file__).resolve().parents[1]
SUPPORT = r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <assert.h>
static BOOL pendingLayout, allowed=YES;
static NSUInteger nativeLayouts, styles, invalidations;
@interface UIView:NSObject
@property(strong) NSArray *subviews;
@property(weak) UIView *superview;
-(void)setNeedsLayout;
-(void)invalidateIntrinsicContentSize;
@end
@implementation UIView
-(void)setNeedsLayout{pendingLayout=YES;invalidations++;}
-(void)invalidateIntrinsicContentSize{pendingLayout=YES;invalidations++;}
@end
@interface UITabBar:UIView @end
@implementation UITabBar @end
@interface LGTestHost:NSObject
@property(strong) UIView *view;
-(void)viewDidLayoutSubviews;
@end
@implementation LGTestHost
-(void)viewDidLayoutSubviews{nativeLayouts++;}
@end
static BOOL LGTabBarAllowed(void){return allowed;}
static void LGStyleStockTabBar(UITabBar *bar){styles++;}
static NSMutableDictionary<NSString *, NSValue *> *g_tabBarHostOrigs;
'''
MAIN = r'''
int main(){@autoreleasepool{
 Class cls=objc_allocateClassPair(LGTestHost.class,"Sileo.TabBarController",0);
 objc_registerClassPair(cls);
 LGTestHost *host=[cls new];host.view=[UIView new];
 UITabBar *bar=[UITabBar new];bar.superview=host.view;host.view.subviews=@[bar];
 SEL selector=@selector(viewDidLayoutSubviews);
 g_tabBarHostOrigs=[@{@"Sileo.TabBarController":[NSValue valueWithPointer:
     class_getMethodImplementation(cls,selector)]} mutableCopy];
 pendingLayout=YES;
 for(NSUInteger pass=0;pendingLayout&&pass<8;pass++){
  pendingLayout=NO;LGHookedHostDidLayout(host,selector);
 }
 if(pendingLayout){fprintf(stderr,"FAIL: host layout requeues itself after 8 passes (%lu invalidations)\n",(unsigned long)invalidations);return 1;}
 assert(nativeLayouts==1&&styles==1&&invalidations==0);
 // A preference notification still invalidates once, then layout must settle.
 UIView *window=host.view;
 PREFERENCE_REFRESH
 assert(pendingLayout&&invalidations==3);
 pendingLayout=NO;LGHookedHostDidLayout(host,selector);
 assert(!pendingLayout&&nativeLayouts==2&&styles==3&&invalidations==3);
 allowed=NO;LGHookedHostDidLayout(host,selector);
 assert(nativeLayouts==3&&styles==3&&!pendingLayout);
 puts("PASS: Sileo host layout settles; preference refresh invalidates once; excluded host keeps native layout");
}return 0;}
'''


def main():
    source = (ROOT / 'Hooks/TabBar.x').read_text()
    refresh = function(source, 'static void LGRefreshTabBarsInView(')
    host = function(source, 'static void LGHookedHostDidLayout(')
    preference = re.search(r'LGRefreshTabBarsInView\(window[^;]*;', source).group()
    code = SUPPORT + refresh + '\n' + host + MAIN.replace('PREFERENCE_REFRESH', preference)
    with tempfile.TemporaryDirectory(prefix='liquidass-tabbar-layout-') as tmp:
        src, exe = Path(tmp) / 'test.m', Path(tmp) / 'test'
        src.write_text(code)
        subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-framework', 'Foundation',
                        str(src), '-o', str(exe)], check=True)
        subprocess.run([str(exe)], check=True)


if __name__ == '__main__':
    main()
