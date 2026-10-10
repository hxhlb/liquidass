#!/usr/bin/env python3.11
"""Execute the production bounded retry methods with a deterministic queue."""
from pathlib import Path
import subprocess
import tempfile
from test_clock_icon_ownership import function
ROOT=Path(__file__).resolve().parents[1]
SUPPORT=r'''
#import <Foundation/Foundation.h>
#import "LGHostRegistry.h"
#include <assert.h>
static NSMutableArray *pending;
static BOOL globalEnabled=YES, hostEnabled=YES, succeed;
static BOOL LG_globalEnabled(void){return globalEnabled;}
static id LGGlassPreferenceValue(NSString *key){return @(hostEnabled);}
static void fakeAfter(dispatch_time_t time,dispatch_queue_t queue,dispatch_block_t block){[pending addObject:[block copy]];}
#define dispatch_after fakeAfter
@interface LGLiveBackdropView:NSObject {
@public
 BOOL _filterAttached,_filterRetryScheduled;
 NSUInteger _filterRetryGeneration,_filterRetryAttempts,applies;
 NSString *_lgFilterType;
}
@property(strong) id window;
-(void)applyFilters;-(void)updateSpecular;-(void)lgScheduleFilterRetry;-(void)lgCancelFilterRetry;
@end
@implementation LGLiveBackdropView
-(id)init{if((self=[super init])){_lgFilterType=@"dylv.liquidglass.island";_window=[NSObject new];}return self;}
-(void)applyFilters{applies++;if(succeed){_filterAttached=YES;[self lgCancelFilterRetry];}else [self lgScheduleFilterRetry];}
-(void)updateSpecular{}
'''
CHECKS=r'''
@end
static void next(){dispatch_block_t b=pending.firstObject;[pending removeObjectAtIndex:0];b();}
int main(){@autoreleasepool{
 pending=[NSMutableArray new];LGLiveBackdropView *v=[LGLiveBackdropView new];
 [v applyFilters];for(int i=0;i<100;i++)[v lgScheduleFilterRetry];assert(pending.count==1);
 while(pending.count)next();assert(v->applies==6 && v->_filterRetryAttempts==5);
 [v lgScheduleFilterRetry];assert(!pending.count);
 [v lgCancelFilterRetry];[v applyFilters];hostEnabled=NO;NSUInteger before=v->applies;next();assert(v->applies==before&&!pending.count);
 hostEnabled=YES;[v lgCancelFilterRetry];[v applyFilters];globalEnabled=NO;next();assert(v->applies==before+1&&!pending.count);
 globalEnabled=YES;[v lgCancelFilterRetry];[v applyFilters];v.window=nil;[v lgCancelFilterRetry];before=v->applies;next();assert(v->applies==before);
 v.window=[NSObject new];[v applyFilters];[v lgCancelFilterRetry];[v applyFilters];before=v->applies;
 next();assert(v->applies==before&&v->_filterRetryScheduled);succeed=YES;next();assert(v->_filterAttached&&!pending.count);
 [v lgScheduleFilterRetry];assert(!pending.count);
 succeed=NO;__weak LGLiveBackdropView *weak;
 @autoreleasepool{LGLiveBackdropView *temporary=[LGLiveBackdropView new];weak=temporary;[temporary applyFilters];}
 assert(!weak);next();assert(!pending.count);
 puts("PASS five-retry limit, duplicate suppression, disable/detach/generation cancellation, successful recovery and weak lifetime");
}return 0;}
'''
def main():
 s=(ROOT/'Shared/LGLiveBackdropView.m').read_text()
 code=SUPPORT+function(s,'- (void)lgCancelFilterRetry {')+function(s,'- (void)lgScheduleFilterRetry {')+CHECKS
 with tempfile.TemporaryDirectory(prefix='liquidass-filter-retry-') as d:
  src=Path(d)/'test.m';exe=Path(d)/'test';src.write_text(code)
  subprocess.run(['xcrun','clang','-fobjc-arc','-I'+str(ROOT/'Shared'),'-framework','Foundation',str(src),'-o',str(exe)],check=True)
  subprocess.run([str(exe)],check=True)
if __name__=='__main__':main()
