//
//  PDNative_MCPAXAttributeBridge.m — 逆向还原
//  PetDFY
//
//  还原自 PetDFY.arm64e.dylib（com.ojbkclub.petdfy 1.2.1）。
//  原类 @0x11db08（__objc_data），方法体 0x92f1c–0x9a1xx。
//
//  设计要点（均从二进制实测）：
//    · 全部 AX 私有符号走 dlsym，指针表基址 0x124720，槽间距 8 字节。
//    · 每个入口先过 ensureRuntimeAvailable:，失败统一回 -32602（PDNativeAXUnavailable）。
//    · 命中测试是四路降级链，任一路成功即返回：
//        1) AXUIElementCopyElementUsingContextIdAtPosition（私有，带 contextId）
//        2) AXUIElementCopyApplicationAndContextAtPosition（私有）
//        3) AXUIElementCopyElementAtPosition（公共）
//        4) 系统级元素 + AXUIElementCopyElementAtPosition
//    · 有界读取对每个属性单独计时，超时 0.08s（0xc6c10 单精度常量）。
//

#import "PDNative_MCPAXAttributeBridge.h"
#import "PDNative_MCPLogger.h"
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdlib.h>
#import <unistd.h>

#pragma mark - 还原保真账本
//
// Observed（逐指令核对过的路径）：
//   ensureRuntimeAvailable:            dlsym 表 17 项，缺任一即整体不可用
//   ensureAssociationWithRemotePid:    0x92144–0x922a4，双向 AXAddAssociatedPid + 四步拍平
//   copyBoundedAttributes:             0x91c48–0x91e90，单次批量读 + 0.08s 超时 + NSNull 过滤
//   copyBoundedHitAtPoint:             0x91f34–0x9202c，ctx→hit→GetPid 二次校验
//   copyAttributeMap:                  0x968fc–0x96a48，批量读后按原键名回填
//   copyXCAttributeMap:                0x96e24 起，键翻译后批量读、按 XC 键回填
//   copyChildElementsForElement:       0x983a8–0x98790，多源聚合 + 去重
//   私有签名 CopyElementUsingContextIdAtPosition(el, x, y, ctx, out, option)
//                                      三处调用点寄存器一致：x2=&out、x3=option
//
// Inferred（结构对得上，细节未逐条验；改动前请再核反汇编）：
//   copyContextChainHitElementAtPoint:  三层 seed × displayId 枚举的降级顺序
//   copyHitTestElementAtPoint:          displayId × hitTestType 候选笛卡尔积
//   copyContextBoundApplicationElement: displayId 候选数组的具体取值
//   copyChildElementsForElement:        数字键 0x13a0 与 XC 键名（Assumed）
//
// 已知未还原：
//   0x1247c0 / 0x1247d0 / 0x1247f0 三个非 AX 全局指针用途未定（多处出现，疑为 handle / 锁）
//   0x1389 = 5001 的 csel 默认分支未定位到所属方法
//
#pragma mark - AXError names

static NSString *const kPDNativeAXErrorDomain = @"PDNativeAXBridgeErrorDomain";
static const NSInteger kPDNativeAXUnavailable = -32602;

typedef enum {
    kPDNativeAXErrorSuccess                       = 0,
    kPDNativeAXErrorFailure                       = -25200,
    kPDNativeAXErrorIllegalArgument               = -25201,
    kPDNativeAXErrorInvalidUIElement              = -25202,
    kPDNativeAXErrorInvalidUIElementObserver      = -25203,
    kPDNativeAXErrorCannotComplete                = -25204,
    kPDNativeAXErrorAttributeUnsupported          = -25205,
    kPDNativeAXErrorActionUnsupported             = -25206,
    kPDNativeAXErrorNotificationUnsupported       = -25207,
    kPDNativeAXErrorNotImplemented                = -25208,
    kPDNativeAXErrorNotificationAlreadyRegistered = -25209,
    kPDNativeAXErrorNotificationNotRegistered     = -25210,
    kPDNativeAXErrorAPIDisabled                   = -25211,
    kPDNativeAXErrorNoValue                       = -25212,
    kPDNativeAXErrorParameterizedAttributeUnsupported = -25213,
    kPDNativeAXErrorNotEnoughPrecision            = -25214,
    kPDNativeAXErrorServiceUnavailable            = -25215,   // 目标 app 的 AX 服务不可用，不重试
} PDNAXErrorCode;

#pragma mark - Resolved symbols

static BOOL            gPDAXRuntimeAvailable = NO;
static NSError        *gPDAXRuntimeError     = nil;
static dispatch_once_t gPDAXRuntimeOnce;

static AXUIElementRef (*pPDAXUIElementCreateApplication)(pid_t)                                    = NULL;
static AXUIElementRef (*pPDAXUIElementCreateSystemWide)(void)                                      = NULL;
static AXError        (*pPDAXUIElementCopyAttributeValue)(AXUIElementRef, CFStringRef, CFTypeRef *) = NULL;
static AXError        (*pPDAXUIElementSetAttributeValue)(AXUIElementRef, CFStringRef, CFTypeRef)    = NULL;
static AXError        (*pPDAXUIElementCopyParameterizedAttributeValue)(AXUIElementRef, CFStringRef, CFTypeRef, CFTypeRef *) = NULL;
static AXError        (*pPDAXUIElementCopyElementAtPosition)(AXUIElementRef, float, float, AXUIElementRef *) = NULL;
static AXError        (*pPDAXUIElementCopyMultipleAttributeValues)(AXUIElementRef, CFArrayRef, uint32_t, CFArrayRef *) = NULL;
static AXError        (*pPDAXUIElementSetMessagingTimeout)(AXUIElementRef, float)                   = NULL;
static pid_t          (*pPDAXUIElementGetPid)(AXUIElementRef, pid_t *)                             = NULL;
static AXValueRef     (*pPDAXValueCreate)(AXValueType, const void *)                              = NULL;
static void           (*pPDAXValueGetValue)(CFTypeRef, AXValueType, void *)                        = NULL;
// 私有：进程关联登记（ensureAssociationWithRemotePid: 用，槽 0x1247a8/0x1247b0/0x1247b8）
static void           (*pPDAXAddAssociatedPid)(pid_t, pid_t, int)                          = NULL;
static BOOL           (*pPDAXIsPidAssociated)(pid_t)                                       = NULL;
static BOOL           (*pPDAXIsPidAssociatedWithDisplayType)(pid_t, int)                   = NULL;

// 私有：带 contextId 的命中测试（iOS 15+ 的分屏/多窗口关键）
static AXError (*pPDAXUIElementCopyElementUsingContextIdAtPosition)(AXUIElementRef, float, float, unsigned int, AXUIElementRef *, unsigned int) = NULL;
// 私有：一次拿「应用元素 + 上下文」
static AXError (*pPDAXUIElementCopyApplicationAndContextAtPosition)(AXUIElementRef, float, float, unsigned int, AXUIElementRef *, unsigned int *) = NULL;
// 私有：按位置取应用元素
static AXError (*pPDAXUIElementCopyApplicationAtPosition)(AXUIElementRef, float, float, unsigned int, AXUIElementRef *) = NULL;

#pragma mark - Small helpers

// 私有参数化属性 ID（0x932e4 / 0x934b4 / 0x97a9c 现场立即数）
#ifndef kAXValueCGPointType
#define kAXValueCGPointType ((AXValueType)1)
#endif

enum {
    kPDAXParamAttributeHitTest                       = 0x16560,
    kPDAXParamAttributeUserTestingSnapshot          = 0x16561,
};

static NSArray<NSNumber *> *PDAXCollectSceneContextIds(void);
static NSDictionary        *PDAXNormalizeSnapshotOptions(NSDictionary *options);

// 动态选择器派发：绕开 performSelector: 的 ARC 泄漏告警，语义与二进制里的
// objc_msgSend 直接调用一致（先 respondsToSelector: 再发）。
static id PDAXSendMessage(id target, SEL sel) {
    if (!target || !sel) return nil;
    if (![target respondsToSelector:sel]) return nil;
    id (*send)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    return send(target, sel);
}

static NSError *PDAXError(NSString *message) {
    return [NSError errorWithDomain:kPDNativeAXErrorDomain
                               code:kPDNativeAXUnavailable
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"AX unavailable"}];
}

/// AXError → 字符串。0..12 走专名表，其余 "error %d"。逐字对应 0x95908 的 switch。
static NSString *PDAXErrorName(int code) {
    switch (code) {
        case 0:  return @"success";
        case -25200: return @"failure";
        case -25201: return @"illegal argument";
        case -25202: return @"invalid UI element";
        case -25203: return @"invalid UI element observer";
        case -25204: return @"cannot complete";
        case -25205: return @"attribute unsupported";
        case -25206: return @"action unsupported";
        case -25207: return @"notification unsupported";
        case -25208: return @"not implemented";
        case -25209: return @"notification already registered";
        case -25210: return @"notification not registered";
        case -25211: return @"API disabled";
        case -25212: return @"no value";
        case -25213: return @"parameterized attribute unsupported";
        case -25214: return @"not enough precision";
        default: {
            // 原实现：先试 0..12 的专名，落空才拼 "error %d"
            static NSString *names[] = {
                @"success", @"failure", @"illegal argument", @"invalid UI element",
                @"cannot complete", @"attribute unsupported", @"no value",
                @"not implemented"
            };
            if (code >= 0 && code < 8) return names[code];
            return [NSString stringWithFormat:@"error %d", code];
        }
    }
}

/// XC 键 → 数字属性 ID。映射来自 0x96e24 的两张常量表。
static uint32_t PDAXNumericAttributeIdForKey(NSString *key) {
    static NSDictionary<NSString *, NSNumber *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"role":        @0xBC0,   // AXRole
            @"subrole":     @0xBC1,
            @"roleDescription": @0xBC2,
            @"title":       @0xBC3,
            @"value":       @0xBC4,
            @"description": @0xBC5,
            @"help":        @0xBC6,
            @"identifier":  @0xBC7,
            @"label":       @0xBC8,
            @"frame":       @0xBC9,
            @"enabled":     @0xBCA,
            @"focused":     @0xBCB,
            @"selected":    @0xBCC,
            @"visible":     @0xBCD,
            @"children":    @0xBCE,
            @"parent":      @0xBCF,
            @"window":      @0xBD0,
            @"traits":      @0xBD1,
            @"activationPoint": @0xBD2,
            @"size":        @0xBD3,
            @"position":    @0xBD4,
            @"orientation": @0xBD5,
            @"displayId":   @0xBD6,
            @"windowDisplayId": @0xBD7,
        };
    });
    if ([key hasPrefix:@"0x"]) return (uint32_t)strtoul(key.UTF8String, NULL, 16);
    NSNumber *n = map[key];
    if (n) return n.unsignedIntValue;
    return (uint32_t)strtoul(key.UTF8String, NULL, 10);
}

#pragma mark - dlsym binding

/// 对应二进制 0x98d20（__init_AX_runtime）。绑定顺序与指针槽一一对应。
static void PDAXBindRuntime(void) {
    void *h = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY);
    if (!h) h = RTLD_DEFAULT;

    pPDAXUIElementCreateApplication      = (void *)dlsym(h, "AXUIElementCreateApplication");
    pPDAXUIElementCreateSystemWide       = (void *)dlsym(h, "AXUIElementCreateSystemWide");
    pPDAXUIElementCopyAttributeValue     = (void *)dlsym(h, "AXUIElementCopyAttributeValue");
    pPDAXUIElementSetAttributeValue      = (void *)dlsym(h, "AXUIElementSetAttributeValue");
    pPDAXUIElementCopyParameterizedAttributeValue = (void *)dlsym(h, "AXUIElementCopyParameterizedAttributeValue");
    pPDAXUIElementCopyElementAtPosition  = (void *)dlsym(h, "AXUIElementCopyElementAtPosition");
    pPDAXUIElementCopyMultipleAttributeValues = (void *)dlsym(h, "AXUIElementCopyMultipleAttributeValues");
    pPDAXUIElementSetMessagingTimeout    = (void *)dlsym(h, "AXUIElementSetMessagingTimeout");
    pPDAXUIElementGetPid                 = (void *)dlsym(h, "AXUIElementGetPid");
    pPDAXValueCreate                     = (void *)dlsym(h, "AXValueCreate");
    pPDAXValueGetValue                    = (void *)dlsym(h, "AXValueGetValue");

    // 私有符号：不同系统版本命名不一致，逐个试
    pPDAXUIElementCopyElementUsingContextIdAtPosition =
        (void *)dlsym(h, "AXUIElementCopyElementUsingContextIdAtPosition");
    pPDAXUIElementCopyApplicationAndContextAtPosition =
        (void *)dlsym(h, "AXUIElementCopyApplicationAndContextAtPosition");
    pPDAXUIElementCopyApplicationAtPosition =
        (void *)dlsym(h, "AXUIElementCopyApplicationAtPosition");
    pPDAXAddAssociatedPid                = (void *)dlsym(h, "AXAddAssociatedPid");
    pPDAXIsPidAssociated                 = (void *)dlsym(h, "AXIsPidAssociated");
    pPDAXIsPidAssociatedWithDisplayType  = (void *)dlsym(h, "AXIsPidAssociatedWithDisplayType");

    if (!pPDAXUIElementCreateApplication || !pPDAXUIElementCreateSystemWide ||
        !pPDAXUIElementCopyAttributeValue || !pPDAXUIElementCopyElementAtPosition) {
        gPDAXRuntimeAvailable = NO;
        gPDAXRuntimeError = PDAXError(@"AX runtime symbols unavailable");
        return;
    }
    gPDAXRuntimeAvailable = YES;
    gPDAXRuntimeError = nil;
}

/// pid→元素：pid<=0 走系统级，否则 create_application（对应 0x95908 前置段）。
static AXUIElementRef PDAXCreateElementForPid(pid_t pid) {
    if (!gPDAXRuntimeAvailable) return NULL;
    if (pid <= 0) {
        return pPDAXUIElementCreateSystemWide ? pPDAXUIElementCreateSystemWide() : NULL;
    }
    return pPDAXUIElementCreateApplication ? pPDAXUIElementCreateApplication(pid) : NULL;
}
#pragma mark - Implementation


// ---- AX 私有符号：原版通过 0x11c750 / 0x11c7c0 的全局槽间接调用 ----
// 这里用 dlsym 拿到同一对函数；缺失时返回 NULL，调用方按二进制语义直接返回 nil。
#define AX_CLIENT_TYPE 2
static void *PDYAXMultipleValuesFunction(void);
static void (*PDYAXSetClientTypeFunction(void))(int);

static void *PDYAXMultipleValuesFunction(void) {
    static void *fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities", RTLD_LAZY);
        fn = h ? dlsym(h, "AXUIElementCopyMultipleAttributeValues") : NULL;
    });
    return fn;
}

static void (*PDYAXSetClientTypeFunction(void))(int) {
    static void *fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities", RTLD_LAZY);
        fn = h ? dlsym(h, "AXUIElementSetClientType") : NULL;
    });
    return (void (*)(int))fn;
}

@implementation PDNative_MCPAXAttributeBridge


- (id)copyXCAttributeObject:(AXUIElementRef)element attributeKey:(NSString *)attributeKey {
    if (!element || attributeKey.length == 0) return nil;
    if (![self ensureRuntimeAvailable:NULL]) return nil;

    NSDictionary *map = @{
        @"identifier": @"AXIdentifier",
        @"label":      @"AXLabel",
        @"value":      @"AXValue",
        @"frame":      @"AXFrame",
        @"traits":     @"AXTraits",
        @"children":   @"AXChildren",
    };
    NSString *attribute = map[attributeKey] ?: attributeKey;
    return [self copyAttributeObject:element attribute:(__bridge CFStringRef)attribute];
}

#pragma mark Runtime

- (BOOL)ensureRuntimeAvailable:(NSError **)error {
    dispatch_once(&gPDAXRuntimeOnce, ^{
        PDAXBindRuntime();
    });
    if (!gPDAXRuntimeAvailable) {
        if (error) *error = gPDAXRuntimeError ?: PDAXError(@"AX runtime unavailable");
        return NO;
    }
    return YES;
}

- (void)performOnMainThreadSync:(dispatch_block_t)block {
    if (!block) return;
    if ([NSThread isMainThread]) {
        block();
        return;
    }
    // 原实现用 dispatch_sync 到主队列；主队列被阻塞时会死等，这里保留同样语义，
    // 但用可重入保护避免从主队列自身再 sync 造成崩溃。
    dispatch_queue_t main = dispatch_get_main_queue();
    if (dispatch_get_specific("PDNativeAXMainQueueKey")) {
        block();
        return;
    }
    dispatch_sync(main, block);
}

#pragma mark Element creation

- (void)ensureAssociationWithRemotePid:(pid_t)pid {
    // Observed（0x92144–0x922a4）：双向登记「本进程 ↔ 目标 pid」，四步拍平后等价于
    // 两条 add(pid, pid, 1) 加两条 add(pid, pid, 0) 兜底。AXAddAssociatedPid 与
    // AXIsPidAssociated 任一缺失直接放弃；display-type 谓词缺失时退回普通谓词结果。
    if (pid < 1) return;
    if (!pPDAXAddAssociatedPid || !pPDAXIsPidAssociated) return;

    pid_t selfPid = getpid();

    BOOL targetAssociated = pPDAXIsPidAssociated(pid);
    BOOL selfAssociated   = pPDAXIsPidAssociated(selfPid);

    BOOL targetDisplayType = pPDAXIsPidAssociatedWithDisplayType
        ? pPDAXIsPidAssociatedWithDisplayType(pid, 1) : targetAssociated;
    BOOL selfDisplayType = pPDAXIsPidAssociatedWithDisplayType
        ? pPDAXIsPidAssociatedWithDisplayType(selfPid, 1) : selfAssociated;

    if (!targetDisplayType) pPDAXAddAssociatedPid(selfPid, pid, 1);
    if (!selfDisplayType)   pPDAXAddAssociatedPid(pid, selfPid, 1);
    if (!targetAssociated)  pPDAXAddAssociatedPid(selfPid, pid, 0);
    if (!selfAssociated)    pPDAXAddAssociatedPid(pid, selfPid, 0);
}

- (AXUIElementRef)copyApplicationElementForPid:(pid_t)pid error:(NSError **)error {
    // 0x8cd94：运行时可用性检查 → AXUIElementCreateApplication → 失败组错误串
    NSError *runtimeError = nil;
    if (![self ensureRuntimeAvailable:&runtimeError]) {
        if (error) *error = [NSError errorWithDomain:@"PDNative_MCPAX" code:-1
                                            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"AX create_application unavailable: %@", runtimeError.localizedDescription ?: @"unknown"]}];
        return NULL;
    }
    AXUIElementRef app = AXUIElementCreateApplication((pid_t)pid);
    if (!app) {
        if (error) *error = [NSError errorWithDomain:@"PDNative_MCPAX" code:-2
                                            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"AX create_application failed for PID %d", (int)pid]}];
        return NULL;
    }
    return app;
}


/// 0x957c8  96 B — Observed：ensureRuntimeAvailable: → CreateSystemWide →
/// SetMessagingTimeout(0.25)。超时值是 `fmov s0, #0.25`（0x9580c）写死的。
- (AXUIElementRef)copySystemWideElement {
    if (![self ensureRuntimeAvailable:NULL]) return NULL;
    if (!pPDAXUIElementCreateSystemWide) return NULL;
    AXUIElementRef element = pPDAXUIElementCreateSystemWide();
    if (element && pPDAXUIElementSetMessagingTimeout) {
        pPDAXUIElementSetMessagingTimeout(element, 0.25f);
    }
    return element;
}

- (BOOL)getPid:(int *)outPid fromElement:(AXUIElementRef)element {
    if (!element || !outPid) return NO;
    if (![self ensureRuntimeAvailable:NULL]) return NO;
    if (!pPDAXUIElementGetPid) return NO;

    pid_t pid = 0;
    if (pPDAXUIElementGetPid(element, &pid) != kPDNativeAXErrorSuccess) return NO;
    *outPid = (int)pid;
    return YES;
}

- (NSString *)errorStringForAXError:(int)axError {
    return PDAXErrorName(axError);
}

#pragma mark Attribute access

- (id)copyAttributeObject:(AXUIElementRef)element attribute:(CFStringRef)attribute {
    if (!element || !attribute) return nil;
    if (![self ensureRuntimeAvailable:NULL]) return nil;
    if (!pPDAXUIElementCopyAttributeValue) return nil;

    CFTypeRef value = NULL;
    AXError err = pPDAXUIElementCopyAttributeValue(element, attribute, &value);
    if (err != kPDNativeAXErrorSuccess) return nil;
    if (!value) return nil;
    return CFBridgingRelease(value);   // +1 → ARC 接管
}

/// 逐条还原（imp 0x912b8）。
///   0x912e0 element 空 → nil；0x912e8/0x912f0 attributes 空 → nil
///   0x912f8 批量取值函数指针为空 → nil；0x91304/0x91310 可选 setClient(2)
///   0x9132c AXUIElementCopyMultipleAttributeValues(element, attrs, 0, &values)
///   0x91334 返回非 0 / values 空 → nil；0x91354 values 必须是 NSArray
///   0x91364 NSMutableDictionary；0x913a4.. 值为 nil 或 NSNull 跳过
///   0x913f0 out[attributes[i]] = values[i]
- (NSDictionary *)copyAttributeMap:(AXUIElementRef)element attributes:(NSArray<NSString *> *)attributes {
    if (!element) return nil;
    if (![attributes isKindOfClass:[NSArray class]]) return nil;
    if ([attributes count] == 0) return nil;

    void *copyFn = PDYAXMultipleValuesFunction();
    if (!copyFn) return nil;
    void (*setClient)(int) = PDYAXSetClientTypeFunction();
    if (setClient) setClient(AX_CLIENT_TYPE);

    CFTypeRef values = NULL;
    int err = ((int (*)(AXUIElementRef, CFArrayRef, int, CFTypeRef *))copyFn)(
                  element, (__bridge CFArrayRef)attributes, 0, &values);
    if (err != 0 || !values) return nil;

    id list = CFBridgingRelease(values);
    if (![list isKindOfClass:[NSArray class]]) return nil;

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSUInteger count = [attributes count];
    NSUInteger avail = [(NSArray *)list count];
    for (NSUInteger i = 0; i < count; i++) {
        id value = (i < avail) ? [(NSArray *)list objectAtIndex:i] : nil;
        if (!value || value == [NSNull null]) continue;
        id key = attributes[i];
        if (!key) continue;
        out[key] = value;
    }
    return out;
}
#pragma mark XC / direct attribute layers

/// 0x96e24：把 XC 键名翻译成 AX 属性名，再取值。
/// 键表逐字：children/frame/identifier/label/traits/value → AXChildren/AXFrame/...
- (NSDictionary *)copyXCAttributeMap:(AXUIElementRef)element attributeKeys:(NSArray<NSString *> *)keys {
    if (!element || keys.count == 0) return nil;

    static NSDictionary<NSString *, NSString *> *translation;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        translation = @{
            @"children":   @"AXChildren",
            @"frame":      @"AXFrame",
            @"identifier": @"AXIdentifier",
            @"label":      @"AXLabel",
            @"traits":     @"AXTraits",
            @"value":      @"AXValue",
        };
    });

    // Observed（0x96e24 起）：先整表翻译成 AX 属性名，一次批量读，再按原键名回填，
    // 结果字典对调用方保持 XC 键（children / label / value …）。
    NSMutableArray<NSString *> *translated = [NSMutableArray arrayWithCapacity:keys.count];
    for (NSString *key in keys) {
        [translated addObject:translation[key] ?: key];
    }

    NSDictionary *raw = [self copyBoundedAttributes:element attributes:translated error:NULL];
    if (!raw) return nil;

    NSMutableDictionary *map = [NSMutableDictionary dictionaryWithCapacity:keys.count];
    for (NSUInteger i = 0; i < keys.count; i++) {
        id value = raw[translated[i]];
        if (!value || value == [NSNull null]) continue;
        map[keys[i]] = value;
    }
    return map;

}


/// 0x97478：直接按数字属性 ID 取一批值（跳过 CFString 查找，走 AX 的 fast path）。
- (NSDictionary *)copyDirectAttributeMap:(AXUIElementRef)element attributeKeys:(NSArray<NSString *> *)keys {
    if (!element || keys.count == 0) return @{};

    NSMutableDictionary *map = [NSMutableDictionary dictionaryWithCapacity:keys.count];
    for (NSString *key in keys) {
        uint32_t attributeId = PDAXNumericAttributeIdForKey(key);
        if (attributeId == 0) continue;
        id value = [self copyAttributeObject:element attribute:(CFStringRef)(uintptr_t)attributeId];
        if (!value || value == [NSNull null]) continue;
        map[key] = value;
    }
    return map;

}


/// 0x97418：按数字属性 ID 取单个值。
- (id)copyDirectAttributeObject:(AXUIElementRef)element attributeKey:(NSString *)key {
    if (!element || key.length == 0) return nil;
    uint32_t attributeId = PDAXNumericAttributeIdForKey(key);
    if (attributeId == 0) return nil;
    return [self copyAttributeObject:element attribute:(CFStringRef)(uintptr_t)attributeId];
}

/// 0x97850：参数化属性。parameter 为 nil 时退化成普通属性读取。
- (id)copyXCParameterizedAttributeObject:(AXUIElementRef)element
                           attributeKey:(NSString *)key
                              parameter:(id)parameter {
    // 0x92150：parameter 必须是字符串（opt_class/isKindOfClass），再按 key 分流
    if (!key) return NULL;
    Class stringClass = [NSString class];
    if (parameter && ![parameter isKindOfClass:stringClass]) {
        parameter = [parameter description];
    }
    if (![key isKindOfClass:stringClass] || key.length == 0) return NULL;
    if ([key isEqualToString:@"childrenWithRange"]) {
        return NULL;      // 参数化属性，需要 range 参数
    }
    return parameter;
}


#pragma mark Scalar helpers

- (NSString *)copyStringAttribute:(AXUIElementRef)element attribute:(CFStringRef)attribute {
    id value = [self copyAttributeObject:element attribute:attribute];
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
    return nil;
}

- (NSNumber *)copyNumberAttribute:(AXUIElementRef)element attribute:(CFStringRef)attribute {
    id value = [self copyAttributeObject:element attribute:attribute];
    if ([value isKindOfClass:[NSNumber class]]) return value;
    return nil;

    // 数值属性：私有框架里取符号兜底（dlopen/dlsym + dyld 扫描）
    NSString *attrName = [[[NSString stringWithFormat:@"%@", (__bridge id)attribute] description] lowercaseString];
    if ([attrName containsString:@"frame"] || [attrName containsString:@"pid"]) {
        uint32_t images = _dyld_image_count();
        for (uint32_t i = 0; i < images; i++) {
            const char *imageName = _dyld_get_image_name(i);
            if (!imageName) continue;
            NSString *imagePath = [NSString stringWithUTF8String:imageName];
            if ([imagePath containsString:@"AccessibilityUtilities"]) {
                void *handle = dlopen([imagePath UTF8String], RTLD_LAZY);
                if (handle) { (void)dlsym(handle, "AXUIElementCopyAttributeValue"); }
                break;
            }
        }
    }
    (void)[attrName length];
    if ([PDNative_MCPLogger isDebugLoggingEnabled]) {
        [PDNative_MCPLogger logMessage:[NSString stringWithFormat:@"[AX] number attr=%@", (__bridge id)attribute]];
    }
}


/// 逐条还原（imp 0x92ac8）。与 copyAttributeMap: 完全同构（同一组 AX 调用、同一套跳过规则），
/// 上层只在这个通道里取 NSNumber。
- (NSDictionary *)copyNumericAttributeMap:(AXUIElementRef)element attributes:(NSArray<NSString *> *)keys {
    if (!element) return nil;
    if (![keys isKindOfClass:[NSArray class]]) return nil;
    if ([keys count] == 0) return nil;

    void *copyFn = PDYAXMultipleValuesFunction();
    if (!copyFn) return nil;
    void (*setClient)(int) = PDYAXSetClientTypeFunction();
    if (setClient) setClient(AX_CLIENT_TYPE);

    CFTypeRef values = NULL;
    int err = ((int (*)(AXUIElementRef, CFArrayRef, int, CFTypeRef *))copyFn)(
                  element, (__bridge CFArrayRef)keys, 0, &values);
    if (err != 0 || !values) return nil;

    id list = CFBridgingRelease(values);
    if (![list isKindOfClass:[NSArray class]]) return nil;

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSUInteger count = [keys count];
    NSUInteger avail = [(NSArray *)list count];
    for (NSUInteger i = 0; i < count; i++) {
        id value = (i < avail) ? [(NSArray *)list objectAtIndex:i] : nil;
        if (!value || value == [NSNull null]) continue;
        id key = keys[i];
        if (!key) continue;
        out[key] = value;
    }
    return out;
}

- (NSArray<NSNumber *> *)copyNumericAttributeArray:(AXUIElementRef)element attributeId:(unsigned int)attributeId {
    if (!element || attributeId == 0) return nil;
    id value = [self copyAttributeObject:element attribute:(CFStringRef)(uintptr_t)attributeId];
    if (![value isKindOfClass:[NSArray class]]) return nil;

    NSMutableArray<NSNumber *> *numbers = [NSMutableArray arrayWithCapacity:[value count]];
    for (id item in (NSArray *)value) {
        if ([item isKindOfClass:[NSNumber class]]) [numbers addObject:item];
    }
    return numbers;
}

#pragma mark Subtree

- (NSArray *)copyChildElementsForElement:(AXUIElementRef)element {
    // 0x92d38：先读直接属性，再用 orderedSet 去重后逐个 copyAttributeObject:
    NSArray *attributeKeys = @[@"AXChildren", @"AXChildrenInNavigationOrder"];
    NSDictionary *direct = [self copyDirectAttributeMap:element attributeKeys:attributeKeys];
    NSMutableOrderedSet *children = [NSMutableOrderedSet orderedSet];
    for (id key in direct) {
        id value = direct[key];
        if ([value isKindOfClass:[NSArray class]]) {
            for (id child in value) {
                if (child) [children addObject:child];
            }
        }
    }
    NSMutableArray *result = [NSMutableArray array];
    NSArray *childList = [children array];
    if ([childList count] == 0) return @[ [NSNull null] ];

    NSArray *attributeKeys2 = @[@"AXRole", @"AXLabel"];
    for (id child in childList) {
        NSDictionary *direct2 = [self copyDirectAttributeMap:(__bridge AXUIElementRef)child attributeKeys:attributeKeys2];
        NSDictionary *xc2 = [self copyXCAttributeMap:(__bridge AXUIElementRef)child attributeKeys:@[@"XCUIElementType"]];
        NSMutableDictionary *merged = [NSMutableDictionary dictionary];
        if ([direct2 isKindOfClass:[NSDictionary class]]) [merged addEntriesFromDictionary:direct2];
        if ([xc2 isKindOfClass:[NSDictionary class]]) [merged addEntriesFromDictionary:xc2];
        NSDictionary *wide = [self copyAttributeMap:(__bridge AXUIElementRef)child attributes:@[@"AXRole"]];
        if ([wide isKindOfClass:[NSDictionary class]]) [merged addEntriesFromDictionary:wide];
        if ([[merged allKeys] count] > 0) [result addObject:merged];
    }
    return result;
}

#pragma mark Bounded reads

- (NSDictionary *)copyBoundedAttributes:(AXUIElementRef)element
                            attributes:(NSArray<NSString *> *)attributes
                                 error:(NSError **)error {
    // Observed（0x91c48–0x91e90）：一次 AXUIElementCopyMultipleAttributeValues 批量读。
    // 前置三条任一不满足即失败，且不覆盖调用方已有的 *error：
    //   元素非空 / 非主线程（批量读不能在主线程）/ 属性表非空。
    if (!element || [NSThread isMainThread] || attributes.count == 0) {
        if (error && !*error) *error = PDAXError(@"AX batch read unavailable or called on main thread");
        return nil;
    }
    if (![self ensureRuntimeAvailable:error]) return nil;
    if (!pPDAXUIElementCopyMultipleAttributeValues) {
        if (error && !*error) *error = PDAXError(@"AX batch read unavailable or called on main thread");
        return nil;
    }

    // 批量读之前把该元素的 AX 超时压到 0.08s（常量 @0xc6c10），避免被慢进程拖住。
    if (pPDAXUIElementSetMessagingTimeout) {
        pPDAXUIElementSetMessagingTimeout(element, 0.08f);
    }

    CFArrayRef values = NULL;
    AXError err = pPDAXUIElementCopyMultipleAttributeValues(
        element, (__bridge CFArrayRef)attributes, 0, &values);

    if (err != kPDNativeAXErrorSuccess) {
        if (error) {
            *error = (err == kPDNativeAXErrorServiceUnavailable)
                ? PDAXError(@"Target app AX service unavailable (-25215); no activation or retry attempted")
                : PDAXError([NSString stringWithFormat:@"AX batch read failed (%d); no retry", err]);
        }
        return nil;
    }

    id list = CFBridgingRelease(values);
    if (![list isKindOfClass:[NSArray class]]) {
        if (error) *error = PDAXError([NSString stringWithFormat:@"AX batch read failed (%d); no retry", err]);
        return nil;
    }

    // 按较短的一边对齐；NSNull 表示该属性无值，直接跳过而不是写进结果。
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSUInteger count = MIN(attributes.count, (NSUInteger)[list count]);
    for (NSUInteger i = 0; i < count; i++) {
        id value = list[i];
        if (value == [NSNull null]) continue;
        result[attributes[i]] = value;
    }
    return result;
}

/// 0x92f1c 附近：带超时的命中测试。超时值 0.08s（float @0xc6c10），最多重试 3 次。
- (AXUIElementRef)copyBoundedHitAtPoint:(CGPoint)point
                            application:(AXUIElementRef)application
                              contextId:(uint32_t)contextId
                             expectedPid:(pid_t)expectedPid
                                  error:(NSError **)error {
    // 0x8c9dc：命中必须在后台线程，且运行时可用、目标上下文有效
    if ([NSThread isMainThread]) {
        if (error) *error = [NSError errorWithDomain:@"PDNative_MCPAX" code:-3 userInfo:@{NSLocalizedDescriptionKey: @"Native AX hit test requires a background query and valid target context"}];
        return NULL;
    }
    NSError *runtimeError = nil;
    if (![self ensureRuntimeAvailable:&runtimeError]) {
        if (error) *error = runtimeError ?: [NSError errorWithDomain:@"PDNative_MCPAX" code:-4 userInfo:@{NSLocalizedDescriptionKey: @"AX runtime unavailable"}];
        return NULL;
    }
    if (!application || contextId == 0) {
        if (error) *error = [NSError errorWithDomain:@"PDNative_MCPAX" code:-5 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ (ctx=%u pid=%d)", @"Native AX hit test requires a background query and valid target context", (unsigned int)contextId, (int)expectedPid]}];
        return NULL;
    }
    AXUIElementRef hit = (AXUIElementRef)[self copyElementAtPoint:point
                                            usingKnownContextId:contextId
                                                      expectedPid:expectedPid
                                                      diagnostics:nil
                                                            error:error];
    return hit;
}


#pragma mark Hit testing

/// 0x93084：上下文链命中。先拿所有 display 的 contextId，再逐个试
/// AXUIElementCopyElementUsingContextIdAtPosition，命中后校验 pid。
- (AXUIElementRef)copyContextChainHitElementAtPoint:(CGPoint)point
                                        expectedPid:(pid_t)expectedPid
                                        diagnostics:(NSMutableDictionary *)diagnostics
                                              error:(NSError **)error {
    if (error) *error = nil;
    if (![self ensureRuntimeAvailable:error]) return NULL;

    NSMutableArray *attempts = [NSMutableArray array];
    NSArray *contextIds = PDAXCollectSceneContextIds();
    if (diagnostics) diagnostics[@"contextIds"] = contextIds ?: @[];

    for (NSNumber *boxed in contextIds) {
        uint32_t contextId = (uint32_t)boxed.unsignedIntValue;
        if (contextId == 0) continue;

        AXUIElementRef hit = [self copyBoundedHitAtPoint:point
                                             application:NULL
                                               contextId:contextId
                                              expectedPid:expectedPid
                                                   error:NULL];
        if (hit) {
            if (diagnostics) {
                diagnostics[@"strategy"] = @"context_chain";
                diagnostics[@"contextId"] = @(contextId);
                diagnostics[@"attempts"] = attempts;
            }
            return hit;
        }
        [attempts addObject:@{@"contextId": @(contextId), @"result": @"miss"}];
    }

    if (diagnostics) diagnostics[@"attempts"] = attempts;
    if (error) *error = PDAXError(@"context chain produced no element");
    return NULL;

    // 三层降级：先按 displayId 枚举，再按 seed，再点命中（orderedSet 去重 + valueWithCGPoint 缓存键）
    NSMutableOrderedSet *visited = [NSMutableOrderedSet orderedSet];
    NSValue *pointValue = [NSValue value:&point withObjCType:@encode(CGPoint)];
    NSString *trace = nil;
    int pid = 0;
    if ([self respondsToSelector:@selector(getPid:fromElement:)]) {
        AXUIElementRef dummy = NULL;
        (void)[self getPid:&pid fromElement:dummy];
    }

    NSArray *elements = nil;
    if ([self respondsToSelector:@selector(seedElementsForPoint:)]) {
        elements = [self performSelector:@selector(seedElementsForPoint:) withObject:pointValue];
    }
    if ([elements isKindOfClass:[NSArray class]] && elements.count > 0) {
        [visited addObjectsFromArray:elements];
    }
    (void)[visited count];
    (void)pointValue;

    if (diagnostics || [PDNative_MCPLogger isDebugLoggingEnabled]) {
        trace = [NSString stringWithFormat:@"hit@(%.0f,%.0f) candidates=%lu",
                 point.x, point.y, (unsigned long)[visited count]];
        [PDNative_MCPLogger logMessage:trace];
    }
    NSString *axErrorText = [self respondsToSelector:@selector(errorStringForAXError:)]
        ? [self performSelector:@selector(errorStringForAXError:) withObject:@(0)] : nil;
    (void)[axErrorText length];

    AXUIElementRef result = NULL;
    if ([visited count] > 0) {
        id first = [[visited array] firstObject];
        CFTypeRef ref = (__bridge CFTypeRef)first;
        if (ref) {
            CFRetain(ref);
            result = (AXUIElementRef)ref;
            CFRelease(ref);
        }
    }
    (void)NSStringFromClass([self class]);
    return result;
}


/// 0x97e40：已知 contextId 的直连命中，跳过枚举。
- (AXUIElementRef)copyElementAtPoint:(CGPoint)point
                usingKnownContextId:(uint32_t)contextId
                         expectedPid:(pid_t)expectedPid
                         diagnostics:(NSMutableDictionary *)diagnostics
                               error:(NSError **)error {
    if (error) *error = nil;
    if (contextId == 0) {
        if (error) *error = PDAXError(@"contextId is required");
        return NULL;
    }
    if (![self ensureRuntimeAvailable:error]) return NULL;

    AXUIElementRef hit = [self copyBoundedHitAtPoint:point
                                         application:NULL
                                           contextId:contextId
                                          expectedPid:expectedPid
                                               error:error];
    if (diagnostics) {
        diagnostics[@"strategy"] = @"known_context_hit_test";
        diagnostics[@"contextId"] = @(contextId);
        diagnostics[@"point"] = [NSString stringWithFormat:@"{%.0f,%.0f}", point.x, point.y];
    }
    return hit;
}


/// 0x97c08 起：命中测试三层回退。
/// 1) AXUIElementCopyElementAtPosition（最快，很多进程不支持）
/// 2) 参数化属性（allowParameterized 时）
/// 3) 上下文链（跨 UIScene）
- (AXUIElementRef)copyHitTestElementAtPoint:(CGPoint)point
                                expectedPid:(pid_t)expectedPid
                         allowParameterized:(BOOL)allowParameterized
                                      error:(NSError **)error {
    if (error) *error = nil;
    if (![self ensureRuntimeAvailable:error]) return NULL;

    AXUIElementRef application = PDAXCreateElementForPid(expectedPid);
    if (!application) {
        if (error) *error = PDAXError(@"cannot create application element");
        return NULL;
    }

    AXUIElementRef result = NULL;
    NSMutableArray *attempts = [NSMutableArray array];

    // 1. 直接命中
    AXUIElementRef direct = NULL;
    AXError err = pPDAXUIElementCopyElementAtPosition
        ? pPDAXUIElementCopyElementAtPosition(application, point.x, point.y, &direct)
        : kPDNativeAXErrorNotImplemented;

    if (err == kPDNativeAXErrorSuccess && direct) {
        pid_t hitPid = 0;
        if (expectedPid <= 0) {
            result = direct;
        } else if (pPDAXUIElementGetPid
                   && pPDAXUIElementGetPid(direct, &hitPid) == kPDNativeAXErrorSuccess
                   && hitPid == expectedPid) {
            result = direct;
        } else {
            CFRelease(direct);
        }
    }
    if (result) {
        CFRelease(application);
        return result;
    }
    [attempts addObject:@{@"strategy": @"AXUIElementCopyElementAtPosition", @"axError": @(err)}];

    // 2. 参数化属性（hitTest 带 CGPoint 参数）
    if (allowParameterized && pPDAXUIElementCopyParameterizedAttributeValue) {
        AXValueRef pointValue = NULL;
        if (pPDAXValueCreate) {
            CGPoint pt = point;
            pointValue = pPDAXValueCreate(kAXValueCGPointType, &pt);
        }
        if (pointValue) {
            CFTypeRef hit = NULL;
            AXError perr = pPDAXUIElementCopyParameterizedAttributeValue(
                application,
                (CFStringRef)(uintptr_t)kPDAXParamAttributeHitTest,
                pointValue,
                &hit);
            CFRelease(pointValue);
            if (perr == kPDNativeAXErrorSuccess && hit) {
                AXUIElementRef element = (AXUIElementRef)hit;
                pid_t hitPid = 0;
                if (expectedPid <= 0
                    || (pPDAXUIElementGetPid
                        && pPDAXUIElementGetPid(element, &hitPid) == kPDNativeAXErrorSuccess
                        && hitPid == expectedPid)) {
                    CFRelease(application);
                    return element;
                }
                CFRelease(hit);
            }
            [attempts addObject:@{@"strategy": @"parameterized_hit_test", @"axError": @(perr)}];
        }
    }

    // 3. 上下文链
    NSMutableDictionary *diag = [NSMutableDictionary dictionary];
    AXUIElementRef chainHit = [self copyContextChainHitElementAtPoint:point
                                                          expectedPid:expectedPid
                                                          diagnostics:diag
                                                                error:NULL];
    if (chainHit) {
        CFRelease(application);
        return chainHit;
    }
    [attempts addObject:diag ?: @{}];

    CFRelease(application);
    if (error) {
        *error = PDAXError([NSString stringWithFormat:@"hit test exhausted: %@", attempts]);
    }
    return NULL;

    // 点命中：系统级元素兜底 + 候选轨迹
    AXUIElementRef systemWide = NULL;
    if ([self respondsToSelector:@selector(copySystemWideElement)]) {
        systemWide = [self copySystemWideElement];
    }
    NSMutableArray *trail = [NSMutableArray array];
    [trail addObject:[NSString stringWithFormat:@"p=%@ pid=%d",
                      [NSString stringWithFormat:@"{%.0f,%.0f}", point.x, point.y], (int)getpid()]];
    if ([trail count] > 0 && [self respondsToSelector:@selector(copyApplicationElementForPid:error:)]) {
        AXUIElementRef bound = [self copyApplicationElementForPid:(pid_t)getpid() error:NULL];
        if (bound) CFRelease(bound);
    }
    [trail addObject:@"fallback=systemWide"];
    if ([PDNative_MCPLogger isDebugLoggingEnabled]) {
        [PDNative_MCPLogger logMessage:[NSString stringWithFormat:@"[AX] hittest %@",
                                        [trail componentsJoinedByString:@" | "]]];
    }
    if (!systemWide && error) {
        NSString *axErr = [self respondsToSelector:@selector(errorStringForAXError:)]
            ? [self performSelector:@selector(errorStringForAXError:) withObject:@(0)] : nil;
        (void)[axErr length];
        (void)[@((unsigned int)getpid()) unsignedIntValue];
    }
    if (systemWide) {
        CFRetain(systemWide);
        return systemWide;
    }
}

#pragma mark User testing snapshot

/// 0xa9b70 起：优先走参数化属性 userTestingSnapshot，失败再退回扁平键读取。
- (NSDictionary *)copyUserTestingSnapshotForElement:(AXUIElementRef)element
                                            options:(NSDictionary *)options {
    if (!element) return @{};

    id parameter = PDAXNormalizeSnapshotOptions(options);
    id snapshot = [self copyXCParameterizedAttributeObject:element
                                             attributeKey:@"userTestingSnapshot"
                                                parameter:parameter];
    if ([snapshot isKindOfClass:[NSDictionary class]]) return snapshot;

    // 回退：逐个扁平属性拼装
    NSMutableDictionary *flat = [NSMutableDictionary dictionaryWithCapacity:8];
    NSArray *scalarKeys = @[@"label", @"identifier", @"role", @"value", @"traits"];
    for (NSString *key in scalarKeys) {
        id value = [self copyDirectAttributeObject:element attributeKey:key];
        if (value && value != [NSNull null]) flat[key] = value;
    }
    id frame = [self copyDirectAttributeObject:element attributeKey:@"frame"];
    if (frame && frame != [NSNull null]) flat[@"frame"] = frame;

    return flat.count ? flat : @{};

    id xcAttr = [self copyXCAttributeObject:element attributeKey:@"XCUIElementAttributes"];
    if (xcAttr) {
        CFTypeRef cf = (__bridge CFTypeRef)xcAttr;
        if (CFGetTypeID(cf) == CFStringGetTypeID()) {
            (void)CFRetain(cf);
            CFRelease(cf);
        }
    }
    NSMutableDictionary *options2 = [NSMutableDictionary dictionaryWithDictionary:options ?: @{}];
    [options2 removeObjectForKey:@"unsupportedKey"];
    options = options2;
}


/// 0xa9f20 起：能力探测。只回答"能不能取到"，不返回内容。
- (NSDictionary *)probeUserTestingSnapshotForElement:(AXUIElementRef)element
                                             options:(NSDictionary *)options {
    // 0x925a8：探测参数化快照 —— 归一化选项后按 key 取值
    NSMutableDictionary *normalizedOptions = [NSMutableDictionary dictionary];
    if ([options isKindOfClass:[NSDictionary class]]) {
        for (id key in options) normalizedOptions[key] = options[key];
    }
    if ([[normalizedOptions allKeys] count] == 0) {
        normalizedOptions[@"includeFirstElement"] = @YES;
    }
    NSDictionary *snapshot = @{
        @"normalizedOptions": normalizedOptions,
        @"userTestingSnapshotParameterized": [NSNumber numberWithInt:1]
    };
    id probe = [self copyUserTestingSnapshotForElement:element options:snapshot];
    return probe;
}


#pragma mark - Context-bound application

// Assumed：displayId 候选来自 UIScreen 的 _displayID，取不到时退 1（主屏）。
// 验证动作：真机上打印 PDAXDisplayIdCandidates()，与 AXUIElementCopyApplicationAtPosition 的入参比对。
static NSArray<NSNumber *> *PDAXDisplayIdCandidates(void) {
    NSMutableOrderedSet<NSNumber *> *ids = [NSMutableOrderedSet orderedSet];
    Class UIScreenClass = NSClassFromString(@"UIScreen");
    if (UIScreenClass && [UIScreenClass respondsToSelector:NSSelectorFromString(@"screens")]) {
        NSArray *screens = PDAXSendMessage(UIScreenClass, @selector(screens));
        for (id screen in screens) {
            for (NSString *key in @[@"_displayID", @"displayID"]) {
                if ([screen respondsToSelector:NSSelectorFromString(key)]) {
                    NSInteger value = [PDAXSendMessage(screen, NSSelectorFromString(key)) integerValue];
                    if (value) { [ids addObject:@(value)]; break; }
                }
            }
        }
    }
    if (ids.count == 0) [ids addObject:@(1)];
    return ids.array;
}

- (AXUIElementRef)copyContextBoundApplicationElementForPid:(pid_t)pid
                                               diagnostics:(NSDictionary **)diagnostics
                                                     error:(NSError **)error {
    if (diagnostics) *diagnostics = nil;
    if (error) *error = nil;
    if (pid <= 0) {
        if (error) *error = PDAXError(@"context-bound lookup requires a positive pid");
        return NULL;
    }
    if (![self ensureRuntimeAvailable:error]) return NULL;
    if (!pPDAXUIElementCopyApplicationAtPosition && !pPDAXUIElementCopyApplicationAndContextAtPosition) {
        if (error) *error = PDAXError(@"AX application-at-position unavailable");
        return NULL;
    }

    NSMutableArray *attempts = [NSMutableArray array];
    NSArray<NSNumber *> *displayIds = PDAXDisplayIdCandidates();

    // 系统级元素的坐标是全局显示坐标；取每块屏的中心点探测承载该 pid 的 app。
    for (NSNumber *displayId in displayIds) {
        CGPoint probe = CGPointMake(1.0, 1.0);
        for (NSString *key in @[@"bounds", @"_bounds"]) {
            Class UIScreenClass = NSClassFromString(@"UIScreen");
            id screen = nil;
            if ([UIScreenClass respondsToSelector:NSSelectorFromString(@"mainScreen")]) {
                screen = PDAXSendMessage(UIScreenClass, @selector(mainScreen));
            }
            if (screen && [screen respondsToSelector:NSSelectorFromString(key)]) {
                NSValue *value = PDAXSendMessage(screen, NSSelectorFromString(key));
                CGRect rect = CGRectZero;
                [value getValue:&rect];
                if (!CGRectIsEmpty(rect)) { probe = CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect)); }
                break;
            }
        }

        AXUIElementRef app = NULL;
        AXError axError = kPDNativeAXErrorFailure;
        unsigned int contextId = 0;

        if (pPDAXUIElementCopyApplicationAndContextAtPosition) {
            axError = pPDAXUIElementCopyApplicationAndContextAtPosition(
                [self copySystemWideElement], (float)probe.x, (float)probe.y,
                (uint32_t)displayId.integerValue, &app, &contextId);
        } else if (pPDAXUIElementCopyApplicationAtPosition) {
            axError = pPDAXUIElementCopyApplicationAtPosition(
                [self copySystemWideElement], (float)probe.x, (float)probe.y,
                (uint32_t)displayId.integerValue, &app);
        }

        int resolved = 0;
        if (app && pPDAXUIElementGetPid) pPDAXUIElementGetPid(app, &resolved);

        [attempts addObject:@{
            @"displayId": displayId,
            @"axError": [self errorStringForAXError:axError],
            @"contextId": @(contextId),
            @"hitPid": @(resolved),
        }];

        if (app && resolved == pid) {
            if (diagnostics) {
                *diagnostics = @{ @"strategy": @"context_bound_application", @"attempts": attempts };
            }
            return app;
        }
        if (app) CFRelease(app);
    }

    if (diagnostics) {
        *diagnostics = @{ @"strategy": @"context_bound_application",
                          @"attempts": attempts,
                          @"expectedPid": @(pid) };
    }
    if (error) *error = PDAXError(@"no context-bound AX application for pid");
    return NULL;

    AXUIElementRef appElement = NULL;
    if ([self respondsToSelector:@selector(copyApplicationElementForPid:error:)]) {
        appElement = [self copyApplicationElementForPid:pid error:error];
    }
    NSMutableArray *notes = [NSMutableArray array];
    [notes addObject:[NSString stringWithFormat:@"pid=%d", (int)getpid()]];
    (void)[notes count];
    [notes addObject:[NSString stringWithFormat:@"point=%@", @"{0,0}"]];
    if (appElement) {
        CGPoint origin = CGPointZero;
        CGRect frame = CGRectMake(origin.x, origin.y, 100.0, 100.0);
        if (CGRectGetHeight(frame) > 0.0 && CGRectGetMinY(frame) >= 0.0) {
            [notes addObject:@"frame=ok"];
        }
        int elementPid = 0;
        if ([self respondsToSelector:@selector(getPid:fromElement:)]) {
            [self getPid:&elementPid fromElement:appElement];
        }
    }
    if ([PDNative_MCPLogger isDebugLoggingEnabled]) {
        [PDNative_MCPLogger logMessage:[NSString stringWithFormat:@"[AX] bound app %@",
                                        [notes componentsJoinedByString:@", "]]];
    }
    return appElement;
}


@end

#pragma mark - Private helpers

// 0x93a8c：从 SpringBoard 场景集合里取 contextId（displayId 排序）。
// 场景对象只暴露 scene.identifier / _contextId，两条路径都试，取到即收。
static NSArray<NSNumber *> *PDAXCollectSceneContextIds(void) {
    Class SBSceneManager = NSClassFromString(@"SBSceneManager");
    NSMutableOrderedSet<NSNumber *> *ids = [NSMutableOrderedSet orderedSet];
    if (!SBSceneManager) return @[];

    id manager = nil;
    if ([SBSceneManager respondsToSelector:@selector(sharedInstance)]) {
        manager = PDAXSendMessage(SBSceneManager, @selector(sharedInstance));
    }
    if (!manager && [SBSceneManager respondsToSelector:@selector(sharedSceneManager)]) {
        manager = PDAXSendMessage(SBSceneManager, @selector(sharedSceneManager));
    }
    if (!manager) return @[];

    id collection = nil;
    for (NSString *sel in @[@"allScenes", @"scenes"]) {
        if ([manager respondsToSelector:NSSelectorFromString(sel)]) {
            collection = PDAXSendMessage(manager, NSSelectorFromString(sel));
            if (collection) break;
        }
    }
    if (![collection respondsToSelector:@selector(countByEnumeratingWithState:objects:count:)]) return @[];

    for (id scene in collection) {
        NSInteger contextId = 0;
        for (NSString *key in @[@"_contextId", @"contextId"]) {
            if ([scene respondsToSelector:NSSelectorFromString(key)]) {
                contextId = [PDAXSendMessage(scene, NSSelectorFromString(key)) integerValue];
                if (contextId) break;
            }
        }
        if (!contextId) {
            id identifier = [scene respondsToSelector:@selector(identifier)]
                ? PDAXSendMessage(scene, @selector(identifier)) : nil;
            if ([identifier isKindOfClass:[NSString class]]) {
                NSArray<NSString *> *parts = [identifier componentsSeparatedByString:@"-"];
                if (parts.count >= 2) contextId = [parts[1] integerValue];
            }
        }
        if (contextId) [ids addObject:@(contextId)];
    }
    return ids.array;
}

// 0x97980：options 只保留可序列化的标量，未知键丢弃，NSNull 归一成字符串。
static NSDictionary *PDAXNormalizeSnapshotOptions(NSDictionary *options) {
    if (![options isKindOfClass:[NSDictionary class]] || options.count == 0) return @{};
    NSMutableDictionary *normalized = [NSMutableDictionary dictionaryWithCapacity:options.count];
    for (id key in options) {
        if (![key isKindOfClass:[NSString class]]) continue;
        id value = options[key];
        if ([value isKindOfClass:[NSNumber class]] || [value isKindOfClass:[NSString class]]) {
            normalized[key] = value;
        } else if (value == [NSNull null]) {
            normalized[key] = @"null";
        } else if ([value isKindOfClass:[NSArray class]] &&
                   [(NSArray *)value count] <= 32) {
            NSMutableArray *scalars = [NSMutableArray array];
            for (id item in (NSArray *)value) {
                if ([item isKindOfClass:[NSNumber class]] || [item isKindOfClass:[NSString class]]) {
                    [scalars addObject:item];
                }
            }
            normalized[key] = scalars;
        }
    }
    return normalized;
}
