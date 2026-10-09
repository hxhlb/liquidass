#!/usr/bin/env python3.11
"""Exercise the production CFPreferences reader and cross-process diagnostic codec."""
from pathlib import Path
import subprocess
import tempfile
import uuid
from test_clock_icon_ownership import function

ROOT = Path(__file__).resolve().parents[1]
PRELUDE = r'''
#import <Foundation/Foundation.h>
#import <notify.h>
#include <assert.h>
static BOOL syncOK;
static id serviceValue;
static NSUInteger copies;
static Boolean fakeSynchronize(CFStringRef domain) {
    assert(CFEqual(domain,CFSTR("dylv.liquidassprefs")));return syncOK;
}
static CFDictionaryRef fakeCopy(CFArrayRef keys,CFStringRef domain,CFStringRef user,CFStringRef host) {
    assert(!keys && CFEqual(domain,CFSTR("dylv.liquidassprefs")));
    assert(CFEqual(user,kCFPreferencesCurrentUser) && CFEqual(host,kCFPreferencesAnyHost));
    copies++;return serviceValue?(CFDictionaryRef)CFRetain((__bridge CFTypeRef)serviceValue):NULL;
}
static uint64_t states[3];static int registrations;
static uint32_t fakeRegister(const char *name,int *token){*token=registrations++;return NOTIFY_STATUS_OK;}
static uint32_t fakeSet(int token,uint64_t state){states[token]=state;return NOTIFY_STATUS_OK;}
static uint32_t fakeGet(int token,uint64_t *state){*state=states[token];return NOTIFY_STATUS_OK;}
#define notify_register_check fakeRegister
#define notify_set_state fakeSet
#define notify_get_state fakeGet
#import "LGRendererDiagnostics.h"
#define CFPreferencesAppSynchronize fakeSynchronize
#define CFPreferencesCopyMultiple fakeCopy
static NSUInteger refreshes;
#define CATransaction LGPrefsTestTransaction
@interface LGLiveBackdropView : NSObject
- (void)reapplyFilterForParameterReload;
@end
@implementation LGLiveBackdropView
- (void)reapplyFilterForParameterReload { refreshes++; }
@end
@interface CATransaction : NSObject
+ (void)begin; + (void)commit; + (void)setDisableActions:(BOOL)disabled;
@end
@implementation CATransaction
+ (void)begin {} + (void)commit {} + (void)setDisableActions:(BOOL)disabled {}
@end
static NSHashTable *sLGAllGlasses;
static void LGInvalidateGlassPreferenceCache(void) {}
#define LGLog(...) do {} while(0)
static void fakeDispatch(dispatch_queue_t queue, dispatch_block_t block) { block(); }
#define dispatch_async fakeDispatch
'''
MAIN = r'''
int main(){@autoreleasepool{
    syncOK=YES;
    serviceValue=@{@"Renderer.Profile":@"enhanced",@"Enhanced.DynamicIsland.LightTintColor":@"#FF0000FF"};
    assert([lgReadHostPreferences() isEqual:serviceValue] && copies==1);
    syncOK=NO;assert(lgReadHostPreferences()==nil && copies==1);
    syncOK=YES;serviceValue=nil;assert(lgReadHostPreferences()==nil);
    serviceValue=@123;assert(lgReadHostPreferences()==nil);
    serviceValue=@{};assert(lgReadHostPreferences()!=nil && lgReadHostPreferences().count==0);
    uint32_t status,light,dark;assert(!LGRendererDiagRead(&status,&light,&dark));
    LGRendererDiagWrite(LGRendererDiagLight,7,LGRendererDiagRGBA(1,0,0,1));
    LGRendererDiagWrite(LGRendererDiagDark,7,LGRendererDiagRGBA(0,1,0,1));
    LGRendererDiagWrite(LGRendererDiagStatus,7,7|(27<<8));
    assert(LGRendererDiagRead(&status,&light,&dark));
    assert(status==(7|(27<<8)) && light==0xFF0000FF && dark==0x00FF00FF);
    LGRendererDiagWrite(LGRendererDiagStatus,8,0);assert(!LGRendererDiagRead(&status,&light,&dark));
    LGRendererDiagWrite(LGRendererDiagLight,8,0xFF0000FF);LGRendererDiagWrite(LGRendererDiagDark,8,0x00FF00FF);
    assert(LGRendererDiagRead(&status,&light,&dark) && !(status&1));
    sLGAllGlasses=[NSHashTable hashTableWithOptions:NSPointerFunctionsStrongMemory];[sLGAllGlasses addObject:[LGLiveBackdropView new]];
    LGParametersReloaded(NULL,NULL,NULL,NULL,NULL);assert(refreshes==0);
    LGRendererDiagWrite(LGRendererDiagStatus,8,7);
    LGParametersReloaded(NULL,NULL,NULL,NULL,NULL);assert(refreshes==1);
    assert(LGRendererDiagRGBA(0,0,0,0)==0 && LGRendererDiagRGBA(0,0,0,0.5)==128);
    puts("PASS common preference service/domain/user, sync/read/type failures, valid empty reset, RGBA and diagnostic generation consistency");
}return 0;}
'''


def main():
    source = (ROOT / 'LiquidAssBackboardd/Tweak.mm').read_text()
    reader = function(source, 'static NSDictionary *lgReadHostPreferences(')
    live = (ROOT / 'Shared/LGLiveBackdropView.m').read_text()
    callback = function(live, 'static void LGParametersReloaded(')
    assert 'LGRendererDiagRead' not in function(live, 'static void LGMotionPreferencesDidChange(')
    assert 'dictionaryWithContentsOfFile' not in reader and '__has_include' not in reader
    with tempfile.TemporaryDirectory(prefix='liquidass-prefs-reader-') as tmp:
        src = Path(tmp) / 'test.m'
        exe = Path(tmp) / 'test'
        src.write_text(PRELUDE + reader + callback + MAIN)
        subprocess.run(['xcrun','clang','-fobjc-arc','-I'+str(ROOT/'Shared'),'-framework','Foundation',str(src),'-o',str(exe)],check=True)
        subprocess.run([str(exe)],check=True)
        # Real Darwin state transport between separate processes, with an
        # isolated test namespace and the unchanged production codec.
        protocol = (ROOT / 'Shared/LGRendererDiagnostics.h').read_text().replace(
            'dylv.liquidglass/', 'iya.banana.test.' + uuid.uuid4().hex + '/')
        ipc = protocol + r'''
int main(int argc,char **argv){@autoreleasepool{
 if(argc>1){LGRendererDiagWrite(1,12,0xFF0000FF);LGRendererDiagWrite(2,12,0x00FF00FF);
 LGRendererDiagWrite(0,12,7|(27<<8));puts("ready");fflush(stdout);getchar();}
 else {uint32_t s,l,d;assert(LGRendererDiagRead(&s,&l,&d));
 assert(s==(7|(27<<8)) && l==0xFF0000FF && d==0x00FF00FF);puts("PASS real cross-process Darwin renderer diagnostics");}
}return 0;}
'''
        src.write_text('#include <assert.h>\n#include <stdio.h>\n' + ipc)
        subprocess.run(['xcrun','clang','-fobjc-arc','-framework','Foundation',str(src),'-o',str(exe)],check=True)
        writer = subprocess.Popen([str(exe),'writer'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
        try:
            assert writer.stdout.readline().strip() == 'ready'
            subprocess.run([str(exe)],check=True)
        finally:
            writer.communicate('\n',timeout=5)


if __name__ == '__main__':
    main()
