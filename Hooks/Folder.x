#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import <objc/runtime.h>

static BOOL isFolderIconMaterial(UIView *mat) {
    static Class folderCls, iconCls;
    if (!folderCls) folderCls = NSClassFromString(@"SBFolderIconImageView");
    if (!iconCls)   iconCls   = NSClassFromString(@"SBIconView");
    for (UIView *v = mat.superview; v; v = v.superview) {
        if ([v isKindOfClass:folderCls]) return YES;
        if ([v isKindOfClass:iconCls])   break;
    }
    return NO;
}

static BOOL isOpenFolderMaterial(UIView *mat) {
    if (!hasAncestorOfClassName(mat, @"SBFolderBackgroundView")) return NO;
    CGRect b = mat.bounds;
    return CGRectGetWidth(b) >= 200.0 && CGRectGetHeight(b) >= 200.0;
}

#pragma mark - folder-open coordination

static NSHashTable<UIView *> *sFolderIconGlasses;
static NSHashTable<UIView *> *sFolderIconMaterials;
static NSHashTable<UIView *> *sOpenFolderMaterials;

static void refreshOpenFolderHierarchy(UIView *root, BOOL forceFilterRefresh);

CGFloat LGFolderIconCornerRadiusFallback(void) {
    // app icon glass borrows this when its image view exposes no radius
    for (UIView *glass in sFolderIconGlasses.allObjects) {
        CGFloat radius = glass.layer.cornerRadius;
        if (isfinite(radius) && radius > 0.0) return radius;
    }
    for (UIView *material in sFolderIconMaterials.allObjects) {
        CGFloat radius = material.layer.cornerRadius;
        if (isfinite(radius) && radius > 0.0) return radius;
    }
    return 0.0;
}

static BOOL anyOpenFolderActive(void) {
    for (UIView *m in sOpenFolderMaterials.allObjects)
        if (m.window) return YES;
    return NO;
}

static void hideFolderIconGlasses(void) {
    // open folder and folder icon captures cannot overlap cleanly
    for (UIView *g in sFolderIconGlasses.allObjects) {
        [g.layer removeAllAnimations];
        g.alpha  = 1.0;
        g.hidden = YES;
    }
}

static void fadeInFolderIconGlasses(void) {
    for (UIView *g in sFolderIconGlasses.allObjects) {
        g.hidden = NO;
        g.alpha  = 0.0;
        [UIView animateWithDuration:0.2 delay:0.0
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{ g.alpha = 1.0; }
                         completion:nil];
    }
}

#pragma mark - inject

static void injectFolderIcon(UIView *mat) {
    if (!sFolderIconMaterials) sFolderIconMaterials = [NSHashTable weakObjectsHashTable];
    [sFolderIconMaterials addObject:mat];

    UIView *g = LGInstallRegisteredGlassInMaterial(mat, kGlassKey, @"FolderIcon",
                                                    UIEdgeInsetsZero, -1.0, nil);
    if (!g) return;
    if (!sFolderIconGlasses) sFolderIconGlasses = [NSHashTable weakObjectsHashTable];
    [sFolderIconGlasses addObject:g];
    g.hidden = anyOpenFolderActive();
}

static void injectOpenFolder(UIView *mat) {
    LGLiveBackdropView *glass = LGInstallRegisteredGlassInMaterial(
        mat, kGlassKey, @"OpenFolder", UIEdgeInsetsZero, -1.0, nil);
    if (!glass) {
        [sOpenFolderMaterials removeObject:mat];
        if (!anyOpenFolderActive()) fadeInFolderIconGlasses();
        return;
    }

    UIView *parent = mat.superview;
    if (parent && glass.superview == parent) {
        NSUInteger materialIndex = [parent.subviews indexOfObjectIdenticalTo:mat];
        NSUInteger glassIndex = [parent.subviews indexOfObjectIdenticalTo:glass];
        if (materialIndex != NSNotFound &&
            (glassIndex == NSNotFound || glassIndex <= materialIndex)) {
            [parent insertSubview:glass aboveSubview:mat];
        }
    }
    [glass applyFilters];
    [glass.layer setNeedsDisplay];

    if (!sOpenFolderMaterials) sOpenFolderMaterials = [NSHashTable weakObjectsHashTable];
    if (![sOpenFolderMaterials containsObject:mat]) {
        [sOpenFolderMaterials addObject:mat];
        hideFolderIconGlasses();
    }
}

static void refreshOpenFolderHierarchy(UIView *root, BOOL forceFilterRefresh) {
    if (!root.window) return;

    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:root];
    while (pending.count) {
        UIView *view = pending.lastObject;
        [pending removeLastObject];
        if (view.subviews.count) [pending addObjectsFromArray:view.subviews];
        if (!isExactClass(view, @"MTMaterialView") || !isOpenFolderMaterial(view)) continue;

        injectOpenFolder(view);
        if (!forceFilterRefresh) continue;

        LGLiveBackdropView *glass = objc_getAssociatedObject(view, kGlassKey);
        if (!glass) continue;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        glass.layer.filters = nil;
        [glass applyFilters];
        [glass.layer setNeedsDisplay];
        [CATransaction commit];
    }
}

static void scheduleOpenFolderRefreshes(UIView *background) {
    __weak UIView *weakBackground = background;
    for (NSNumber *delay in @[@0.0, @0.16, @0.38, @0.72]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIView *strongBackground = weakBackground;
            if (!strongBackground.window) return;
            refreshOpenFolderHierarchy(strongBackground, delay.doubleValue > 0.0);
        });
    }
}

%hook MTMaterialView
- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    if (!self_.window) {
        [sFolderIconMaterials removeObject:self_];

        if ([sOpenFolderMaterials containsObject:self_]) {
            [sOpenFolderMaterials removeObject:self_];
            if (!anyOpenFolderActive()) fadeInFolderIconGlasses();
        }
        return;
    }
    if (isFolderIconMaterial(self_))      injectFolderIcon(self_);
    else if (isOpenFolderMaterial(self_)) injectOpenFolder(self_);
}
- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;
    if (isFolderIconMaterial(self_))      injectFolderIcon(self_);
    else if (isOpenFolderMaterial(self_)) injectOpenFolder(self_);
}
%end

%hook SBFolderBackgroundView

- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    if (self_.window) scheduleOpenFolderRefreshes(self_);
}

- (void)layoutSubviews {
    %orig;
    refreshOpenFolderHierarchy((UIView *)self, NO);
}

%end
