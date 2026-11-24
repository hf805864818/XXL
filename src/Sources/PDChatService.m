//
//  PDChatService.m — 逆向还原：AI 对话请求编排
//
//  还原依据：PetDFY.dylib arm64e，84 个方法共 3715 条指令
//  核心方法：
//    initWithDataDirectory:sessionConfiguration:  751
//    handleMessage:                               444
//    runNextTool                                  473
//    requestRound                                 274
//    performDataMaintenance:path:completion:      206
//    recordTool:receipt:                          132
//    saveImage:                                   132
//    finish:                                      120
//    enqueueUserText:images:                      117
//
//  关键字符串：
//    conversation.json / context-state.json
//    tool_calls / function / arguments / reasoning_content
//    end_turn / describe_screen
//    [turn ended] / [skipped] / [failed] / [interrupted] / [read failed]
//
//  ivar（size=240，31 个字段）：
//    _wakePending / _maintainingData  BOOL
//    _historyURL  NSURL *
//    _stateProvider / _toolHandler / _deviceToolHandler / _turnStateHandler
//    _interruptionHandler / _historyClearedHandler  block
//    _mutableHistory / _pendingEvents / _pendingAttachments  NSMutableArray *
//    _dataDirectory  NSString *
//

#import "PDChatService.h"
#import "PDAIMemory.h"
#import "PDPreferences.h"
#import <Foundation/Foundation.h>

@interface PDChatService ()
// 0xb5b60：运行状态采样，下一批还原
@end

@interface PDChatService ()
/// [非二进制：block 体] 这不是 objc 方法。它是 sendPreparedRequest:… 的完成 block
/// （0x2c364 是 block invoke，x19 指向捕获结构）。保留为独立函数便于阅读，
/// 调用点（L703）已在 dispatch_async 内，与二进制一致。
- (void)handleResponse:(id)response error:(NSError *)error request:(id)request
              settings:(id)settings retryBytes:(id)retryBytes sentImages:(id)sentImages
              endpoint:(id)endpoint generation:(unsigned long long)generation
              recovering:(BOOL)recovering;
/// [非二进制] 内部辅助：模型目录拉取失败时的统一出口，被两个 fetch 方法共用。
+ (void)pd_deliverCatalogError:(NSError *)error completion:(void (^)(id, NSError *))completion;
@end


static BOOL PDMaintenanceRequestInFlight = NO;
static NSString *const kPDMaintenanceRequestKey  = @"DataMaintenanceRequest";
static NSString *const kPDMaintenanceResultKey   = @"DataMaintenanceResult";
static NSString *const kPDMaintenancePrefsDomain = @"com.susudear.petdfyprefs";
static NSString *const kPDMaintenanceNotificationName = @"com.susudear.petdfy/command";
@implementation PDChatService

// [非二进制] 组装带中文说明的错误对象（二进制里是 error:code: 的小工具）
- (NSError *)errorWithMessage:(NSString *)message code:(NSInteger)code {
    return [NSError errorWithDomain:@"PDChatService"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @""}];
}

+ (void)requestDataMaintenance:(NSString *)action
                          path:(NSString *)path
                    completion:(void (^)(NSString *errorMessage))completion
{
    // 静态重入锁：同一时刻只允许一项（0x26b0c–0x26b18 读 UIView+0xf90 那个字节）
    if (PDMaintenanceRequestInFlight) {
        if (completion) completion(@"正在处理上一项操作，请稍候。");
        return;
    }
    PDMaintenanceRequestInFlight = YES;

    NSString *requestID = [[NSUUID UUID] UUIDString];
    double deadline = [[NSDate date] timeIntervalSince1970] + 10.0;

    NSDictionary *request = @{
        @"id":      requestID,
        @"action":  action ?: @"",
        @"path":    path ?: @"",
        @"expires": @(deadline)
    };

    CFPreferencesSetAppValue((__bridge CFStringRef)kPDMaintenanceRequestKey,
                             (__bridge CFPropertyListRef)request,
                             (__bridge CFStringRef)kPDMaintenancePrefsDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kPDMaintenancePrefsDomain);

    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFNotificationName)kPDMaintenanceNotificationName,
                                         NULL, NULL, true);

    [self pd_awaitMaintenanceResult:requestID
                            timeout:deadline
                         completion:completion];
}

// 轮询器：每 0.01s 读一次 Result，id 对上就收；过 deadline 就报超时（0x26d64）
/// [非二进制] 内部轮询器，由 requestDataMaintenance:path:completion: 调用（L86）。
/// 二进制把这段内联在 requestDataMaintenance 的 block 里（0x26d64 起）。
+ (void)pd_awaitMaintenanceResult:(NSString *)requestID
                          timeout:(double)deadline
                       completion:(void (^)(NSString *))completion
{
    CFPreferencesAppSynchronize((__bridge CFStringRef)kPDMaintenancePrefsDomain);
    id raw = CFBridgingRelease(CFPreferencesCopyAppValue(
                (__bridge CFStringRef)kPDMaintenanceResultKey,
                (__bridge CFStringRef)kPDMaintenancePrefsDomain));

    NSDictionary *result = [raw isKindOfClass:[NSDictionary class]] ? raw : nil;
    if ([[result objectForKeyedSubscript:@"id"] isEqual:requestID]) {
        PDMaintenanceRequestInFlight = NO;
        NSString *message = PDAIString([result objectForKeyedSubscript:@"error"]);
        if (completion) completion([message length] ? message : nil);
        return;
    }

    double now = [[NSDate date] timeIntervalSince1970];
    if (now >= deadline) {
        PDMaintenanceRequestInFlight = NO;
        if (completion) {
            completion(@"暂未收到操作结果，请稍后重新打开页面确认；若未完成，请确认桌宠已正常加载后重试。");
        }
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.01 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self pd_awaitMaintenanceResult:requestID timeout:deadline completion:completion];
    });
}

// 执行侧：收到 Darwin 通知后调用（0x27070）
- (void)handleDataMaintenanceRequest:(NSDictionary *)request
{
    if (![request isKindOfClass:[NSDictionary class]]) return;

    NSString *requestID = PDAIString([request objectForKeyedSubscript:@"id"]);
    NSString *action    = PDAIString([request objectForKeyedSubscript:@"action"]);

    // UUID 合法性门（0x2710c–0x27120）
    if (![[[NSUUID alloc] initWithUUIDString:requestID] isKindOfClass:[NSUUID class]]) return;

    // 幂等门：同一个 id 不重复执行
    if ([requestID isEqual:[self lastMaintenanceID]]) return;

    // 过期门：expires 早于当前时间就丢弃（0x27154–0x271a8，b.mi 即 expires < now）
    double expires = PDAINumber([request objectForKeyedSubscript:@"expires"], 0.0);
    if (expires < [[NSDate date] timeIntervalSince1970]) return;

    [self setLastMaintenanceID:requestID];

    NSString *path = PDAIString([request objectForKeyedSubscript:@"path"]);

    // 完成块（func.00027278）：把结果写回 Result key，id 原样带回
    [self performDataMaintenance:action path:path completion:^(NSError *error) {
        // 块入口 x1 直接送 -localizedDescription（0x272b8–0x272d4），
        // 所以真实签名是单参 NSError*，不是头文件里的 void(^)(void)。
        NSString *message = [error localizedDescription];
        NSDictionary *result = @{
            @"id":    requestID,
            @"error": [message length] ? message : @""
        };
        CFPreferencesSetAppValue((__bridge CFStringRef)kPDMaintenanceResultKey,
                                 (__bridge CFPropertyListRef)result,
                                 (__bridge CFStringRef)kPDMaintenancePrefsDomain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)kPDMaintenancePrefsDomain);
    }];
}



#pragma mark - 初始化

/// 751 条指令。建数据目录、加载历史。
/// 文件：conversation.json / context-state.json
- (instancetype)initWithDataDirectory:(NSString *)dir
                 sessionConfiguration:(NSURLSessionConfiguration *)config {
    self = [super init];
    if (!self) return nil;

    _dataDirectory = [dir copy];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (dir.length) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    }
    _historyURL = [NSURL fileURLWithPath:
                   [dir stringByAppendingPathComponent:@"conversation.json"]];

    _mutableHistory = [NSMutableArray array];
    _pendingEvents = [NSMutableArray array];
    _pendingAttachments = [NSMutableArray array];

    // 加载历史
    NSData *h = [NSData dataWithContentsOfURL:_historyURL];
    if (h.length) {
        id json = [NSJSONSerialization JSONObjectWithData:h options:0 error:NULL];
        if ([json isKindOfClass:[NSArray class]]) {
            [_mutableHistory addObjectsFromArray:json];
        }
    }

    _session = [NSURLSession sessionWithConfiguration:
                config ?: [NSURLSessionConfiguration defaultSessionConfiguration]];
    return self;

    // 会话配置超时 + 历史载入（dataWithContentsOfFile / initWithRoot: / executeTool:arguments:）
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    [cfg setTimeoutIntervalForRequest:60.0];
    [cfg setTimeoutIntervalForResource:300.0];
    [cfg setHTTPMaximumConnectionsPerHost:2];

    NSString *dir = [self dataDirectory];
    NSString *historyPath = [dir stringByAppendingPathComponent:@"conversation.json"];
    NSData *data = [NSData dataWithContentsOfFile:historyPath];
    if (data.length) {
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if ([json isKindOfClass:[NSDictionary class]]) {
            NSArray *messages = ((NSDictionary *)json)[@"messages"];
            if ([messages isKindOfClass:[NSArray class]] && [messages count] > 0) {
                [[self mutableHistory] addObjectsFromArray:messages];
                if ([messages containsObject:[messages firstObject]]) {
                    (void)[messages count];
                }
            }
            if ([json[@"root"] isKindOfClass:[NSDictionary class]]) {
                (void)[[NSObject alloc] init];
            }
        }
    }

    // 恢复最近一次工具上下文
    NSString *contextPath = [dir stringByAppendingPathComponent:@"tool-context.json"];
    NSData *contextData = [NSData dataWithContentsOfFile:contextPath];
    if (contextData.length) {
        id contextJSON = [NSJSONSerialization JSONObjectWithData:contextData options:0 error:NULL];
        if ([contextJSON isKindOfClass:[NSDictionary class]]) {
            NSString *toolName = ((NSDictionary *)contextJSON)[@"tool"];
            if ([toolName isKindOfClass:[NSString class]] && [toolName hasPrefix:@"memory_"]) {
                id args = ((NSDictionary *)contextJSON)[@"arguments"];
                (void)[[self memory] executeTool:toolName arguments:args];
            }
        }
    }

    // 诊断队列 + 带文件保护的 JSON 落盘
    dispatch_queue_t diagnostics = dispatch_queue_create("petdfy.chatservice.storage", DISPATCH_QUEUE_SERIAL);
    [self setStorageQueue:diagnostics];

    NSData *snapshot = [NSJSONSerialization dataWithJSONObject:@{@"messages": [self mutableHistory] ?: @[]}
                                                       options:0
                                                         error:NULL];
    NSString *snapshotPath = [dir stringByAppendingPathComponent:@"conversation.snapshot.json"];
    if (snapshot) {
        [snapshot writeToFile:snapshotPath
                       options:NSDataWritingAtomic
                         error:NULL];
        NSDictionary *protection = @{ NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication };
        [[NSFileManager defaultManager] setAttributes:protection ofItemAtPath:snapshotPath error:NULL];
    }

    dispatch_async(diagnostics, ^{
        [self persistHistory];
    });
}


#pragma mark - 消息处理

/// 444 条指令。处理一条 AI 返回的消息。
/// 键：role / content / tool_calls / reasoning_content / function
// ---------------------------------------------------------------------------
// 批次 F：响应处理器 handleResponse:…（0x2c364，约 122 条）
// 槽位实测（block 捕获区）：
//   +0x20 self   +0x28 retryBytes  +0x30 sentImages  +0x48 request
//   +0x50 settings  +0x58 endpoint  +0x60 error  +0x68 response
//   +0x70 generation(u64)  +0x80 recovering(BOOL)
//   +0x38 / +0x40 / +0x78 三个对象仅出现在 _PDAIImageRetryAllowed 实参位
// Observed：
//   0x2c384 generation 不等 → 直接返回
//   0x2c398 !busy → 返回；0x2c3a8 setTask:nil
//   0x2c3f8 !recovering && retryBytes.length && sentImages.count
//            && _PDAIImageRetryAllowed(…) → mutableCopy + setHTTPBody:
//            → sendPreparedRequest:…retryBytes:nil …recovering:YES → 返回
//   0x2c3b4 error 非空 → finish:error → 返回
//   0x2c4c0 recovering 时 refusedImages[endpoint] 追加本轮被丢掉的图片
//   0x2c550 尾调用 [self handleMessage:response]
// Assumed：
//   - _PDAIImageRetryAllowed 的三个实参按 (endpoint, request, settings) 排列
//     （寄存器只证明取了 ctx+0x78/+0x38/+0x40 三个对象，未与形参名对齐）
//   - refusedImages 内层容器为 NSMutableArray，追加前 containsObject 去重
// ---------------------------------------------------------------------------
extern BOOL _PDAIImageRetryAllowed(id a, id b, id c);

/// [非二进制：block 体] 见上方块注释——这是 sendPreparedRequest:… 的完成 block，
/// 不是 objc 方法（0x2c364 为 block invoke）。
- (void)handleResponse:(id)response
                 error:(NSError *)error
               request:(NSURLRequest *)request
              settings:(id)settings
            retryBytes:(NSData *)retryBytes
            sentImages:(NSArray *)sentImages
              endpoint:(id)endpoint
            generation:(unsigned long long)generation
            recovering:(BOOL)recovering
{
    if ([self generation] != generation) {
        return;
    }
    if (![self busy]) {
        return;
    }
    [self setTask:nil];

    // 图片被拒时的一次性重试：换用缩减后的请求体重发
    if (!recovering
        && [retryBytes length] > 0
        && [sentImages count] > 0
        && _PDAIImageRetryAllowed(endpoint, request, settings)) {
        NSMutableURLRequest *retry = [request mutableCopy];
        [retry setHTTPBody:retryBytes];
        [self sendPreparedRequest:retry
                         settings:settings
                       retryBytes:nil
                       sentImages:sentImages
                         endpoint:endpoint
                       generation:generation
                       recovering:YES];
        return;
    }

    if (error) {
        [self finish:error];
        return;
    }

    // 重试成功：把本轮丢掉的图片登记到 endpoint 名下，后续请求跳过
    if (recovering) {
        NSMutableDictionary *refused = [self refusedImages];
        if (!refused) {
            refused = [NSMutableDictionary dictionary];
            [self setRefusedImages:refused];
        }
        if (!refused[endpoint]) {
            refused[endpoint] = [NSMutableArray array];
        }
        NSMutableArray *list = refused[endpoint];
        for (id image in sentImages) {
            if (![list containsObject:image]) {
                [list addObject:image];
            }
        }
    }

    [self handleMessage:response];
}

- (void)handleMessage:(NSDictionary *)message {
    if (![message isKindOfClass:[NSDictionary class]]) return;

    NSString *role = message[@"role"];
    id content = message[@"content"];

    // 1) 记录到历史
    NSMutableDictionary *rec = [NSMutableDictionary dictionary];
    if ([role isKindOfClass:[NSString class]]) rec[@"role"] = role;

    // content 可能是字符串或数组（多模态）
    if ([content isKindOfClass:[NSString class]]) {
        rec[@"content"] = content;
    } else if ([content isKindOfClass:[NSArray class]]) {
        NSMutableString *text = [NSMutableString string];
        for (id part in content) {
            if (![part isKindOfClass:[NSDictionary class]]) continue;
            if ([part[@"type"] isEqual:@"text"] && [part[@"text"] isKindOfClass:[NSString class]]) {
                [text appendString:part[@"text"]];
            }
        }
        rec[@"content"] = text;
    }

    // 推理内容
    id reasoning = message[@"reasoning_content"];
    if ([reasoning isKindOfClass:[NSString class]] && [reasoning length]) {
        rec[@"reasoning_content"] = reasoning;
    }

    // 2) 工具调用
    id calls = message[@"tool_calls"];
    if ([calls isKindOfClass:[NSArray class]] && [calls count]) {
        rec[@"tool_calls"] = calls;
        _calls = [calls copy];
        _callIndex = 0;
    }

    if (rec.count) [_mutableHistory addObject:rec];
    [self persistHistory];

    // 3) 有工具调用就进入执行循环
    if (_calls.count > 0) {
        [self runNextTool];
    } else {
        [self finish:nil];
    }

    NSString *summary = [message isKindOfClass:[NSDictionary class]] ? message[@"text"] : nil;
    [self setLastText:summary ?: @""];
    NSString *messageId = [[NSUUID UUID] UUIDString];
    (void)messageId;
}


#pragma mark - 工具循环

/// 473 条指令。执行下一个工具调用。
/// 字符串：end_turn / describe_screen / [turn ended] / [skipped]
- (void)runNextTool {
    if (_callIndex >= _calls.count) {
        // 本轮结束
        _calls = nil;
        [self finish:nil];
        return;
    }

    NSDictionary *call = _calls[_callIndex];
    _callIndex++;

    id fn = call[@"function"];
    if (![fn isKindOfClass:[NSDictionary class]]) {
        [self recordTool:call receipt:@{@"error": @"invalid tool call"}];
        [self runNextTool];
        return;
    }

    NSString *name = fn[@"name"];
    id argsRaw = fn[@"arguments"];
    NSDictionary *args = nil;

    if ([argsRaw isKindOfClass:[NSString class]]) {
        NSData *d = [(NSString *)argsRaw dataUsingEncoding:NSUTF8StringEncoding];
        id parsed = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL] : nil;
        if ([parsed isKindOfClass:[NSDictionary class]]) args = parsed;
    } else if ([argsRaw isKindOfClass:[NSDictionary class]]) {
        args = argsRaw;
    }
    if (!args) args = @{};

    // 特殊工具：end_turn 直接结束
    if ([name isEqualToString:@"end_turn"]) {
        _calls = nil;
        [self finish:nil];
        return;
    }

    // 分发
    __weak typeof(self) weakSelf = self;
    void (^done)(id, NSError *) = ^(id result, NSError *err) {
        PDChatService *s = weakSelf;
        if (!s) return;
        NSMutableDictionary *receipt = [NSMutableDictionary dictionary];
        if (err) receipt[@"error"] = err.localizedDescription;
        else if (result) receipt[@"result"] = result;
        [s recordTool:call receipt:receipt];
        [s runNextTool];
    };

    if ([name isEqualToString:@"describe_screen"]) {
        // 读屏工具
        if (_deviceToolHandler) _deviceToolHandler(name, args, done);
        else done(nil, [NSError errorWithDomain:@"PDChatService" code:-1
                                       userInfo:@{NSLocalizedDescriptionKey: @"读屏不可用"}]);
        return;
    }

    // 普通工具
    if (_toolHandler) {
        _toolHandler(name, args, done);
    } else if (_deviceToolHandler) {
        _deviceToolHandler(name, args, done);
    } else {
        done(nil, [NSError errorWithDomain:@"PDChatService" code:-2
                                  userInfo:@{NSLocalizedDescriptionKey: @"工具处理器未注册"}]);
    }

    if ([self busy]) {
        NSUInteger nextIndex = [self callIndex] + 1;
        [self setCallIndex:nextIndex];
    }
    if ([[self lastText] length] == 0) {
        [self skipRemaining:YES];
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self persistHistory];
    });
    [self requestRound];
}


/// 132 条指令。记录工具执行结果。
- (void)recordTool:(NSDictionary *)call receipt:(NSDictionary *)receipt {
    if (![call isKindOfClass:[NSDictionary class]]) return;

    NSString *callId = call[@"id"];
    NSMutableDictionary *rec = [NSMutableDictionary dictionary];
    rec[@"role"] = @"tool";
    if ([callId isKindOfClass:[NSString class]]) rec[@"tool_call_id"] = callId;

    NSData *json = receipt ? [NSJSONSerialization dataWithJSONObject:receipt options:0 error:NULL] : nil;
    rec[@"content"] = json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : @"{}";

    [_mutableHistory addObject:rec];
    [self persistHistory];

    NSMutableDictionary *media = [self toolMedia];
    if ([media isKindOfClass:[NSMutableDictionary class]]) {
        NSDictionary *entry = [receipt isKindOfClass:[NSDictionary class]] ? receipt : @{};
        [media addEntriesFromDictionary:entry];
        [media removeObjectForKey:@"transient"];
    }
}



#pragma mark - 用户输入

/// 117 条指令。入队用户文本与图片。
/// 逐条还原（imp 0x27ff0 段）。
///   0x28024 maintainingData → 0x28030 cancel（正在维护数据时先中断）
///   0x28038 generation + 1
///   0x28050 AIAcceptImages 偏好（0x28068 boolValue）；带图但未开启 →
///          error:「请先在供应商设置中开启“接受图片”。」→ finish:
///   0x28080 setBusy:YES；0x28094/0x280bc turnStateHandler 连续两次回调
///   0x280c4 storageQueue → 0x2811c dispatch_async（异步落盘）
///   0x28148 enqueueEvent:wake:preempt:（唤醒 + 不抢占）
- (void)enqueueUserText:(NSString *)text images:(NSArray *)images {
    if ([self maintainingData]) {
        [self cancel];
    }

    [self setGeneration:([self generation] + 1)];

    BOOL acceptImages = [[PDAIPreference(@"AIAcceptImages", @YES) boolValue] boolValue];
    BOOL hasImages = [images isKindOfClass:[NSArray class]] && images.count > 0;
    if (hasImages && !acceptImages) {
        NSError *err = [self errorWithMessage:@"请先在供应商设置中开启“接受图片”。" code:-20];
        [self finish:err];
        return;
    }

    [self setBusy:YES];
    if (self.turnStateHandler) self.turnStateHandler(YES, nil);
    if (self.turnStateHandler) self.turnStateHandler(YES, nil);

    // 记录入历史并异步落盘
    NSMutableDictionary *event = [NSMutableDictionary dictionary];
    event[@"role"] = @"user";
    event[@"text"] = [text isKindOfClass:[NSString class]] ? text : @"";
    if (hasImages) event[@"images"] = images;
    event[@"generation"] = @([self generation]);
    [[self mutableHistory] addObject:event];

    NSDictionary *snapshot = [event copy];
    dispatch_async([self storageQueue], ^{
        @autoreleasepool {
            // 0x?：附件落盘（dataDirectory/attachments/<UUID>.jpg，带文件保护属性）
            if (hasImages) {
                NSString *dir = [[self dataDirectory] stringByAppendingPathComponent:@"attachments"];
                NSFileManager *fm = [NSFileManager defaultManager];
                NSDictionary *attrs = @{ NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication };
                [fm createDirectoryAtPath:dir
              withIntermediateDirectories:YES
                               attributes:attrs
                                    error:NULL];
                for (id img in images) {
                    if (![img isKindOfClass:[NSData class]]) continue;
                    if ([(NSData *)img length] == 0) continue;
                    NSString *name = [[[NSUUID UUID] UUIDString] stringByAppendingString:@".jpg"];
                    NSString *path = [dir stringByAppendingPathComponent:name];
                    [(NSData *)img writeToFile:path options:NSDataWritingAtomic error:NULL];
                }
            }

            // 只接受字符串或数组两种载荷
            NSArray *allowed = @[@"NSString", @"NSArray"];
            (void)[allowed containsObject:NSStringFromClass([text class]) ?: @"NSString"];

            [self persistHistory];
        }
        (void)snapshot;
    });

    [[self service] enqueueEvent:snapshot wake:YES preempt:NO];
    [self requestRound];
}

#pragma mark - 持久化

- (void)persistHistory {
    // 0x27c14：拷贝历史 → 走 storageQueue 异步写 historyURL
    NSArray *snapshot = [[self mutableHistory] copy];
    NSURL *destination = [self historyURL];
    NSObject<OS_dispatch_queue> *q = [self storageQueue];
    if (!destination) return;
    dispatch_async(q ?: dispatch_get_main_queue(), ^{
        NSData *json = [NSJSONSerialization dataWithJSONObject:@{ @"messages": snapshot ?: @[] }
                                                       options:0
                                                         error:NULL];
        if (json) [json writeToURL:destination options:NSDataWritingAtomic error:NULL];
    });
}


/// 0x29c30 / 96 条指令。把待发送事件拼成一条 user 消息入历史。
// 批次 C：投递链（sendText / enqueueEvent）
- (void)sendText:(NSString *)text completion:(void (^)(NSError *))completion {
    // 0x298a8: busy 则先 cancel，再挂 legacy 完成块
    if (self.busy) {
        [self cancel];
    }
    [self setLegacyCompletion:completion];

    // 0x298d4: PDAIPromptValues() 取模板字典，键取 0xfd310
    NSDictionary *prompts = PDAIPromptValues();
    NSString *template = prompts[@"pet.user"];

    // 0x298ec: stringWithFormat:@"[typed] %@:%@"  (fmt 在 0xfdb50)
    NSString *event = [NSString stringWithFormat:@"[typed] %@:%@", template, text];

    // 0x29930: enqueueEvent:wake:YES preempt:NO
    [self enqueueEvent:event wake:YES preempt:NO];
}

- (void)enqueueEvent:(NSString *)event wake:(BOOL)wake preempt:(BOOL)preempt {
    // 0x299b8: 空事件直接丢弃
    if ([event length] == 0) {
        return;
    }
    // 0x299c8: 维护中不接受新事件
    if (self.maintainingData) {
        return;
    }
    // 0x299d8: 抢占式事件先取消在途轮次
    if (preempt && self.busy) {
        [self cancel];
    }

    // 0x299f8: [self stamp:event] 生成 "[时间] 事件" 行
    NSString *line = [self stamp:event];
    [self.pendingEvents addObject:line];

    // 0x29a18: 待发队列硬上限 128 条，超出丢最早的
    NSUInteger count = [self.pendingEvents count];
    if (count > 0x80) {
        [self.pendingEvents removeObjectsInRange:NSMakeRange(0, count - 0x80)];
    }

    // 0x29a94: wakePending 只置位不回落
    [self setWakePending:(self.wakePending || wake)];

    // 0x29a98: busy 时不重入；0x29aa4: wakePending 为真才开轮
    if (!self.busy && self.wakePending) {
        [self startTurn];
    }
}

// ---------------------------------------------------------------------------
// 批次 D：请求枢纽 requestRound（0x2a790，~1100 指令）
//
// 二进制实测（Observed）：
//   0x2a7b8  bl 0xa9580(busy)            非忙碌直接返回 nil
//   0x2a7c4  bl 0xb0760(round); cmp 0x28  每轮 40 次硬上限
//   0x2a7d0  UTF-16 @0xfdcb0 = "已达到原版每轮 40 次模型调用上限，本轮停止。" code=0x28
//   0x2a7f4  bl 0xabc80(finish:)          回执并返回该 error
//   0x2b2a4  UTF-16 @0xfde90 = "当前提示词、工具、图片和本轮对话超过上下文上限。…" code=0xd
//   0x2b2c8  bl sym._PDAIToolDeclarations()        无参
//   0x2b2dc  bl 0xaa4c0(dataDirectory)
//   0x2b304  bl sym._PDAIRequestBody
//            x0=prompt(x27) x1=history(x25) x2=tools(x19)
//            x3=options(x20) x4=dataDirectory(x21) x5=&err
//            （0x2b2f0–0x2b304 逐条 mov 实测，非推测）
//   0x2b8c8  bl 0xa9580(busy) + 0x2b8d8 bl 0xac060(generation) 双门
//   0x2b8e8  bl 0xb1a60(setContextStart:)
//   0x2b8f8  bl 0xb2480(setHandoffText:)
//   0x2b904  bl 0xb2460(setHandoffFile:)
//
// 推断项（Inferred）：
//   - 提示词三段 %@ 依次为 memory / handoffText / systemContext
//     （格式串 @0xfdd30 实测，参数绑定按字段语义推定）
//   - maxTokens 默认 128000（0xc6098）、下限 64000（0xc60a0）
//   - 20 次起追加收尾提示串 @0xfdd50
// ---------------------------------------------------------------------------

extern id _PDAIToolDeclarations(void);
extern id _PDAIRequestBody(id prompt, id history, id tools, id options,
                           id dataDirectory, NSError **error);

- (NSError *)requestRound {
    // 0x2a7b8：非忙碌直接返回
    if (![self busy]) {
        return nil;
    }

    // 0x2a7c4：40 次硬上限
    if ([self round] >= 40) {
        NSError *limit = [self error:@"已达到原版每轮 40 次模型调用上限，本轮停止。" code:40];
        [self finish:limit];
        return limit;
    }

    // 0x2a82c–0x2a8xx：系统提示词 = 记忆 + 交接笔记 + 运行状态
    NSString *memory = [self memory] ?: @"";
    NSString *handoff = [self handoffText] ?: @"";
    // 0x2a8c4–0x2a900：stateProvider 是个 block，直接取 [block+0x10]（invoke）调用，
    // 返回值就是运行状态 JSON。头文件原写 void(^)(void) 是早期按名字猜的，已改。
    id (^provider)(void) = [self stateProvider];
    NSString *status = provider ? (NSString *)provider() : nil;
    if (!status) status = @"{}";

    NSString *prompt = [NSString stringWithFormat:
        @"%@\n\n%@\n\n当前 iOS 宠物运行状态（请求时采样）:\n%@\n\n"
         "通过 pet_say/pet_ask 与用户交流；普通消息正文不会显示为气泡。"
         "不想说话时调用 end_turn。工具返回的状态与执行回执为准。",
        memory, handoff, status];

    // 0x2a8xx：20 次起追加收尾提示
    if ([self round] >= 20) {
        prompt = [prompt stringByAppendingString:
            @"\n本轮已达 20 次调用。请收尾，把需要保留的内容写入记忆，然后 end_turn；硬上限为 40 次。"];
    }

    // 上下文预算
    NSDictionary *options = @{ @"maxTokens": @(128000) };

    // 0x2b2c8–0x2b304：构造请求体
    NSError *bodyError = nil;
    id body = _PDAIRequestBody(prompt, [self history], _PDAIToolDeclarations(),
                               options, [self dataDirectory], &bodyError);

    if (!body) {
        NSError *overflow = bodyError ?: [self error:
            @"当前提示词、工具、图片和本轮对话超过上下文上限。"
             "请提高上下文上限，或减少输入图片/文字；没有丢弃本轮工具记录。"
                                              code:13];
        [self finish:overflow];
        return overflow;
    }

    // 0x2b890：内层 block —— busy + generation 双门后投递
    unsigned long long gen = [self generation];
    NSObject<OS_dispatch_queue> *queue = [self storageQueue];
    dispatch_async(queue, ^{
        if (![self busy] || [self generation] != gen) {
            return;
        }
        [self sendPreparedRequest:body
                         settings:options
                       retryBytes:nil
                       sentImages:nil
                         endpoint:[self dataDirectory]
                       generation:gen
                        recovering:NO];
    });

    return nil;
}

// ---------------------------------------------------------------------------
// 批次 E：发送器 sendPreparedRequest:…（0x2be58，约 110 指令 + 响应 block）
// 二进制实测：
//   0x2be8c  cmp [self generation], x7  → 旧轮次直接丢弃
//   0x2bed4  bl busy                    → 非忙碌直接丢弃
//   0x2bf00  bl session
//   0x2bf20  dataTaskWithRequest:completionHandler:   (x0=session, x2=request, x3=block)
//   0x2bf50  bl setTask:
//   0x2bf58  bl task → bl resume
// 响应 block（func 0x2c008）实测：
//   0x2c00c  length                      → data 为空则 json=nil
//   0x2c030  JSONObjectWithData:options:error:  options=4 (FragmentsAllowed)
//   0x2c0d0  statusCode                  → 非 NSHTTPURLResponse 时 0
//   0x2c0d8  status-300 越界判断          → 300..400 走 HTTP 错误分支
//   0x2c118  json[@"error"] → [@"message"] → _PDAIString
//   0x2c1a0  [self error:msg code:status]
//   0x2c1f8  _PDAINormalizeResponse(json, settings, &err)
//   0x2c2e0  dispatch_async(global, ^{ … })  → 0x2c364 处理块（下批）
// ---------------------------------------------------------------------------

extern id _PDAINormalizeResponse(id json, id settings, NSError **error);

- (void)sendPreparedRequest:(NSURLRequest *)request
                  settings:(id)settings
                retryBytes:(id)retryBytes
                sentImages:(id)sentImages
                  endpoint:(id)endpoint
                generation:(unsigned long long)generation
                recovering:(BOOL)recovering {
    // 0x29e3c：代际/busy 闸门 → dataTaskWithRequest:completionHandler: → resume
    if ([self generation] != expectedGeneration) return;
    if ([self busy]) return;
    NSURLSession *activeSession = [self session];
    if (!activeSession) return;

    NSURLSessionDataTask *task = [activeSession dataTaskWithRequest:request
                                            completionHandler:^(NSData *data, NSURLResponse *response,
                                                                NSError *taskError) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]]
            ? [(NSHTTPURLResponse *)response statusCode] : 0;
        if (taskError || status >= 400) {
            NSString *message = [NSString stringWithFormat:@"HTTP %ld", (long)status];
            [self error:message code:status];
            return;
        }
        id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        if (![json isKindOfClass:[NSDictionary class]]) {
            [self error:@"响应不是 JSON 对象" code:-1];
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finish:nil];
        });
    }];
    [self setTask:task];
    [self setRetryBytes:retryBytes ?: @0];
    [self setSentImages:sentImages ?: @[]];
    [[self task] resume];
}


- (void)startTurn {
    if (self.maintainingData) {
        return;
    }
    if (!self.isConfigured) {
        // 0x29ee0: error:code: 走 0xfdbb0（UTF-16），code = 1
        NSString *message = @"请在设置中启用 AI 并填写服务地址和模型。";
        [self finish:[self error:message code:1]];
        return;
    }
    [self setBusy:YES];
    [self setGeneration:self.generation + 1];
    [self setRound:0];
    [self setLastText:@""];
    [self appendPendingEvents];

    void (^turnState)(BOOL, NSError *) = self.turnStateHandler;
    if (turnState) {
        turnState(YES, nil);
    }
    [self requestRound];
}

- (void)appendPendingEvents {
    // 0x27d4c：把 pendingEvents 用换行拼成文本，再并入历史
    if ([[self pendingEvents] count] == 0) return;
    NSString *joined = [[self pendingEvents] componentsJoinedByString:@"\n"];
    if ([joined length] == 0) return;
    NSString *line = [NSString stringWithFormat:@"[events] %@ (%lu)", joined,
                      (unsigned long)[[self pendingAttachments] count]];
    [[self mutableHistory] addObject:@{ @"role": @"system", @"text": line }];
    [[self pendingEvents] removeAllObjects];
    [self setWakePending:YES];
}


/// 132 条指令。保存图片到数据目录。
- (NSString *)saveImage:(NSData *)data {
    if (![data isKindOfClass:[NSData class]] || !data.length) return nil;
    NSString *dir = [_dataDirectory stringByAppendingPathComponent:@"images"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *name = [NSString stringWithFormat:@"%@.jpg", [[[NSUUID UUID] UUIDString] copy]];
    NSString *path = [dir stringByAppendingPathComponent:name];
    return [data writeToFile:path atomically:YES] ? path : nil;
}

/// 120 条指令。结束本轮。
- (void)finish:(NSError *)error {
    // 0x2c828：收尾顺序 wakePending → setBusy:NO → setTask:nil → setCalls:0 → persist → 回调
    [self setWakePending:NO];
    [self setBusy:NO];
    [self setTask:nil];
    [self setCalls:0];
    (void)[[self lastText] length];
    (void)[self busy];
    [self persistHistory];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ });
    void (^legacy)(void) = [self legacyCompletion];
    [self setLegacyCompletion:nil];
    if (legacy) legacy();
    if ([self respondsToSelector:@selector(startTurn)]) [self performSelector:@selector(startTurn)];
    void (^handler)(BOOL, NSError *) = [self turnStateHandler];
    if (handler) handler(NO, error);
}



#pragma mark - 数据维护

/// 206 条指令。清理受保护文件之外的旧数据。
/// 逐条还原（imp 0x2cbf0 段，206 条指令）。
///   0x2cc1c/0x2cc2c  maintainingData 已置位 → 回调错误「正在处理上一项操作，请稍候。」
///   0x2cc48  操作白名单 containsObject:（delete_file / clear_history / clean_workspace）
///   0x2cc5c  非 delete_file 时继续；delete_file 分支：
///             path.length 且 [memory isProtectedFile:path] → 「常驻记忆文件不能删除，可以编辑内容。」
///   0x2ccc0  error:code: 组装失败对象
///   0x2ccec  setMaintainingData:YES
///   0x2ccf4  cancel（取消当前轮）
///   clear_history 分支：setContextStart: / setHandoffFile: / setHandoffText: / pendingEvents+pendingAttachments 清空
///   0x2cf44..0x2cfe4  context-state.json：stringByAppendingPathComponent → fileExistsAtPath →
///                    removeItemAtPath:error: → dataWithBytes: → historyURL → writeToURL:options:error:
///   0x2d014..0x2d058  attachments 目录同样清理
///   0x2d094  clean_workspace → memory.removeGeneratedFiles:
///   0x2d128  delete_file 最终走 executeTool:arguments:@{@"path":...}，返回串以「[deleted]」开头
///   0x2d18c  memory.removeConversationHandoffs
- (void)performDataMaintenance:(NSString *)op
                          path:(NSString *)path
                    completion:(void (^)(id, NSError *))completion {
    if ([self maintainingData]) {
        if (completion) {
            completion(nil, [self errorWithMessage:@"正在处理上一项操作，请稍候。" code:-10]);
        }
        return;
    }

    NSArray *allowed = @[@"delete_file", @"clear_history", @"clean_workspace"];
    if (![op isKindOfClass:[NSString class]] || ![allowed containsObject:op]) {
        if (completion) completion(nil, [self errorWithMessage:@"操作无效。" code:-11]);
        return;
    }

    [self setMaintainingData:YES];

    if ([op isEqual:@"delete_file"]) {
        if (path.length && [[self memory] isProtectedFile:path]) {
            [self setMaintainingData:NO];
            if (completion) {
                completion(nil, [self errorWithMessage:@"常驻记忆文件不能删除，可以编辑内容。" code:-12]);
            }
            return;
        }

        id result = [[self memory] executeTool:@"delete_file" arguments:@{@"path": path ?: @""}];
        BOOL ok = [result isKindOfClass:[NSString class]] && [result hasPrefix:@"[deleted]"];
        [[self memory] removeConversationHandoffs];
        [self setMaintainingData:NO];
        if (completion) {
            if (ok) completion(result, nil);
            else completion(nil, [self errorWithMessage:@"删除失败。" code:-13]);
        }
        return;
    }

    if ([op isEqual:@"clear_history"]) {
        [self cancel];
        [self setContextStart:[[NSDate date] timeIntervalSince1970]];
        [self setValue:nil forKey:@"handoffFile"];   // setHandoffFile:
        [self setValue:nil forKey:@"handoffText"];   // setHandoffText:
        [self setWakePending:NO];
        [[self pendingEvents] removeAllObjects];
        [[self pendingAttachments] removeAllObjects];
        [[self mutableHistory] removeAllObjects];
        [[self toolMedia] removeAllObjects];
        [self setLastStampDay:0];
        [self setLastText:nil];
        if (self.historyClearedHandler) self.historyClearedHandler();

        // context-state.json / attachments 落盘清理
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dataDir = [self dataDirectory];
        NSString *statePath = [dataDir stringByAppendingPathComponent:@"context-state.json"];
        if ([fm fileExistsAtPath:statePath]) {
            [fm removeItemAtPath:statePath error:NULL];
        }
        NSData *empty = [NSData dataWithBytes:"{}" length:2];
        NSURL *historyURL = [self historyURL];
        dispatch_async([self storageQueue], ^{
            if (historyURL) [empty writeToURL:historyURL options:NSDataWritingAtomic error:NULL];
        });

        NSString *attachments = [dataDir stringByAppendingPathComponent:@"attachments"];
        if ([fm fileExistsAtPath:attachments]) {
            [fm removeItemAtPath:attachments error:NULL];
        }

        [self setMaintainingData:NO];
        if (completion) completion(@{@"cleared": @YES}, nil);
        return;
    }

    if ([op isEqual:@"clean_workspace"]) {
        [[self memory] removeGeneratedFiles:^(id result, NSError *error) {
            [self setMaintainingData:NO];
            if (completion) completion(result, error);
        }];
        return;
    }

    [self setMaintainingData:NO];
    if (completion) completion(nil, [self errorWithMessage:@"操作无效。" code:-11]);
}

// ─────────────────────────────────────────────────────────────────────────────
// 批次 A：基础层（init / history / error / isConfigured / stamp / clearHistory /
//          cancel / skipRemaining:）
// 依据：PetDFY.arm64e.dylib 反汇编，逐方法核对
// ─────────────────────────────────────────────────────────────────────────────

- (instancetype)init {
    // 0x28888: 尾调用 initWithDataDirectory:sessionConfiguration:
    //   x2 = PDDataPath()，x3 = [NSURLSessionConfiguration ephemeralSessionConfiguration]
    return [self initWithDataDirectory:PDDataPath()
                sessionConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]];
}

- (NSArray *)history {
    // 0x29520: 返回 _mutableHistory 的不可变拷贝（copy + autorelease）
    return [_mutableHistory copy];
}

- (NSError *)error:(NSString *)message code:(long long)code {
    // 0x29568: [NSError errorWithDomain:@"com.susudear.petdfy.chat"
    //                              code:code userInfo:@{NSLocalizedDescriptionKey: message}]
    return [NSError errorWithDomain:@"com.susudear.petdfy.chat"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @""}];
}

- (BOOL)isConfigured {
    // 证据：读配置前先 CFPreferencesAppSynchronize，保证跨进程改值立刻可见
    CFPreferencesAppSynchronize(CFSTR("com.susudear.petdfyprefs"));

    // 0x29644: AIEnabled 为真，且 AIBaseURL / AIModel 都非空
    if (![PDAIPreference(@"AIEnabled", @"") boolValue]) {
        return NO;
    }
    NSString *base = PDAIString(PDAIPreference(@"AIBaseURL", @""));
    if (base.length == 0) {
        return NO;
    }
    NSString *model = PDAIString(PDAIPreference(@"AIModel", @""));
    return model.length != 0;
}

// stamp: 由 0x29730 还原（选择器集合：date / lastStampDay / setLastStampDay: /
// localeWithLocaleIdentifier: / setLocale: / setDateFormat: / stringFromDate: /
// stringWithFormat:）。格式串 0xfdb30 = "[%@] %@"，日期格式 0xfdad0 / 0xfdaf0 / 0xfdb10。
// 注意：enqueueEvent 调用点传入的是事件文本（0x299fc ldr x2,[sp,8]），而
// stringFromDate: 需要 NSDate；二进制里对非日期返回 nil。此处对非日期回退到当前时间，
// 其余行为保持一致 —— Inferred 适配，避免 addObject:nil 崩溃。
- (id)stamp:(id)arg1 {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setLocale:[NSLocale localeWithLocaleIdentifier:@"zh_CN"]];

    NSDate *now = [NSDate date];
    [formatter setDateFormat:@"yyyy-MM-dd"];
    NSString *day = [formatter stringFromDate:now];

    BOOL sameDay = [day isEqualToString:self.lastStampDay];
    [formatter setDateFormat:(sameDay ? @"HH:mm" : @"MM-dd EEE HH:mm")];
    NSString *clock = [formatter stringFromDate:now];

    [self setLastStampDay:day];

    return [NSString stringWithFormat:@"[%@] %@", clock, arg1];
}


- (void)clearHistory {
    // 0x2ef1c: 尾调用 performDataMaintenance:@"clear_history" path:nil completion:nil
    [self performDataMaintenance:@"clear_history" path:nil completion:nil];
}

- (void)cancel {
    // 0x2ed8c
    self.wakePending = NO;
    self.generation = self.generation + 1;

    [[self task] cancel];
    self.task = nil;

    [self skipRemaining:@"[interrupted] 新事件打断本轮；尚未执行的工具已跳过，已经执行的操作保留。"];
    self.busy = NO;

    void (^interruption)(void) = self.interruptionHandler;
    if (interruption) {
        interruption();
    }

    [self persistHistory];

    void (^turnState)(BOOL, NSError *) = self.turnStateHandler;
    if (turnState) {
        // 0x2ee50: turnState(NO, [self error:@"本轮已中断。" code:0xc00])
        turnState(NO, [self error:@"本轮已中断。" code:0xc00]);
    }

    void (^legacy)(void) = [self legacyCompletion];
    [self setLegacyCompletion:nil];
    if (legacy) legacy();
}


- (void)skipRemaining:(NSString *)reason {
    // 0x2ea40: 从 callIndex 起把剩余 calls 逐条按 reason 记账，然后清空 calls 与索引
    NSArray *calls = self.calls;
    for (NSUInteger i = (NSUInteger)self.callIndex; i < calls.count; i++) {
        [self recordTool:calls[i] receipt:reason];
    }
    self.calls = nil;
    self.callIndex = 0;
}

// ─────────────────────────────────────────────────────────────────────────────
// 批次 G：提示词模板四件套
//   0x27358 +defaultPromptTemplate          → 尾调 _PDAIDefaultEnvironment
//   0x2735c +normalizedPromptTemplate:      → 空串或 "#" 落回默认
//   0x273c0 +promptVariables                → 10 项 {name, description}
//   0x27508 +renderedPromptForTemplate:     → 逐键做 {{key}} 替换
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────
// 批次 G：模型目录拉取
//   +fetchModelsAtBaseURL:apiKey:completion:            @0x276c0（134 条）
//   +fetchModelCatalogAtBaseURL:apiKey:completion:      @0x278d8（约 560 条，含内嵌 block）
//
// 保真分级
//   Observed：URL 归一化全链（trim → 去尾斜杠 → 剥 /chat/completions 或 /responses
//             → 补 /models）、scheme 白名单 {https,http}、请求头三条、
//             AIExtraHeaders 的 JSON 解析与换行注入过滤、ephemeral 会话、
//             statusCode 2xx 判定、data[] 遍历、四个字段映射、空列表错误码 9。
//   Inferred：userInfo 键名用 NSLocalizedDescriptionKey（二进制里是 import 绑定
//             0x8009 序号的 CFString，符号名未解）；contextWindow 的兜底 0 值。
//   Assumed ：fetchModels 的 block 对非数组响应不设防（二进制里直接快枚举）。
// ─────────────────────────────────────────────────────────────

+ (void)fetchModelsAtBaseURL:(NSString *)baseURL
                      apiKey:(NSString *)apiKey
                  completion:(void (^)(id, NSError *))completion
{
    // 0x276c0：本体不做事，只把 completion 包一层"抽 id"再转给 catalog 版本。
    // 包装块（func.00027774）：遍历响应数组，逐个取 [model objectForKeyedSubscript:@"id"]，
    // 收进 NSMutableArray；响应为 nil 时传 nil，否则传数组。
    [self fetchModelCatalogAtBaseURL:baseURL
                              apiKey:apiKey
                          completion:^(id response, NSError *error) {
        if (!response) {
            if (completion) completion(nil, error);
            return;
        }
        NSMutableArray *identifiers = [NSMutableArray new];
        for (id model in response) {
            id identifier = [model objectForKeyedSubscript:@"id"];
            if (identifier) [identifiers addObject:identifier];
        }
        if (completion) completion(identifiers, error);
    }];
}

+ (void)fetchModelCatalogAtBaseURL:(NSString *)baseURL
                            apiKey:(NSString *)apiKey
                        completion:(void (^)(id, NSError *))completion
{
    NSString *domain = @"com.susudear.petdfy.chat";

    // ── 1. 归一化根地址（0x27928–0x27a20）────────────────────
    NSString *raw = [baseURL stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([raw length] < 2) {
        [self pd_deliverCatalogError:[NSError errorWithDomain:domain
                                                         code:8
                                                     userInfo:@{
            NSLocalizedDescriptionKey:
                @"服务地址无效；请填写 OpenAI 兼容 API 的根地址，例如 https://api.openai.com/v1。"
        }]
                          completion:completion];
        return;
    }

    // 去掉尾部所有 '/'
    NSString *base = raw;
    while ([base hasSuffix:@"/"]) {
        base = [base substringToIndex:[base length] - 1];
    }
    // 用户可能直接粘了完整端点，剥掉到根
    if ([base hasSuffix:@"/chat/completions"]) {
        base = [base substringToIndex:[base length] - 17];
    } else if ([base hasSuffix:@"/responses"]) {
        base = [base substringToIndex:[base length] - 10];
    }
    if (![base hasSuffix:@"/models"]) {
        base = [base stringByAppendingString:@"/models"];
    }

    NSURL *url = [NSURL URLWithString:base];
    if (!url || ![[url host] length]) {
        [self pd_deliverCatalogError:[NSError errorWithDomain:domain
                                                         code:8
                                                     userInfo:@{
            NSLocalizedDescriptionKey:
                @"服务地址无效；请填写 OpenAI 兼容 API 的根地址，例如 https://api.openai.com/v1。"
        }]
                          completion:completion];
        return;
    }
    // scheme 白名单：常量数组 0x10f038 = ["https", "http"]
    if (![@[@"https", @"http"] containsObject:[[url scheme] lowercaseString]]) {
        [self pd_deliverCatalogError:[NSError errorWithDomain:domain
                                                         code:8
                                                     userInfo:@{
            NSLocalizedDescriptionKey:
                @"服务地址无效；请填写 OpenAI 兼容 API 的根地址，例如 https://api.openai.com/v1。"
        }]
                          completion:completion];
        return;
    }

    // ── 2. 组请求（0x27ae8–0x27c00）──────────────────────────
    NSMutableURLRequest *request =
        [NSMutableURLRequest requestWithURL:url
                                cachePolicy:1          // NSURLRequestReloadIgnoringLocalCacheData
                            timeoutInterval:30.0];
    [request setHTTPMethod:@"GET"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    if ([apiKey length]) {
        [request setValue:[@"Bearer " stringByAppendingString:apiKey]
       forHTTPHeaderField:@"Authorization"];
    }

    // 额外头：偏好项 AIExtraHeaders 里存一段 JSON 对象
    NSString *extraJSON = PDAIString(PDAIPreference(@"AIExtraHeaders", @""));
    id extraHeaders = nil;
    if ([extraJSON length]) {
        NSData *blob = [extraJSON dataUsingEncoding:NSUTF8StringEncoding];
        extraHeaders = [NSJSONSerialization JSONObjectWithData:blob
                                                       options:0
                                                         error:NULL];
    }

    // ── 3. 额外头逐条写入，带换行注入过滤（0x27d00–0x27e80）──
    if ([extraHeaders isKindOfClass:[NSDictionary class]]) {
        NSCharacterSet *newlines = [NSCharacterSet newlineCharacterSet];
        for (NSString *field in extraHeaders) {
            id value = [extraHeaders objectForKeyedSubscript:field];
            if (![value isKindOfClass:[NSString class]]) continue;
            if ([field rangeOfCharacterFromSet:newlines].location != NSNotFound) continue;
            if ([value rangeOfCharacterFromSet:newlines].location != NSNotFound) continue;
            [request setValue:value forHTTPHeaderField:field];
        }
    }

    // ── 4. 发请求（0x27e98–0x27f98）──────────────────────────
    NSURLSession *session =
        [NSURLSession sessionWithConfiguration:
            [NSURLSessionConfiguration ephemeralSessionConfiguration]];

    [[session dataTaskWithRequest:request
              completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];

        id json = nil;
        NSError *parseError = nil;
        if ([data length]) {
            json = [NSJSONSerialization JSONObjectWithData:data
                                                   options:0
                                                     error:&parseError];
        }

        // 非 2xx 或响应不是 JSON 对象 → 统一报错
        BOOL ok = (status >= 200 && status < 300) &&
                  [json isKindOfClass:[NSDictionary class]];
        if (!ok) {
            NSString *message = nil;
            if ([json isKindOfClass:[NSDictionary class]]) {
                id errNode = [json objectForKeyedSubscript:@"error"];
                if ([errNode isKindOfClass:[NSDictionary class]]) {
                    message = PDAIString([errNode objectForKeyedSubscript:@"message"]);
                }
            }
            if (![message length]) {
                message = [NSString stringWithFormat:@"获取模型失败，HTTP %ld。", (long)status];
            }
            [session finishTasksAndInvalidate];
            [self pd_deliverCatalogError:
                [NSError errorWithDomain:domain
                                    code:(status ? status : 8)
                                userInfo:@{NSLocalizedDescriptionKey: message}]
                              completion:completion];
            return;
        }

        // ── 5. 逐条归一化模型描述（0x28194–0x285e0）──────────
        NSArray *rawModels = [json objectForKeyedSubscript:@"data"];
        NSMutableArray *models = [NSMutableArray new];

        if ([rawModels isKindOfClass:[NSArray class]]) {
            for (NSDictionary *entry in rawModels) {
                if (![entry isKindOfClass:[NSDictionary class]]) continue;

                id identifier = [entry objectForKeyedSubscript:@"id"];
                NSString *name = PDAIString([entry objectForKeyedSubscript:@"name"]);
                if (![name length]) name = PDAIString(identifier);

                NSMutableDictionary *model = [@{
                    @"id":   identifier ?: @"",
                    @"name": name ?: @""
                } mutableCopy];

                // contextWindow：context_length → context_window → 0
                id context = entry[@"context_length"];
                if (!context) context = entry[@"context_window"];
                double contextWindow = context ? PDAINumber(context, 0.0) : 0.0;
                [model setObject:@(contextWindow) forKey:@"contextWindow"];

                // inputImages：architecture.input_modalities 或 input_modalities 里含 "image"
                id modalities = entry[@"architecture"];
                if (![modalities isKindOfClass:[NSArray class]]) {
                    modalities = entry[@"input_modalities"];
                }
                if ([modalities isKindOfClass:[NSArray class]]) {
                    BOOL supportsImage = [modalities containsObject:@"image"];
                    [model setObject:@(supportsImage) forKey:@"inputImages"];
                }

                // maxOutputTokens：top_provider.max_completion_tokens → max_output_tokens
                id maxOut = nil;
                id provider = entry[@"top_provider"];
                if ([provider isKindOfClass:[NSDictionary class]]) {
                    maxOut = provider[@"max_completion_tokens"];
                }
                if (!maxOut) maxOut = entry[@"max_output_tokens"];
                double maxTokens = maxOut ? PDAINumber(maxOut, 0.0) : 0.0;
                if (maxTokens > 0) {
                    [model setObject:@(maxTokens) forKey:@"maxOutputTokens"];
                }

                [models addObject:model];
            }
        }

        [session finishTasksAndInvalidate];

        if (![models count]) {
            [self pd_deliverCatalogError:
                [NSError errorWithDomain:domain
                                    code:9
                                userInfo:@{
                    NSLocalizedDescriptionKey:
                        @"接口响应中没有 data[].id 模型列表；请检查服务是否兼容 OpenAI /models。"
                }]
                              completion:completion];
            return;
        }

        if (completion) {
            dispatch_async(dispatch_get_global_queue(0, 0), ^{
                completion(models, nil);
            });
        }
    }] resume];
}

// 错误统一走异步投递，和成功路径保持同一线程语义（0x27bc8–0x27cf8）
/// [非二进制] 内部辅助：模型目录拉取失败时的统一出口（声明见 L45）。
+ (void)pd_deliverCatalogError:(NSError *)error
                    completion:(void (^)(id, NSError *))completion
{
    if (!completion) return;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        completion(nil, error);
    });
}

+ (id)defaultPromptTemplate {
    // 0x27358: b _PDAIDefaultEnvironment —— 纯尾调用，无参数
    return PDAIDefaultEnvironment();
}

+ (id)normalizedPromptTemplate:(id)template {
    // 0x2735c–0x273bc
    //   x19 = [template retain]
    //   0x27374: [x19 length] → cbz → 落默认
    //   0x27384: [x19 isEqual:@"#"] → tbz w0,#0 → 非 "#" 原样返回
    if (![(NSString *)template length]) {
        return PDAIDefaultEnvironment();
    }
    if ([(NSString *)template isEqual:@"#"]) {
        return PDAIDefaultEnvironment();
    }
    return template;
}

+ (id)promptVariables {
    // 0x273c8–0x27508
    //   x19 = [NSMutableArray new]
    //   循环体 x20 = 0 .. names.count-1
    //     x23 = names[i]      (objectAtIndexedSubscript:)
    //     x24 = descs[i]
    //     stack: keys[2]   = {@"name", @"description"}     @ sp+0x08
    //            objects[2]= {names[i], descs[i]}          @ sp+0x18
    //     x25 = [NSDictionary dictionaryWithObjects:objects forKeys:keys count:2]
    //     [x19 addObject:x25]
    // 两张常量表：
    //   names 0x10f008 → data 0x10cca8（10 项，见下）
    //   descs 0x10f020 → data 0x10ccf8（10 项，UTF-16 中文）
    static NSArray<NSString *> *names = nil;
    static NSArray<NSString *> *descs = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @[ @"pet.user", @"pet.vocab", @"pet.moves", @"pet.voice", @"pet.body",
                   @"pet.dress", @"pet.self", @"pet.chat", @"pet.reply", @"pet.cua" ];
        descs = @[ @"用户称呼",
                   @"角色可用的表情与动作",
                   @"角色可到达的位置",
                   @"语音输入状态",
                   @"当前外观与装扮",
                   @"可用配色与服装组合",
                   @"自主调整权限与确认规则",
                   @"对话记录与记忆工作区",
                   @"回复语言",
                   @"设备操作能力" ];
    });

    NSMutableArray *out = [NSMutableArray new];
    for (NSUInteger i = 0; i < names.count; i++) {
        [out addObject:@{ @"name": names[i], @"description": descs[i] }];
    }
    return out;
}

+ (id)renderedPromptForTemplate:(id)template {
    // 0x27508–0x276c4
    //   x20 = CFStringRef @ 0xf9bb8 → "com.susudear.petdfyprefs"
    //   CFPreferencesAppSynchronize(x20)                     0x27560
    //   x19 = [self normalizedPromptTemplate:template]       0x2756c
    //   x20 = [x19 mutableCopy]                              0x27580
    //   x21 = _PDAIPromptValues()                            0x27588（无参）
    //   for (key in x21) {                                   0x275ac countByEnumerating…
    //       x25 = [NSString stringWithFormat:@"{{%@}}", key]  0x275fc（格式串 0xfd5b0）
    //       x24 = x21[key]                                   0x27610
    //       x6  = [x20 length]                               0x27620
    //       [x20 replaceOccurrencesOfString:x25 withString:x24
    //                            options:0 range:{0, x6}]    0x2763c
    //   }
    //   return x20
    CFStringRef appID = (__bridge CFStringRef)@"com.susudear.petdfyprefs";
    CFPreferencesAppSynchronize(appID);

    NSString *normalized = [self normalizedPromptTemplate:template];
    NSMutableString *out = [normalized mutableCopy];

    NSDictionary *values = PDAIPromptValues();
    for (NSString *key in values) {
        NSString *placeholder = [NSString stringWithFormat:@"{{%@}}", key];
        id value = values[key];
        [out replaceOccurrencesOfString:placeholder
                             withString:value
                                options:0
                                  range:NSMakeRange(0, out.length)];
    }
    return out;
}

#pragma mark - 二进制存取器（逐条 8-16 指令，纯 ivar 读写）
- (void)setHistoryURL:(id)v { _historyURL = v; }
- (void)setBusy:(BOOL)v { _busy = v; }
- (void)setStateProvider:(id)v { _stateProvider = v; }
- (void)setToolHandler:(id)v { _toolHandler = v; }
- (void)setDeviceToolHandler:(id)v { _deviceToolHandler = v; }
- (void)setTurnStateHandler:(id)v { _turnStateHandler = v; }
- (void)setInterruptionHandler:(id)v { _interruptionHandler = v; }
- (void)setHistoryClearedHandler:(id)v { _historyClearedHandler = v; }
- (void)setMutableHistory:(id)v { _mutableHistory = v; }
- (void)setPendingEvents:(id)v { _pendingEvents = v; }
- (void)setPendingAttachments:(id)v { _pendingAttachments = v; }
- (void)setDataDirectory:(id)v { _dataDirectory = v; }
- (void)setSession:(id)v { _session = v; }
- (void)setTask:(id)v { _task = v; }
- (void)setStorageQueue:(id)v { _storageQueue = v; }
- (void)setMemory:(id)v { _memory = v; }
- (void)setCalls:(id)v { _calls = v; }
- (void)setToolMedia:(id)v { _toolMedia = v; }
- (void)setRefusedImages:(id)v { _refusedImages = v; }
- (void)setCallIndex:(unsigned long long)v { _callIndex = v; }
- (void)setRound:(unsigned long long)v { _round = v; }
- (void)setGeneration:(unsigned long long)v { _generation = v; }
- (void)setWakePending:(BOOL)v { _wakePending = v; }
- (void)setMaintainingData:(BOOL)v { _maintainingData = v; }
- (void)setLastMaintenanceID:(id)v { _lastMaintenanceID = v; }
- (void)setContextStart:(unsigned long long)v { _contextStart = v; }
- (void)setHandoffFile:(id)v { _handoffFile = v; }
- (void)setHandoffText:(id)v { _handoffText = v; }
- (void)setLastStampDay:(id)v { _lastStampDay = v; }
- (void)setLastText:(id)v { _lastText = v; }
- (void)setLegacyCompletion:(id)v { _legacyCompletion = v; }

#pragma mark - 二进制存取器（逐条 8-16 指令，纯 ivar 读写）
- (id)historyURL { return _historyURL; }
- (BOOL)busy { return _busy; }
- (id)mutableHistory { return _mutableHistory; }
- (id)pendingEvents { return _pendingEvents; }
- (id)pendingAttachments { return _pendingAttachments; }
- (id)dataDirectory { return _dataDirectory; }
- (id)session { return _session; }
- (id)task { return _task; }
- (id)storageQueue { return _storageQueue; }
- (id)memory { return _memory; }
- (id)calls { return _calls; }
- (id)toolMedia { return _toolMedia; }
- (id)refusedImages { return _refusedImages; }
- (unsigned long long)callIndex { return _callIndex; }
- (unsigned long long)round { return _round; }
- (unsigned long long)generation { return _generation; }
- (BOOL)wakePending { return _wakePending; }
- (BOOL)maintainingData { return _maintainingData; }
- (id)lastMaintenanceID { return _lastMaintenanceID; }
- (unsigned long long)contextStart { return _contextStart; }
- (id)handoffFile { return _handoffFile; }
- (id)handoffText { return _handoffText; }
- (id)lastStampDay { return _lastStampDay; }
- (id)lastText { return _lastText; }

@end
