#!/usr/bin/env python3.11
"""Execute the production registration state machine with a delayed filter table."""
from pathlib import Path
import subprocess,tempfile
from test_clock_icon_ownership import function
ROOT=Path(__file__).resolve().parents[1]
SUPPORT=r'''
#import <Foundation/Foundation.h>
#include <unordered_map>
#include <unordered_set>
#include <string>
#include <sys/mman.h>
#include <string.h>
#include <assert.h>
#include <stdio.h>
#import "LGHostRegistry.h"
#define lglog(...) do {} while(0)
static bool g_filterRegistered,g_useHookPath,g_gaussianHooksInstalled,g_legacyRenderABI;
static int g_gaussianEdgeInfoSlot=-1,g_gaussianRenderSlot=-1;
static const size_t kVtableSlots=22;
static void *g_gaussCtxValue,*g_customCtx;
static void **g_customVtable;
using Render13Fn=void(*)();using EdgeInfoFn=void(*)();
static Render13Fn g_origGaussR13;static EdgeInfoFn g_origGaussEdgeInfo;
static void ourIdentityStub(){} static void ourCustomEdgeInfo(){} static void ourCustomRender13(){}
static void *LGSymStripData(void *p){return p;}
static void *LGSymStripCode(void *p){return p;}
static void *LGSymMakeCallable(void *p){return p;}
static bool LGSymAddressInQuartzCoreImage(void *p){return p!=nullptr;}
static void *tableValue,*gaussValue,*vtable[22];
static bool tableSymbol=true,gaussSymbol=true,hookSuccess=true;
static int edgeSlot=10,renderSlot=7,edgeScans,renderScans,hookCalls,registrations,prefsStarts,notifications;
static NSMutableArray *pending;
static void *LGResolve_FilterTableSlot(){return tableSymbol?&tableValue:nullptr;}
static void *LGResolve_GaussianCtxSlot(){return gaussSymbol?&gaussValue:nullptr;}
static int LGResolve_EdgeInfoVtableSlot(void *const *,int){edgeScans++;return g_gaussianHooksInstalled?-1:edgeSlot;}
static int LGResolve_RenderVtableSlot(void *const *,int){renderScans++;return g_gaussianHooksInstalled?-1:renderSlot;}
static bool lgInstallGaussianHooks(void *,void *,void *){hookCalls++;return hookSuccess;}
static void lgStartPrefsObserver(){prefsStarts++;}
static std::unordered_map<std::string,uint32_t> names;
static uint32_t internAtom(const char *name){auto p=names.emplace(name,(uint32_t)names.size()+1);return p.first->second;}
static void addFilter(uint32_t,void *){assert(tableValue);registrations++;}
static auto g_internAtom=&internAtom;
static auto g_addFilter=&addFilter;
static const char *kCustomFilterTypeName="dylv.liquidglass.refraction";
static void lgRegisterCustomAtom(uint32_t atom,void *descriptor){assert(atom&&descriptor&&tableValue);g_addFilter(atom,descriptor);}
static void lgRegisterSystemBlurVariants(void *descriptor){assert(descriptor&&tableValue);registrations++;}
static void fakeAfter(dispatch_time_t,dispatch_queue_t,dispatch_block_t block){[pending addObject:[block copy]];}
#define dispatch_after fakeAfter
#define CFNotificationCenterPostNotification(...) (++notifications)
'''
MAIN=r'''
static void reset(bool hookPath=true){
 if(g_customVtable)munmap(g_customVtable,kVtableSlots*sizeof(void*));
 if(g_customCtx)munmap(g_customCtx,256);
 g_customVtable=nullptr;g_customCtx=nullptr;
 g_filterRegistered=g_gaussianHooksInstalled=g_legacyRenderABI=false;g_useHookPath=hookPath;
 g_gaussianEdgeInfoSlot=g_gaussianRenderSlot=-1;
 tableValue=nullptr;for(int i=0;i<22;i++)vtable[i]=(void *)(uintptr_t)(0x1000+i*0x100);
 gaussValue=vtable;tableSymbol=gaussSymbol=hookSuccess=true;
 edgeSlot=10;renderSlot=7;edgeScans=renderScans=hookCalls=registrations=prefsStarts=notifications=0;
 g_internAtom=&internAtom;g_addFilter=&addFilter;names.clear();pending=[NSMutableArray new];
}
static void retry(){assert(pending.count==1);dispatch_block_t block=pending[0];[pending removeObjectAtIndex:0];block();}
int main(void){@autoreleasepool{
 reset();gaussValue=nullptr;
 assert(!registerCustomFilter() && !hookCalls && !registrations && pending.count==1);
 gaussValue=vtable;retry();
 assert(hookCalls==1 && g_gaussianHooksInstalled && !registrations && pending.count==1);
 assert(edgeScans==1&&renderScans==1);
 retry();retry(); // Simulated scanners reject patched functions; cached slots must avoid rescans.
 assert(hookCalls==1 && edgeScans==1&&renderScans==1 && !registrations);
 tableValue=(void *)1;retry();
 assert(g_filterRegistered && registrations>0 && prefsStarts==1 && notifications==1);
 int count=registrations;assert(registerCustomFilter() && registrations==count && hookCalls==1);
 reset(false);assert(!registerCustomFilter() && !hookCalls && pending.count==1);
 tableValue=(void *)1;retry();assert(g_filterRegistered && !hookCalls && g_customCtx && g_customVtable);
 reset();hookSuccess=false;assert(!registerCustomFilter() && hookCalls==1 && !registrations && !pending.count);
 reset();edgeSlot=22;assert(!registerCustomFilter() && !hookCalls && !registrations);
 reset();edgeSlot=renderSlot;assert(!registerCustomFilter() && !hookCalls && !registrations);
 reset();g_internAtom=nullptr;assert(!registerCustomFilter() && !hookCalls && !registrations);
 reset();tableSymbol=false;assert(!registerCustomFilter() && !hookCalls && !registrations);
 reset();gaussSymbol=false;assert(!registerCustomFilter() && !hookCalls && !registrations);
 reset();g_legacyRenderABI=true;renderSlot=-1;
 assert(!registerCustomFilter() && g_gaussianRenderSlot==7 && pending.count==1);
 tableValue=(void *)1;retry();assert(g_filterRegistered && hookCalls==1);
 reset();puts("PASS delayed Gaussian/table readiness, one-time hooks, no patched-code rescans, clone path, invalid/failure guards and legacy slot fallback");
}return 0;}
'''
def main():
 text=(ROOT/'LiquidAssBackboardd/Tweak.mm').read_text()
 a=text.index('typedef struct {\n    const char *typeName;');b=text.index('static NSDictionary *lgReadHostPreferences',a)
 source=SUPPORT+text[a:b]+function(text,'static bool registerCustomFilter(void) {')+MAIN
 assert 'lgClearAccessibilityFiles' not in text
 with tempfile.TemporaryDirectory(prefix='liquidass-register-') as td:
  src=Path(td)/'test.mm';exe=Path(td)/'test';src.write_text(source)
  subprocess.run(['xcrun','clang++','-std=c++17','-fobjc-arc','-I'+str(ROOT/'Shared'),'-framework','Foundation',str(src),'-o',str(exe)],check=True)
  subprocess.run([str(exe)],check=True)
if __name__=='__main__':main()
