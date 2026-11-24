//
//  Batch4.m — 逆向还原：PDRootController / PDKeyboardMonitor / PDInteractionView / PDDeviceTools
//
//  PDRootController  (9 方法 / 153 指令)   根控制器
//  PDKeyboardMonitor (9 方法 / 161 指令)   键盘状态监听
//  PDInteractionView (9 方法 / 235 指令)   交互视图
//  PDDeviceTools    (14 方法 / 246 指令)   设备工具执行器
//

#import "PDRootController.h"
#import "PDKeyboardMonitor.h"
#import "PDInteractionView.h"
#import "PDDeviceTools.h"
#import "PDPetView.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>

#pragma mark - PDInteractionView

@implementation PDInteractionView

/// 22 条指令。透明绘制。
- (void)drawRect:(CGRect)rect {
    // 交互视图本身不绘制，只做命中测试

    CGContextRef context = UIGraphicsGetCurrentContext();
    if (context) CGContextClearRect(context, [self bounds]);
}


/// 67 条指令。判断点是否落在宠物上。
/// 反汇编：isHidden / alpha / isUserInteractionEnabled / isPaused / mask
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden) return NO;
    if (self.alpha < 0.01) return NO;
    if (!self.userInteractionEnabled) return NO;

    PDPetView *pet = _pet;
    if (!pet) return NO;
    if (pet.hidden) return NO;
    if ([pet isKindOfClass:[PDPetView class]]) {
        // 用宠物的命中蒙版判断（mask 是 CAShapeLayer 或位图）
        CGPoint p = [self convertPoint:point toView:pet];
        if ([pet respondsToSelector:@selector(hit:)]) {
            return ((BOOL (*)(id, SEL, CGPoint))objc_msgSend)(pet, @selector(hit:), p);
        }
        return [pet pointInside:p withEvent:event];
    }
    return NO;
}


- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if ([_pet respondsToSelector:@selector(touchesBegan:withEvent:)]) {
        [_pet touchesBegan:touches withEvent:event];
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if ([_pet respondsToSelector:@selector(touchesMoved:withEvent:)]) {
        [_pet touchesMoved:touches withEvent:event];
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if ([_pet respondsToSelector:@selector(touchesEnded:withEvent:)]) {
        [_pet touchesEnded:touches withEvent:event];
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if ([_pet respondsToSelector:@selector(touchesCancelled:withEvent:)]) {
        [_pet touchesCancelled:touches withEvent:event];
    }
}

- (PDPetView *)pet { return _pet; }
- (void)setPet:(PDPetView *)v { _pet = v; }

@end

