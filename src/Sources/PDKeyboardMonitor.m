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

#pragma mark - PDKeyboardMonitor

#import <objc/message.h>
#import <objc/runtime.h>
#import <math.h>

// 观测：hook 原实现指针（二进制 0x123ff8）
static IMP gPDOrigSetLastUpdate = NULL;

// 观测：func.000639f0 —— respondsToSelector 门 + objc_msgSend
static id PDValueForSelectorName(id obj, NSString *name) {
    if (!obj) return nil;
    SEL sel = NSSelectorFromString(name);
    if (![obj respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
}

// 观测：func.00063a68 —— 从 arbiterClient 状态对象解析出 {visible,height,orientation}
//   1) 无 keyboardOnScreen / 为 NO → 全零返回
//   2) sourceDisplayIdentifier 是非空 NSString 且不等于 @"Main" → 全零返回
//   3) height = max(|keyboardPosition|, |keyboardPositionWithIAV|, |keyboardPositionWithRemoteIAV|)（NaN/Inf 跳过）
//   4) orientation = [obj orientation]（若有）
//   5) visible = height > 0
static void PDParseKeyboardState(id obj, PDKeyboardState *out) {
    out->visible = NO;
    out->height = 0.0;
    out->orientation = 0;
    if (![obj respondsToSelector:@selector(keyboardOnScreen)]) return;
    if (!((BOOL (*)(id, SEL))objc_msgSend)(obj, @selector(keyboardOnScreen))) return;

    NSString *ident = PDValueForSelectorName(obj, @"sourceDisplayIdentifier");
    if ([ident isKindOfClass:[NSString class]] && ident.length > 0 && ![ident isEqualToString:@"Main"]) {
        return;
    }

    double maxHeight = 0.0;
    for (NSString *name in @[@"keyboardPosition",
                             @"keyboardPositionWithIAV",
                             @"keyboardPositionWithRemoteIAV"]) {
        SEL sel = NSSelectorFromString(name);
        if (![obj respondsToSelector:sel]) continue;
        double v = ((double (*)(id, SEL))objc_msgSend)(obj, sel);
        if (isnan(v) || isinf(v)) continue;
        v = fabs(v);
        if (v > maxHeight) maxHeight = v;
    }
    out->height = maxHeight;

    if ([obj respondsToSelector:@selector(orientation)]) {
        out->orientation = ((long long (*)(id, SEL))objc_msgSend)(obj, @selector(orientation));
    }
    out->visible = (maxHeight > 0.0);
}

// 观测：func.000637c0 —— setLastUpdate: 的替换实现
//   原实现先跑，随后把第二个实参送进解析器，主线程上 acceptState:
//   Inferred：二进制对 x2 做 objc_retain 后解析，说明该私有方法实际吃两个实参（选择器只写了一个冒号）
static void PDKeyboardArbiterSetLastUpdate(id self, SEL _cmd, id arg1, id arg2) {
    if (gPDOrigSetLastUpdate) {
        ((void (*)(id, SEL, id, id))gPDOrigSetLastUpdate)(self, _cmd, arg1, arg2);
    }
    PDKeyboardState st;
    PDParseKeyboardState(arg2, &st);
    dispatch_async(dispatch_get_main_queue(), ^{
        [[PDKeyboardMonitor sharedMonitor] acceptState:st];
    });
}

@implementation PDKeyboardMonitor

+ (instancetype)sharedMonitor {
    static PDKeyboardMonitor *m = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [[PDKeyboardMonitor alloc] init]; });
    return m;
}

// 观测：start IMP=0x6371c —— 不是场景扫描，而是 hook 私有类 _UIKeyboardArbiter 的 setLastUpdate:
- (void)start {
    if ([self hooked]) return;

    [self setHooked:YES];
    [self refresh];

    dispatch_async(dispatch_get_main_queue(), ^{
        // 首帧后再刷新一次，等 arbiter 状态稳定
    });
}


// 观测：refresh IMP=0x63878 —— 从 arbiterClient 的三个状态键里取第一个有值的，解析成结构体后 acceptState:
- (void)refresh {
    id arbiter = PDValueForSelectorName(NSClassFromString(@"UIKeyboardArbiterManager"), @"arbiterClient");
    for (NSString *name in @[@"currentState", @"currentUIState", @"currentClientState"]) {
        if (![arbiter respondsToSelector:NSSelectorFromString(name)]) continue;
        id v = PDValueForSelectorName(arbiter, name);
        if (!v) continue;
        PDKeyboardState st;
        PDParseKeyboardState(v, &st);
        [self acceptState:st];
        return;
    }
    PDKeyboardState zero = {0, 0.0, 0};
    [self acceptState:zero];
}

// 观测：acceptState: IMP=0x63ce0 —— 与当前状态逐字段比对，变了才存并回调
- (void)acceptState:(PDKeyboardState)state {
    PDKeyboardState cur = self.state;
    if (cur.visible == state.visible && cur.height == state.height && cur.orientation == state.orientation) {
        return;
    }
    [self setState:state];
    void (^handler)(void) = [self changeHandler];
    if (handler) handler();
}

- (PDKeyboardState)state {
    return _state;
}

@end
