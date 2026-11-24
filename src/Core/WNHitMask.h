//
//  WNHitMask : NSObject
//  逆向还原：ivar/方法/属性来自二进制元数据
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

@interface WNHitMask : NSObject {
    CGRect _bounds;
    CGRect _clip;
    double _cell;
    unsigned long long _w;
    unsigned long long _h;
    float _clipX;
    float _clipY;
    NSMutableData * _pixels;
}

- (id)initWithBounds:(CGRect)arg1 clipX:(float *)arg2 clipY:(float *)arg3 clipRect:(CGRect)arg4;
- (void)addPositions:(float *)arg1 UV:(float *)arg2 indices:(unsigned short *)arg3 count:(unsigned long long)arg4 rgba:(char *)arg5 width:(unsigned long long)arg6 height:(unsigned long long)arg7 opacity:(float)arg8;
- (struct CGPath *)newPath;
@end
