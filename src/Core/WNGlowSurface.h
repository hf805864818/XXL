//
//  WNGlowSurface : NSObject
//  逆向还原：ivar/方法/属性来自二进制元数据
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

@interface WNGlowSurface : NSObject {
    id<MTLTexture> _silhouette;
    id<MTLTexture> _blurred;
    id<MTLBuffer> _positions;
    CGRect _stageRect;
}

@property (nonatomic, strong) id<MTLTexture> silhouette;
@property (nonatomic, strong) id<MTLTexture> blurred;
@property (nonatomic, strong) id<MTLBuffer> positions;
@property (nonatomic) CGRect stageRect;

- (CGRect)stageRect;
@end
