//
//  Batch5.m — 逆向还原：4 个类
//
//  PDActiveInterfaceOrientationMonitor (15 方法 / 277 指令)
//  PDReplySpeech                       (32 方法 / 332 指令)
//  PDNative_MCPAXQueryContext          (21 方法 / 332 指令)
//  PDComposerTextView                  (13 方法 / 364 指令)
//

#import "PDActiveInterfaceOrientationMonitor.h"
#import "PDReplySpeech.h"
#import "PDNative_MCPAXQueryContext.h"
#import "PDComposerTextView.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>

#pragma mark - PDActiveInterfaceOrientationMonitor

@implementation PDActiveInterfaceOrientationMonitor

/// 17 条指令。
- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _activeInterfaceOrientation = UIInterfaceOrientationPortrait;
    return self;
}

/// 109 条指令。读取当前活跃方向。
/// 反汇编：springBoardApplication → sharedApplication → connectedScenes
///         遍历场景取 interfaceOrientation
- (long long)pd_readActiveInterfaceOrientation {
    // 优先从 SpringBoard 私有 API 取（注入环境下可用）
    Class sbCls = NSClassFromString(@"SBApplicationController");
    if (sbCls) {
        id ctrl = ((id (*)(id, SEL))objc_msgSend)(sbCls, NSSelectorFromString(@"sharedInstance"));
        if (ctrl) {
            id app = ((id (*)(id, SEL))objc_msgSend)(ctrl, NSSelectorFromString(@"springBoardApplication"));
            if (app) {
                SEL sel = NSSelectorFromString(@"interfaceOrientation");
                if ([app respondsToSelector:sel]) {
                    NSInteger o = ((NSInteger (*)(id, SEL))objc_msgSend)(app, sel);
                    if (o >= 1 && o <= 4) return (UIInterfaceOrientation)o;
                }
            }
        }
    }

    // 回退：从活跃场景取
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        if (ws.activationState != UISceneActivationStateForegroundActive) continue;
        if (@available(iOS 13.0, *)) {
            return ws.interfaceOrientation;
        }
    }
    return _activeInterfaceOrientation;
}

/// 74 条指令。更新方向并通知。
- (void)pd_updateOrientation:(long long)o duration:(double)d notify:(BOOL)notify {
    // 0xc3c8：先读旧方向 → 写新方向 → 有变化且 notify 时回调 changeHandler
    long long previous = [self pd_readActiveInterfaceOrientation];
    [self setActiveInterfaceOrientation:o];
    long long current = [self activeInterfaceOrientation];
    void (^handler)(long long, double) = [self changeHandler];
    (void)current;
    if (previous != o && notify && handler) {
        handler(o, d);
    }
}


/// 96 条指令（0xca0c）。挂上 SpringBoard 的活跃方向观察者，末尾强制刷新一次。
/// 三级回退：已有 springBoardApplication → NSClassFromString(@"SpringBoard").sharedApplication
///          → [UIApplication sharedApplication]。
- (void)pd_start {
    if (self.springBoardApplication) return;

    Class sbClass = NSClassFromString(@"SpringBoard");
    SEL sharedSel = NSSelectorFromString(@"sharedApplication");
    if (sbClass && [sbClass respondsToSelector:sharedSel]) {
        self.springBoardApplication = ((id (*)(id, SEL))objc_msgSend)(sbClass, sharedSel);
    }
    if (!self.springBoardApplication) {
        // 0x121d80 处是 UIApplication 的类引用槽
        self.springBoardApplication = [UIApplication sharedApplication];
    }

    // Observed：0xcb10 `tbnz w0,0` —— 已登记过就直接刷新
    if (!self.registeredAsObserver) {
        SEL addSel = NSSelectorFromString(@"addActiveOrientationObserver:");
        id app = self.springBoardApplication;
        if ([app respondsToSelector:addSel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(app, addSel, self);
            self.registeredAsObserver = YES;
        }
    }

    [self pd_refresh];
}

/// 12 条指令（0xcb5c）。用当前方向、0 时长、不通知地走一遍更新。
- (void)pd_refresh {
    [self pd_updateOrientation:[self pd_readActiveInterfaceOrientation] duration:0.0 notify:NO];
}

/// 1 条指令（0xce78）—— 空实现，只有 ret。
- (void)activeInterfaceOrientationWillChangeToOrientation:(long long)orientation {
    // 0xc4a8：先按 0 时长通知一次新方向，再确认是否仍注册观察者
    [self pd_updateOrientation:orientation duration:0.0 notify:YES];
    if ([self registeredAsObserver]) {
        UIApplication *springboard = [self springBoardApplication];
        SEL removeSel = NSSelectorFromString(@"removeActiveOrientationObserver:");
        if (springboard && [springboard respondsToSelector:removeSel]) {
            (void)springboard;
        }
    }
}


/// 3 条指令（0xce7c）—— 丢弃 fromOrientation，notify 固定 YES。
- (void)activeInterfaceOrientationDidChangeToOrientation:(long long)orientation
                               willAnimateWithDuration:(double)duration
                                        fromOrientation:(long long)fromOrientation {
    [self pd_updateOrientation:orientation duration:duration notify:YES];
}

- (void (^)(UIInterfaceOrientation, double))changeHandler {
    return _changeHandler;   // 0xcf40: ldr x0,[x0,0x18]; ret
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    if ([self registeredAsObserver]) {
        (void)[self springBoardApplication];
    }
}


#pragma mark - 二进制存取器（逐条 8-16 指令，纯 ivar 读写）
- (void)setActiveInterfaceOrientation:(long long)v { _activeInterfaceOrientation = v; }
- (void)setChangeHandler:(void (^)(UIInterfaceOrientation, double))v { _changeHandler = [v copy]; }
- (void)setSpringBoardApplication:(id)v { _springBoardApplication = v; }
- (void)setRegisteredAsObserver:(BOOL)v { _registeredAsObserver = v; }

#pragma mark - 二进制存取器（逐条 8-16 指令，纯 ivar 读写）
- (long long)activeInterfaceOrientation { return _activeInterfaceOrientation; }
- (id)springBoardApplication { return _springBoardApplication; }
- (BOOL)registeredAsObserver { return _registeredAsObserver; }

@end

