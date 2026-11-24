//
//  WNMesh : NSObject
//  逆向还原：ivar/方法/属性来自二进制元数据
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

@interface WNMesh : NSObject {
    BOOL _multiply;
    unsigned long long _positionOffset;
    unsigned long long _indexCount;
    id<MTLBuffer> _uv;
    id<MTLBuffer> _indices;
    NSString * _texture;
    NSData * _hitIndices;
}

@property (nonatomic) unsigned long long positionOffset;
@property (nonatomic) unsigned long long indexCount;
@property (nonatomic, strong) id<MTLBuffer> uv;
@property (nonatomic, strong) id<MTLBuffer> indices;
@property (nonatomic, copy) NSString * texture;
@property (nonatomic) BOOL multiply;
@property (nonatomic, strong) NSData * hitIndices;

- (unsigned long long)positionOffset;
- (void)setPositionOffset:(unsigned long long)arg1;
- (unsigned long long)indexCount;
- (void)setIndexCount:(unsigned long long)arg1;
- (BOOL)multiply;
- (void)setMultiply:(BOOL)arg1;
@end
