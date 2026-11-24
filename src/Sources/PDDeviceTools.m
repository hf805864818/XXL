//
//  PDDeviceTools.m — 逆向还原
//
//  反汇编来源：PetDFY.arm64e.dylib
//    method.PDDeviceTools.init                      0x6ed64   (140 指令)
//    method.PDDeviceTools.cancel                    0x6edf0   ( 60 指令)
//    method.PDDeviceTools.execute:arguments:completion: 0x6ee2c (608 指令)
//    func.0006f08c  错误信封构造器（被 execute 调 3 次）
//    func.0006f158  主线程门（generation 复核 + 转投执行队列）
//    func.0006f280  执行队列体（权限复核 → 执行 → 回主线程）
//    func.0006f530  回主线程收尾（清 inFlight → 权限复核 → 回调）
//
//  ivar 偏移（来自 class_ro）：
//    0x08 BOOL inFlight
//    0x10 prepareHandler (copy)
//    0x18 queue (strong)
//    0x20 executor (strong)
//    0x28 generation (assign, 64-bit)
//

#import "PDDeviceTools.h"
#import "PDDeviceToolsDeclarations.h"
#import <Foundation/Foundation.h>

#pragma mark - 常量

// Observed（init 中 dispatch_queue_create 的 label，0xbf235）
static NSString *const kPDDeviceToolsQueueLabel = @"com.susudear.petdfy.device-tools";

// Observed（0x110640）：主线程门发现 generation 已变时投递的信封
static NSDictionary *PDDeviceToolsPausedResult(void) {
    return @{ @"failed"  : @YES,
              @"images"  : @[],
              @"receipt" : @"设备已暂停或本轮被打断，操作未执行。" };
}

// Observed（0x110668）：执行队列发现 generation 已变时用的信封
static NSDictionary *PDDeviceToolsInterruptedResult(void) {
    return @{ @"failed"  : @YES,
              @"images"  : @[],
              @"receipt" : @"本轮被打断，操作未执行。" };
}

// Observed（0x6eef8–0x6f064，三段拼装）：
//   keys   = ["receipt", "failed", "images"]
//   values = [<文案>, @YES, @[]]
//   文案由 inFlight 决定：忙 → 上一项未返回；否则 → 不可用/参数无效
static NSDictionary *PDDeviceToolsRejectedResult(BOOL busy) {
    NSString *message = busy ? @"上一项原生设备操作尚未返回，请稍后重试。"
                             : @"设备操作不可用或参数无效。";
    return @{ @"receipt" : message,
              @"failed"  : @YES,
              @"images"  : @[] };
}

// Observed（func.0006f08c，0x6f08c–0x6f150）：把权限文案包成失败信封
static NSDictionary *PDDeviceToolsEnvelope(NSString *receipt) {
    return @{ @"receipt" : receipt ?: @"",
              @"failed"  : @YES,
              @"images"  : @[] };
}

#pragma mark -

@implementation PDDeviceTools

// Observed（0x6ed64）：[super init] → 建串行队列 → 建 executor。
// 队列 label 逐字为 com.susudear.petdfy.device-tools，attr 传 0（默认串行）。
- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _queue = dispatch_queue_create("petdfy.deviceTools", DISPATCH_QUEUE_SERIAL);
    _tools = [NSMutableDictionary new];
    [self setGeneration:[self generation] + 1];
    return self;
}


// Observed（0x6edf0）：整体是尾调用 setGeneration:，x2 = generation + 1。
// 不碰 inFlight —— 取消靠代数失配让在途回调自行发现。
- (void)cancel {
    self.generation = self.generation + 1;
}

// Observed（0x6ee2c，608 指令）。四道前置门 + 三级跳（主线程门 → 执行队列 → 回主线程）。
//
//   门 1  权限文案非空            → 直接回失败信封
//   门 2  PDIsDeviceTool(name)
//         && [arguments isKindOfClass:NSDictionary]
//         && prepareHandler 非空  → 回「不可用/参数无效」
//   门 3  inFlight == YES        → 回「上一项未返回」
//   门 4  记下 generation、置 inFlight = YES
//
// 之后 dispatch_async(主队列)：
//      generation 变了 → inFlight = NO，回「设备已暂停」
//      否则 dispatch_async(执行队列)：
//          权限再查一次 → 变了回「本轮被打断」→ 否则执行 → 回主队列收尾
// 收尾：inFlight = NO，权限再查一次，有错回信封，无错回结果。
//
// 注：permission 在三个位置各查一次（进门、队列体、收尾），不是冗余——
//     prepareHandler 可能已经改变了授权状态。
- (void)execute:(NSString *)name
      arguments:(NSDictionary *)arguments
     completion:(void (^)(NSDictionary *))completion {
    if (!completion) {
        return;
    }

    NSString *permissionError = PDDeviceToolPermissionError(name, arguments);
    if (permissionError) {
        completion(PDDeviceToolsEnvelope(permissionError));
        return;
    }

    if (!PDIsDeviceTool(name) ||
        ![arguments isKindOfClass:[NSDictionary class]] ||
        !self.prepareHandler) {
        completion(PDDeviceToolsRejectedResult(self.inFlight));
        return;
    }

    if (self.inFlight) {
        completion(PDDeviceToolsRejectedResult(YES));
        return;
    }

    const unsigned long long generation = self.generation;
    self.inFlight = YES;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.generation != generation) {
            self.inFlight = NO;
            completion(PDDeviceToolsPausedResult());
            return;
        }

        dispatch_async(self.queue, ^{
            @autoreleasepool {
                NSDictionary *result = nil;

                NSString *queuePermissionError = PDDeviceToolPermissionError(name, arguments);
                if (queuePermissionError) {
                    result = PDDeviceToolsEnvelope(queuePermissionError);
                } else if (self.generation != generation) {
                    result = PDDeviceToolsInterruptedResult();
                } else {
                    // Observed（0x6f318）：执行结果直接交给 PDDeviceToolResult，
                    // 由它返回完整信封（receipt / failed / images），此处不再二次包装。
                    result = PDDeviceToolResult([self.executor execute:name
                                                              arguments:arguments]);
                }

                dispatch_async(dispatch_get_main_queue(), ^{
                    self.inFlight = NO;

                    NSString *finishError = PDDeviceToolPermissionError(name, arguments);
                    if (finishError) {
                        completion(PDDeviceToolsEnvelope(finishError));
                    } else {
                        completion(result);
                    }
                });
            }
        });
    });
}

#pragma mark - 访问器（ivar 直取，反汇编里全是 4–8 条指令的 getter/setter）

- (void (^)(void))prepareHandler {
    return _prepareHandler;
}

- (void)setPrepareHandler:(void (^)(void))prepareHandler {
    _prepareHandler = [prepareHandler copy];
}

- (id)queue {
    return _queue;
}

- (void)setQueue:(id)queue {
    _queue = queue;
}

- (id)executor {
    return _executor;
}

- (void)setExecutor:(id)executor {
    _executor = executor;
}

- (unsigned long long)generation {
    return _generation;
}

- (void)setGeneration:(unsigned long long)generation {
    _generation = generation;
}

- (BOOL)inFlight {
    return _inFlight;
}

- (void)setInFlight:(BOOL)inFlight {
    _inFlight = inFlight;
}

@end

// ============================================================================
//  还原保真账本
// ============================================================================
//
//  Observed（直接来自反汇编）
//    1. init 的队列 label = "com.susudear.petdfy.device-tools"，attr = 0
//    2. init 里 executor = objc_opt_new(PDDeviceNativeExecutor)
//    3. cancel 是尾调用 setGeneration:，实参 generation + 1，不改 inFlight
//    4. execute 的四道门顺序：权限文案 → isDeviceTool/参数类型/prepareHandler
//       → inFlight → 记 generation 并置 inFlight
//    5. 三级跳：dispatch_get_main_queue → self.queue → dispatch_get_main_queue
//    6. 权限检查在三个位置各做一次（0x6ee5c / 0x6f2c8 / 0x6f58c）
//    7. 三段信封文案逐字：
//         设备已暂停或本轮被打断，操作未执行。
//         本轮被打断，操作未执行。
//         上一项原生设备操作尚未返回，请稍后重试。
//         设备操作不可用或参数无效。
//         设备操作异常：%@（catch 分支的格式串，0x1059f0）
//    8. 信封键固定三个：receipt / failed / images；failed 恒 @YES，
//       images 恒 __NSArray0__struct（@[]），receipt 放文案
//    9. 忙/不忙的文案选择是 csel：inFlight != 0 → 忙文案，否则不可用文案
//
//  Inferred（从指令序列推导，未见源码）
//    A. 队列体里的 @autoreleasepool 边界（0x6f2b0 起 objc_autoreleasePoolPush）
//    B. catch 分支捕获 NSException 后取 name/reason 拼 "设备操作异常：%@"
//    C. 收尾块在清 inFlight 之后才再查权限——顺序由 0x6f530 前 20 条确定
//
//  Assumed（无法从二进制确认）
//    i. completion 在 result 为 nil 时是否会崩溃（未加保护，与二进制一致）
//   ii. prepareHandler 的调用时机——反汇编里只检查非空、从未调用；
//       推测由外部（PDRootController）在挂 handler 时自行触发
//
//  NOT RUN
//    - 无 iOS 运行环境，未做实机时序验证；队列嵌套顺序按指令顺序推定
//
// ============================================================================
