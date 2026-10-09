#!/usr/bin/env python3.11
"""Exercise the actual music palette lifecycle; this is not phone rendering proof."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SUPPORT = r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdio.h>
typedef NSInteger UIUserInterfaceStyle;
enum {UIUserInterfaceStyleUnspecified, UIUserInterfaceStyleLight, UIUserInterfaceStyleDark};
@interface UITraitCollection : NSObject
@property UIUserInterfaceStyle userInterfaceStyle;
+ (instancetype)traitCollectionWithUserInterfaceStyle:(UIUserInterfaceStyle)style;
@end
@implementation UITraitCollection
+ (instancetype)traitCollectionWithUserInterfaceStyle:(UIUserInterfaceStyle)style {
    UITraitCollection *t=[self new];t.userInterfaceStyle=style;return t;
}
@end
@interface UIColor : NSObject
@property(copy) NSString *name;
+ (instancetype)named:(NSString *)name;
+ (instancetype)labelColor;
+ (instancetype)secondaryLabelColor;
+ (instancetype)tertiaryLabelColor;
+ (instancetype)quaternaryLabelColor;
+ (instancetype)separatorColor;
- (instancetype)resolvedColorWithTraitCollection:(UITraitCollection *)traits;
@end
@implementation UIColor
+ (instancetype)named:(NSString *)name {UIColor *c=[self new];c.name=name;return c;}
+ (instancetype)labelColor{return [self named:@"primary"];}
+ (instancetype)secondaryLabelColor{return [self named:@"secondary"];}
+ (instancetype)tertiaryLabelColor{return [self named:@"tertiary"];}
+ (instancetype)quaternaryLabelColor{return [self named:@"quaternary"];}
+ (instancetype)separatorColor{return [self named:@"separator"];}
- (instancetype)resolvedColorWithTraitCollection:(UITraitCollection *)traits {
    return [UIColor named:[NSString stringWithFormat:@"%ld-%@",(long)traits.userInterfaceStyle,self.name]];
}
- (BOOL)isEqual:(id)obj{return [obj isKindOfClass:UIColor.class]&&[self.name isEqual:((UIColor *)obj).name];}
@end
@interface UIScreen : NSObject
@property(strong) UITraitCollection *traitCollection;
+ (instancetype)mainScreen;
@end
@implementation UIScreen
+ (instancetype)mainScreen{static UIScreen *s;if(!s){s=[self new];s.traitCollection=[UITraitCollection new];}return s;}
@end
@class UIWindow;
@interface UIView : NSObject
@property(strong) UIWindow *window;
@end
@implementation UIView @end
@interface UIWindow : UIView
@property(strong) UIScreen *screen;
@end
@implementation UIWindow @end
static BOOL enabled=YES;
static BOOL LGIslandContentEnabled(void){return enabled;}
static NSUInteger assignments, colorWrites;
#define CHECK(c,msg) do{if(!(c)){puts("FAIL " msg);return 1;}}while(0)
'''
MAIN = r'''
@implementation MRUVisualStylingProvider
@synthesize primaryColor=_primaryColor;
- (void)setPrimaryColor:(UIColor *)color{colorWrites++;_primaryColor=color;}
@end
@implementation MRUActivityNowPlayingView
@synthesize stylingProvider=_stylingProvider;
- (void)setStylingProvider:(MRUVisualStylingProvider *)provider {
    assignments++;_stylingProvider=provider;LGUpdateIslandMedia(self);
}
@end
int main(void){@autoreleasepool{
    UIWindow *window=[UIWindow new];window.screen=UIScreen.mainScreen;
    window.screen.traitCollection.userInterfaceStyle=1;
    MRUVisualStylingProvider *native=[MRUVisualStylingProvider new];
    native.primaryColor=[UIColor named:@"systemWhiteColor"];
    MRUActivityNowPlayingView *island=[MRUActivityNowPlayingView new];
    island.stylingProvider=native;
    CHECK(island.stylingProvider==native,"unattached content was recolored");
    island.window=window;LGUpdateIslandMedia(island);
    MRUVisualStylingProvider *light=island.stylingProvider;
    CHECK(light!=native && [light.primaryColor.name isEqual:@"1-primary"],"hard-coded white was not replaced");
    CHECK([light.secondaryColor.name isEqual:@"1-secondary"] && !light.supportsVibrancy,"secondary controls still use dark/vibrant palette");
    CHECK([native.primaryColor.name isEqual:@"systemWhiteColor"] && !native.secondaryColor,"native/shared provider mutated");
    NSUInteger baseline=assignments, writes=colorWrites;
    for(int i=0;i<1000;i++)LGUpdateIslandMedia(island);
    CHECK(assignments==baseline && colorWrites==writes,"stable layout repainted palette");
    // The native controller can set white after its initial provider assignment.
    light.primaryColor=[UIColor named:@"systemWhiteColor"];LGUpdateIslandMedia(island);
    CHECK([light.primaryColor.name isEqual:@"1-primary"],"late native white write survived layout");
    window.screen.traitCollection.userInterfaceStyle=2;LGRefreshIslandMedia(window);
    CHECK(island.stylingProvider==native,"dark mode lost original provider");
    window.screen.traitCollection.userInterfaceStyle=1;LGRefreshIslandMedia(window);
    CHECK(island.stylingProvider==light,"light mode did not reuse isolated palette");
    MRUVisualStylingProvider *replacement=[MRUVisualStylingProvider new];
    replacement.primaryColor=[UIColor named:@"replacement-native"];
    island.stylingProvider=replacement;
    CHECK(island.stylingProvider==light,"replacement dropped active light palette");
    enabled=NO;LGRefreshIslandMedia(nil);
    CHECK(island.stylingProvider==replacement,"disable restored stale native provider");
    enabled=YES;LGUpdateIslandMedia(island);
    island.window=nil;LGUpdateIslandMedia(island);
    CHECK(island.stylingProvider==replacement,"detach did not restore native provider");
    island.window=window;LGUpdateIslandMedia(island);
    island.stylingProvider=nil;
    CHECK(!island.stylingProvider,"nil native provider was resurrected");
    puts("PASS music-only isolated light palette, native-provider preservation, late white write, 1000 stable layouts, dark/disable/detach and replacement");
}return 0;}
'''


def main():
    text = (ROOT / "Hooks/DynamicIslandContent.x").read_text()
    core = text[text.index("@interface MRUVisualStylingProvider"):text.index("%group LGIslandMediaLifecycle")]
    with tempfile.TemporaryDirectory(prefix="liquidass-island-media-") as tmp:
        src = Path(tmp) / "test.m"
        exe = Path(tmp) / "test"
        src.write_text(SUPPORT + core + MAIN)
        subprocess.run(["xcrun", "clang", "-fobjc-arc", "-framework", "Foundation", str(src), "-o", str(exe)], check=True)
        subprocess.run([str(exe)], check=True)


if __name__ == "__main__":
    main()
