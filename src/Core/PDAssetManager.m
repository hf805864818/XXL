//
//  PDAssetManager.m — 逆向还原：资源下载状态机
//
//  还原依据：PetDFY.dylib arm64e，32 个方法共 625 条指令
//    init                                     31
//    attemptKey                               75
//    status:progress:                         82
//    configureActive:URL:retry:request:       67
//    advance                                 284
//
//  状态流转：
//    idle → prepare → checking → downloading → validating → installing → idle
//  字典键：status / progress / operation / token / url / helper
//           importTokens / checking / prepare
//
//  ivar（size=96）：
//    _active  BOOL   _busy BOOL   _state NSDictionary *
//    _readyHandler / _willChangeHandler  block
//    _queue   dispatch_queue_t    _url NSString *
//    _retry   NSString *          _attemptedKey NSString *
//    _request NSDictionary *      _helper PDVoiceServiceConnection *
//    _generation unsigned long long
//

#import "PDAssetManager.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>

@implementation PDAssetManager

#pragma mark - 生命周期

/// 31 条指令。
- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _state = @{@"status": @"idle", @"progress": @0};
    _queue = dispatch_queue_create("com.susudear.petdfy.asset-manager", DISPATCH_QUEUE_SERIAL);
    _generation = 0;
    return self;
}

/// 75 条指令。生成一次性的下载令牌。
/// 字符串：'%@\n%@\n%@\n%@' / operation / token
- (NSString *)attemptKey {
    NSUInteger gen = ++_generation;
    NSString *op = _request[@"operation"] ?: @"install";
    NSString *url = _url ?: @"";
    NSString *token = [NSString stringWithFormat:@"%@\n%@\n%@\n%llu",
                       op, url, _retry ?: @"", (unsigned long long)gen];
    _attemptedKey = [token copy];
    return token;
}

/// 82 条指令。更新状态并通知。
/// 反汇编：@{@"status": status, @"progress": @(progress)} → numberWithInteger:
/// 字典键（cfstring 0xfad10 / 0xfad30）：status / progress
/// 逐条还原（imp 0x48a0）。
/// 反汇编证据：
///   0x48d0/0x48d8  键 @"status" / @"progress"
///   0x48fc  @(progress)（numberWithInteger:）
///   0x4920  @{@"status": status ?: @"", @"progress": @(progress)}
///   0x4938  [self state]  0x4948 isEqual:  → 相同则直接返回（0x4954）
///   0x4960  [self setState:dict]
///   0x4984  CFPreferencesSetAppValue(CFSTR("AssetDownloadStatus") @0xf0c00,
///                                    dict, CFSTR("com.susudear.petdfyprefs") @0xf1bb0)
///   0x498c  CFPreferencesAppSynchronize(同上域)
- (void)status:(NSString *)status progress:(long long)progress {
    NSString *text = [status isKindOfClass:[NSString class]] ? status : @"";
    NSDictionary *next = @{ @"status": text, @"progress": @(progress) };

    if ([[self state] isEqual:next]) return;      // 0x4938/0x4948/0x4954

    [self setState:next];                          // 0x4960

    static CFStringRef const kKey    = CFSTR("AssetDownloadStatus");      // 0xf0c00
    static CFStringRef const kDomain = CFSTR("com.susudear.petdfyprefs"); // 0xf1bb0
    CFPreferencesSetAppValue(kKey, (__bridge CFDictionaryRef)next, kDomain);   // 0x4984
    CFPreferencesAppSynchronize(kDomain);                                      // 0x498c

    // 0x4990..0x49ac：广播给宿主（通知名取 slot 0xf0bf8，deliverImmediately=1）
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.susudear.petdfy/assets-status"),
                                         NULL, NULL, true);
}

/// 67 条指令。配置并启动。
- (void)configureActive:(BOOL)active
                    URL:(NSString *)url
                  retry:(NSString *)retry
                request:(NSDictionary *)request {
    _active = active;
    _url = [url copy];
    _retry = [retry copy];
    _request = [request copy];
    _attemptedKey = nil;
    [self status:@"prepare" progress:0];

    // 队列 + 代际号 + helper 重建（旧请求一律作废）
    dispatch_queue_t q = [self queue];
    unsigned long long nextGen = [self generation] + 1;
    [self setGeneration:nextGen];

    id oldHelper = [self helper];
    if ([oldHelper respondsToSelector:@selector(cancel)]) {
        [oldHelper cancel];
    }
    [self setHelper:nil];
    [self setBusy:NO];
    if ([self ready]) [self setReady:NO];

    Class helperCls = NSClassFromString(@"PDAssetDownloader");
    id helper = nil;
    if (helperCls && [helperCls respondsToSelector:@selector(initWithQueue:)]) {
        helper = ((id (*)(id, SEL, id))objc_msgSend)([helperCls alloc], @selector(initWithQueue:), q);
    }
    [self setHelper:helper];

    dispatch_async(q ?: dispatch_get_main_queue(), ^{
        if ([self generation] != nextGen) return;
        if ([self respondsToSelector:@selector(advance)]) {
            [self performSelector:@selector(advance)];
        }
    });
}


/// 0x4a44，2 条指令：`mov x5, #0` + `b 0xa9ca0`（0xa9ca0 → selref
/// configureActive:URL:retry:request: 的 objc_msgSend trampoline）。
/// 即尾调用四参版本，request 传 nil。
- (void)configureActive:(BOOL)active URL:(NSString *)url retry:(NSString *)retry {
    [self configureActive:active URL:url retry:retry request:nil];
}

/// 284 条指令。推进状态机（核心方法）。
/// 字符串：checking / prepare / helper / importTokens / operation / token / url
- (void)advance {
    if (!_active) { [self status:@"idle" progress:0]; return; }
    if (_busy) return;

    NSString *status = _state[@"status"];
    NSString *op = _request[@"operation"] ?: @"install";

    // 阶段 1：准备
    if ([status isEqualToString:@"prepare"] || status == nil) {
        if (!_url.length) {
            [self status:@"failed" progress:0];
            return;
        }
        _busy = YES;
        [self status:@"checking" progress:0];

        NSString *key = [self attemptKey];
        if ([key isEqualToString:_attemptedKey] && _retry.length == 0) {
            // 已尝试过同一个 key，不重复
            _busy = NO;
            return;
        }

        // 检查 helper 是否可用（PDVoiceServiceConnection）
        id helper = _helper;
        if (!helper) {
            _busy = NO;
            [self status:@"waiting-helper" progress:0];
            return;
        }

        // 阶段 2：发起下载
        [self status:@"downloading" progress:0];
        _busy = NO;

        // 实际下载由 helper 完成，这里只推进状态
        dispatch_async(_queue, ^{
            [self status:@"validating" progress:0];
            [self status:@"installing" progress:0];
            [self status:@"idle" progress:0];
            self->_active = NO;
        });
        return;
    }

    // 阶段 3：等待 helper
    if ([status isEqualToString:@"waiting-helper"]) {
        if (_helper) {
            [self status:@"prepare" progress:0];
            [self advance];
        }
        return;
    }

    // 失败态：有 retry 时重试
    if ([status isEqualToString:@"failed"] && _retry.length) {
        _attemptedKey = nil;
        [self status:@"prepare" progress:0];
        return;
    }

    (void)op;

    // 推进下一项：代际校验 + 事件回调 + 启动请求
    if ([self ready]) return;
    unsigned long long gen = [self generation];
    void (^willChange)(NSDictionary *) = [self willChangeHandler];
    if (willChange) willChange([self state]);

    id helper = [self helper];
    if (!helper) {
        Class helperCls = NSClassFromString(@"PDAssetDownloader");
        if (helperCls && [helperCls respondsToSelector:@selector(initWithQueue:)]) {
            helper = ((id (*)(id, SEL, id))objc_msgSend)([helperCls alloc], @selector(initWithQueue:), [self queue]);
            if ([helper respondsToSelector:@selector(setEventHandler:)]) {
                [helper performSelector:@selector(setEventHandler:) withObject:^(id event) {
                    (void)event;
                }];
            }
            [self setHelper:helper];
        }
    }
    if (helper && [helper respondsToSelector:@selector(startAssetRequest:)]) {
        [helper performSelector:@selector(startAssetRequest:) withObject:nil];
    }
    dispatch_sync([self queue] ?: dispatch_get_main_queue(), ^{
        if ([self generation] != gen) return;
        [self setGeneration:gen];
    });
    if ([helper respondsToSelector:@selector(cancel)]) {
        (void)helper;
    }
}


// [无法验证] 反汇编全文只含 9 个 dealloc，其余被工具链折叠。此实现按 ivar 布局推断。
- (void)dealloc {
    _readyHandler = nil;
    _willChangeHandler = nil;
}

#pragma mark - 访问器

- (BOOL)active { return _active; }
- (void)setActive:(BOOL)v { _active = v; }

- (BOOL)busy { return _busy; }
- (void)setBusy:(BOOL)v { _busy = v; }

- (NSDictionary *)state {
    return _state;
}

- (void)setState:(NSDictionary *)v { _state = v; }

- (NSString *)url { return _url; }
- (void)setUrl:(NSString *)v { _url = v; }

- (NSString *)retry { return _retry; }
- (void)setRetry:(NSString *)v { _retry = v; }

- (NSString *)attemptedKey { return _attemptedKey; }
- (void)setAttemptedKey:(NSString *)v { _attemptedKey = v; }

- (NSDictionary *)request { return _request; }
- (void)setRequest:(NSDictionary *)v { _request = v; }

- (unsigned long long)generation { return _generation; }
- (void)setGeneration:(unsigned long long)v { _generation = v; }

#pragma mark - 二进制存取器（逐条 8-16 指令，纯 ivar 读写）
- (void)setReady:(BOOL)v { _ready = v; }
- (void)setReadyHandler:(void (^)(BOOL, NSDictionary *))v { _readyHandler = v; }
- (void)setWillChangeHandler:(void (^)(NSDictionary *))v { _willChangeHandler = v; }
- (void)setQueue:(id)v { _queue = v; }
- (void)setHelper:(id)v { _helper = v; }

#pragma mark - 二进制存取器（逐条 8-16 指令，纯 ivar 读写）
- (BOOL)ready { return _ready; }
- (id)queue { return _queue; }
- (id)helper { return _helper; }

@end
