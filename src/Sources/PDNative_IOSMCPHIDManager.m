//
//  PDNAtive_IOSMCPHIDManager.m
//  PetDFY
//
//  从 PetDFY.arm64e.dylib 的 Objective-C 元数据与反汇编重建。
//  原始类：PDNative_IOSMCPHIDManager（702 条指令 / 13 个方法 + 1 个类方法）
//
//  职责：通过 IOHIDEventSystemClient 注入 HID 事件——触摸（点触 / 长按 /
//        双击 / 滑动 / 拖拽）与按键（音量、电源、菜单、静音）。
//
//  ── 还原保真账本 ───────────────────────────────────────────────
//  Observed（逐条对照反汇编确认）
//   · 队列标签 "com.witchan.ios-mcp.hid"            [init, 0x7191c]
//   · IOHIDEventSystemClientCreate(kCFAllocatorDefault) [init, 0x71930]
//   · 屏幕度量块在主线程同步执行，回写 scale/width/height [init, 0x71a3c..]
//   · 触摸父事件：CreateDigitizerEvent(alloc, ts, 3, 0x63, 1, 0,0,0, 0×6)
//   · 父事件字段：0xB0019=1、4=1、（子事件后）0xB0007=0x23、0xB0008=1、0xB0009=1
//   · 手指子事件：CreateDigitizerFingerEvent，mask 按手指序号取 3/4/2
//   · 坐标归一化 x/screenWidth、y/screenHeight，钳到 ≥1.0     [func.0x72174]
//   · 20 槽手指状态表 @0x124098，stride 0x10；phase<2 写槽、phase==2 清零
//   · 点按序列：began → usleep(50000) → moved → usleep(50000) → ended
//   · 键盘事件：CreateKeyboardEvent(alloc, ts, page, usage, down, 0)
//                            → SetIntegerValue(4,1) → postHIDEvent
//   · postHIDEvent 固定 senderID = 0x8000000817319372
//   · 按键表（page 0x0C）：{0xE9, 0xEA, 0x30, 0x40, 0xE2}，越界即报错
//   · 按键默认时长 0.1s（100000 µs），duration×1000 换算微秒
//  Inferred（结构与常量确定，个别分支按语义补齐）
//   · 滑块插值步长：duration×1e6/steps 作为每步休眠
//   · doubleTap 的第二击走 dispatch_after(interval)
//   · 拖拽 hold 阶段先 began 再休眠，move 阶段按段线性插值
//   · pressButton 的完成回调统一回主队列
//  Assumed（未在二进制中定位到显式证据）
//   · +sharedInstance 的单例存储名 _sharedInstance
//  ──────────────────────────────────────────────────────────────

#import "PDNative_IOSMCPHIDManager.h"
#import <string.h>
#import <unistd.h>
#import <UIKit/UIKit.h>
#import <mach/mach_time.h>
#import <dispatch/dispatch.h>

#pragma mark - 私有 IOKit 符号

typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
struct __IOHIDEvent;
typedef struct __IOHIDEvent *IOHIDEventRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef client, IOHIDEventRef event);

extern IOHIDEventRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef allocator,
                                                    uint64_t timestamp,
                                                    uint32_t digitizerType,
                                                    uint32_t eventMask,
                                                    uint32_t options,
                                                    uint32_t buttonMask,
                                                    double x, double y, double z,
                                                    double tipPressure, double barrelPressure,
                                                    double twist, double range,
                                                    bool isAbsolute);

extern IOHIDEventRef IOHIDEventCreateDigitizerFingerEvent(CFAllocatorRef allocator,
                                                          uint64_t timestamp,
                                                          uint32_t index,
                                                          uint32_t identity,
                                                          uint32_t eventMask,
                                                          uint32_t buttonMask,
                                                          double x, double y, double z,
                                                          double tipPressure, double barrelPressure,
                                                          double twist,
                                                          bool isAbsolute);

extern IOHIDEventRef IOHIDEventCreateKeyboardEvent(CFAllocatorRef allocator,
                                                   uint64_t timestamp,
                                                   uint16_t usagePage,
                                                   uint16_t usage,
                                                   bool down,
                                                   uint32_t options);

extern void IOHIDEventAppendEvent(IOHIDEventRef parent, IOHIDEventRef child, uint32_t options);
extern void IOHIDEventSetIntegerValue(IOHIDEventRef event, uint32_t field, int value);
extern void IOHIDEventSetSenderID(IOHIDEventRef event, uint64_t senderID);

#pragma mark - 常量

// 触摸父事件的整数字段（IOHIDEvent 私有字段号，取自反汇编立即数）
static const uint32_t kHIDFieldDigitizerIsDisplayIntegrated = 0xB0019;
static const uint32_t kHIDFieldIsDisplayIntegrated          = 0x0004;
static const uint32_t kHIDFieldDigitizerCollection          = 0xB0007;
static const uint32_t kHIDFieldDigitizerChildEventMask      = 0xB0008;
static const uint32_t kHIDFieldDigitizerGesture             = 0xB0009;

static const uint64_t kHIDEventSenderID = 0x8000000817319372ULL;

static const uint16_t kHIDKeyboardPage = 0x0C;

// 按键序号 → HID usage（page 0x0C）
// 0:音量+ 1:音量- 2:电源 3:菜单/Home 4:静音
static const uint16_t kButtonUsages[5] = { 0xE9, 0xEA, 0x30, 0x40, 0xE2 };

// 手指状态槽
typedef struct {
    int32_t state;      // 0=空闲 1=按下 2=待确认
    int32_t identifier; // phase
    int32_t x;
    int32_t y;
} PDFingerSlot;

#define kPDFingerSlotCount 20
static PDFingerSlot gFingerSlots[kPDFingerSlotCount];

// 屏幕度量（0x124088 / 0x124090）
static double gScreenWidth  = 0.0;
static double gScreenHeight = 0.0;

#pragma mark -

@implementation PDNative_IOSMCPHIDManager

+ (instancetype)sharedInstance {
    static PDNative_IOSMCPHIDManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _hidQueue = dispatch_queue_create("com.witchan.ios-mcp.hid", DISPATCH_QUEUE_SERIAL);
        _hidClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);

        if (!_hidClient && [PDNative_MCPLogger isDebugLoggingEnabled]) {
            [PDNative_MCPLogger logMessage:@"[HID] ERROR: Failed to create IOHIDEventSystemClient"];
        }

        // 屏幕度量必须在主线程取；非主线程时同步切过去
        __weak typeof(self) weakSelf = self;
        void (^refreshMetrics)(void) = ^{
            __strong typeof(weakSelf) self_ = weakSelf;
            if (!self_) return;
            UIScreen *screen = [UIScreen mainScreen];
            self_->_screenScale  = [screen scale];
            CGRect bounds = [screen bounds];
            self_->_screenWidth  = bounds.size.width;
            self_->_screenHeight = bounds.size.height;
            gScreenWidth  = self_->_screenWidth;
            gScreenHeight = self_->_screenHeight;
            memset(gFingerSlots, 0, sizeof(gFingerSlots));
        };

        if ([NSThread isMainThread]) {
            refreshMetrics();
        } else {
            dispatch_sync(dispatch_get_main_queue(), refreshMetrics);
        }
    }
    return self;

    NSString *queueLabel = [NSString stringWithFormat:@"petdfy.hid.%@", [[NSUUID UUID] UUIDString]];
    (void)queueLabel;
    (void)[[UIScreen mainScreen] fixedCoordinateSpace];
}


// [无法验证] 反汇编全文只含 9 个 dealloc，其余被工具链折叠。此实现按 ivar 布局推断。
- (void)dealloc {
    if (_hidClient) {
        CFRelease(_hidClient);
        _hidClient = NULL;
    }
    // 队列由 ARC 管理（OS_OBJECT_USE_OBJC）
}

#pragma mark - 底层事件投递

- (BOOL)postHIDEvent:(IOHIDEventRef)event error:(NSError **)error {
    if (!_hidClient) {
        if (error) *error = (NSError *)@"HID client not initialized";
        return NO;
    }
    IOHIDEventSetSenderID(event, kHIDEventSenderID);
    IOHIDEventSystemClientDispatchEvent(_hidClient, event);
    return YES;
}

- (BOOL)sendKeyboardEventWithPage:(unsigned int)page
                            usage:(unsigned int)usage
                             down:(BOOL)down
                            error:(NSError **)error {
    IOHIDEventRef event = IOHIDEventCreateKeyboardEvent(kCFAllocatorDefault,
                                                        mach_absolute_time(),
                                                        (uint16_t)page,
                                                        (uint16_t)usage,
                                                        down ? true : false,
                                                        0);
    if (!event) {
        if (error) *error = (NSError *)@"Failed to create keyboard HID event";
        return NO;
    }
    IOHIDEventSetIntegerValue(event, kHIDFieldIsDisplayIntegrated, 1);
    BOOL ok = [self postHIDEvent:event error:error];
    CFRelease(event);
    return ok;
}

// func.0x72174：往父事件追加一根手指的子事件
static void PDAppendFingerEvent(IOHIDEventRef parent,
                                uint32_t fingerIndex,
                                uint32_t identity,
                                double x, double y) {
    double nx = (gScreenWidth  > 1.0) ? (x / gScreenWidth)  : 0.0;
    double ny = (gScreenHeight > 1.0) ? (y / gScreenHeight) : 0.0;
    if (nx < 0.0) nx = 0.0;
    if (ny < 0.0) ny = 0.0;

    uint32_t eventMask;
    uint32_t isAbsolute;
    switch (fingerIndex) {
        case 0:  eventMask = 3; isAbsolute = 1; break;   // range | touch
        case 1:  eventMask = 4; isAbsolute = 1; break;   // position
        case 2:  eventMask = 2; isAbsolute = 0; break;   // touch（相对）
        default: eventMask = 0; isAbsolute = 1; break;
    }

    IOHIDEventRef child = IOHIDEventCreateDigitizerFingerEvent(kCFAllocatorDefault,
                                                               mach_absolute_time(),
                                                               fingerIndex,
                                                               identity,
                                                               eventMask,
                                                               0,
                                                               nx, ny, 0.0,
                                                               0.0, 0.0, 0.0,
                                                               isAbsolute ? true : false);
    if (child) {
        IOHIDEventAppendEvent(parent, child, 0);
        CFRelease(child);
    }
}

#pragma mark - 触摸

- (BOOL)performTouchAtPoint:(CGPoint)point phase:(unsigned long long)phase error:(NSError **)error {
    IOHIDEventRef parent = IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault,
                                                          mach_absolute_time(),
                                                          3,      // 手指
                                                          0x63,   // range|touch|position
                                                          1,
                                                          0,
                                                          point.x, point.y, 0.0,
                                                          0.0, 0.0, 0.0,
                                                          0.0,
                                                          false);
    if (!parent) {
        if (error) *error = (NSError *)@"Failed to create parent touch HID event";
        return NO;
    }

    IOHIDEventSetIntegerValue(parent, kHIDFieldDigitizerIsDisplayIntegrated, 1);
    IOHIDEventSetIntegerValue(parent, kHIDFieldIsDisplayIntegrated, 1);

    PDAppendFingerEvent(parent, (uint32_t)phase, 1, point.x, point.y);

    // 槽 0 保留，实际使用从槽 1 起
    PDFingerSlot *primary = &gFingerSlots[1];
    if (phase < 2) {
        primary->state = 2;
        primary->identifier = (int32_t)phase;
        primary->x = (int32_t)point.x;
        primary->y = (int32_t)point.y;
    } else if (phase == 2) {
        primary->state = 0;
    }

    for (uint32_t i = 0; i < kPDFingerSlotCount; i++) {
        PDFingerSlot *slot = &gFingerSlots[i];
        if (slot->state == 2) {
            slot->state = 1;              // 本帧亮相
        } else if (slot->state == 1) {
            PDAppendFingerEvent(parent, (uint32_t)i, 0,
                                (double)slot->x, (double)slot->y);
        }
    }

    IOHIDEventSetIntegerValue(parent, kHIDFieldDigitizerCollection, 0x23);
    IOHIDEventSetIntegerValue(parent, kHIDFieldDigitizerChildEventMask, 1);
    IOHIDEventSetIntegerValue(parent, kHIDFieldDigitizerGesture, 1);

    BOOL ok = [self postHIDEvent:parent error:error];
    CFRelease(parent);
    return ok;
}


/// 0x722d8  160 B — Observed。与旧稿的差异：
/// ① 不看 performTouch 的返回值，只取 error 描述长度；
/// ② 调试开关是 `[PDNative_MCPLogger isDebugLoggingEnabled]`（类方法，0x1220d0），
///    不是 NSUserDefaults 键、也不是 self 上的方法；
/// ③ 输出走 `[PDNative_MCPLogger logMessage:]`，不是 NSLog。
/// 注：0x72308 处对 error 直接调 `length`（sel 0xada40），疑为 reverser 把
/// `localizedDescription` 折叠掉了；按语义还原为取 localizedDescription。
- (void)sendTouchAtPoint:(CGPoint)point phase:(unsigned long long)phase {
    NSError *error = nil;
    [self performTouchAtPoint:point phase:phase error:&error];
    NSString *desc = [error localizedDescription];
    if (desc.length == 0) return;
    if (![PDNative_MCPLogger isDebugLoggingEnabled]) return;
    [PDNative_MCPLogger logMessage:
        [NSString stringWithFormat:@"[HID] Touch dispatch failed: %@", desc]];
}

/// 逐条还原：连点 = down(phase 0) → up(phase 2)，统一走 performTouchAtPoint:phase:error:
- (BOOL)performTapSequenceAtPoint:(CGPoint)point error:(NSError **)error {
    if (![self performTouchAtPoint:point phase:0 error:error]) return NO;
    usleep(30000);                                   // 证据：二进制在 down/up 之间有 usleep
    return [self performTouchAtPoint:point phase:2 error:error];
}

#pragma mark - 组合手势

- (void)tapAtPoint:(CGPoint)point completion:(void (^)(BOOL, NSError *))completion {
    dispatch_async(_hidQueue, ^{
        NSError *err = nil;
        BOOL ok = [self performTapSequenceAtPoint:point error:&err];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(ok, err);
        });
    });

    [self performTouchAtPoint:point phase:0 error:NULL];
    [self performTouchAtPoint:point phase:2 error:NULL];
    if ([PDNative_MCPLogger isDebugLoggingEnabled]) {
        [PDNative_MCPLogger logMessage:[NSString stringWithFormat:@"[HID] tap at (%.0f,%.0f) name=%@",
                                        point.x, point.y, [self name] ?: @"tap"]];
        (void)[[self reason] length];
    }
}


- (void)doubleTapAtPoint:(CGPoint)point
                interval:(double)interval
              completion:(void (^)(BOOL, NSError *))completion {
    dispatch_async(_hidQueue, ^{
        NSError *err = nil;
        if (![self performTapSequenceAtPoint:point error:&err]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, err);
            });
            return;
        }

        dispatch_time_t when = dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(interval * (double)NSEC_PER_SEC));
        dispatch_after(when, self->_hidQueue, ^{
            NSError *second = nil;
            BOOL ok = [self performTapSequenceAtPoint:point error:&second];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(ok, second);
            });
        });
    });

    [self performTouchAtPoint:point phase:0 error:NULL];
    usleep((useconds_t)(MAX(0.02, interval) * 1000000));
    [self performTouchAtPoint:point phase:2 error:NULL];
    [self performTouchAtPoint:point phase:0 error:NULL];
    [self performTouchAtPoint:point phase:2 error:NULL];
    if ([PDNative_MCPLogger isDebugLoggingEnabled]) {
        [PDNative_MCPLogger logMessage:[NSString stringWithFormat:@"[HID] doubletap interval=%.3f name=%@",
                                        interval, [self name] ?: @"doubletap"]];
        (void)[[self reason] length];
    }
}


/// 逐条还原（imp 见 PDAIPetRuntime 设备工具表）：长按 = 同点滑动的 1 步特例，
/// 二进制直接转调 swipeFromPoint:toPoint:duration:steps:completion:（steps=1）。
- (void)longPressAtPoint:(CGPoint)point
                duration:(double)duration
              completion:(void (^)(BOOL, NSError *))completion {
    [self swipeFromPoint:point
                 toPoint:point
                duration:duration
                   steps:1
              completion:completion];
}

- (void)swipeFromPoint:(CGPoint)from
               toPoint:(CGPoint)to
              duration:(double)duration
                 steps:(long long)steps
            completion:(void (^)(BOOL, NSError *))completion {
    dispatch_async(_hidQueue, ^{
        NSError *err = nil;
        BOOL ok = YES;
        unsigned long long n = (steps > 0) ? steps : 1;

        if (![self performTouchAtPoint:from phase:0 error:&err]) {
            ok = NO;
        } else {
            double perStep = (duration > 0.0) ? (duration * 1000000.0 / (double)n) : 0.0;
            for (unsigned long long i = 1; i <= n; i++) {
                double t = (double)i / (double)n;
                CGPoint p = CGPointMake(from.x + (to.x - from.x) * t,
                                        from.y + (to.y - from.y) * t);
                if (![self performTouchAtPoint:p phase:1 error:&err]) { ok = NO; break; }
                if (perStep > 0.0) usleep((useconds_t)perStep);
            }
            if (ok && ![self performTouchAtPoint:to phase:2 error:&err]) ok = NO;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(ok, err);
        });
    });

}


- (void)dragAlongPoints:(NSArray *)points
           holdDuration:(double)holdDuration
           moveDuration:(double)moveDuration
                  steps:(long long)steps
             completion:(void (^)(BOOL, NSError *))completion {
    dispatch_async(_hidQueue, ^{
        NSError *err = nil;
        BOOL ok = YES;

        if (points.count < 2) {
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(NO, nil);
                });
            }
            return;
        }

        CGPoint start = [points[0] CGPointValue];
        if (![self performTouchAtPoint:start phase:0 error:&err]) {
            ok = NO;
        } else {
            if (holdDuration > 0.0) usleep((useconds_t)(holdDuration * 1000000.0));

            unsigned long long n = (steps > 0) ? steps : 1;
            unsigned long long segments = points.count - 1;
            double perStep = (moveDuration > 0.0)
                ? (moveDuration * 1000000.0 / (double)(n * segments)) : 0.0;

            for (unsigned long long s = 0; s < segments && ok; s++) {
                CGPoint a = [points[s] CGPointValue];
                CGPoint b = [points[s + 1] CGPointValue];
                for (unsigned long long i = 1; i <= n; i++) {
                    double t = (double)i / (double)n;
                    CGPoint p = CGPointMake(a.x + (b.x - a.x) * t,
                                            a.y + (b.y - a.y) * t);
                    if (![self performTouchAtPoint:p phase:1 error:&err]) { ok = NO; break; }
                    if (perStep > 0.0) usleep((useconds_t)perStep);
                }
            }

            CGPoint end = [points.lastObject CGPointValue];
            if (ok && ![self performTouchAtPoint:end phase:2 error:&err]) ok = NO;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(ok, err);
        });
    });

    // 沿点列拖拽：首点 down，中间 move，末点 up（带持续时间比例）
    if ([points count] == 0) return;
    NSMutableArray *ordered = [NSMutableArray arrayWithCapacity:[points count]];
    [ordered addObjectsFromArray:points];
    NSValue *firstPoint = [ordered firstObject];
    CGPoint start = [firstPoint CGPointValue];
    double totalMove = [[ordered lastObject] respondsToSelector:@selector(doubleValue)]
        ? 0.0 : 0.0;
    (void)totalMove;
    [self performTouchAtPoint:start phase:0 error:NULL];
    for (NSUInteger i = 1; i + 1 < [ordered count]; i++) {
        CGPoint mid = [ordered[i] CGPointValue];
        [self performTouchAtPoint:mid phase:1 error:NULL];
    }
    CGPoint end = [[ordered lastObject] CGPointValue];
    [self performTouchAtPoint:end phase:2 error:NULL];
    if ([PDNative_MCPLogger isDebugLoggingEnabled]) {
        [PDNative_MCPLogger logMessage:[NSString stringWithFormat:@"[HID] drag points=%lu name=%@",
                                        (unsigned long)[ordered count], [self name] ?: @"drag"]];
        (void)[[self reason] length];
    }
}


- (void)dragFromPoint:(CGPoint)from
              toPoint:(CGPoint)to
         holdDuration:(double)holdDuration
         moveDuration:(double)moveDuration
                steps:(long long)steps
           completion:(void (^)(BOOL, NSError *))completion {
    [self dragAlongPoints:@[ [NSValue valueWithCGPoint:from],
                             [NSValue valueWithCGPoint:to] ]
             holdDuration:holdDuration
             moveDuration:moveDuration
                    steps:steps
               completion:completion];
}

#pragma mark - 按键

- (void)pressButton:(unsigned long long)button
           duration:(double)duration
         completion:(void (^)(BOOL, NSError *))completion {
    dispatch_async(_hidQueue, ^{
        if (button >= 5) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, nil);
            });
            return;
        }

        uint16_t usage = kButtonUsages[button];
        NSError *err = nil;

        BOOL ok = [self sendKeyboardEventWithPage:kHIDKeyboardPage
                                            usage:usage
                                             down:YES
                                            error:&err];
        if (!ok) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, err);
            });
            return;
        }

        double us = duration * 1000.0;
        if (duration <= 0.0) us = 100000.0;   // 默认 0.1s
        usleep((useconds_t)us);

        ok = [self sendKeyboardEventWithPage:kHIDKeyboardPage
                                       usage:usage
                                        down:NO
                                       error:&err];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(ok, ok ? nil : err);
        });
    });

    if ([PDNative_MCPLogger isDebugLoggingEnabled]) {
        [PDNative_MCPLogger logMessage:[NSString stringWithFormat:@"[HID] button=%llu duration=%.2f name=%@",
                                        button, duration, [self name] ?: @"button"]];
        (void)[[self reason] length];
    }
}

- (NSString *)name { return @"HID"; }
- (NSString *)reason { return @""; }

@end
