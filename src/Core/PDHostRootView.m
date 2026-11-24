//
//  SmallClasses.m — 逆向还原：6 个小类
//
//  PDVoice              (5 方法 / 12 指令)   语音节点包装
//  WNGlowSurface        (9 方法 / 41 指令)   辉光表面
//  PDWindow             (3 方法 / 53 指令)   覆盖窗口（hitTest 穿透）
//  WNUploadSurface      (12 方法 / 71 指令)  上传表面
//  PDHostRootView       (2 方法 / 130 指令)  宿主根视图（点穿透）
//  PDChatPassthroughView(2 方法 / 130 指令)  聊天透传视图
//

#import "PDVoice.h"
#import "WNGlowSurface.h"
#import "PDWindow.h"
#import "WNUploadSurface.h"
#import "PDHostRootView.h"
#import "PDChatPassthroughView.h"
#import <AVFoundation/AVFoundation.h>
#import <MetalKit/MetalKit.h>
#import <UIKit/UIKit.h>

#pragma mark - PDHostRootView

@implementation PDHostRootView

/// 105 条指令。判断点是否在可交互子视图内。
/// 反汇编：subviews → reverseObjectEnumerator → 遍历
///         检查 isHidden / alpha / isUserInteractionEnabled
/// 逆序遍历 = 从最上层开始（后添加的在上）
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    // 自身不响应，只看子视图
    NSArray *subs = self.subviews;
    for (UIView *v in [subs reverseObjectEnumerator]) {
        if (v.hidden) continue;
        if (v.alpha < 0.01) continue;
        if (!v.userInteractionEnabled) continue;
        CGPoint p = [self convertPoint:point toView:v];
        if ([v pointInside:p withEvent:event]) return YES;
    }
    return NO;

    if (![self isUserInteractionEnabled]) return NO;
    if ([self isHidden]) return NO;
    if ([[self superview] respondsToSelector:@selector(hitTest:withEvent:)]) {
        id hit = [[self superview] performSelector:@selector(hitTest:withEvent:) withObject:event];
        if (hit == self) return YES;
    }
}


/// 25 条指令。只在子视图命中时返回，否则穿透。
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (![self pointInside:point withEvent:event]) return nil;
    return [super hitTest:point withEvent:event];
}

@end

