#!/usr/bin/env python3.11
"""Build a real-UIKit simulator probe from production drawing code; never boots,
erases, installs, or launches a simulator. The caller chooses the test device.
"""
from pathlib import Path
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PRELUDE = r'''
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <notify.h>
#import <math.h>
#import <stdint.h>
#import <stdatomic.h>
#import <stdlib.h>
#import <string.h>
static BOOL LGIsSpringBoardProcess(void) { return NO; }
@interface SBSystemApertureContainerView : UIView @end
@implementation SBSystemApertureContainerView @end
'''
HARNESS = r'''
static IMP originals[4];
static void draw0(id self,SEL cmd,CGRect r){LGDrawIslandText(self,r,^{((void(*)(id,SEL,CGRect))originals[0])(self,cmd,r);});}
static void draw1(id self,SEL cmd,CGRect r){LGDrawIslandText(self,r,^{((void(*)(id,SEL,CGRect))originals[1])(self,cmd,r);});}
static CGRect draw2(id self,SEL cmd,CGRect r){__block CGRect x=CGRectZero;LGDrawIslandText(self,r,^{x=((CGRect(*)(id,SEL,CGRect))originals[2])(self,cmd,r);});return x;}
static CGRect draw3(id self,SEL cmd,CGRect r){__block CGRect x=CGRectZero;LGDrawIslandText(self,r,^{x=((CGRect(*)(id,SEL,CGRect))originals[3])(self,cmd,r);});return x;}
static void draw3void(id self,SEL cmd,CGRect r){LGDrawIslandText(self,r,^{((void(*)(id,SEL,CGRect))originals[3])(self,cmd,r);});}
static NSDictionary *install(void){
    NSMutableDictionary *types=[NSMutableDictionary new];
    const char *names[]={"drawTextInRect:","drawContentsInRect:","_drawTextInRect:","_drawFullMarqueeTextInRect:"};
    IMP replacements[]={(IMP)draw0,(IMP)draw1,(IMP)draw2,(IMP)draw3};
    for(int i=0;i<4;i++){
        SEL sel=sel_registerName(names[i]);Method m=class_getInstanceMethod(UILabel.class,sel);
        if(!m)continue;char *ret=method_copyReturnType(m);
        types[@(names[i])]=@(method_getTypeEncoding(m));
        if(strcmp(ret,i<2?@encode(void):@encode(CGRect))==0){originals[i]=method_getImplementation(m);method_setImplementation(m,replacements[i]);}
        else if(i==3&&strcmp(ret,@encode(void))==0){originals[i]=method_getImplementation(m);method_setImplementation(m,(IMP)draw3void);}
        free(ret);
    }
    return types;
}
static UIImage *capture(UILabel *label,CGRect rect){
    UIGraphicsImageRendererFormat *f=[UIGraphicsImageRendererFormat defaultFormat];f.opaque=NO;f.scale=label.contentScaleFactor;f.preferredRange=UIGraphicsImageRendererFormatRangeStandard;
    UIGraphicsImageRenderer *r=[[UIGraphicsImageRenderer alloc]initWithSize:CGSizeMake(320,70) format:f];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *c){[label drawTextInRect:rect];}];
}
static NSDictionary *pixels(UIImage *image){
    CGImageRef im=image.CGImage;size_t w=CGImageGetWidth(im),h=CGImageGetHeight(im);
    uint8_t *data=calloc(w*h,4);CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB();
    CGContextRef c=CGBitmapContextCreate(data,w,h,8,w*4,cs,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
    CGContextDrawImage(c,CGRectMake(0,0,w,h),im);NSUInteger count=0,black=0,white=0,partial=0;
    for(size_t i=0;i<w*h;i++){unsigned a=data[4*i+3];if(a<32)continue;count++;
        if(data[4*i]<3&&data[4*i+1]<3&&data[4*i+2]<3)black++;
        if(abs((int)data[4*i]-(int)a)<3&&abs((int)data[4*i+1]-(int)a)<3&&abs((int)data[4*i+2]-(int)a)<3)white++;
        if(a<240)partial++;
    }
    CGContextRelease(c);CGColorSpaceRelease(cs);free(data);
    return @{ @"pixels":@(count),@"black":@(black),@"white":@(white),@"partialAlpha":@(partial)};
}
@interface ProbeDelegate : UIResponder<UIApplicationDelegate>
@property(strong,nonatomic) UIWindow *window;
@end
@implementation ProbeDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options{
    NSDictionary *types=install();sLGIslandTextLabels=[NSHashTable weakObjectsHashTable];
    self.window=[[UIWindow alloc]initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *vc=[UIViewController new];vc.view.backgroundColor=UIColor.systemBackgroundColor;
    self.window.rootViewController=vc;[self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_main_queue(),^{
        UIView *island=[[SBSystemApertureContainerView alloc]initWithFrame:CGRectMake(0,0,320,70)];[vc.view addSubview:island];
        UIView *ordinary=[[UIView alloc]initWithFrame:CGRectMake(0,0,320,70)];[vc.view addSubview:ordinary];
        NSString *dir=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
        NSMutableDictionary *report=[@{@"os":UIDevice.currentDevice.systemVersion,@"methodTypes":types} mutableCopy];
        NSArray *names=@[@"light-plain",@"light-attributed",@"dark-plain",@"disabled",@"ordinary",@"light-offset",@"light-offscreen"];
        UIView *offscreen=[SBSystemApertureContainerView new];
        BOOL pass=YES;UIScrollView *results=[[UIScrollView alloc]initWithFrame:vc.view.bounds];results.backgroundColor=UIColor.systemBackgroundColor;
        [vc.view addSubview:results];
        for(NSUInteger i=0;i<names.count;i++){
            UILabel *l=[[UILabel alloc]initWithFrame:CGRectMake(0,0,320,70)];l.font=[UIFont systemFontOfSize:28 weight:UIFontWeightSemibold];l.contentScaleFactor=1;
            l.text=@"Music / 01:23";l.textColor=i==2?UIColor.blackColor:UIColor.whiteColor;
            if(i==1)l.attributedText=[[NSAttributedString alloc]initWithString:@"Recording 01:23" attributes:@{NSFontAttributeName:l.font,NSForegroundColorAttributeName:[UIColor.whiteColor colorWithAlphaComponent:0.6]}];
            [i==4?ordinary:(i==6?offscreen:island) addSubview:l];[l layoutIfNeeded];
            UIColor *originalColor=l.textColor;NSAttributedString *originalText=l.attributedText;
            sLGIslandTextState=LGIslandTextEncode(i==2?2:1,i!=3);
            CGRect rect=i==5?CGRectMake(13,9,290,50):CGRectMake(0,0,320,70);
            UIImage *image=capture(l,rect);NSDictionary *stats=pixels(image);
            BOOL black=i==0||i==1||i==5||i==6;NSUInteger count=[stats[@"pixels"] unsignedIntegerValue];
            BOOL ok=count>100&&[stats[black?@"black":@"white"] unsignedIntegerValue]==count&&l.textColor==originalColor&&l.attributedText==originalText;
            if(i==1)ok=ok&&[stats[@"partialAlpha"] unsignedIntegerValue]>100;
            NSMutableDictionary *entry=[stats mutableCopy];entry[@"pass"]=@(ok);report[names[i]]=entry;pass=pass&&ok;
            [UIImagePNGRepresentation(image)writeToFile:[dir stringByAppendingPathComponent:[names[i]stringByAppendingString:@".png"]] atomically:YES];
            UILabel *title=[[UILabel alloc]initWithFrame:CGRectMake(16,90+i*104,350,25)];title.text=[NSString stringWithFormat:@"%@ %@",ok?@"PASS":@"FAIL",names[i]];title.textColor=UIColor.labelColor;[results addSubview:title];
            UIImageView *iv=[[UIImageView alloc]initWithFrame:CGRectMake(16,115+i*104,320,70)];iv.image=image;iv.backgroundColor=black?UIColor.whiteColor:UIColor.blackColor;[results addSubview:iv];
        }
        results.contentSize=CGSizeMake(360,850);report[@"pass"]=@(pass);
        NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
        [json writeToFile:[dir stringByAppendingPathComponent:@"results.json"] atomically:YES];
        UILabel *ipcLabel=[[UILabel alloc]initWithFrame:CGRectMake(0,0,320,70)];
        ipcLabel.text=@"Music / Recording";ipcLabel.textColor=UIColor.whiteColor;
        ipcLabel.font=[UIFont systemFontOfSize:28 weight:UIFontWeightSemibold];[island addSubview:ipcLabel];[ipcLabel layoutIfNeeded];
        notify_register_dispatch(kLGIslandTextNotification,&sLGIslandTextToken,dispatch_get_main_queue(),^(int token){
            uint64_t state=0;notify_get_state(token,&state);sLGIslandTextState=state;LGInvalidateIslandText();
            NSDictionary *stats=pixels(capture(ipcLabel,CGRectMake(0,0,320,70)));
            NSData *data=[NSJSONSerialization dataWithJSONObject:stats options:NSJSONWritingPrettyPrinted error:nil];
            NSString *name=[NSString stringWithFormat:@"ipc-%llx.json",(unsigned long long)state];
            [data writeToFile:[dir stringByAppendingPathComponent:name] atomically:YES];
        });
    });return YES;
}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(ProbeDelegate.class));}}
'''


def main():
    source = (ROOT / "Hooks/DynamicIslandContent.x").read_text()
    core = source[source.index("static const char *kLGIslandTextNotification"):source.index("@interface UILabel (LGIslandPrivateDrawing)")]
    out = ROOT / "packages/island-text-probe"
    app = out / "IslandTextProbe.app"
    app.mkdir(parents=True, exist_ok=True)
    (out / "main.m").write_text(PRELUDE + core + HARNESS)
    (app / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "iya.banana.IslandTextProbe", "CFBundleExecutable": "IslandTextProbe",
        "CFBundleName": "Island Text Probe", "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
        "CFBundleShortVersionString": "1.0", "MinimumOSVersion": "17.0", "UIDeviceFamily": [1], "UILaunchScreen": {}}))
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
    subprocess.run(["xcrun", "--sdk", "iphonesimulator", "clang", "-fobjc-arc", "-target", "arm64-apple-ios17.0-simulator",
                    "-isysroot", sdk, "-framework", "UIKit", "-framework", "Foundation", "-framework", "CoreGraphics", str(out / "main.m"), "-o", str(app / "IslandTextProbe")], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
    writer = out / "notify_writer.c"
    writer.write_text(r'''
#include <notify.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
int main(int argc,char **argv) {
    if(argc!=2)return 2;
    int token=-1;
    if(notify_register_check("dylv.liquidass/island-text-appearance",&token)!=NOTIFY_STATUS_OK)return 3;
    uint64_t state=strtoull(argv[1],NULL,16);
    if(notify_set_state(token,state)!=NOTIFY_STATUS_OK)return 4;
    if(notify_post("dylv.liquidass/island-text-appearance")!=NOTIFY_STATUS_OK)return 5;
    notify_cancel(token);puts("Published");return 0;
}
''')
    subprocess.run(["xcrun", "--sdk", "iphonesimulator", "clang", "-target", "arm64-apple-ios17.0-simulator",
                    "-isysroot", sdk, str(writer), "-o", str(out / "notify-writer")], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", str(out / "notify-writer")], check=True)
    print(app)


if __name__ == "__main__":
    main()
