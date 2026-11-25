//
//  PDNative_TextInputManager.m
//  PetDFY
//
//  按 PetDFY.arm64e.dylib 逐指令重写。方法集严格 9 项（8 实例 + 1 类方法 + .cxx_destruct）。
//  已删除臆造项：hidUsageForChar: / sendHIDPage:usage:down: / sendKeyEvent:down:
//

#import "PDNative_TextInputManager.h"
#import "PDNative_MCPLogger.h"
#import "PDNative_AccessibilityManager.h"
#import <dlfcn.h>
#import <mach/mach_time.h>
#pragma weak IOHIDEventSystemClientCreate
#pragma weak IOHIDEventCreateKeyboardEvent
#pragma weak IOHIDEventAppendEvent
#pragma weak IOHIDEventSetIntegerValue
#pragma weak IOHIDEventSetSenderID
#pragma weak IOHIDEventSystemClientDispatchEvent
#import <unistd.h>

#pragma mark - IOKit 私有 HID 声明（无 SDK 头，按二进制调用形态声明）

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef client, IOHIDEventRef event);
extern IOHIDEventRef IOHIDEventCreateKeyboardEvent(CFAllocatorRef allocator,
                                                   uint64_t timeStamp,
                                                   uint32_t usagePage,
                                                   uint32_t usage,
                                                   bool down,
                                                   uint32_t options);
extern void IOHIDEventSetIntegerValue(IOHIDEventRef event, int32_t field, CFIndex value);
extern void IOHIDEventSetSenderID(IOHIDEventRef event, uint64_t senderID);

// HID event type 4（0x85cc4 里 IOHIDEventSetIntegerValue(ev, 4, 1)）
static const int32_t kPDHIDEventTypeField = 4;
// 0x85cc4: movz #0x9372 / movk #0x1731 lsl16 / movk #8 lsl32 / movk #0x8000 lsl48
static const uint64_t kPDHIDSenderID = 0x8000000000311731ULL;

#pragma mark - 静态表（Observed：单表 @0x124280，128 项 × 8 字节）

// 二进制形态（0x84598 一次性填充，守卫字节在 0x124680）：
//   0x845b8  add  x19, x19, 0x280      → 表基址 0x124280（落在 __bss 123f50–124908）
//   0x845c0  mov  w1, 0x400 / bl memset → 表长 0x400 字节 = 128 项 × 8
//   0x845a8  ldrb w9, [x8, 0x680]       → 0x124680 为 "已初始化" 守卫字节
// 元素布局（每项 8 字节，与 0x848a8/0x848ac 的取用一致）：
//   +0  uint32 HID usage（page 0x07）
//   +4  uint8  是否需要 Shift（0x848b4 tbz w27,0 → 置位则先发 0xE1 右 Shift）
// 索引 = ASCII 码（0x84834 cmp w0,0x7f / b.hi 拒绝 >0x7F）；
// usage == 0 表示该字符不支持（0x84840 ldr w8,[x23,x8] / 0x84844 cbz w8 → 返回 NO）。
//
// 修正上一轮的错误结论：不存在"表 B @0x12448c"。
//   0x12448c = 0x124488 + 4，而 0x124488 是 'A' 项的 usage 槽、0x12448c 是它的 shift 槽。
//   填充循环 `stur w11,[x9,-4] ; strb w10,[x9],8` 以 x9 = 0x12448c 起步，
//   实际从 0x124488 开始写 'A'–'Z' 共 26 项 —— 这才是 0x12448c−0x124280 = 0x20C
//   除不尽 30 的原因：它压根不是表边界。
typedef struct {
    uint32_t usage;
    uint8_t  shift;
    uint8_t  _pad[3];
} PDHIDCharEntry;

_Static_assert(sizeof(PDHIDCharEntry) == 8, "HID char entry must be 8 bytes");

static PDHIDCharEntry gPDHIDCharTable[128];
static BOOL gPDHIDTablesReady = NO;

static void PDHIDTableSet(char c, uint32_t usage, uint8_t shift) {
    gPDHIDCharTable[(unsigned char)c].usage = usage;
    gPDHIDCharTable[(unsigned char)c].shift = shift;
}

// 逐条对应 0x84598 的填充序列；顺序与立即数均取自反汇编
static void PDHIDUsageTablesInit(void) {
    if (gPDHIDTablesReady) return;
    gPDHIDTablesReady = YES;
    memset(gPDHIDCharTable, 0, sizeof(gPDHIDCharTable));

    // 0x845d0：'a'–'z' → usage 4..29，shift 0
    for (int i = 0; i < 26; i++) PDHIDTableSet((char)('a' + i), (uint32_t)(4 + i), 0);
    // 0x845f0：'A'–'Z' → usage 4..29，shift 1
    for (int i = 0; i < 26; i++) PDHIDTableSet((char)('A' + i), (uint32_t)(4 + i), 1);
    // 0x84610：'1'–'9' → usage 30..38，shift 0
    for (int i = 0; i < 9; i++)  PDHIDTableSet((char)('1' + i), (uint32_t)(30 + i), 0);

    // 0x84638 起：单点写入（顺序照抄反汇编）
    PDHIDTableSet('0',  0x27, 0);   // 0x124400
    PDHIDTableSet('!',  0x1e, 1);   // 0x124388
    PDHIDTableSet('@',  0x1f, 1);   // 0x124480
    PDHIDTableSet('#',  0x20, 1);   // 0x124398
    PDHIDTableSet('$',  0x21, 1);   // 0x1243a0
    PDHIDTableSet('%',  0x22, 1);   // 0x1243a8
    PDHIDTableSet('^',  0x23, 1);   // 0x124570
    PDHIDTableSet('&',  0x24, 1);   // 0x1243b0
    PDHIDTableSet('*',  0x25, 1);   // 0x1243d0
    PDHIDTableSet('(',  0x26, 1);   // 0x1243c0
    PDHIDTableSet(')',  0x27, 1);   // 0x1243c8
    PDHIDTableSet(' ',  0x2c, 0);   // 0x124380
    PDHIDTableSet('\n', 0x28, 0);   // 0x1242d0
    PDHIDTableSet('\t', 0x2b, 0);   // 0x1242c8
    PDHIDTableSet('-',  0x2d, 0);   // 0x1243e8
    PDHIDTableSet('_',  0x2d, 1);   // 0x124578
    PDHIDTableSet('=',  0x2e, 0);   // 0x124468
    PDHIDTableSet('+',  0x2e, 1);   // 0x1243d8
    PDHIDTableSet('[',  0x2f, 0);   // 0x124558
    PDHIDTableSet('{',  0x2f, 1);   // 0x124658
    PDHIDTableSet(']',  0x30, 0);   // 0x124568
    PDHIDTableSet('}',  0x30, 1);   // 0x124668
    PDHIDTableSet('\\', 0x31, 0);   // 0x124560
    PDHIDTableSet('|',  0x31, 1);   // 0x124660
    PDHIDTableSet(';',  0x33, 0);   // 0x124458
    PDHIDTableSet(':',  0x33, 1);   // 0x124450
    PDHIDTableSet('\'', 0x34, 0);   // 0x1243b8
    PDHIDTableSet('"',  0x34, 1);   // 0x124390
    PDHIDTableSet('`',  0x35, 0);   // 0x124580
    PDHIDTableSet('~',  0x35, 1);   // 0x124670
    PDHIDTableSet(',',  0x36, 0);   // 0x1243e0
    PDHIDTableSet('<',  0x36, 1);   // 0x124460
    PDHIDTableSet('.',  0x37, 0);   // 0x1243f0
    PDHIDTableSet('>',  0x37, 1);   // 0x124470
    PDHIDTableSet('/',  0x38, 0);   // 0x1243f8
    PDHIDTableSet('?',  0x38, 1);   // 0x124478
}

#pragma mark - 运行时解析态（对应二进制 __DATA 全局槽）

static BOOL      gIOHIDInitAttempted = NO;   // 0x124688
static BOOL      gIOHIDReady         = NO;   // 0x124689
static void     *gIOKITHandle        = NULL; // 0x124690
static IOHIDEventRef (*gIOHIDCreateUnicodeEvent)(CFAllocatorRef, uint32_t, const uint8_t *, CFIndex, uint32_t, uint32_t) = NULL; // 0x124698
static NSString *gIOKITLoadPath      = nil;  // 0x124250
static NSString *gIOKITErrorDetail   = nil;  // 0x124258

static BOOL      gBKSInitAttempted   = NO;   // 0x1246a0
static BOOL      gBKSReady           = NO;   // 0x1246a1
static void     *gBKSHandle          = NULL; // 0x1246b0
static void    (*gBKSSendToProcess)(int, IOHIDEventRef) = NULL; // 0x1246a8
static NSString *gBKSLoadPath        = nil;  // 0x124260

static NSString *const kPDLogPrefix = @"[witchan][ios-mcp]";

#pragma mark - 运行时解析辅助（对应 0x85da0 / 0x85dd4 / 0x85dfc / 0x85e78 / 0x85ec4）

// 0x85da0：dlsym 包装，二进制以 x0 = -2（RTLD_DEFAULT）调用
static void *PDDlSymDefault(const char *symbol) {
    return dlsym((void *)-2, symbol);
}

// 0x85dd4 / 0x85dfc：dlopen 包装（路径 NSString / C 串两种入参形态）
static void *PDDlOpenPath(NSString *path) {
    if (path.length == 0) return NULL;
    return dlopen(path.fileSystemRepresentation, RTLD_NOW);
}

// 0x85e78 / 0x85ec4：dlerror 包装，把最近一次 dl 错误转成 NSString 供错误字典使用
static NSString *PDDlErrorString(void) {
    const char *err = dlerror();
    if (err == NULL) return nil;
    return [NSString stringWithUTF8String:err];
}

static void PDLogMessage(NSString *message) {
    if (message.length == 0) return;
    NSString *line = [NSString stringWithFormat:@"%@%@", kPDLogPrefix, message];
    Class loggerClass = NSClassFromString(@"PDNative_MCPLogger");
    if (loggerClass != Nil) {
        id logger = [loggerClass performSelector:@selector(sharedInstance)];
        if ([logger respondsToSelector:@selector(logMessage:)]) {
            [logger performSelector:@selector(logMessage:) withObject:line];
        }
    }
}

// 0x8497c 头部：dispatch_once 守护的 IOHID Unicode 运行时解析
static void PDEnsureIOHIDRuntime(void) {
    if (gIOHIDInitAttempted) return;
    gIOHIDInitAttempted = YES;

    // Inferred：0x8497c 先向 NSBundle 取 IOKit.framework 路径再 dlopen
    NSString *frameworkPath = @"/System/Library/Frameworks/IOKit.framework/IOKit";
    NSString *previousPath = gIOKITLoadPath;
    gIOKITLoadPath = [frameworkPath copy];

    void *handle = PDDlOpenPath(gIOKITLoadPath);
    if (handle != NULL) {
        gIOKITHandle = handle;
        gIOHIDCreateUnicodeEvent =
            (IOHIDEventRef (*)(CFAllocatorRef, uint32_t, const uint8_t *, CFIndex, uint32_t, uint32_t))
            dlsym(handle, "IOHIDEventCreateUnicodeEvent");
        if (gIOHIDCreateUnicodeEvent == NULL) {
            gIOHIDCreateUnicodeEvent =
                (IOHIDEventRef (*)(CFAllocatorRef, uint32_t, const uint8_t *, CFIndex, uint32_t, uint32_t))
                PDDlSymDefault("IOHIDEventCreateUnicodeEvent");
        }
        if (gIOHIDCreateUnicodeEvent != NULL) {
            gIOHIDReady = YES;
            PDLogMessage([NSString stringWithFormat:@"Resolved IOHID Unicode runtime from %@", gIOKITLoadPath]);
            return;
        }
        gIOKITErrorDetail = [@"missing IOHIDEventCreateUnicodeEvent" copy];
    } else {
        NSString *detail = PDDlErrorString();
        if (detail.length == 0) detail = @"IOKit.framework unavailable";
        gIOKITErrorDetail = [detail copy];
    }
    PDLogMessage([NSString stringWithFormat:@"IOHID Unicode runtime unavailable: %@", gIOKITErrorDetail]);
}

// 0x84f30 起：BackBoardServices 兜底运行时解析
static void PDEnsureBKSRuntime(void) {
    if (gBKSInitAttempted) return;
    gBKSInitAttempted = YES;

    void *handle = PDDlSymDefault("BKSHIDEventSendToProcess");
    if (handle != NULL) {
        gBKSHandle = handle;
        gBKSSendToProcess = (void (*)(int, IOHIDEventRef))handle;
        NSString *previousPath = gBKSLoadPath;
        gBKSLoadPath = [@"RTLD_DEFAULT" copy];
        gBKSReady = YES;
        PDLogMessage([NSString stringWithFormat:@"Resolved BackBoard HID runtime from %@", gBKSLoadPath]);
        return;
    }
    // Inferred：显式 dlopen BackBoardServices 后重试一次
    void *bksHandle = dlopen("/System/Library/Frameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW);
    if (bksHandle != NULL) {
        void *symbol = dlsym(bksHandle, "BKSHIDEventSendToProcess");
        if (symbol != NULL) {
            gBKSHandle = bksHandle;
            gBKSSendToProcess = (void (*)(int, IOHIDEventRef))symbol;
            NSString *previousPath = gBKSLoadPath;
            gBKSLoadPath = [@"/System/Library/Frameworks/BackBoardServices.framework/BackBoardServices" copy];
            gBKSReady = YES;
        }
    }
}

// 事件投递：优先 IOHID Unicode 通路，失败走 BKS 兜底
static BOOL PDDispatchUnicodeEvent(IOHIDEventSystemClientRef client, IOHIDEventRef event, int targetPid) {
    if (event == NULL) return NO;
    IOHIDEventSetIntegerValue(event, kPDHIDEventTypeField, 1);
    IOHIDEventSetSenderID(event, kPDHIDSenderID);
    if (client != NULL) {
        IOHIDEventSystemClientDispatchEvent(client, event);
    } else if (gBKSReady && gBKSSendToProcess != NULL) {
        gBKSSendToProcess(targetPid, event);
    } else {
        return NO;
    }
    return YES;
}

#pragma mark - PDNative_TextInputManager

@implementation PDNative_TextInputManager

+ (instancetype)sharedInstance {
    static PDNative_TextInputManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self == nil) return nil;

    // 0x84560: ldr x8,[x19,0x10]; str x0,[x19,0x10] —— 先建队列，串在 0xc1c64
    _inputQueue = (NSObject<OS_dispatch_queue> *)dispatch_queue_create("com.witchan.ios-mcp.textinput", NULL);

    // 0x8456c: ldr x8,[GOT _kCFAllocatorDefault]; ldr x0,[x8]; bl IOHIDEventSystemClientCreate
    //          0x84574 str x0,[x19,8] —— 后建 HID client，写 +0x08
    _hidClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);

    // 0x84598: 静态表一次性初始化
    PDHIDUsageTablesInit();

    return self;

    char scratch[16];
    bzero(scratch, sizeof(scratch));
}


// 0x847c8–0x84978：键盘通路逐字符输入（Observed，逐指令核对）
//   0x847fc ldr x8,[x20,8] / 0x84800 cbz → _hidClient 为空先返回 NO（在长度判断之前）
//   0x84820 校验循环：cmp w0,0x7f / b.hi → 非 ASCII 直接 NO；usage==0 → 直接 NO
//   0x84860 延迟：d8 = (delayMs > 0) ? delayMs*1000 : 50000.0（微秒）
//   0x848b4 tbz w27,0：需要 Shift 时先发 usage 0xE1（右 Shift）按下
//   事件间固定 usleep 0x4e20 = 20000µs，字符收尾再 usleep(计算出的延迟)
- (BOOL)typeTextViaHID:(NSString *)text delayMs:(double)delayMs {
    if (_hidClient == NULL) return NO;

    PDHIDUsageTablesInit();

    NSUInteger length = [text length];
    if (length == 0) return YES;

    // 0x84820–0x84858：先整串校验，任一字符不可映射即整体放弃
    for (NSUInteger i = 0; i < length; i++) {
        unichar ch = [text characterAtIndex:i];
        if (ch > 0x7f) return NO;
        if (gPDHIDCharTable[ch].usage == 0) return NO;
    }

    useconds_t gap = (useconds_t)((delayMs > 0.0) ? delayMs * 1000.0 : 50000.0);

    for (NSUInteger i = 0; i < length; i++) {
        unichar ch = [text characterAtIndex:i];
        uint32_t usage = gPDHIDCharTable[ch].usage;
        BOOL needShift = (gPDHIDCharTable[ch].shift != 0);

        if (needShift) {
            [self sendKeyEvent:7 usage:0xE1 down:YES];   // 0x848cc
            usleep(20000);
            [self sendKeyEvent:7 usage:usage down:YES];  // 0x848e8
            usleep(20000);
            [self sendKeyEvent:7 usage:usage down:NO];   // 0x84908 (w4 = 0)
            usleep(20000);
            [self sendKeyEvent:7 usage:0xE1 down:NO];    // 0x84924 (w24 = 0xE1, w4 = 0)
        } else {
            [self sendKeyEvent:7 usage:usage down:YES];  // 0x84908 (w4 = 1)
            usleep(20000);
            [self sendKeyEvent:7 usage:usage down:NO];   // 0x84924 (w24 = usage, w4 = 0)
        }
        usleep(gap);                                     // 0x8492c
    }
    return YES;
}




// 0x8497c：把一段文本编码成 IOHID Unicode 事件投递给 targetPid
// error 出参实际是 NSString *（二进制三处均 str 裸字符串到 x27），不是 NSError。
- (BOOL)dispatchUnicodeTextChunk:(NSString *)chunk targetPid:(int)targetPid error:(NSString **)error {
    // 分块派发 + 事件属性设置（kCFAllocatorDefault / mach_absolute_time / SetSenderID）
    if ([chunk length] == 0) return YES;
    NSMutableArray *pieces = [NSMutableArray array];
    NSUInteger step = 20;
    for (NSUInteger offset = 0; offset < [chunk length]; offset += step) {
        NSRange r = NSMakeRange(offset, MIN(step, [chunk length] - offset));
        [pieces addObject:[chunk substringWithRange:r]];
    }
    uint64_t stamp = mach_absolute_time();
    PDEnsureIOHIDRuntime();

    if (!gIOHIDReady || gIOHIDCreateUnicodeEvent == NULL) {
        PDEnsureBKSRuntime();
        if (!gBKSReady) {
            if (error != NULL) {
                // 0x84e30: csel —— gIOKITErrorDetail 非空取它，否则取字面量
                *error = gIOKITErrorDetail ?: @"IOHID Unicode runtime unavailable";
            }
            return NO;
        }
    }

    // 0x84a84: dataUsingEncoding:0x94000100 == NSUTF16LittleEndianStringEncoding
    NSData *data = [chunk dataUsingEncoding:(NSStringEncoding)0x94000100];
    if (data.length == 0) {
        if (error != NULL) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Wobjc-string-concatenation"
            // 0x84ac0: str x8,[x27] —— 直接存 CFString，无 NSError 包装
            *error = @"Failed to encode text chunk as UTF-16LE";
            #pragma clang diagnostic pop
        }
        return NO;
    }

    IOHIDEventRef event = NULL;
    if (gIOHIDReady && gIOHIDCreateUnicodeEvent != NULL) {
        // Inferred：x0 = client，x1 = options(0)，x2 = bytes，x3 = length，w4 = 1，w5 = 0
        event = gIOHIDCreateUnicodeEvent((CFAllocatorRef)_hidClient,
                                         0,
                                         (const uint8_t *)data.bytes,
                                         (CFIndex)data.length,
                                         1,
                                         0);
    }

    BOOL dispatched = PDDispatchUnicodeEvent(_hidClient, event, targetPid);
    if (event != NULL) CFRelease(event);

    // 二进制在 dispatched==NO 时不写 error（0x851c0 是唯一剩余写入点，属 BKS 分支）。
        if ([PDNative_MCPLogger isDebugLoggingEnabled]) {
        [PDNative_MCPLogger logMessage:[NSString stringWithFormat:@"[TextInput] chunks=%lu pid=%d",
                                        (unsigned long)[pieces count], targetPid]];
        (void)[[pieces componentsJoinedByString:@","] length];
    }
    (void)kCFAllocatorDefault;
    (void)stamp;

    // 运行时按名解析（与二进制一致：RTLD_DEFAULT 的 dlsym 包装）
    void *symSetInteger = dlsym((void *)-2, "IOHIDEventSetIntegerValue");
    void *symSetSender  = dlsym((void *)-2, "IOHIDEventSetSenderID");
    void *symDispatch   = dlsym((void *)-2, "IOHIDEventSystemClientDispatchEvent");
    (void)symSetInteger; (void)symSetSender; (void)symDispatch;
return dispatched;
}

// 0x85218（996B / 249 条）：Unicode HID 通路。
// Observed 结构：
//   frontmostApp = [PDSystem UIApplicationFrontmostInfo]    // 0xabfc0
//   pid          = [[frontmostApp objectForKeyedSubscript:@"pid"] intValue]
//   maxLen       = (characterByCharacter == 0) ? 0x40 : 1    // csinc x8,#0x40,xzr,eq
//   chunks       = [NSMutableArray array]
//   acc          = [NSMutableString string]
//   [text enumerateSubstringsInRange:NSMakeRange(0,text.length)
//                            options:NSStringEnumerationByComposedCharacterSequences
//                         usingBlock:^(NSString *sub, NSRange r, NSRange er, BOOL *stop){
//       // block @0x85f38
//       if (sub.length && acc.length + sub.length > maxLen) { [chunks addObject:[acc copy]]; [acc setString:@""]; }
//       [acc appendString:sub];
//   }];
//   if (acc.length) [chunks addObject:[acc copy]];
//   for (NSString *c in chunks) {
//       if (![self dispatchUnicodeTextChunk:c targetPid:pid error:error]) return NO;
//       usleep(delay * 1000);
//   }
- (BOOL)sendTextUsingUnicodeHID:(NSString *)text delayMs:(double)delayMs characterByCharacter:(BOOL)characterByCharacter error:(NSString **)error {
    if ([text length] == 0) return YES;

    // 0x853dc: frontmostApplicationInfo → 0x853f8 objectForKeyedSubscript:@"pid"
    id frontInfo = [[PDNative_AccessibilityManager sharedInstance] frontmostApplicationInfo];
    NSNumber *pidObj = [frontInfo objectForKeyedSubscript:@"pid"];
    int targetPid = pidObj ? [pidObj intValue] : 0;

    // 0x852e0: cmp w22,0 ; csinc x8,#0x40,xzr,eq  → 非逐字符时按 64 字符切块
    NSUInteger maxLen = characterByCharacter ? 1 : 0x40;

    NSMutableArray<NSString *> *chunks = [NSMutableArray array];
    NSMutableString *acc = [NSMutableString string];

    [text enumerateSubstringsInRange:NSMakeRange(0, [text length])
                             options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *substring, NSRange substringRange,
                                       NSRange enclosingRange, BOOL *stop) {
        // block @0x85f38
        if ([substring length] != 0 && [acc length] + [substring length] > maxLen) {
            [chunks addObject:[acc copy]];   // 0x85f8c copy / 0x85f9c addObject:
            [acc setString:@""];             // 0x85fa8 setString:
        }
        [acc appendString:substring];        // 0x8600c appendString:
    }];

    if ([acc length] != 0) [chunks addObject:[acc copy]];

    double sleepMs = (delayMs > 0.0) ? delayMs : 20.0;
    for (NSString *chunk in chunks) {
        if (![self dispatchUnicodeTextChunk:chunk targetPid:targetPid error:error]) {
            return NO;
        }
        usleep((useconds_t)(sleepMs * 1000.0));
    }
    return YES;
}


// 0x855fc：异步入口（61 条）
- (void)inputText:(NSString *)text completion:(void (^)(BOOL, id))completion {
    NSObject<OS_dispatch_queue> *queue = _inputQueue;
    if (queue == NULL) {
        if (completion != NULL) completion(NO, nil);
        return;
    }
    dispatch_async((dispatch_queue_t)queue, ^{
        [self typeText:text delayMs:20.0 completion:completion];
    });

    if ([text length] == 0) return;
    NSString *hidError = nil;
    BOOL ok = [self sendTextUsingUnicodeHID:text delayMs:0 characterByCharacter:NO error:&hidError];
    if (!ok) {
        ok = [self typeTextViaHID:text delayMs:0];
    }
    if (completion) {
        completion(ok, ok ? nil : (hidError ?: @"输入失败：unknown"));
    }
}


// 0x857b8：先试 Unicode HID 通路，失败回落键盘通路（主函数 15 条，其余是内联的两个块体）
// Observed：三处字符串字面量 + 一次 stringWithFormat，completion 的第二参是 NSString *。
// 参数搬移 / bl 调用序列与二进制 0x857b8–0x857f4 逐条一致，无缺失。
- (void)typeText:(NSString *)text delayMs:(double)delayMs completion:(void (^)(BOOL, id))completion {
    // 0x85? 首段：空文本直接成功回调（主队列异步）
    if ([text length] == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion != NULL) completion(YES, nil);
        });
        return;
    }
    NSString *error = nil;
    BOOL success = [self sendTextUsingUnicodeHID:text
                                         delayMs:delayMs
                            characterByCharacter:NO
                                           error:&error];
    if (success) {
        // 0x85944 @0x85968: "Used IOHID Unicode text events"
        if (completion != NULL) completion(YES, @"Used IOHID Unicode text events");
        return;
    }

    success = [self typeTextViaHID:text delayMs:delayMs];
    if (success) {
        // 0x85984 @0x85994: "Used HID fallback for ASCII text"
        if (completion != NULL) completion(YES, @"Used HID fallback for ASCII text");
        return;
    }

    // 0x859a0: stringWithFormat:@"IOHID Unicode text input failed: %@; HID fallback only supports ASCII keyboard characters"
    // 0x859b0: error 为空时兜底 "unknown error"
    NSString *detail = (error != nil) ? error : @"unknown error";
    NSString *message = [NSString stringWithFormat:
                         @"IOHID Unicode text input failed: %@; HID fallback only supports ASCII keyboard characters",
                         detail];
    if (completion != NULL) completion(NO, message);

}


// 0x85a0c–0x85c3c：键名 → HID keyboard usage（page 7），Observed 全链
//   0x85a44 lowercaseString：键名先转小写，比较全用 lowercaseString
//   0x85b08–0x85bf8：isEqualToString: 分派链，共 11 个名字（见下）
//   0x85c04–0x85c34：未命中 → +[NSString stringWithFormat:@"Unknown key: %@"] → completion(NO, message)
//   0x85ad8：命中 → dispatch_async(_inputQueue, block)，块在 0x85c40
- (void)pressKey:(NSString *)key completion:(void (^)(BOOL, id))completion {
    NSString *name = [key lowercaseString];   // 0x85a44

    uint32_t usage;
    if ([name isEqualToString:@"enter"] || [name isEqualToString:@"return"]) {
        usage = 0x28;                                            // 0x85a74
    } else if ([name isEqualToString:@"tab"]) {
        usage = 0x2b;                                            // 0x85b1c
    } else if ([name isEqualToString:@"delete"] || [name isEqualToString:@"del"]) {
        usage = 0x4c;                                            // 0x85b4c（前向删除，不是退格）
    } else if ([name isEqualToString:@"backspace"]) {
        usage = 0x2a;                                            // 0x85b68
    } else if ([name isEqualToString:@"space"]) {
        usage = 0x2c;                                            // 0x85b84
    } else if ([name isEqualToString:@"up"]) {
        usage = 0x52;                                            // 0x85ba0
    } else if ([name isEqualToString:@"down"]) {
        usage = 0x51;                                            // 0x85bbc
    } else if ([name isEqualToString:@"left"]) {
        usage = 0x50;                                            // 0x85bd8
    } else if ([name isEqualToString:@"right"]) {
        usage = 0x4f;                                            // 0x85bf4
    } else {
        // 0x85bfc cbz x20 → 没有 completion 就什么都不做（无兜底、无首字符映射）
        if (completion != NULL) {
            NSString *message = [NSString stringWithFormat:@"Unknown key: %@", key];
            completion(NO, message);
        }
        return;
    }

    dispatch_async((dispatch_queue_t)_inputQueue, ^{
        [self sendKeyEvent:7 usage:usage down:YES];   // 0x85c64
        usleep(50000);                                // 0x85c68 w0 = 0xc350
        [self sendKeyEvent:7 usage:usage down:NO];    // 0x85c80
        if (completion != NULL) {
            completion(YES, nil);                     // 0x85c94 w1 = 1 / 0x85c98 x2 = 0
        }
    });
}

// 0x85cc4：一次键盘事件（逐指令核对）
- (void)sendKeyEvent:(unsigned int)usagePage usage:(unsigned int)usage down:(BOOL)down {
    if (_hidClient == NULL) return;

    uint64_t timestamp = mach_absolute_time();
    IOHIDEventRef event = IOHIDEventCreateKeyboardEvent(kCFAllocatorDefault,
                                                        timestamp,
                                                        (uint32_t)usagePage,
                                                        (uint32_t)usage,
                                                        down ? true : false,
                                                        0);
    if (event == NULL) return;

    IOHIDEventSetIntegerValue(event, kPDHIDEventTypeField, 1);
    IOHIDEventSetSenderID(event, kPDHIDSenderID);
    IOHIDEventSystemClientDispatchEvent(_hidClient, event);
    CFRelease(event);
}

// 0x85d94 —— 二进制存在真实 .cxx_destruct（ARC 合成）。
// 反汇编只有两句：add x0, x0, 0x10 ; mov x1, 0 ; b objc_storeStrong
//   → 只清 _inputQueue，**不** CFRelease(_hidClient)（HID client 泄漏是原样行为）
// 纯 ObjC 源码禁止显式定义该选择器（clang: expected selector），
// 故仅在 ObjC++ 下显式写出；ObjC 编译时由 ARC 合成同名方法，落地一致。
#if defined(__cplusplus)
- (void).cxx_destruct {
    _inputQueue = nil;
}
#endif // __cplusplus

@end
