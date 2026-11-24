//
//  PDNative_MCPUIElementsFacade.m — 逆向还原
//
//  11 个方法 / 967 指令。AX 组的统一出口。
//
//  ── 方法规模 ──────────────────────────────────────────────────────
//    accessibilityStateErrorSuffixForContext:   528  运行时诊断后缀
//    elementAtPoint:error:                      206  命中测试主入口
//    decorateResult:…                           153  结果装饰
//    initWithContextResolver:…                   47
//    .cxx_destruct                               20
//    属性访问器                                  14
//
//  ── elementAtPoint:error: 的流程（0x90d80）───────────────────────
//    1. resolver.frontmostContext → 取 pid
//       pid <= 0 → *error = "Cannot determine frontmost app PID"，返回 nil
//    2. 准备两个数组：attemptedProviders / providerErrors
//    3. directElementProvider 存在：
//         往 attempted 加 "direct_ax"
//         调用 provider(context, point, &providerError)
//         成功 → serializer 归一化 → decorateResult(…, "direct_ax", …, "hit_test")
//         失败 → 往 errors 加 "direct_ax=<错误>"
//    4. 都没有 → *error = 拼装串：
//          "providers=<a,b>" 或 "providers=<none>"
//        + "；" + "No UI element provider returned a result"
//        + accessibilityStateErrorSuffixForContext(context)（若非空）
//       返回 nil
//
//  ── 错误串的拼装细节（0x90f3c..0x91048）──────────────────────────
//    段与段之间用 "; "（ASCII 分号 + 空格，0x108b50）连接
//    attempted 非空 → "providers=" + [attempted componentsJoinedByString:@","]
//    否则           → "providers=<none>"
//    再追加 "No UI element provider returned a result"
//    最后若 suffix 非空，追加 suffix
//
//  ── accessibilityStateErrorSuffix 的 8 个指标（0x913b8）──────────
//    全部从 context.metadata[@"accessibilityState"] 里取，每个都先
//    respondsToSelector 检查类型，再按格式拼；最后用 "," 连接，
//    整体包成 "accessibilityState[%@]"。
//
//    voiceOverRunning                              → "voiceOver=%d"
//    runtimeLikelyActive                           → "runtimeActive=%d"
//    workspaceAccessibilitySceneCount              → "axScenes=%ld"
//    workspaceVoiceOverSceneCount                  → "voScenes=%ld"
//    axRuntimeMode          （非空字符串）          → "mode=%@"
//    registrationHeuristic  （非空字符串）          → "registration=%@"
//    recommendedRegistrarProcess（非空字符串）      → "registrar=%@"
//    currentProcessLooksLikeVoiceOverRegistrar     → "currentRegistrarLike=%d"
//    currentProcessDirectRegisterLikelyInsufficient → "directRegisterInsufficient=%d"
//
//    另外两个「提示」段不进 accessibilityState[]，而是并列追加：
//    guidance        （非空）→ "accessibilityHint=%@"
//    registrarGuidance（非空）→ "registrarHint=%@"
//
//    metadata 里没有 accessibilityState 字典或为空 → 直接返回 nil
//
//  标记：逆向还原
//

#import "PDNative_MCPUIElementsFacade.h"
#import "PDNative_MCPAXQueryContext.h"
#import "PDNative_MCPAXRemoteContextResolver.h"
#import "PDNative_MCPUIElementSerializer.h"

/// 错误串里段与段之间的分隔符：ASCII 分号 + 空格（0x108b50）。
static NSString * const kPDDiagnosticSeparator = @"; ";
/// accessibilityState 内部各项之间的分隔符。
static NSString * const kPDStateItemSeparator = @",";

@implementation PDNative_MCPUIElementsFacade

@synthesize contextResolver = _contextResolver;
@synthesize serializer = _serializer;
@synthesize directElementProvider = _directElementProvider;

/// 47 指令。三个依赖都可为空，缺哪个就少一条路径。
- (id)initWithContextResolver:(PDNative_MCPAXRemoteContextResolver *)resolver
                   serializer:(PDNative_MCPUIElementSerializer *)serializer
        directElementProvider:(PDDirectElementProvider)provider {
    self = [super init];
    if (!self) {
        return nil;
    }
    _contextResolver = resolver;
    _serializer = serializer;
    _directElementProvider = [provider copy];
    return self;
}

// [无法验证] 反汇编全文只含 9 个 dealloc，其余被工具链折叠。此实现按 ivar 布局推断。
- (void)dealloc {
    _contextResolver = nil;
    _serializer = nil;
    _directElementProvider = nil;
}

#pragma mark - 命中测试

/// 206 指令。
/// 注意：第三个参数的类型编码是 `^@`（id *），不是 `NSError **`。
/// 失败时这里存的是**一段说明字符串**，不是 NSError。
- (id)elementAtPoint:(CGPoint)point error:(id *)error {
    PDNative_MCPAXQueryContext *context = [_contextResolver frontmostContext];
    if (!context || [context pid] <= 0) {
        if (error) {
            *error = @"Cannot determine frontmost app PID";
        }
        return nil;
    }

    NSMutableArray<NSString *> *errors = [NSMutableArray array];
    NSMutableArray<NSString *> *attempted = [NSMutableArray array];

    // ── 直连 AX ─────────────────────────────────────────────
    PDDirectElementProvider provider = _directElementProvider;
    if (provider) {
        [attempted addObject:@"direct_ax"];

        id providerError = nil;
        id raw = provider(context, point, &providerError);
        if (raw) {
            id normalized = [_serializer normalizedElementFromRawElement:raw
                                                                 context:context
                                                                   point:point];
            return [self decorateResult:normalized
                           providerUsed:@"direct_ax"
                     attemptedProviders:attempted
                         providerErrors:errors
                              queryKind:@"hit_test"];
        }
        NSString *message = nil;
        if ([providerError isKindOfClass:[NSError class]]) {
            message = [providerError localizedDescription];
        } else if ([providerError isKindOfClass:[NSString class]]) {
            message = providerError;
        }
        if ([message length]) {
            [errors addObject:[NSString stringWithFormat:@"direct_ax=%@", message]];
        }
    }

    // ── 全部失败：拼一条能让模型看懂的错误串 ─────────────────
    // 结构（0x90f48..0x91048）：
    //   providers=<a,b> 或 providers=<none>
    //   + （errors 非空 ? errors 用 "; " 连接 : "No UI element provider returned a result"）
    //   + accessibilityState 后缀（非空时）
    //   整体用 "; " 连接
    if (error) {
        NSMutableArray<NSString *> *segments = [NSMutableArray array];

        NSString *providers = [attempted count]
            ? [NSString stringWithFormat:@"providers=%@",
               [attempted componentsJoinedByString:@","]]
            : @"providers=<none>";
        [segments addObject:providers];

        if ([errors count]) {
            [segments addObject:[errors componentsJoinedByString:kPDDiagnosticSeparator]];
        } else {
            [segments addObject:@"No UI element provider returned a result"];
        }

        NSString *suffix = [self accessibilityStateErrorSuffixForContext:context];
        if ([suffix length]) {
            [segments addObject:suffix];
        }

        *error = [segments componentsJoinedByString:kPDDiagnosticSeparator];
    }
    return nil;
}



#pragma mark - 结果装饰

/// 153 指令。把 provider 诊断挂到结果字典上。
/// 细节（0x911b0）：
///   - 顶层 dict 是 result 的 mutableCopy；另外建一个 diagnostics 字典
///   - queryKind / providerUsed / attemptedProviders / providerErrors 写进 diagnostics
///   - providerUsed 额外也写进顶层（0x91238）
///   - diagnostics 整体挂到顶层 key "providerDiagnostics"
///   - 再处理 semanticContext：是字典就 mutableCopy 并补 providerUsed / attemptedProviders，
///     不是字典就新建一个空字典；最后整体写回顶层 "semanticContext"
- (id)decorateResult:(id)result
        providerUsed:(NSString *)providerUsed
  attemptedProviders:(NSArray<NSString *> *)attempted
      providerErrors:(NSArray<NSString *> *)errors
           queryKind:(NSString *)queryKind {
    if (![result isKindOfClass:[NSDictionary class]]) {
        return result;
    }

    NSMutableDictionary *out = [result mutableCopy];
    NSMutableDictionary *diagnostics = [NSMutableDictionary dictionary];

    if ([queryKind length]) {
        diagnostics[@"queryKind"] = queryKind;
    }
    if ([providerUsed length]) {
        diagnostics[@"providerUsed"] = providerUsed;
        out[@"providerUsed"] = providerUsed;
    }
    if ([attempted count]) {
        diagnostics[@"attemptedProviders"] = attempted;
    }
    if ([errors count]) {
        diagnostics[@"providerErrors"] = errors;
    }

    out[@"providerDiagnostics"] = [diagnostics copy];

    // semanticContext：是字典就补充，不是就新建
    NSMutableDictionary *semantic = nil;
    id existing = result[@"semanticContext"];
    if ([existing isKindOfClass:[NSDictionary class]]) {
        semantic = [existing mutableCopy];
    } else {
        semantic = [NSMutableDictionary dictionary];
    }
    if ([providerUsed length]) {
        semantic[@"providerUsed"] = providerUsed;
    }
    if ([attempted count]) {
        semantic[@"attemptedProviders"] = attempted;
    }
    out[@"semanticContext"] = [semantic copy];

    return [out copy];
}

#pragma mark - 运行时诊断后缀

/// 528 指令。把 accessibilityState 里的一堆指标拼成一行。
- (NSString *)accessibilityStateErrorSuffixForContext:(PDNative_MCPAXQueryContext *)context {
    if (!context) {
        return nil;
    }

    NSDictionary *metadata = [context metadata];
    if (![metadata isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    id rawState = metadata[@"accessibilityState"];
    if (![rawState isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSDictionary *state = rawState;
    if (![state count]) {
        return nil;
    }

    NSMutableArray<NSString *> *items = [NSMutableArray array];

    // ── 布尔项 ──────────────────────────────────────────────
    id voiceOver = state[@"voiceOverRunning"];
    if ([voiceOver respondsToSelector:@selector(boolValue)]) {
        [items addObject:[NSString stringWithFormat:@"voiceOver=%d", [voiceOver boolValue]]];
    }

    id runtimeActive = state[@"runtimeLikelyActive"];
    if ([runtimeActive respondsToSelector:@selector(boolValue)]) {
        [items addObject:[NSString stringWithFormat:@"runtimeActive=%d", [runtimeActive boolValue]]];
    }

    // ── 计数项 ──────────────────────────────────────────────
    id axScenes = state[@"workspaceAccessibilitySceneCount"];
    if ([axScenes respondsToSelector:@selector(integerValue)]) {
        [items addObject:[NSString stringWithFormat:@"axScenes=%ld", (long)[axScenes integerValue]]];
    }

    id voScenes = state[@"workspaceVoiceOverSceneCount"];
    if ([voScenes respondsToSelector:@selector(integerValue)]) {
        [items addObject:[NSString stringWithFormat:@"voScenes=%ld", (long)[voScenes integerValue]]];
    }

    // ── 字符串项 ────────────────────────────────────────────
    id mode = state[@"axRuntimeMode"];
    if ([mode isKindOfClass:[NSString class]] && [mode length]) {
        [items addObject:[NSString stringWithFormat:@"mode=%@", mode]];
    }

    id registration = state[@"registrationHeuristic"];
    if ([registration isKindOfClass:[NSString class]] && [registration length]) {
        [items addObject:[NSString stringWithFormat:@"registration=%@", registration]];
    }

    id registrar = state[@"recommendedRegistrarProcess"];
    if ([registrar isKindOfClass:[NSString class]] && [registrar length]) {
        [items addObject:[NSString stringWithFormat:@"registrar=%@", registrar]];
    }

    // ── 两个「注册启发式」布尔项 ────────────────────────────
    id registrarLike = state[@"currentProcessLooksLikeVoiceOverRegistrar"];
    if ([registrarLike respondsToSelector:@selector(boolValue)]) {
        [items addObject:[NSString stringWithFormat:@"currentRegistrarLike=%d",
                          [registrarLike boolValue]]];
    }

    id insufficient = state[@"currentProcessDirectRegisterLikelyInsufficient"];
    if ([insufficient respondsToSelector:@selector(boolValue)]) {
        [items addObject:[NSString stringWithFormat:@"directRegisterInsufficient=%d",
                          [insufficient boolValue]]];
    }

    // ── 提示段（不进 accessibilityState[]）──────────────────
    NSMutableArray<NSString *> *hints = [NSMutableArray array];

    id guidance = state[@"guidance"];
    if ([guidance isKindOfClass:[NSString class]] && [guidance length]) {
        [hints addObject:[NSString stringWithFormat:@"accessibilityHint=%@", guidance]];
    }

    id registrarGuidance = state[@"registrarGuidance"];
    if ([registrarGuidance isKindOfClass:[NSString class]] && [registrarGuidance length]) {
        [hints addObject:[NSString stringWithFormat:@"registrarHint=%@", registrarGuidance]];
    }

    // ── 拼装 ────────────────────────────────────────────────
    NSMutableArray<NSString *> *segments = [NSMutableArray array];
    if ([items count]) {
        [segments addObject:[NSString stringWithFormat:@"accessibilityState[%@]",
                             [items componentsJoinedByString:kPDStateItemSeparator]]];
    }
    if ([hints count]) {
        [segments addObject:[hints componentsJoinedByString:kPDDiagnosticSeparator]];
    }
    if (![segments count]) {
        return nil;
    }
    return [segments componentsJoinedByString:kPDDiagnosticSeparator];
}

#pragma mark - 属性

- (PDNative_MCPAXRemoteContextResolver *)contextResolver {
    return _contextResolver;
}

- (void)setContextResolver:(PDNative_MCPAXRemoteContextResolver *)contextResolver {
    _contextResolver = contextResolver;
}

- (PDNative_MCPUIElementSerializer *)serializer {
    return _serializer;
}

- (void)setSerializer:(PDNative_MCPUIElementSerializer *)serializer {
    _serializer = serializer;
}

- (PDDirectElementProvider)directElementProvider {
    return _directElementProvider;
}

- (void)setDirectElementProvider:(PDDirectElementProvider)directElementProvider {
    _directElementProvider = [directElementProvider copy];
}

@end
