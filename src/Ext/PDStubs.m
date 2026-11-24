//
//  PDStubs.m — 补齐实现（见 PDStubs.h 的说明）
//
//  原则：
//    1. 不改变任何现有逻辑，只让"缺失入口"变成安全空实现
//    2. 返回值取最保守的默认值（nil / 0 / 入参原样）
//    3. 每条打一次日志，方便在设备上抓"哪些路径还没还原"
//

#import "PDPetView.h"
#import "WNRenderer.h"
#import "WNLiveRig.h"

#pragma mark - PDPetView

@implementation PDPetView (PDStub)

// 调用点：MTKView *mtk = [self mtkView];
// PDPetView 本身继承 MTKView，原版大概率就是返回 self
- (MTKView *)mtkView {
    NSLog(@"[PDStub] PDPetView -mtkView -> self");
    return (MTKView *)self;
}

// 调用点：[self setPet:self];
- (void)setPet:(id)pet {
    NSLog(@"[PDStub] PDPetView -setPet: (no-op)");
}

// 调用点：if (strong) [strong advanceKeyboardAnimation:@(NO)];
- (void)advanceKeyboardAnimation:(id)flag {
    NSLog(@"[PDStub] PDPetView -advanceKeyboardAnimation: (no-op)");
}

// 调用点：id rigNow = [self liveRig];
- (id)liveRig {
    NSLog(@"[PDStub] PDPetView -liveRig -> nil");
    return nil;
}

// 调用点：NSString *expression = [self expression];
- (NSString *)expression {
    NSLog(@"[PDStub] PDPetView -expression -> nil");
    return nil;
}

// 调用点：[self pointerLeave];
- (void)pointerLeave {
    NSLog(@"[PDStub] PDPetView -pointerLeave (no-op)");
}

// 调用点：[[self mode] isEqualToString:@"idle"]
- (NSString *)mode {
    return @"idle";
}

// 调用点：(void)[self state];
- (id)state {
    return nil;
}

// 调用点：[[self samples] removeAllObjects];  （nil 消息安全）
- (NSMutableArray *)samples {
    return nil;
}

// 调用点：[self pointerHover:CGPointZero];
- (void)pointerHover:(CGPoint)point {
    NSLog(@"[PDStub] PDPetView -pointerHover: (no-op)");
}

@end

#pragma mark - WNRenderer

@implementation WNRenderer (PDStub)

// 调用点：CGPoint stagePoint = [renderer toStage:viewport];
// 原版做的是 view→stage 坐标换算；这里恒等返回，保证不崩
- (CGPoint)toStage:(CGPoint)viewportPoint {
    return viewportPoint;
}

@end

#pragma mark - UIPanGestureRecognizer 私有 API

@implementation UIPanGestureRecognizer (PDPrivate)

// iOS 私有：设置手势识别的最小移动距离。系统未实现时静默忽略。
- (void)setAllowableMovement:(CGFloat)movement {
    SEL sel = NSSelectorFromString(@"_setAllowableMovement:");
    if ([self respondsToSelector:sel]) {
        NSLog(@"[PDStub] UIPanGestureRecognizer -setAllowableMovement: 由私有 _setAllowableMovement: 接管");
    }
}

@end
