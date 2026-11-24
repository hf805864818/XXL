//
//  WNClip : NSObject
//  逆向还原：ivar/方法/属性来自二进制元数据
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

@interface WNClip : NSObject {
    NSDictionary * _info;
    NSData * _positions;
    NSArray * _meshes;
    id<MTLBuffer> _positionBuffer;
    id<MTLBuffer> _backgroundPositions;
}

@property (nonatomic, strong) NSDictionary * info;
@property (nonatomic, strong) NSData * positions;
@property (nonatomic, strong) NSArray * meshes;
@property (nonatomic, strong) id<MTLBuffer> positionBuffer;
@property (nonatomic, strong) id<MTLBuffer> backgroundPositions;

- (id)quad;
@end
