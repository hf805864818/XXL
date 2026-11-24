//
//  WNUploadSurface : NSObject
//  逆向还原：ivar/方法/属性来自二进制元数据
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

@interface WNUploadSurface : NSObject {
    struct CGContext * context;
    NSMutableData * _pixels;
    id<MTLTexture> _texture;
    id<MTLBuffer> _quadPositions;
    id _paintKey;
    WNLiveRig * _paintRig;
}

@property (nonatomic, strong) NSMutableData * pixels;
@property (nonatomic, strong) id<MTLTexture> texture;
@property (nonatomic, strong) id<MTLBuffer> quadPositions;
@property (nonatomic, strong) id paintKey;
@property (nonatomic, strong) WNLiveRig * paintRig;

- (void)dealloc;
- (struct CGContext *)context;
@end
