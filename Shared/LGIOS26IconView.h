#pragma once

#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, LGIOS26IconMode) {
    LGIOS26IconModeClear = 0,
    LGIOS26IconModeTinted = 1,
};

typedef NS_ENUM(NSInteger, LGIOS26IconAlgorithm) {
    LGIOS26IconAlgorithmAppleMitigated = 0,
    LGIOS26IconAlgorithmLegacy = 1,
};

UIImage *LGIOS26ProcessedIconImage(UIImage *image, LGIOS26IconMode mode);
UIImage *LGIOS26AppleMitigatedIconImage(UIImage *image,
                                       BOOL darkAppearance,
                                       BOOL preservesSubjectColor);
UIImage *LGIOS26GrayscaleIconImage(UIImage *image);
UIImage *LGIOS26TintedIconImage(UIImage *image, CGFloat hue, CGFloat intensity);

@interface LGIOS26IconView : UIView

@property (nonatomic) BOOL usesSharedBackdrop;

- (void)updateWithImage:(UIImage *)image
           cornerRadius:(CGFloat)cornerRadius
                    mode:(LGIOS26IconMode)mode
               algorithm:(LGIOS26IconAlgorithm)algorithm
          darkAppearance:(BOOL)darkAppearance
                 tintHue:(CGFloat)tintHue
           tintIntensity:(CGFloat)tintIntensity
   preservesSubjectColor:(BOOL)preservesSubjectColor
        imageIsProcessed:(BOOL)imageIsProcessed;

@end
