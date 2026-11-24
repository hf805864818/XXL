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

#pragma mark - PDWindow

@implementation PDWindow

/// 0x59e4，45 条指令。触摸命中测试：命中窗口自身或根视图时穿透。
///   0x5a08  blraa x8,x8        → objc_msgSendSuper2(PDWindow, hitTest:withEvent:)
///   0x5a10  cmp  x0, x20       ; x20 = self        → 相等返回 0
///   0x5a28  bl   0xb06c0       ; rootViewController
///   0x5a30  bl   0xb67e0       ; view
///   0x5a40  csel x8, xzr, x19, eq ; 命中 == rootVC.view 时返回 0
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self) return nil;
    if (hit == self.rootViewController.view) return nil;
    return hit;
}

/// 0x59e0 是单条尾跳 trampoline：`b 0xaee60`。
///   0xaee60: adrp x1,0x11f000 / ldr x1,[x1,0x6f0] (= selref 0x11f6f0 → "pdAllowsKey")
///            ldr x16,[0xf8000+0x708] (= GOT → _objc_msgSend) / braa x16,x16
/// 即直接转发到 -pdAllowsKey，返回值原样透传，不取反。
- (BOOL)canBecomeKeyWindow {
    return [self pdAllowsKey];
}

- (BOOL)pdAllowsKey { return _pdAllowsKey; }
- (void)setPdAllowsKey:(BOOL)v { _pdAllowsKey = v; }

@end

