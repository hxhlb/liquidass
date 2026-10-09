#!/usr/bin/env python3.11
"""Exercise host-to-remote appearance using the production scene adapter."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SUPPORT = r'''
#import <Foundation/Foundation.h>
#include <stdio.h>
enum {UIUserInterfaceStyleUnspecified, UIUserInterfaceStyleLight, UIUserInterfaceStyleDark};
static BOOL springboard=YES, enabled=YES;
static NSUInteger reads, writes;
@interface UITraitCollection : NSObject
@property NSInteger userInterfaceStyle;
@end
@implementation UITraitCollection @end
@interface UIScreen : NSObject
@property(strong) UITraitCollection *traitCollection;
+ (instancetype)mainScreen;
@end
@implementation UIScreen
+ (instancetype)mainScreen {
    reads++;
    if(!springboard)[NSException raise:@"DaemonUIAccess" format:@"UIScreen used outside the host"];
    static UIScreen *s;if(!s){s=[self new];s.traitCollection=[UITraitCollection new];}return s;
}
@end
static BOOL LGIsSpringBoardProcess(void){return springboard;}
static BOOL LGIslandContentEnabled(void){return enabled;}
@interface SceneSettings : NSObject
@property(nonatomic) NSInteger userInterfaceStyle;
@end
@implementation SceneSettings
@synthesize userInterfaceStyle=_userInterfaceStyle;
- (void)setUserInterfaceStyle:(NSInteger)style {writes++;_userInterfaceStyle=style;}
@end
@interface Scene : NSObject
@property(strong) SceneSettings *settings;
- (void)updateSettingsWithBlock:(void(^)(id))block;
@end
@implementation Scene
- (void)updateSettingsWithBlock:(void(^)(id))block {block(self.settings);}
@end
@interface Element : NSObject
@property(strong) Scene *scene;
@end
@implementation Element @end
#define CHECK(c,msg) do{if(!(c)){puts("FAIL " msg);return 1;}}while(0)
'''
MAIN = r'''
int main(void){@autoreleasepool {
    UIScreen.mainScreen.traitCollection.userInterfaceStyle=1;
    Element *e=[Element new];e.scene=[Scene new];e.scene.settings=[SceneSettings new];
    e.scene.settings.userInterfaceStyle=2;
    Scene *ordinary=[Scene new];ordinary.settings=[SceneSettings new];ordinary.settings.userInterfaceStyle=2;
    CHECK(e.scene.settings.userInterfaceStyle!=UIScreen.mainScreen.traitCollection.userInterfaceStyle,
          "fixture did not reproduce live host Light / remote Dark mismatch");
    LGApplyIslandHostedAppearance(e,e.scene.settings);
    CHECK(e.scene.settings.userInterfaceStyle==1,"remote activity retained forced Dark");
    NSUInteger baseline=writes;
    for(int i=0;i<1000;i++){
        LGApplyIslandHostedAppearance(e,e.scene.settings);LGRefreshIslandHostedScenes();
    }
    CHECK(writes==baseline,"stable settings generated scene updates");
    UIScreen.mainScreen.traitCollection.userInterfaceStyle=2;LGRefreshIslandHostedScenes();
    CHECK(e.scene.settings.userInterfaceStyle==2,"host Dark did not reach remote scene");
    UIScreen.mainScreen.traitCollection.userInterfaceStyle=1;LGRefreshIslandHostedScenes();
    CHECK(e.scene.settings.userInterfaceStyle==1,"host Light did not reach remote scene");
    e.scene.settings.userInterfaceStyle=2;LGApplyIslandHostedAppearance(e,e.scene.settings);
    CHECK(e.scene.settings.userInterfaceStyle==1,"native forced-Dark update bypassed adapter");
    CHECK(ordinary.settings.userInterfaceStyle==2,"ordinary app scene modified");
    enabled=NO;LGRefreshIslandHostedScenes();
    CHECK(e.scene.settings.userInterfaceStyle==2 && !sLGIslandHostedScenes.count,"disable did not restore native scene style");
    enabled=YES;LGApplyIslandHostedAppearance(e,e.scene.settings);
    enabled=NO;LGApplyIslandHostedAppearance(e,e.scene.settings);
    CHECK(e.scene.settings.userInterfaceStyle==2,"disabled native callback failed restoration");
    enabled=YES;LGApplyIslandHostedAppearance(e,e.scene.settings);
    NSUInteger before=reads;springboard=NO;LGRefreshIslandHostedScenes();
    CHECK(reads==before,"non-host callback read UIScreen");
    springboard=YES;enabled=NO;LGRefreshIslandHostedScenes();
    before=reads;LGRefreshIslandHostedScenes();
    CHECK(reads==before,"empty registry unnecessarily initialized UIScreen");
    puts("PASS actual host-Light/remote-Dark regression, theme propagation, 1000 stable callbacks, native restoration and non-host UI exclusion");
}return 0;}
'''


def main():
    text = (ROOT / "Hooks/DynamicIslandContent.x").read_text()
    core = text[text.index("@interface NSObject (LGIslandHostedScene)"):text.index("%group LGIslandHostedAppearanceLifecycle")]
    with tempfile.TemporaryDirectory(prefix="liquidass-island-host-") as tmp:
        src = Path(tmp) / "test.m"
        exe = Path(tmp) / "test"
        src.write_text(SUPPORT + core + MAIN)
        subprocess.run(["xcrun", "clang", "-fobjc-arc", "-framework", "Foundation", str(src), "-o", str(exe)], check=True)
        subprocess.run([str(exe)], check=True)


if __name__ == "__main__":
    main()
