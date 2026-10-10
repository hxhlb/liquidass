#!/usr/bin/env python3.11
"""Exercise the production RWB background hook before/after window attachment."""
from pathlib import Path
import subprocess
import tempfile
from test_widget_host import function

ROOT = Path(__file__).resolve().parents[1]
SUPPORT = r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "LGWidgetCompatibility.h"
#include <stdio.h>
static BOOL kIsEnabled=YES, kExcludePhotos=NO;
static void *kRWBOriginalBackgroundColorKey=&kRWBOriginalBackgroundColorKey;
@interface UIColor:NSObject
+(id)clearColor;
@end
@implementation UIColor
+(id)clearColor{return @"clear";}
@end
@interface Widget:NSObject
@property(copy) NSString *extensionBundleIdentifier;
@end
@implementation Widget @end
@interface Scene:NSObject
@property(strong) Widget *widget;
@end
@implementation Scene @end
@interface UIWindow:NSObject
@property(strong) Scene *windowScene;
@end
@implementation UIWindow @end
@interface UIView:NSObject
@property(strong) id backgroundColor;
@property(strong) UIWindow *window;
-(void)layoutSubviews;
@end
#define CHECK(c,msg) do{if(!(c)){puts("FAIL " msg);return 1;}}while(0)
'''
CHECKS = r'''
@interface FakeUIHostingView:UIView @end
@implementation FakeUIHostingView @end
int main(){@autoreleasepool{
 for(id color in @[@"white",@"black",NSNull.null]){
  UIView *view=[UIView new];view.backgroundColor=color==NSNull.null?nil:color;
  kIsEnabled=YES;kExcludePhotos=NO;[view layoutSubviews];
  CHECK([view.backgroundColor isEqual:@"clear"], "exclusion off must clear unattached backgrounds as banana33 did");
  [view layoutSubviews];kIsEnabled=NO;[view layoutSubviews];
  CHECK(color==NSNull.null ? !view.backgroundColor : [view.backgroundColor isEqual:color], "disable failed to restore original background");
 }
 UIView *view=[UIView new];view.backgroundColor=@"white";
 kIsEnabled=YES;kExcludePhotos=YES;[view layoutSubviews];
 CHECK([view.backgroundColor isEqual:@"white"], "exclusion on must protect an unidentified unattached view");
 UIWindow *window=[UIWindow new];Scene *scene=[Scene new];Widget *widget=[Widget new];
 scene.widget=widget;window.windowScene=scene;view.window=window;
 widget.extensionBundleIdentifier=@"com.apple.mobileslideshow.PhotosReliveWidget";
 [view layoutSubviews];CHECK([view.backgroundColor isEqual:@"white"], "attached Photos background lost");
 widget.extensionBundleIdentifier=@"com.example.weather.widget";
 [view layoutSubviews];CHECK([view.backgroundColor isEqual:@"clear"], "ordinary attached background retained");
 kIsEnabled=NO;[view layoutSubviews];CHECK([view.backgroundColor isEqual:@"white"], "ordinary attached restore failed");
 FakeUIHostingView *hosting=[FakeUIHostingView new];hosting.backgroundColor=@"white";
 kIsEnabled=YES;kExcludePhotos=NO;[hosting layoutSubviews];
 CHECK([hosting.backgroundColor isEqual:@"white"], "existing UIHostingView exemption changed");
 puts("PASS: default-off clears unattached white/black backgrounds; Photos-on protection and original-state restoration preserved");
}return 0;}
'''


def main():
    source = (ROOT / 'LiquidAssRWB/Tweak.x').read_text()
    hook = function(source[source.index('%hook UIView'):], '- (void)layoutSubviews {')
    code = SUPPORT + function(source, 'static BOOL RWBWindowPreservesPhotoContent(')
    code += '\n@implementation UIView\n' + hook.replace('%orig;', '') + '\n@end\n' + CHECKS
    with tempfile.TemporaryDirectory(prefix='liquidass-widget-window-') as tmp:
        src, exe = Path(tmp) / 'test.m', Path(tmp) / 'test'
        src.write_text(code)
        subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-framework', 'Foundation',
                        '-I' + str(ROOT / 'Shared'), str(src), '-o', str(exe)], check=True)
        subprocess.run([str(exe)], check=True)


if __name__ == '__main__':
    main()
