//
//  PDNative_AccessibilityManager.m
//  逆向还原自 PetDFY.arm64e.dylib
//
//  定位：AX 查询总调度器。串行化所有无障碍查询，给每次查询上 2 秒预算，
//        超时/异常/重入三条路都有明确收口，最终都走同一个 finisher 回主调方。
//
//  证据分级
//  ---------
//  Observed（直接来自反汇编）
//    - 队列标签 com.witchan.ios-mcp.ax（0xc1ad9 原始字节）
//    - performQuery 三段式：@synchronized 标志位 → dispatch_after(2s) → dispatch_async(_axQueue)
//    - 2.0 秒预算：systemUptime + 2.0 作为 nodeSource.queryDeadline；
//      dispatch_time(0, 0x77359400) 作为超时点
//    - finisher 的双重调用守卫：__block BOOL 在 @synchronized 内先查后置位
//    - 异常转字符串格式 @"AX query exception: %@: %@"
//    - compactPayload 的 payload 必须是 NSDictionary 才处理，否则回
//      inner error 或 @"No compact UI elements available"
//    - 注入键 processName / frontmostContext，setObject:forKeyedSubscript:
//    - 三条错误串逐字保留
//  Inferred（由 ivar 类型、ivar 顺序、selector 交叉验证推出）
//    - init 里五次 alloc 的类归属：AttributeBridge → NodeSource → ContextResolver
//      → Serializer → UIElementFacade（与 ivar 声明顺序一一对应）
//    - worker 里对 nodeSource 调的是 setQueryDeadline:（stub 0xb38e0）
//  Assumed
//    - 超时分支不主动清 _queryInFlight：由 worker 收尾时统一清
//      （反汇编在超时块内确实没有写 [self+0x10] 的指令）
//

#import "PDNative_AccessibilityManager.h"

@implementation PDNative_AccessibilityManager

#pragma mark - 单例

+ (id)sharedInstance {
    static PDNative_AccessibilityManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[PDNative_AccessibilityManager alloc] init];
    });
    return shared;
}

#pragma mark - 生命周期

- (id)init {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    _axQueue = dispatch_queue_create("com.witchan.ios-mcp.ax", 0);
    _axAttributeBridge = [PDNative_MCPAXAttributeBridge new];
    _axNodeSource = [[PDNative_MCPAXNodeSource alloc] initWithAttributeBridge:_axAttributeBridge];
    _contextResolver = [PDNative_MCPAXRemoteContextResolver new];
    _uiElementSerializer = [PDNative_MCPUIElementSerializer new];

    __weak PDNative_AccessibilityManager *weakSelf = self;
    _uiElementsFacade = [[PDNative_MCPUIElementsFacade alloc]
                         initWithContextResolver:_contextResolver
                                      serializer:_uiElementSerializer
                           directElementProvider:^id(PDNative_MCPAXQueryContext *context,
                                                     CGPoint point,
                                                     id *error) {
        PDNative_AccessibilityManager *strongSelf = weakSelf;
        if (strongSelf == nil) {
            if (error != NULL) {
                *error = @"AccessibilityManager unavailable";
            }
            return nil;
        }

        NSError *inner = nil;
        id element = [strongSelf directAXElementAtPoint:point
                                                    pid:context.pid
                                              contextId:context.contextId
                                              displayId:context.displayId
                                                  error:&inner];
        if (element != nil) {
            if (error != NULL) {
                *error = nil;
            }
            return element;
        }
        if (error != NULL) {
            *error = inner;
        }
        return nil;
    }];

    return self;
}

#pragma mark - 直连 AX（只读快路径）

/// 16 条指令的尾调用壳：不查上下文，直接落到 nodeSource 的命中测试，
/// allowParameterizedHitTest 固定 YES。
- (id)directAXElementAtPoint:(CGPoint)point
                         pid:(int)pid
                   contextId:(unsigned int)contextId
                   displayId:(unsigned int)displayId
                       error:(NSError **)error {
    return [_axNodeSource elementAtPoint:point
                                     pid:pid
                               contextId:contextId
                               displayId:displayId
             allowParameterizedHitTest:YES
                                   error:error];
}

- (BOOL)hasOutstandingQuery {
    return _queryInFlight;
}

#pragma mark - compact 载荷封装

/// nodeSource 出的是裸字典；这里补两个上下文键再交给上层。
/// 非字典结果不包装，直接按失败返回。
- (id)compactPayloadForContext:(PDNative_MCPAXQueryContext *)context
                   maxElements:(long long)maxElements
                    visibleOnly:(BOOL)visibleOnly
                  clickableOnly:(BOOL)clickableOnly
                          error:(NSError **)error {
    if (context == nil || [context pid] <= 0) {
        if (error != NULL) {
            *error = (NSError *)@"No frontmost application context available";
        }
        return nil;
    }

    NSError *inner = nil;
    id payload = [_axNodeSource compactElementsForPid:[context pid]
                                             bundleId:[context bundleId]
                                            contextId:[context contextId]
                                            displayId:[context displayId]
                                          maxElements:maxElements
                                           visibleOnly:visibleOnly
                                          clickableOnly:clickableOnly
                                                  error:&inner];

    if (![payload isKindOfClass:[NSDictionary class]]) {
        if (error != NULL) {
            *error = (inner != nil ? inner : (NSError *)@"No compact UI elements available");
        }
        return nil;
    }

    NSMutableDictionary *enriched = [payload mutableCopy];
    NSString *processName = [context processName];
    if (processName.length != 0) {
        enriched[@"processName"] = processName;
    }
    NSDictionary *contextDictionary = [context dictionaryRepresentation];
    if (contextDictionary.count != 0) {
        enriched[@"frontmostContext"] = contextDictionary;
    }

    if (error != NULL) {
        *error = nil;
    }
    return enriched;
}

#pragma mark - 查询调度

/// 一次只跑一个查询。重入直接拒绝，不排队。
/// 预算 2 秒：超时块先挂上，worker 后派发；两边都只能通过 finisher 回调一次。
- (void)performQuery:(id (^)(NSError **))query
          completion:(void (^)(NSDictionary *payload, NSError *error))completion {
    @synchronized (self) {
        if (_queryInFlight) {
            if (completion != nil) {
                completion(nil, (NSError *)@"Previous AX query is still running; do not retry");
            }
            return;
        }
        _queryInFlight = YES;
    }

    id (^queryBlock)(NSError **) = [query copy];

    __block BOOL finished = NO;

    // 唯一出口：谁先到谁说话，后到的静默丢弃。
    void (^finisher)(id, NSError *) = ^(id result, NSError *error) {
        @synchronized (self) {
            if (finished) {
                return;
            }
            finished = YES;
        }
        if (completion != nil) {
            completion((NSDictionary *)result, error);
        }
    };

    double deadline = [NSProcessInfo processInfo].systemUptime + 2.0;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(0, 0),
                   ^{
        finisher(nil, (NSError *)@"AX query timed out; no further traversal will be started");
    });

    dispatch_async(_axQueue, ^{
        [_axNodeSource setQueryDeadline:deadline];

        id result = nil;
        NSError *inner = nil;
        NSError *error = nil;
        BOOL threw = NO;

        @try {
            result = queryBlock(&inner);
        }
        @catch (NSException *exception) {
            threw = YES;
            error = (NSError *)[NSString stringWithFormat:@"AX query exception: %@: %@",
                                exception.name, exception.reason];
        }

        if (!threw && result == nil) {
            if ([NSProcessInfo processInfo].systemUptime < deadline) {
                error = inner;
            } else {
                error = (NSError *)@"AX query timed out; result discarded";
            }
        }

        @synchronized (self) {
            _queryInFlight = NO;
        }

        finisher(result, error);
    });
}

#pragma mark - 对外包装

- (void)getCompactUIElementsWithMaxElements:(long long)maxElements
                                visibleOnly:(BOOL)visibleOnly
                              clickableOnly:(BOOL)clickableOnly
                                 completion:(void (^)(NSDictionary *payload, NSError *error))completion {
    [self performQuery:^id(NSError **error) {
        PDNative_MCPAXQueryContext *context = [self->_contextResolver frontmostContext];
        if (context == nil || context.pid <= 0) {
            if (error != NULL) {
                *error = (NSError *)@"No frontmost application context available";
            }
            return nil;
        }
        return [self compactPayloadForContext:context
                                  maxElements:maxElements
                                   visibleOnly:visibleOnly
                                 clickableOnly:clickableOnly
                                         error:error];
    } completion:completion];
}

- (void)getElementAtPoint:(CGPoint)point
               completion:(void (^)(NSDictionary *payload, NSError *error))completion {
    [self performQuery:^id(NSError **error) {
        return [self->_uiElementsFacade elementAtPoint:point error:(id *)error];
    } completion:completion];
}

- (id)frontmostApplicationInfo {
    NSDictionary *dictionary = [_contextResolver frontmostContextDictionary];
    return (dictionary != nil ? dictionary : @{});
}

@end
