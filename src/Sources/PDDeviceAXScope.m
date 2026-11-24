//
//  PDDeviceAXScope.m — 逆向还原实现
//
//  还原依据：PetDFY.arm64e.dylib
//    closeOnMain            0x700d0   82 条
//    finish                 0x70218   25 条
//    +recoverInterruptedScope 0x6f8c8  60 条
//    +acquireWith...error:  0x6fac0  ~110 条（含主队列块体 0x6fce4）
//    +acquireWithError:     0x6ffe4   36 条
//
//  性质：辅助功能（AX）查询的作用域守卫。
//    1) acquire 在后台线程建 scope，主队列里"先读当前值 → 需要就写开 → 记录 → 定时收尾"；
//    2) 同一时刻只允许一个活 scope（全局 weak 槽 0x124038）；
//    3) 收尾一律回主队列，closeOnMain 负责把 AX 状态写回原值。
//
//  常量表（__cfstring，char* 在 +0x10，已 fix）：
//    0x105cf0  "DeviceAXRestorePending"
//    0x1014d0  "com.susudear.petdfyprefs"
//    0x105d10  "应用辅助功能接口不可用"
//    0x105d30  "应用辅助功能未及时就绪；本次未读取元素，也不会重试。"
//    0xc5d48   double 1e9（秒 → 纳秒）
//    0xc6020   double 1.2（acquireWithError: 的默认 warmup）
//

#import "PDDeviceAXScope.h"
#include <dlfcn.h>

static NSString *const kPDDeviceAXRestorePendingKey = @"DeviceAXRestorePending";
static NSString *const kPDDeviceAXPrefsAppID = @"com.susudear.petdfyprefs";
static NSString *const kPDDeviceAXErrorUnavailable = @"应用辅助功能接口不可用";
static NSString *const kPDDeviceAXErrorNotReady = @"应用辅助功能未及时就绪；本次未读取元素，也不会重试。";

// 私有 Accessibility 符号（AXRuntime / AXRuntime.framework）：二进制用 dlsym(RTLD_DEFAULT, ...) 取地址，
// 取不到就把对应 block 置 nil（0x6f9a0 / 0x6fa30 的 objc_retainBlock 之后接 cbz 判断）。
//   块体 0x70390: ldr x8,[x0,0x20]; blraaz x8; cset w0, ne   → ^BOOL(void)
//   块体 0x703b4: ldr x2,[x0,0x20]; mov x0,x1; braaz x2      → ^void(BOOL)
typedef Boolean (*PDAXSAccessibilityEnabledFn)(void);
typedef void (*PDAXSAccessibilitySetEnabledFn)(Boolean);

// 全局 weak 槽：0x124000 + 0x38 = 0x124038
static __weak PDDeviceAXScope *gPDDeviceAXActiveScope;

#pragma mark - 私有符号的两个 block 构造器
//
// 0x6f9a0：dlsym(RTLD_DEFAULT, "_AXSApplicationAccessibilityEnabled") → 捕获进块；
//          块体 0x70390: ldr x8,[x0,0x20]; blraaz x8; cset w0,ne   → ^BOOL(void)
//          符号缺失时块为 nil（调用方 0x6f914 / 0x6fb0c 用 cbz 判）
// 0x6fa30：dlsym(RTLD_DEFAULT, "_AXSApplicationAccessibilitySetEnabled") → 捕获进块；
//          块体 0x703b4: ldr x2,[x0,0x20]; mov x0,x1; braaz x2     → ^void(BOOL)
static PDDeviceAXReadBlock PDAXSMakeEnabledBlock(void) {
    PDAXSAccessibilityEnabledFn fn =
        (PDAXSAccessibilityEnabledFn)dlsym(RTLD_DEFAULT, "_AXSApplicationAccessibilityEnabled");
    if (!fn) return nil;
    return ^BOOL(void) {
        return fn() != 0;
    };
}

static PDDeviceAXWriteBlock PDAXSMakeSetEnabledBlock(void) {
    PDAXSAccessibilitySetEnabledFn fn =
        (PDAXSAccessibilitySetEnabledFn)dlsym(RTLD_DEFAULT, "_AXSApplicationAccessibilitySetEnabled");
    if (!fn) return nil;
    return ^void(BOOL on) {
        fn((Boolean)(on ? 1 : 0));
    };
}

// 全局常量 block：0xf9ff0（isa __NSConcreteGlobalBlock，flags 0x50000000 = BLOCK_IS_GLOBAL，
// 无捕获，invoke 0x70074）。acquireWithError: 把它当 mark 传下去。
//   0x70084  ldr x8,[0xf8000+0xbd8] → kCFBooleanTrue（bind 行 378）
//   0x70090  cmp w1,#0 / csel x1, x8, xzr, ne  → value = pending ? kCFBooleanTrue : NULL
//   0x700ac  CFPreferencesSetAppValue(@"DeviceAXRestorePending", value, @"com.susudear.petdfyprefs")
//   0x700cc  CFPreferencesAppSynchronize(appID)
static void (^ const kPDDeviceAXMarkRestoreBlock)(BOOL) = ^(BOOL pending) {
    CFStringRef key = (__bridge CFStringRef)kPDDeviceAXRestorePendingKey;
    CFStringRef appID = (__bridge CFStringRef)kPDDeviceAXPrefsAppID;
    CFPreferencesSetAppValue(key, (CFPropertyListRef)(pending ? kCFBooleanTrue : NULL), appID);
    CFPreferencesAppSynchronize(appID);
};

@implementation PDDeviceAXScope

- (BOOL)closed { return _closed; }
- (void)setClosed:(BOOL)v { _closed = v; }

- (BOOL)changed { return _changed; }
- (void)setChanged:(BOOL)v { _changed = v; }

- (BOOL)ready { return _ready; }
- (void)setReady:(BOOL)v { _ready = v; }

@synthesize readState = _readState;
@synthesize writeState = _writeState;
@synthesize markRestore = _markRestore;

#pragma mark - 收尾

/// 0x700d0，82 条指令。主线程收尾：幂等关闭 + 解绑全局槽 + 把 AX 状态写回。
///   0x700e8  bl 0xa99a0 (closed) / tbnz → return      幂等
///   0x700f8  bl 0xb1780 (setClosed:YES)
///   0x70104  objc_loadWeakRetained(&0x124038) → cmp 指针 → 相等才 objc_storeWeak(nil)
///   0x7012c  bl 0xa97e0 (changed) / cbz → return       没改过就不写回
///   0x70138  bl 0xb6b60 (writeState) → invoke(arg=0)   无 nil 检查
///   0x7015c  bl 0xafd20 (readState)  → invoke          无 nil 检查
///   0x70174  cbz w0 → 0x70180                         读回仍是关的才补 mark
///   0x70184  bl 0xadf60 (markRestore) / 0x701a4 再取一次 → invoke(arg=0)
/// 逐条还原（imp 0x6c18c）。
///   0x6c1a0/0x6c1a4 已 closed → 返回
///   0x6c1b0  setClosed:YES
///   0x6c1b4..0x6c1dc 弱引用静态槽（0x11c038）若指向 self → 置空
///   0x6c1e4/0x6c1e8 changed 为假 → 跳过
///   0x6c1f0..0x6c204 取 writeState 块并以 NO 调用
///   0x6c210..0x6c22c 取 readState 块：返回 YES 则只释放；NO 则继续
///   0x6c234..0x6c268 取 markRestore 块并以 NO 调用
- (void)closeOnMain {
    if ([self closed]) return;
    [self setClosed:YES];

    // 全局弱引用（原版 0x11c038 静态槽）指向自己时清空
    if (gPDDeviceAXActiveScope == self) gPDDeviceAXActiveScope = nil;   // 0x6c1c8/0x6c1dc

    if ([self changed]) {
        void (^write)(BOOL) = [self writeState];
        if (write) write(NO);
    }

    BOOL (^read)(void) = [self readState];
    BOOL restored = read ? read() : NO;
    if (!restored) {
        void (^mark)(BOOL) = [self markRestore];
        if (mark) mark(NO);
    }
}

/// 0x70218，25 条指令。收尾入口：保证 closeOnMain 在主线程执行。
///   0x7021c bl 0xad320（isMainThread）→ tbnz w0,0 → 0x70260: b 0xa9980（closeOnMain 桩）
///   否则 dispatch_sync(0xf8000+0xba0 = 主队列, ^{ closeOnMain })  块体 0x702cc
- (void)finish {
    if ([NSThread isMainThread]) {
        [self closeOnMain];
        return;
    }
    dispatch_sync(dispatch_get_main_queue(), ^{
        [self closeOnMain];
    });
}

#pragma mark - 恢复上次被中断的作用域

/// 0x6f8c8，60 条指令。启动时若上次留下 "DeviceAXRestorePending" 标记，
/// 就把 AX 关掉并清标记（上次进程被杀死时没来得及恢复）。
///   0x6f8dc  cfstring 0x105cf0 "DeviceAXRestorePending"
///   0x6f8ec  bl _CFPreferencesGetAppBooleanValue(key, 0x1014d0 appID, NULL)
///   0x6f8f4  cbz w0 → return                        没标记就什么都不做
///   0x6f8f8  bl 0x6f9a0  → read 块（_AXSApplicationAccessibilityEnabled）
///   0x6f904  bl 0x6fa30  → write 块（_AXSApplicationAccessibilitySetEnabled）
///   0x6f914  cbz read / cbz write → 0x6f968         任一符号缺失就放弃
///   0x6f92c  write(NO)                              先关
///   0x6f940  read() 非 0 → 0x6f968 直接返回          已经关了就不用清标记
///   0x6f95c  CFPreferencesSetAppValue(key, NULL, appID) + CFPreferencesAppSynchronize(appID)
+ (void)recoverInterruptedScope {
    CFStringRef key = (__bridge CFStringRef)kPDDeviceAXRestorePendingKey;
    CFStringRef appID = (__bridge CFStringRef)kPDDeviceAXPrefsAppID;

    if (!CFPreferencesGetAppBooleanValue(key, appID, NULL)) return;

    BOOL (^isEnabled)(void) = PDAXSMakeEnabledBlock();
    void (^setEnabled)(BOOL) = PDAXSMakeSetEnabledBlock();
    if (!isEnabled || !setEnabled) return;

    setEnabled(NO);
    if (isEnabled()) return;          // 关不掉：保留标记，下次再试

    CFPreferencesSetAppValue(key, NULL, appID);
    CFPreferencesAppSynchronize(appID);
}

#pragma mark - 申请作用域

/// 0x6fac0，主体 + 主队列块体 0x6fce4（约 130 条）。
/// 参数：x2=read x3=write x4=mark d0=warmup d1=duration x5=error
///
///   0x6fad8  if (error) *error = nil
///   0x6fae4  [NSThread isMainThread]（0xad320）
///   0x6fb04  cbz write / cbz read / cbnz main → 0x6fc84 失败：*error = 0x105d10
///   0x6fb28  objc_opt_new → scope
///   0x6fb30  setReadState: / setWriteState: / setMarkRestore:   (0xb3980/0xb4c60/0xb2f80)
///   0x6fbc0  dispatch_semaphore_create(0)
///   0x6fbe4  dispatch_async(主队列, 块 0x6fce4)
///   0x6fbf8  dispatch_semaphore_wait(sem, dispatch_time(0, duration*1e9))
///   0x6fc20  wait != 0 → 失败
///   0x6fc28  ready == 0 → 失败
///   0x6fc30  closed != 0 → 失败
///   0x6fcd8  成功：objc_retain(scope) 后返回
///   失败     [scope finish]（0xabc60）+ *error = 0x105d30，返回 nil
///
/// 块体 0x6fce4 捕获布局：+0x20 self +0x28 sem +0x30 read +0x38 mark +0x40 write
///                       +0x48 warmup +0x50 duration
+ (id)acquireWithRead:(PDDeviceAXReadBlock)read
                write:(PDDeviceAXWriteBlock)write
                 mark:(PDDeviceAXMarkBlock)mark
               warmup:(double)warmup
             duration:(double)duration
                error:(NSError **)error {
    if (error) *error = nil;

    BOOL onMain = [NSThread isMainThread];
    if (!write || !read || onMain) {
        if (error) *error = (NSError *)kPDDeviceAXErrorUnavailable;
        return nil;
    }

    PDDeviceAXScope *scope = [PDDeviceAXScope new];
    [scope setReadState:read];
    [scope setWriteState:write];
    [scope setMarkRestore:mark];

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    // 块体 0x6fce4：主队列执行
    dispatch_async(dispatch_get_main_queue(), ^{
        // 已有别的 scope 或自己已关闭：立刻放行，不做任何写入
        if ([scope closed]) {
            dispatch_semaphore_signal(sem);
            return;
        }
        PDDeviceAXScope *active = gPDDeviceAXActiveScope;
        if (active && ![active closed]) {
            dispatch_semaphore_signal(sem);
            return;
        }
        gPDDeviceAXActiveScope = scope;

        // 先读当前 AX 状态；关着就打开，并记下"改过"以便收尾写回
        if (!read()) {
            [scope setChanged:YES];
            if (mark) mark(YES);
            write(YES);
        }
        [scope setReady:read()];

        // duration 到点自动收尾
        dispatch_after(dispatch_time(0, (int64_t)(duration * (double)NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [scope finish];
        });

        // 改过就等 warmup 秒再放行，否则立即放行
        int64_t delay = 0;
        if ([scope changed]) delay = (int64_t)(warmup * (double)NSEC_PER_SEC);
        dispatch_after(dispatch_time(0, delay), dispatch_get_main_queue(), ^{
            dispatch_semaphore_signal(sem);
        });
    });

    long waitResult = dispatch_semaphore_wait(sem,
        dispatch_time(0, (int64_t)(duration * (double)NSEC_PER_SEC)));

    if (waitResult != 0 || ![scope ready] || [scope closed]) {
        [scope finish];
        if (error) *error = (NSError *)kPDDeviceAXErrorNotReady;
        return nil;
    }
    return scope;
}

/// 0x6ffe4，36 条指令。便捷入口：read/write 用两个私有符号的 block，
/// mark 用全局常量 block（0xf9ff0，写 "DeviceAXRestorePending" 标记），
/// warmup = 1.2（0xc6020），duration = 3.0（fmov d1,#3.0）。
///   0x70000  bl 0x6f9a0 → read 块     → x21 → x2
///   0x7000c  bl 0x6fa30 → write 块    → x22 → x3
///   0x70018  adrp/add 0xf9000+0xff0 = 0xf9ff0 → x4（mark 常量块）
///   0x70024  ldr d0,[0xc6000+0x20] = 1.2
///   0x70028  fmov d1,#3.0
///   0x70038  x5 = error
///   0x7003c  bl 0xa8660（acquireWithRead:write:mark:warmup:duration:error: 桩）
+ (id)acquireWithError:(NSError **)error {
    PDDeviceAXReadBlock read = PDAXSMakeEnabledBlock();
    PDDeviceAXWriteBlock write = PDAXSMakeSetEnabledBlock();
    return [self acquireWithRead:read
                           write:write
                            mark:kPDDeviceAXMarkRestoreBlock
                          warmup:1.2
                        duration:3.0
                           error:error];
}

#pragma mark - 保真账本
//
//  Observed（逐条从反汇编 / 数据段读出，可用给定命令复核）
//    · selector 名（resolve.py）：
//        isMainThread 0xad320 · closed 0xa99a0 · finish 0xabc60 · ready 0xafd40
//        changed 0xa97e0 · setChanged: 0xb1660 · setClosed: 0xb1780
//        setReadState: 0xb3980 · setWriteState: 0xb4c60 · setMarkRestore: 0xb2f80
//        setReady: 0xb39a0 · writeState getter 0xb6b60 · readState getter 0xafd20
//        markRestore getter 0xadf60 · acquireWithRead:... 0xa8660
//    · cfstring 原文（flags 0x7c8 = ASCII / 0x7d0 = UTF-16，char* 在 +0x10，rebase 低位直取）：
//        0x105cf0 "DeviceAXRestorePending"
//        0x1014d0 "com.susudear.petdfyprefs"
//        0x105d10 "应用辅助功能接口不可用"
//        0x105d30 "应用辅助功能未及时就绪；本次未读取元素，也不会重试。"
//    · 两个私有符号名（0x6f9a0 / 0x6fa30 里的 C 字符串）：
//        "_AXSApplicationAccessibilityEnabled" / "_AXSApplicationAccessibilitySetEnabled"
//    · double 常量：0xc5000+0xd48 = 1e9；0xc6020 = 1.2
//    · 全局 weak 槽 0x124038；主队列槽 0xf8000+0xba0 = GOT 0xf8ba0，
//      chained fixup bind 序号 371 → 导入表 __dispatch_main_q（即 dispatch_get_main_queue()）
//    · 失败路径把 cfstring 直接写进 *error（x22 非空时 str x8,[x22]），
//      即 error 实际收到的是 NSString 而非 NSError —— 原二进制如此，忠实保留 (id) 强转。
//    · acquire 的参数寄存器：x2=read x3=write x4=mark x5=error d0=warmup d1=duration
//      （0x6faec fmov d9,d0 / 0x6fae8 fmov d8,d1）；捕获布局
//      block+0x20 self +0x28 sem +0x30 read +0x38 mark +0x40 write
//      +0x48 duration +0x50 warmup（0x6fbe0 stp d8,d9,[sp,0x50]）
//    · 块体 0x6fce4 里第一个 dispatch_after 用 +0x48（duration）→ [scope finish]，
//      第二个用 +0x50（warmup，且仅当 changed 为真，否则 dispatch_time(0,0)）→ signal(sem)
//    · closeOnMain 对 writeState / readState 无 nil 检查（0x70144 / 0x70168 直接 invoke），
//      对 markRestore 有 nil 检查（0x7019c cbz x20）
//
//  Inferred（有依据，非逐条确证）
//    · 块体对 readState/writeState/markRestore 的调用走 getter（不是直接读 ivar），
//      等价于 self.readState()，源码层面写成 [_readState copy] 亦可，此处用属性访问。
//    · 0x6fd44 的 tbz w22,0 判的是「已有活跃 scope 且未关闭」，即 bail 条件为
//      (w && ![w closed])。
//
//  Assumed（无法从二进制确证，按语义补全）
//    · kCFBooleanTrue 即 CFBoolean 真值（bind 行 378，符号名已核对）。
//    · mark(YES) 表示「已改动，收尾需恢复」；mark(NO) 表示「恢复动作本身」。
//    · write(YES) 表示打开 AX；write(NO) 表示关闭。
//
//  NOT RUN（本机无 iOS 运行时，仅 -fsyntax-only）
//    · 全部方法的运行时行为验证；AX 私有符号在真机上的实际返回。

@end

