//
//  WNPreparedDeformer : NSObject
//  逆向还原：ivar/方法/属性来自二进制元数据
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

@interface WNPreparedDeformer : NSObject {
    id parent;              // 二进制写入的是 def[@"parent"]（NSString 名字），非对象指针（0x4a0a8）
    BOOL rotation;
    BOOL active;
    double px;
    double py;
    double sx;
    double sy;
    double tx;
    double ty;
    double cosine;
    double sine;
    double x0;
    double y0;
    double width;
    double height;
    id warp;
}

- (CGPoint)transformPoint:(CGPoint)p;
- (void)prepareWithAngle:(double)angle;
- (CGPoint)transformPointThroughChain:(CGPoint)p;

@property (nonatomic) BOOL active;
@property (nonatomic) BOOL rotation;
@property (nonatomic) double px;
@property (nonatomic) double py;
@property (nonatomic) double sx;
@property (nonatomic) double sy;
@property (nonatomic) double tx;
@property (nonatomic) double ty;
@property (nonatomic) double x0;
@property (nonatomic) double y0;
@property (nonatomic) double width;
@property (nonatomic) double height;
@property (nonatomic) double cosine;
@property (nonatomic) double sine;
@property (nonatomic, strong) id parent;
@property (nonatomic, strong) id warp;

@end
