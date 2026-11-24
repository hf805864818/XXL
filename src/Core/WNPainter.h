//
//  WNPainter : NSObject
//  逆向还原：ivar/方法/属性来自二进制元数据
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

@interface WNPainter : NSObject {
    BOOL _darkAppearance;
    NSURL * _url;
    NSMutableDictionary * _images;
    WNLiveRig * _rig;
    NSDictionary * _schemeInfo;
    NSMutableDictionary * _eyeContexts;
}

@property (nonatomic, strong) NSURL * url;
@property (nonatomic, strong) NSMutableDictionary * images;
@property (nonatomic, strong) WNLiveRig * rig;
@property (nonatomic, strong) NSDictionary * schemeInfo;
@property (nonatomic, strong) NSMutableDictionary * eyeContexts;
@property (nonatomic) BOOL darkAppearance;

- (id)initWithResourceURL:(id)arg1;
- (void)dealloc;
- (void)useRig:(id)arg1;
- (struct CGImage *)image:(id)arg1;
- (void)draw:(struct CGImage *)arg1 context:(struct CGContext *)arg2 rect:(CGRect)arg3;
- (void)sprite:(id)arg1 context:(struct CGContext *)arg2 options:(id)arg3;
- (void)paintEye:(id)arg1 open:(double)arg2 ix:(double)arg3 iy:(double)arg4 tilt:(double)arg5 glint:(double)arg6 highlight:(id)arg7 time:(double)arg8 context:(struct CGContext *)arg9;
- (id)faceOperationsForRig:(id)arg1;
- (void)paintFaceOperations:(id)arg1 rig:(id)arg2 context:(struct CGContext *)arg3;
- (void)paintFaceForRig:(id)arg1 context:(struct CGContext *)arg2;
- (struct CGImage *)newFaceForRig:(id)arg1;
- (void)applyGroup:(struct CGContext *)arg1 rig:(id)arg2;
- (struct CGImage *)sleepGlowRed:(double)arg1 green:(double)arg2 blue:(double)arg3;
- (id)shadowOperationsForRig:(id)arg1;
- (void)paintShadowOperations:(id)arg1 context:(struct CGContext *)arg2;
- (void)paintOverlayForRig:(id)arg1 background:(BOOL)arg2 context:(struct CGContext *)arg3;
- (struct CGImage *)newOverlayForRig:(id)arg1 background:(BOOL)arg2;
- (BOOL)hasForegroundForRig:(WNLiveRig *)arg1;
- (CGRect)shadowBoundsForRig:(id)arg1;
- (CGRect)foregroundBoundsForRig:(WNLiveRig *)arg1;
- (BOOL)darkAppearance;
- (void)setDarkAppearance:(BOOL)arg1;
@end
