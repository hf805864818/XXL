//
//  PDStubs.h / PDStubs.m
//  PetDFY 编译补齐层（逆向还原遗漏的方法）
//
//  背景：T3 源码里有 12 个方法"被调用但既无声明也无实现"——
//        逆向时漏掉了（原版二进制里有，还原源码没写）。
//        clang 在 ARC 下必须知道返回类型，否则报
//        "no visible @interface declares the selector"，编译直接失败。
//
//  这里给它们补最宽松的声明 + 安全实现：
//        - 返回 nil / 0 / 原值
//        - 不改变任何现有逻辑
//        - 运行时打一条 [PDStub] 日志，方便定位"哪些入口还没还原"
//
//  后续若要恢复真实功能，在对应 .m 里实现同名方法即可（category 会被覆盖）。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - PDPetView 缺失入口

@interface PDPetView (PDStub)
- (nullable MTKView *)mtkView;
- (void)setPet:(nullable id)pet;
- (void)advanceKeyboardAnimation:(nullable id)flag;
- (nullable id)liveRig;
- (nullable NSString *)expression;
- (void)pointerLeave;
- (nullable NSString *)mode;
- (nullable id)state;
- (nullable NSMutableArray *)samples;
- (void)pointerHover:(CGPoint)point;
@end

#pragma mark - WNRenderer 缺失入口

@interface WNRenderer (PDStub)
- (CGPoint)toStage:(CGPoint)viewportPoint;
@end

#pragma mark - UIPanGestureRecognizer 私有 API

@interface UIPanGestureRecognizer (PDPrivate)
- (void)setAllowableMovement:(CGFloat)movement;
@end

NS_ASSUME_NONNULL_END
