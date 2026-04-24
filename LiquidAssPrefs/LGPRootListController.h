#if LIQUIDASS_STANDALONE_UI
#import <UIKit/UIKit.h>
#else
#import <Preferences/PSListController.h>
#endif

#if LIQUIDASS_STANDALONE_UI
@interface LGPRootListController : UIViewController
#else
@interface LGPRootListController : PSListController
#endif

- (void)openHomescreen;
- (void)openLockscreen;
- (void)openAppLibrary;
- (void)openMoreOptions;

@end
