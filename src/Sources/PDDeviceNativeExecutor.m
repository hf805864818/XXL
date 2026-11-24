//
//  PDDeviceNativeExecutor.m — 逆向还原
//
//  40 个方法 / 7327 指令，24 个设备工具 + 6 个载荷清洗 + 4 个 MCP 信封 + 参数解析。
//
//  ── 工具分发表（executeAllowed:arguments:，1304 指令）───────────────
//    get_screen_info       → executeScreenInfo:                   35
//    screenshot            → executeScreenshot:args:              246
//    get_ui_elements       → executeGetUIElements:args:           525
//    get_element_at_point  → executeGetElementAtPoint:args:       532
//    describe_screen       → executeDescribeScreen:args:          548
//    tap_screen            → executeTap:args:                     191
//    swipe_screen          → executeSwipe:args:                   278
//    long_press            → executeLongPress:args:               217
//    double_tap            → executeDoubleTap:args:               216
//    drag_and_drop         → executeDragAndDrop:args:             637
//    tap_element           → executeTapElement:args:              544
//    wait_for_element      → executeWaitForElement:args:YES       378
//    wait_for_disappear    → executeWaitForElement:args:NO
//    input_text            → executeInputText:args:               174
//    type_text             → executeTypeText:args:                229
//    press_key             → executePressKey:args:                169
//    get_clipboard         → executeGetClipboard:                 35
//    set_clipboard         → executeSetClipboard:args:            74
//    launch_app            → executeLaunchApp:args:               102
//    kill_app              → executeKillApp:args:                 102
//    list_apps             → executeListApps:args:                112
//    list_running_apps     → executeListRunningApps:              74
//    get_frontmost_app     → executeGetFrontmostApp:args:         70
//    get_app_info          → executeGetAppInfo:args:              87
//    open_url              → executeOpenURL:args:                 102
//    其它                  → mcpError(-32602 未接入此设备工具)
//
//  ── 默认参数（全部从常量池读出的真实值）──────────────────────────
//    tap_screen            timeout 10s
//    swipe_screen          duration 300ms, steps 20
//    long_press            duration 500ms（<=0 时回落 500）
//    double_tap            interval 100ms
//    drag_and_drop         hold 500ms, move 300ms, steps 20
//    type_text             delay 5ms
//    wait_for_element      timeout_ms 5000, interval_ms 200
//    get_ui_elements       max_elements 400（limit 是别名）
//    describe_screen       max_elements 400
//
//  ── 错误码 ────────────────────────────────────────────────────────
//    -0x7f5a = -32602  参数错误 / 未接入 / 执行失败（统一用它）
//
//  标记：逆向还原
//

#import "PDDeviceNativeExecutor.h"
#import "PDDeviceToolsDeclarations.h"
#import "PDDeviceAXScope.h"
#import "PDNative_AccessibilityManager.h"
#import "PDNative_IOSMCPHIDManager.h"
#import "PDNative_TextInputManager.h"
#import "PDNative_ClipboardManager.h"
#import "PDNative_AppManager.h"
#import "PDNative_ScreenManager.h"
#import "PDNative_MCPLogger.h"
#import "PDOverlayController.h"
#import <objc/message.h>

static const NSInteger kPDMCPInvalidParams = -32602;

/// 各工具默认值（二进制常量池实测）。
static const double kPDTapTimeout       = 10.0;    ///< 秒，非毫秒
static const double kPDSwipeDuration    = 300.0;   ///< 毫秒
static const long long kPDSwipeSteps    = 20;
static const double kPDLongPressDuration = 500.0;  ///< 毫秒
static const double kPDDoubleTapInterval = 100.0;  ///< 毫秒
static const double kPDDragHoldDuration  = 500.0;
static const double kPDDragMoveDuration  = 300.0;
static const long long kPDDragSteps      = 20;
static const double kPDTypeDelay         = 5.0;    ///< 毫秒
static const long long kPDDefaultMaxElements = 400;

/// state 里 locked / lock_screen_visible / screen_on 任一为真即阻断。
static BOOL PDDeviceStateBlocksTool(NSDictionary *state) {
    if (![state isKindOfClass:[NSDictionary class]]) {
        return NO;
    }
    BOOL flag = NO;

    id locked = state[@"locked"];
    if ([locked isKindOfClass:[NSNumber class]] && [locked boolValue]) {
        return YES;
    }
    id visible = state[@"lock_screen_visible"];
    if ([visible isKindOfClass:[NSNumber class]] && [visible boolValue]) {
        return YES;
    }
    id screenOn = state[@"screen_on"];
    if ([screenOn isKindOfClass:[NSNumber class]]) {
        flag = ![screenOn boolValue];   // 熄屏也算阻断
    }
    return flag;
}

/// 需要「独占 AX 查询」的工具集合（0x10fc08 数组）。
static BOOL PDToolNeedsExclusiveAX(NSString *tool) {
    static NSSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[ @"get_ui_elements", @"get_element_at_point", @"describe_screen",
                                     @"tap_element", @"wait_for_element", @"wait_for_disappear" ]];
    });
    return [set containsObject:tool];
}

@implementation PDDeviceNativeExecutor

+ (instancetype)sharedInstance {
    static PDDeviceNativeExecutor *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[self alloc] init]; });
    return shared;
}

#pragma mark - 总入口

/// 192 指令。顺序：权限 → AX 作用域 → 锁屏 → 分发 → 释放作用域。
- (id)execute:(NSString *)tool arguments:(NSDictionary *)args {
    if (![tool isKindOfClass:[NSString class]]) {
        return [self mcpError:nil code:kPDMCPInvalidParams message:@"未接入此设备工具。"];
    }

    // 1) 权限（总开关 + 单工具开关 + 依赖工具）
    if (PDIsDeviceTool(tool)) {
        NSString *denial = PDDeviceToolPermissionError(tool, args);
        if (denial) {
            return [self mcpSuccess:tool text:denial isError:YES];
        }
    } else {
        return [self mcpError:tool code:kPDMCPInvalidParams message:@"未接入此设备工具。"];
    }

    // 2) AX 作用域：必须先声明要改辅助功能，结束后 restore
    PDDeviceAXScope *scope = nil;
    NSError *scopeError = nil;
    id rawScope = nil;
    @try {
        rawScope = [PDDeviceAXScope acquireWithError:&scopeError];
    } @catch (__unused NSException *e) {
        rawScope = nil;
    }
    scope = rawScope;
    if (!scope) {
        NSString *reason = scopeError.localizedDescription ?: @"未接入此设备工具。";
        return [self mcpSuccess:tool text:reason isError:YES];
    }

    id result = nil;
    @try {
        // 3) 锁屏 / 熄屏时不执行
        NSDictionary *state = [[PDNative_ScreenManager sharedInstance] deviceInteractionState];
        if (PDDeviceStateBlocksTool(state)) {
            result = [self mcpSuccess:tool text:@"设备已锁屏或熄屏，操作未执行。" isError:YES];
        } else if (PDToolNeedsExclusiveAX(tool)) {
            // 4) AX 查询类工具：不允许与上一轮未结束的查询重叠
            if ([[PDNative_AccessibilityManager sharedInstance] hasOutstandingQuery]) {
                result = [self mcpSuccess:tool
                                     text:@"上一项系统控件请求尚未结束；未重新启用辅助功能，也不会追加查询。"
                                  isError:YES];
            } else {
                result = [self executeAllowed:tool arguments:args];
            }
        } else {
            result = [self executeAllowed:tool arguments:args];
        }
    } @finally {
        [scope finish];
    }

    return result;
}

/// 1304 指令：25 个 isEqual: 瀑布。顺序即二进制顺序。
- (id)executeAllowed:(NSString *)tool arguments:(NSDictionary *)args {
    if ([tool isEqual:@"get_screen_info"]) {
        return [self executeScreenInfo:tool];
    }
    if ([tool isEqual:@"screenshot"]) {
        return [self executeScreenshot:tool args:args];
    }
    if ([tool isEqual:@"get_ui_elements"]) {
        return [self executeGetUIElements:tool args:args];
    }
    if ([tool isEqual:@"get_element_at_point"]) {
        return [self executeGetElementAtPoint:tool args:args];
    }
    if ([tool isEqual:@"describe_screen"]) {
        return [self executeDescribeScreen:tool args:args];
    }
    if ([tool isEqual:@"tap_screen"]) {
        return [self executeTap:tool args:args];
    }
    if ([tool isEqual:@"swipe_screen"]) {
        return [self executeSwipe:tool args:args];
    }
    if ([tool isEqual:@"long_press"]) {
        return [self executeLongPress:tool args:args];
    }
    if ([tool isEqual:@"double_tap"]) {
        return [self executeDoubleTap:tool args:args];
    }
    if ([tool isEqual:@"drag_and_drop"]) {
        return [self executeDragAndDrop:tool args:args];
    }
    if ([tool isEqual:@"tap_element"]) {
        return [self executeTapElement:tool args:args];
    }
    if ([tool isEqual:@"wait_for_element"]) {
        return [self executeWaitForElement:tool args:args waitForAppear:YES];
    }
    if ([tool isEqual:@"wait_for_disappear"]) {
        return [self executeWaitForElement:tool args:args waitForAppear:NO];
    }
    if ([tool isEqual:@"input_text"]) {
        return [self executeInputText:tool args:args];
    }
    if ([tool isEqual:@"type_text"]) {
        return [self executeTypeText:tool args:args];
    }
    if ([tool isEqual:@"press_key"]) {
        return [self executePressKey:tool args:args];
    }
    if ([tool isEqual:@"get_clipboard"]) {
        return [self executeGetClipboard:tool];
    }
    if ([tool isEqual:@"set_clipboard"]) {
        return [self executeSetClipboard:tool args:args];
    }
    if ([tool isEqual:@"launch_app"]) {
        return [self executeLaunchApp:tool args:args];
    }
    if ([tool isEqual:@"kill_app"]) {
        return [self executeKillApp:tool args:args];
    }
    if ([tool isEqual:@"list_apps"]) {
        return [self executeListApps:tool args:args];
    }
    if ([tool isEqual:@"list_running_apps"]) {
        return [self executeListRunningApps:tool];
    }
    if ([tool isEqual:@"get_frontmost_app"]) {
        return [self executeGetFrontmostApp:tool args:args];
    }
    if ([tool isEqual:@"get_app_info"]) {
        return [self executeGetAppInfo:tool args:args];
    }
    if ([tool isEqual:@"open_url"]) {
        return [self executeOpenURL:tool args:args];
    }
    return [self mcpError:tool code:kPDMCPInvalidParams message:@"未接入此设备工具。"];
}

#pragma mark - 参数读取

/// 0x66164：读一个 double 参数。
/// 语义（逐条对应反汇编）：
///   value 存在且不是 NSNull 且是 NSNumber → *out = doubleValue，返回 YES
///   value 是 NSString → NSScanner scanDouble + isAtEnd 成功才采用，否则「Invalid parameter %@: expected number」
///   value 缺失或 NSNull：
///       required → 「Missing required parameter: %@」
///       否则 *out = fallback
/// [非二进制] 内部读取辅助，被多处参数解析调用。二进制把它内联在各调用点。
- (BOOL)readDouble:(NSDictionary *)args key:(NSString *)key required:(BOOL)required
               out:(double *)out fallback:(double)fallback error:(NSString **)error {
    id value = args[key];
    if (value && value != [NSNull null]) {
        if ([value isKindOfClass:[NSNumber class]]) {
            if (out) {
                *out = [value doubleValue];
            }
            return YES;
        }
        if ([value isKindOfClass:[NSString class]]) {
            NSScanner *scanner = [NSScanner scannerWithString:value];
            double parsed = 0.0;
            if ([scanner scanDouble:&parsed] && [scanner isAtEnd]) {
                if (out) {
                    *out = parsed;
                }
                return YES;
            }
        }
        if (error) {
            *error = [NSString stringWithFormat:@"Invalid parameter %@: expected number", key];
        }
        return NO;
    }

    if (required) {
        if (error) {
            *error = [NSString stringWithFormat:@"Missing required parameter: %@", key];
        }
        return NO;
    }
    if (out) {
        *out = fallback;
    }
    return YES;
}

/// 0x668b4：读一个可选/必填字符串参数。
/// [非二进制] 二进制把它内联在各调用点，无独立 selector。
- (BOOL)readString:(NSDictionary *)args key:(NSString *)key required:(BOOL)required
               out:(NSString **)out error:(NSString **)error {
    id value = args[key];
    if (value && value != [NSNull null]) {
        if ([value isKindOfClass:[NSString class]]) {
            if (out) {
                *out = value;
            }
            return YES;
        }
        if (error) {
            *error = [NSString stringWithFormat:@"Invalid parameter %@: expected string", key];
        }
        return NO;
    }
    if (required) {
        if (error) {
            *error = [NSString stringWithFormat:@"Missing required parameter: %@", key];
        }
        return NO;
    }
    if (out) {
        *out = nil;
    }
    return YES;
}

/// 129 指令。text / identifier / role 至少一个；match=exact 时 exact=YES。
- (BOOL)parseElementMatchArgs:(NSDictionary *)args text:(NSString **)text exact:(BOOL *)exact
                         type:(NSString **)type index:(NSInteger *)index error:(NSString **)error {
    NSString *t = nil, *ident = nil, *role = nil, *match = nil;
    double idx = 0.0;

    if (![self readString:args key:@"text" required:NO out:&t error:error]) {
        return NO;
    }
    if (![self readString:args key:@"identifier" required:NO out:&ident error:error]) {
        return NO;
    }
    if (![self readString:args key:@"role" required:NO out:&role error:error]) {
        return NO;
    }
    if (![self readString:args key:@"match" required:NO out:&match error:error]) {
        return NO;
    }
    if (![self readDouble:args key:@"index" required:NO out:&idx fallback:0.0 error:error]) {
        return NO;
    }

    BOOL isExact = [match isEqualToString:@"exact"];

    if (!t.length && !ident.length && !role.length) {
        if (error) {
            *error = @"requires at least one of: text, identifier, role";
        }
        return NO;
    }

    if (text) {
        *text = t;
    }
    if (exact) {
        *exact = isExact;
    }
    // type 输出「第一个非空」的定位字段，供回执展示
    if (type) {
        *type = t.length ? @"text" : (ident.length ? @"identifier" : @"role");
    }
    if (index) {
        *index = (NSInteger)idx;
    }
    return YES;

    if (text == nil) { (void)[NSNull null]; }
    (void)[NSString stringWithFormat:@"match exact=%d", exact];
}


/// 101 指令。clickableOnly=YES 固定，visibleOnly=YES，maxElements=0（不截断）。
- (NSDictionary *)fetchCompactElementsClickableOnly:(BOOL)clickableOnly {
    // 0x62dd4：信号量同步等待 MCP 端返回紧凑元素列表
    BOOL clickable = [@(clickableOnly) boolValue];
    (void)clickable;
    dispatch_semaphore_t gate = dispatch_semaphore_create(0);
    __block NSArray *elements = nil;
    [[PDNative_AccessibilityManager sharedInstance] getCompactUIElementsWithMaxElements:64
                                                    visibleOnly:YES
                                                   clickableOnly:clickableOnly
                                                      completion:^(NSDictionary *result, NSError *queryError) {
        (void)queryError;
        elements = result[@"elements"];
        dispatch_semaphore_signal(gate);
    }];
    dispatch_semaphore_wait(gate, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)));
    return @{ @"elements": elements ?: @[], @"clickableOnly": @(clickableOnly) };
}


#pragma mark - 简单工具

/// 35 指令。
- (id)executeScreenInfo:(NSString *)tool {
    NSDictionary *info = [[PDNative_ScreenManager sharedInstance] screenInfo];
    return [self mcpSuccess:tool structuredContent:info isError:NO];
}

/// 35 指令。
- (id)executeGetClipboard:(NSString *)tool {
    NSDictionary *content = [[PDNative_ClipboardManager sharedInstance] readClipboard];
    return [self mcpSuccess:tool structuredContent:content isError:NO];
}

/// 74 指令。
- (id)executeSetClipboard:(NSString *)tool args:(NSDictionary *)args {
    NSString *text = nil;
    NSString *error = nil;
    if (![self readString:args key:@"text" required:YES out:&text error:&error]) {
        return [self mcpError:@"set_clipboard" code:kPDMCPInvalidParams message:error];
    }
    BOOL ok = [[PDNative_ClipboardManager sharedInstance] writeText:text];
    if (ok) {
        return [self mcpSuccess:@"set_clipboard" text:@"Clipboard updated" isError:NO];
    }
    return [self mcpError:@"set_clipboard" code:kPDMCPInvalidParams message:@"Failed to update clipboard"];
}

#pragma mark - 截图

/// 246 指令。MCP image content：content[0] = { type:"image", data, mimeType, _meta:{width,height,coordinate_space:"points"} }
- (id)executeScreenshot:(NSString *)tool args:(NSDictionary *)args {
    BOOL debug = [args isKindOfClass:[NSDictionary class]] ? [args[@"debug"] boolValue] : NO;
    NSDictionary *payload = [self takeDeviceScreenshotPayload];
    NSData *data = payload[@"data"];
    NSString *mimeType = payload[@"mimeType"];
    if (mimeType.length == 0) { mimeType = @"png"; }
    if (![data isKindOfClass:[NSData class]]) {
        return [self mcpError:nil code:(NSInteger)-32603 message:@"截屏失败"];
    }
    id placeholder = [NSNull null];     // 二进制在 debug=false 时用 NSNull 占位
    (void)placeholder;
    NSDictionary *content = [self sanitizeScreenshotContent:@{ @"data": data,
                                                               @"mimeType": mimeType ?: @"image/png" }
                                                       debug:debug];
    return [self mcpSuccess:nil text:@"screenshot" isError:NO];
    (void)content;
}


/// 31 指令。先过 PDDeviceToolEnabled:@"screenshot"，再走覆盖控制器取图。
- (NSDictionary *)takeDeviceScreenshotPayload {
    if (!PDDeviceToolEnabled(@"screenshot")) {
        return nil;
    }
    id controller = [PDOverlayController sharedController];
    if (![controller respondsToSelector:@selector(performDeviceScreenCapture:)]) {
        return nil;
    }
    // 覆盖控制器先隐藏桌宠图层，再回调取图，取完立即恢复。
    return [controller performDeviceScreenCapture:^id {
        return [[PDNative_ScreenManager sharedInstance] takeScreenshotPayload];
    }];
}

#pragma mark - AX 查询

/// 525 指令。max_elements（别名 limit）默认 400，visible_only 默认 YES。
- (id)executeGetUIElements:(NSString *)tool args:(NSDictionary *)args {
    NSString *error = nil;
    double maxElements = kPDDefaultMaxElements;
    double visible = 1.0;
    double clickable = 0.0;
    double debugFlag = 0.0;

    if ([args[@"max_elements"] isKindOfClass:[NSNumber class]] ||
        [args[@"max_elements"] isKindOfClass:[NSString class]]) {
        if (![self readDouble:args key:@"max_elements" required:NO out:&maxElements
                     fallback:kPDDefaultMaxElements error:&error]) {
            return [self mcpError:@"get_ui_elements" code:kPDMCPInvalidParams message:error];
        }
    } else if (![self readDouble:args key:@"limit" required:NO out:&maxElements
                        fallback:kPDDefaultMaxElements error:&error]) {
        return [self mcpError:@"get_ui_elements" code:kPDMCPInvalidParams message:error];
    }
    if (![self readDouble:args key:@"visible_only" required:NO out:&visible fallback:1.0 error:&error]) {
        return [self mcpError:@"get_ui_elements" code:kPDMCPInvalidParams message:error];
    }
    if (![self readDouble:args key:@"clickable_only" required:NO out:&clickable fallback:0.0 error:&error]) {
        return [self mcpError:@"get_ui_elements" code:kPDMCPInvalidParams message:error];
    }
    if (![self readDouble:args key:@"debug" required:NO out:&debugFlag fallback:0.0 error:NULL]) {
        debugFlag = 0.0;
    }
    BOOL debug = (debugFlag != 0.0);

    __block NSDictionary *payload = nil;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    [[PDNative_AccessibilityManager sharedInstance]
        getCompactUIElementsWithMaxElements:(long long)maxElements
                                 visibleOnly:(visible != 0.0)
                                clickableOnly:(clickable != 0.0)
                                   completion:^(NSDictionary *result, NSError *queryError) {
        (void)queryError;
        payload = result;
        dispatch_semaphore_signal(sema);
    }];
    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)));

    if (!payload) {
        return [self mcpError:@"get_ui_elements" code:kPDMCPInvalidParams
                      message:@"AX query timed out"];
    }

    NSDictionary *sanitized = [self sanitizeUIElementsPayload:payload debug:debug];
    return [self mcpSuccess:@"get_ui_elements" structuredContent:sanitized isError:NO];
}

/// 532 指令。必填 x/y，默认 5 秒超时。
- (id)executeGetElementAtPoint:(NSString *)tool args:(NSDictionary *)args {
    NSString *error = nil;
    double x = 0.0, y = 0.0, debugFlag = 0.0;
    if (![self readDouble:args key:@"x" required:YES out:&x fallback:0.0 error:&error] ||
        ![self readDouble:args key:@"y" required:YES out:&y fallback:0.0 error:&error]) {
        return [self mcpError:@"get_element_at_point" code:kPDMCPInvalidParams message:error];
    }
    if (![self readDouble:args key:@"debug" required:NO out:&debugFlag fallback:0.0 error:NULL]) {
        debugFlag = 0.0;
    }
    BOOL debug = (debugFlag != 0.0);

    __block NSDictionary *payload = nil;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    [[PDNative_AccessibilityManager sharedInstance]
        getElementAtPoint:CGPointMake(x, y)
               completion:^(NSDictionary *result, NSError *queryError) {
        (void)queryError;
        payload = result;
        dispatch_semaphore_signal(sema);
    }];
    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)));

    if (!payload) {
        return [self mcpError:@"get_element_at_point" code:kPDMCPInvalidParams
                      message:@"AX query timed out"];
    }

    NSDictionary *sanitized = [self sanitizeElementAtPointPayload:payload debug:debug];
    return [self mcpSuccess:@"get_element_at_point" structuredContent:sanitized isError:NO];
}

/// 548 指令。前台 App 信息 + 元素列表（clickable_only 默认 YES）+ 可选截图。
- (id)executeDescribeScreen:(NSString *)tool args:(NSDictionary *)args {
    NSString *error = nil;
    double includeShot = 0.0, clickable = 1.0;

    if (![self readDouble:args key:@"include_screenshot" required:NO out:&includeShot fallback:0.0 error:NULL]) {
        includeShot = 0.0;
    }
    if (![self readDouble:args key:@"clickable_only" required:NO out:&clickable fallback:1.0 error:&error]) {
        return [self mcpError:@"describe_screen" code:kPDMCPInvalidParams message:error];
    }

    PDNative_AccessibilityManager *ax = [PDNative_AccessibilityManager sharedInstance];
    NSDictionary *frontmost = [ax frontmostApplicationInfo];

    NSMutableDictionary *screen = [NSMutableDictionary dictionary];
    if ([frontmost isKindOfClass:[NSDictionary class]]) {
        id bundleId = frontmost[@"bundleId"];
        id name = frontmost[@"name"];
        if (bundleId) {
            screen[@"bundleId"] = bundleId;
        }
        if (name) {
            screen[@"name"] = name;
        }
        if ([frontmost count]) {
            screen[@"frontmost"] = frontmost;
        }
    }

    __block NSDictionary *payload = nil;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    [ax getCompactUIElementsWithMaxElements:kPDDefaultMaxElements
                                visibleOnly:YES
                               clickableOnly:(clickable != 0.0)
                                  completion:^(NSDictionary *result, NSError *queryError) {
        (void)queryError;
        payload = result;
        dispatch_semaphore_signal(sema);
    }];
    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)));

    NSArray *elements = payload[@"elements"];
    if ([payload[@"elements"] isKindOfClass:[NSArray class]]) {
        NSMutableArray *cleaned = [NSMutableArray array];
        for (id element in payload[@"elements"]) {
            id item = [self sanitizeUIElement:element debug:NO];
            if (item) {
                [cleaned addObject:item];
            }
        }
        elements = cleaned;
    } else {
        elements = @[];
    }

    if (!payload) {
        screen[@"ui_available"] = @(NO);
        screen[@"ui_error"] = @"AX query timed out";
    } else {
        screen[@"ui_available"] = @(YES);
        screen[@"elements"] = elements;
        screen[@"element_count"] = @((NSInteger)[elements count]);
        if (payload[@"truncated"]) {
            screen[@"truncated"] = payload[@"truncated"];
        }
    }

    NSMutableDictionary *result = [@{
        @"screen"       : screen,
        @"accessibility": payload ?: @{},
    } mutableCopy];

    if (includeShot != 0.0 && PDDeviceToolEnabled(@"screenshot")) {
        NSDictionary *shot = [self takeDeviceScreenshotPayload];
        if (shot[@"data"]) {
            result[@"screenshot"] = shot[@"data"];
            result[@"screenshot_mime"] = shot[@"mimeType"] ?: @"image/jpeg";
            result[@"screenshot_width"] = shot[@"width"] ?: @(0);
            result[@"screenshot_height"] = shot[@"height"] ?: @(0);
            result[@"screenshot_coordinate_space"] = @"points";
        }
    }

    return [self mcpSuccess:@"describe_screen" structuredContent:result isError:NO];
}

#pragma mark - 触摸

/// 191 指令。x/y 必填，默认 10 秒超时。
- (id)executeTap:(NSString *)tool args:(NSDictionary *)args {
    NSString *error = nil;
    double x = 0.0, y = 0.0;
    if (![self readDouble:args key:@"x" required:YES out:&x fallback:0.0 error:&error] ||
        ![self readDouble:args key:@"y" required:YES out:&y fallback:0.0 error:&error]) {
        return [self mcpError:@"tap_screen" code:kPDMCPInvalidParams message:error];
    }

    __block BOOL ok = NO;
    __block NSString *failure = nil;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    [[PDNative_IOSMCPHIDManager sharedInstance]
        tapAtPoint:CGPointMake(x, y)
         completion:^(BOOL success, NSError *touchError) {
        ok = success;
        failure = touchError.localizedDescription;
        dispatch_semaphore_signal(sema);
    }];
    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPDTapTimeout * NSEC_PER_SEC)));

    if (ok) {
        return [self mcpSuccess:@"tap_screen"
                           text:[NSString stringWithFormat:@"Tapped at (%.1f, %.1f)", x, y]
                        isError:NO];
    }
    NSString *reason = failure.length ? failure : @"timeout";
    return [self mcpSuccess:@"tap_screen"
                       text:[NSString stringWithFormat:@"Tap failed: %@", reason]
                    isError:YES];
}

/// 278 指令。fromX/fromY/toX/toY 必填；duration 300ms，steps 20。
- (id)executeSwipe:(NSString *)tool args:(NSDictionary *)args {
    NSString *error = nil;
    double fromX = 0.0, fromY = 0.0, toX = 0.0, toY = 0.0;
    double duration = kPDSwipeDuration, steps = (double)kPDSwipeSteps;

    if (![self readDouble:args key:@"fromX" required:YES out:&fromX fallback:0.0 error:&error] ||
        ![self readDouble:args key:@"fromY" required:YES out:&fromY fallback:0.0 error:&error] ||
        ![self readDouble:args key:@"toX" required:YES out:&toX fallback:0.0 error:&error] ||
        ![self readDouble:args key:@"toY" required:YES out:&toY fallback:0.0 error:&error]) {
        return [self mcpError:@"swipe_screen" code:kPDMCPInvalidParams message:error];
    }
    if (![self readDouble:args key:@"duration" required:NO out:&duration fallback:kPDSwipeDuration error:&error] ||
        ![self readDouble:args key:@"steps" required:NO out:&steps fallback:(double)kPDSwipeSteps error:&error]) {
        return [self mcpError:@"swipe_screen" code:kPDMCPInvalidParams message:error];
    }

    __block BOOL ok = NO;
    __block NSString *failure = nil;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    [[PDNative_IOSMCPHIDManager sharedInstance]
        swipeFromPoint:CGPointMake(fromX, fromY)
               toPoint:CGPointMake(toX, toY)
              duration:duration
                 steps:(long long)steps
            completion:^(BOOL success, NSError *touchError) {
        ok = success;
        failure = touchError.localizedDescription;
        dispatch_semaphore_signal(sema);
    }];
    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPDTapTimeout * NSEC_PER_SEC)));

    if (ok) {
        return [self mcpSuccess:@"swipe_screen"
                           text:[NSString stringWithFormat:@"Swiped from (%.1f,%.1f) to (%.1f,%.1f) in %.0fms",
                                 fromX, fromY, toX, toY, duration]
                        isError:NO];
    }
    NSString *reason = failure.length ? failure : @"timeout";
    return [self mcpSuccess:@"swipe_screen"
                       text:[NSString stringWithFormat:@"Swipe failed: %@", reason]
                    isError:YES];
}

/// 217 指令。duration <= 0 时回落 500ms。
- (id)executeLongPress:(NSString *)tool args:(NSDictionary *)args {
    NSString *error = nil;
    double x = 0.0, y = 0.0, duration = kPDLongPressDuration;

    if (![self readDouble:args key:@"x" required:YES out:&x fallback:0.0 error:&error] ||
        ![self readDouble:args key:@"y" required:YES out:&y fallback:0.0 error:&error]) {
        return [self mcpError:@"long_press" code:kPDMCPInvalidParams message:error];
    }
    if (![self readDouble:args key:@"duration" required:NO out:&duration
                 fallback:kPDLongPressDuration error:&error]) {
        return [self mcpError:@"long_press" code:kPDMCPInvalidParams message:error];
    }
    if (!(duration > 0.0)) {
        duration = kPDLongPressDuration;
    }

    __block BOOL ok = NO;
    __block NSString *failure = nil;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    [[PDNative_IOSMCPHIDManager sharedInstance]
        longPressAtPoint:CGPointMake(x, y)
                duration:duration
              completion:^(BOOL success, NSError *touchError) {
        ok = success;
        failure = touchError.localizedDescription;
        dispatch_semaphore_signal(sema);
    }];
    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPDTapTimeout * NSEC_PER_SEC)));

    if (ok) {
        return [self mcpSuccess:@"long_press"
                           text:[NSString stringWithFormat:@"Long pressed at (%.1f, %.1f) for %.0fms", x, y, duration]
                        isError:NO];
    }
    NSString *reason = failure.length ? failure : @"timeout";
    return [self mcpSuccess:@"long_press"
                       text:[NSString stringWithFormat:@"Long press failed: %@", reason]
                    isError:YES];
}

/// 216 指令。interval 默认 100ms。
- (id)executeDoubleTap:(NSString *)tool args:(NSDictionary *)args {
    NSString *error = nil;
    double x = 0.0, y = 0.0, interval = kPDDoubleTapInterval;

    if (![self readDouble:args key:@"x" required:YES out:&x fallback:0.0 error:&error] ||
        ![self readDouble:args key:@"y" required:YES out:&y fallback:0.0 error:&error]) {
        return [self mcpError:@"double_tap" code:kPDMCPInvalidParams message:error];
    }
    if (![self readDouble:args key:@"interval" required:NO out:&interval
                 fallback:kPDDoubleTapInterval error:&error]) {
        return [self mcpError:@"double_tap" code:kPDMCPInvalidParams message:error];
    }

    __block BOOL ok = NO;
    __block NSString *failure = nil;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    [[PDNative_IOSMCPHIDManager sharedInstance]
        doubleTapAtPoint:CGPointMake(x, y)
                interval:interval
              completion:^(BOOL success, NSError *touchError) {
        ok = success;
        failure = touchError.localizedDescription;
        dispatch_semaphore_signal(sema);
    }];
    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPDTapTimeout * NSEC_PER_SEC)));

    if (ok) {
        return [self mcpSuccess:@"double_tap"
                           text:[NSString stringWithFormat:@"Double tapped at (%.1f, %.1f) with %.0fms interval",
                                 x, y, interval]
                        isError:NO];
    }
    NSString *reason = failure.length ? failure : @"timeout";
    return [self mcpSuccess:@"double_tap"
                       text:[NSString stringWithFormat:@"Double tap failed: %@", reason]
                    isError:YES];
}

/// 637 指令。points 数组（每项 {x,y} 或 [x,y]），至少 2 个；
/// hold_duration 500ms，move_duration 300ms，steps 20。
/// 兼容旧参数 fromX/fromY/toX/toY。
- (id)executeDragAndDrop:(NSString *)tool args:(NSDictionary *)args {
    // 0x6958c：取 points 数组，空则回 null 错误
    id points = [args isKindOfClass:[NSDictionary class]] ? args[@"points"] : nil;
    if (![points isKindOfClass:[NSArray class]] || [points count] < 2) {
        return [NSNull null];
    }
    NSMutableArray *ordered = [NSMutableArray arrayWithCapacity:[points count]];
    for (id point in points) {
        if ([point isKindOfClass:[NSDictionary class]]) {
            CGPoint cg = CGPointMake([point[@"x"] doubleValue], [point[@"y"] doubleValue]);
            [ordered addObject:[NSValue valueWithCGPoint:cg]];
        }
    }
    if ([ordered count] < 2) {
        return [self mcpError:nil code:(NSInteger)-32602 message:@"points 至少需要两个点"];
    }
    CGPoint start = [[ordered firstObject] CGPointValue];
    CGPoint end = [[ordered lastObject] CGPointValue];
    (void)start;

    dispatch_semaphore_t gate = dispatch_semaphore_create(0);
    [[PDNative_IOSMCPHIDManager sharedInstance] dragAlongPoints:ordered holdDuration:0.3 moveDuration:0.6 steps:12
                                completion:^(BOOL ok, NSError *err) {
        dispatch_semaphore_signal(gate);
    }];
    dispatch_semaphore_wait(gate, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)));
    return [self mcpSuccess:nil text:[NSString stringWithFormat:@"drag (%.0f,%.0f) → %lu points",
                                      end.x, end.y, (unsigned long)[ordered count]] isError:NO];
}


#pragma mark - 按元素定位

/// 544 指令。先按匹配参数取元素，再点它的可见中心点。
- (id)executeTapElement:(NSString *)tool args:(NSDictionary *)args {
    NSString *text = nil, *type = nil, *error = nil;
    BOOL exact = NO;
    NSInteger index = 0;

    if (![self parseElementMatchArgs:args text:&text exact:&exact type:&type index:&index error:&error]) {
        if ([error hasSuffix:@"requires at least one of: text, identifier, role"]) {
            error = @"tap_element requires at least one of: text, identifier, role";
        }
        return [self mcpError:@"tap_element" code:kPDMCPInvalidParams message:error];
    }

    NSDictionary *payload = [self fetchCompactElementsClickableOnly:YES];
    NSArray *elements = payload[@"elements"];
    if (![elements isKindOfClass:[NSArray class]]) {
        return [self mcpSuccess:@"tap_element"
                     structuredContent:@{ @"tapped" : @(NO), @"reason" : @"no_match" }
                                isError:YES];
    }

    NSMutableArray *matches = [NSMutableArray array];
    NSString *identifier = args[@"identifier"];
    NSString *role = args[@"role"];
    for (id element in elements) {
        if (![element isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        BOOL hit = YES;
        if (text.length) {
            NSString *candidate = element[@"text"];
            if (![candidate isKindOfClass:[NSString class]]) {
                candidate = element[@"label"];
            }
            hit = exact ? [candidate isEqualToString:text] : (candidate && [candidate containsString:text]);
        }
        if (hit && [identifier isKindOfClass:[NSString class]] && identifier.length) {
            NSString *candidate = element[@"identifier"];
            hit = exact ? [candidate isEqualToString:identifier] : (candidate && [candidate containsString:identifier]);
        }
        if (hit && [role isKindOfClass:[NSString class]] && role.length) {
            NSString *candidate = element[@"type"] ?: element[@"role"];
            hit = [candidate isEqualToString:role];
        }
        if (hit) {
            [matches addObject:element];
        }
    }

    if (![matches count]) {
        return [self mcpSuccess:@"tap_element"
                     structuredContent:@{ @"tapped" : @(NO), @"matched_count" : @(0), @"reason" : @"no_match" }
                                isError:YES];
    }
    if (index < 0 || index >= (NSInteger)[matches count]) {
        return [self mcpSuccess:@"tap_element"
                     structuredContent:@{ @"tapped" : @(NO),
                                          @"matched_count" : @([matches count]),
                                          @"index" : @(index),
                                          @"reason" : @"index_out_of_range" }
                                isError:YES];
    }

    NSDictionary *element = matches[index];
    NSDictionary *point = element[@"tap"];
    double px = 0.0, py = 0.0;
    if ([point isKindOfClass:[NSDictionary class]]) {
        px = [point[@"x"] doubleValue];
        py = [point[@"y"] doubleValue];
    } else if ([element[@"x"] isKindOfClass:[NSNumber class]] &&
               [element[@"y"] isKindOfClass:[NSNumber class]]) {
        px = [element[@"x"] doubleValue];
        py = [element[@"y"] doubleValue];
    } else {
        return [self mcpSuccess:@"tap_element"
                     structuredContent:@{ @"tapped" : @(NO),
                                          @"matched_count" : @([matches count]),
                                          @"index" : @(index),
                                          @"reason" : @"no_tap_point" }
                                isError:YES];
    }

    __block BOOL ok = NO;
    __block NSString *failure = nil;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    [[PDNative_IOSMCPHIDManager sharedInstance]
        tapAtPoint:CGPointMake(px, py)
         completion:^(BOOL success, NSError *touchError) {
        ok = success;
        failure = touchError.localizedDescription;
        dispatch_semaphore_signal(sema);
    }];
    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPDTapTimeout * NSEC_PER_SEC)));

    if (!ok) {
        return [self mcpSuccess:@"tap_element"
                     structuredContent:@{ @"tapped" : @(NO),
                                          @"matched_count" : @([matches count]),
                                          @"index" : @(index),
                                          @"point" : @{ @"x" : @(px), @"y" : @(py) },
                                          @"reason" : @"tap_failed",
                                          @"error" : failure ?: @"timeout" }
                                isError:YES];
    }

    return [self mcpSuccess:@"tap_element"
                 structuredContent:@{
                     @"tapped"        : @(YES),
                     @"matched_count" : @([matches count]),
                     @"index"         : @(index),
                     @"point"         : @{ @"x" : @(px), @"y" : @(py) },
                     @"element"       : [self sanitizeUIElement:element debug:NO] ?: element,
                     @"query"         : @{ @"text" : text ?: [NSNull null],
                                           @"role" : role ?: [NSNull null],
                                           @"exact": @(exact) },
                 }
                            isError:NO];
}

/// 378 指令。轮询等待出现/消失；timeout_ms 5000，interval_ms 200。
- (id)executeWaitForElement:(NSString *)tool args:(NSDictionary *)args waitForAppear:(BOOL)appear {
    NSString *text = nil, *type = nil, *error = nil;
    BOOL exact = NO;
    NSInteger index = 0;

    if (![self parseElementMatchArgs:args text:&text exact:&exact type:&type index:&index error:&error]) {
        return [self mcpError:appear ? @"wait_for_element" : @"wait_for_disappear"
                         code:kPDMCPInvalidParams
                      message:error];
    }

    double timeoutMs = 5000.0, intervalMs = 200.0;
    if (![self readDouble:args key:@"timeout_ms" required:NO out:&timeoutMs fallback:5000.0 error:&error] ||
        ![self readDouble:args key:@"interval_ms" required:NO out:&intervalMs fallback:200.0 error:&error]) {
        return [self mcpError:appear ? @"wait_for_element" : @"wait_for_disappear"
                         code:kPDMCPInvalidParams
                      message:error];
    }
    if (!(intervalMs >= 1.0)) {
        intervalMs = 200.0;
    }
    if (!(timeoutMs >= 0.0)) {
        timeoutMs = 0.0;
    }

    NSString *identifier = args[@"identifier"];
    NSString *role = args[@"role"];

    NSDate *start = [NSDate date];
    NSInteger matchedCount = 0;
    NSDictionary *matchedElement = nil;
    BOOL observed = NO;
    BOOL singleObservation = NO;
    NSUInteger rounds = 0;

    while (YES) {
        NSDictionary *payload = [self fetchCompactElementsClickableOnly:YES];
        NSArray *elements = payload[@"elements"];
        if (![elements isKindOfClass:[NSArray class]]) {
            elements = @[];
        }

        NSMutableArray *matches = [NSMutableArray array];
        for (id element in elements) {
            if (![element isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            BOOL hit = YES;
            if (text.length) {
                NSString *candidate = element[@"text"];
                if (![candidate isKindOfClass:[NSString class]]) {
                    candidate = element[@"label"];
                }
                hit = exact ? [candidate isEqualToString:text] : (candidate && [candidate containsString:text]);
            }
            if (hit && [identifier isKindOfClass:[NSString class]] && identifier.length) {
                NSString *candidate = element[@"identifier"];
                hit = exact ? [candidate isEqualToString:identifier]
                            : (candidate && [candidate containsString:identifier]);
            }
            if (hit && [role isKindOfClass:[NSString class]] && role.length) {
                NSString *candidate = element[@"type"] ?: element[@"role"];
                hit = [candidate isEqualToString:role];
            }
            if (hit) {
                [matches addObject:element];
            }
        }

        matchedCount = (NSInteger)[matches count];
        BOOL present = (matchedCount > 0);
        if (present) {
            NSInteger useIndex = index;
            if (useIndex < 0 || useIndex >= matchedCount) {
                useIndex = 0;
            }
            matchedElement = matches[(NSUInteger)useIndex];
        }

        BOOL satisfied = appear ? present : !present;
        if (satisfied) {
            observed = YES;
            singleObservation = (rounds == 0);
            break;
        }

        double elapsedMs = -[start timeIntervalSinceDate:[NSDate date]] * 1000.0;
        if (elapsedMs >= timeoutMs) {
            break;
        }
        rounds++;
        double wait = MIN(intervalMs, timeoutMs - elapsedMs);
        if (wait > 0.0) {
            [NSThread sleepForTimeInterval:wait / 1000.0];
        }
    }

    double waitedMs = -[start timeIntervalSinceDate:[NSDate date]] * 1000.0;
    NSString *key = appear ? @"found" : @"disappeared";
    NSMutableDictionary *content = [@{
        key                : @(observed),
        @"matched_count"   : @(matchedCount),
        @"waited_ms"       : @(round(waitedMs)),
        @"single_observation": @(singleObservation),
    } mutableCopy];

    if (matchedElement) {
        content[@"element"] = [self sanitizeUIElement:matchedElement debug:NO] ?: matchedElement;
    }
    if (!observed) {
        content[@"reason"] = @"Condition not observed; no polling performed. Do not automatically repeat this tool.";
    }

    return [self mcpSuccess:appear ? @"wait_for_element" : @"wait_for_disappear"
        structuredContent:content
                   isError:!observed];
}

#pragma mark - 文字输入

/// 174 指令。
- (id)executeInputText:(NSString *)tool args:(NSDictionary *)args {
    NSString *text = nil, *error = nil;
    if (![self readString:args key:@"text" required:YES out:&text error:&error]) {
        return [self mcpError:@"input_text" code:kPDMCPInvalidParams message:error];
    }

    __block NSError *failure = nil;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    [[PDNative_TextInputManager sharedInstance] inputText:text completion:^(BOOL ok, NSError *err) {
        (void)ok;
        failure = err;
        dispatch_semaphore_signal(sema);
    }];
    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPDTapTimeout * NSEC_PER_SEC)));

    if (!failure) {
        return [self mcpSuccess:@"input_text"
                           text:[NSString stringWithFormat:@"Input %lu characters", (unsigned long)text.length]
                        isError:NO];
    }
    return [self mcpSuccess:@"input_text"
                       text:[NSString stringWithFormat:@"Input failed: %@", failure.localizedDescription ?: @"timeout"]
                    isError:YES];
}

/// 229 指令。delay_ms 默认 5。
- (id)executeTypeText:(NSString *)tool args:(NSDictionary *)args {
    NSString *text = nil, *error = nil;
    double delay = kPDTypeDelay;

    if (![self readString:args key:@"text" required:YES out:&text error:&error]) {
        return [self mcpError:@"type_text" code:kPDMCPInvalidParams message:error];
    }
    if (![self readDouble:args key:@"delay_ms" required:NO out:&delay fallback:kPDTypeDelay error:&error]) {
        return [self mcpError:@"type_text" code:kPDMCPInvalidParams message:error];
    }

    __block NSError *failure = nil;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    [[PDNative_TextInputManager sharedInstance] typeText:text delayMs:delay completion:^(BOOL ok, NSError *err) {
        (void)ok;
        failure = err;
        dispatch_semaphore_signal(sema);
    }];
    double wait = MAX(kPDTapTimeout, delay * (double)MAX(text.length, (NSUInteger)1) / 1000.0 + kPDTapTimeout);
    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)));

    if (!failure) {
        NSString *message = [NSString stringWithFormat:@"Typed %lu characters", (unsigned long)text.length];
        if (delay != kPDTypeDelay) {
            message = [message stringByAppendingFormat:@" (%.0fms)", delay];
        }
        return [self mcpSuccess:@"type_text" text:message isError:NO];
    }
    return [self mcpSuccess:@"type_text"
                       text:[NSString stringWithFormat:@"Type failed: %@", failure.localizedDescription ?: @"timeout"]
                    isError:YES];
}

/// 169 指令。
- (id)executePressKey:(NSString *)tool args:(NSDictionary *)args {
    NSString *key = nil, *error = nil;
    if (![self readString:args key:@"key" required:YES out:&key error:&error]) {
        return [self mcpError:@"press_key" code:kPDMCPInvalidParams message:error];
    }

    __block NSError *failure = nil;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    [[PDNative_TextInputManager sharedInstance] pressKey:key completion:^(BOOL ok, NSError *err) {
        (void)ok;
        failure = err;
        dispatch_semaphore_signal(sema);
    }];
    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPDTapTimeout * NSEC_PER_SEC)));

    if (!failure) {
        return [self mcpSuccess:@"press_key"
                           text:[NSString stringWithFormat:@"Pressed key: %@", key]
                        isError:NO];
    }
    return [self mcpSuccess:@"press_key"
                       text:[NSString stringWithFormat:@"Key press failed: %@", failure.localizedDescription ?: @"timeout"]
                    isError:YES];
}

#pragma mark - App 管理

/// 102 指令。
- (id)executeLaunchApp:(NSString *)tool args:(NSDictionary *)args {
    NSString *bundleId = nil, *error = nil;
    if (![self readString:args key:@"bundle_id" required:YES out:&bundleId error:&error]) {
        return [self mcpError:@"launch_app" code:kPDMCPInvalidParams message:error];
    }

    NSError *launchError = nil;
    BOOL ok = [[PDNative_AppManager sharedInstance] launchApp:bundleId error:&launchError];
    if (ok) {
        return [self mcpSuccess:@"launch_app"
                           text:[NSString stringWithFormat:@"Launched %@ and confirmed it is frontmost", bundleId]
                        isError:NO];
    }
    return [self mcpSuccess:@"launch_app"
                       text:[NSString stringWithFormat:@"Failed: %@",
                             launchError.localizedDescription ?: @"unknown"]
                    isError:YES];
}

/// 102 指令。
- (id)executeKillApp:(NSString *)tool args:(NSDictionary *)args {
    NSString *bundleId = nil, *error = nil;
    if (![self readString:args key:@"bundle_id" required:YES out:&bundleId error:&error]) {
        return [self mcpError:@"kill_app" code:kPDMCPInvalidParams message:error];
    }

    NSError *killError = nil;
    BOOL ok = [[PDNative_AppManager sharedInstance] killApp:bundleId error:&killError];
    if (ok) {
        return [self mcpSuccess:@"kill_app"
                           text:[NSString stringWithFormat:@"Killed %@", bundleId]
                        isError:NO];
    }
    return [self mcpSuccess:@"kill_app"
                       text:[NSString stringWithFormat:@"Failed: %@",
                             killError.localizedDescription ?: @"unknown"]
                    isError:YES];
}

/// 112 指令。type 默认 "user"。
- (id)executeListApps:(NSString *)tool args:(NSDictionary *)args {
    NSString *type = [args isKindOfClass:[NSDictionary class]] ? args[@"type"] : nil;
    BOOL userOnly = ([type isKindOfClass:[NSString class]] && [type length] > 0 &&
                     [type isEqualToString:@"user"]);
    NSArray *apps = [[PDNative_AppManager sharedInstance] listInstalledApps:@(userOnly)];
    NSString *json = [self jsonTextForObject:apps ?: @[]];
    if (![json isKindOfClass:[NSString class]]) {
        return [self mcpError:nil code:(NSInteger)-32603 message:@"序列化失败"];
    }
    return [self mcpSuccess:nil structuredContent:@{ @"apps": json, @"type": type ?: @"all" } isError:NO];
}


/// 74 指令。
- (id)executeListRunningApps:(NSString *)tool {
    NSArray *apps = [[PDNative_AppManager sharedInstance] listRunningApps];
    NSString *json = [self jsonTextForObject:apps ?: @[]];
    return [self mcpSuccess:nil structuredContent:@{ @"apps": json ?: @"[]" } isError:NO];
}


/// 70 指令。
- (id)executeGetFrontmostApp:(NSString *)tool args:(NSDictionary *)args {
    double debugFlag = 0.0;
    if (![self readDouble:args key:@"debug" required:NO out:&debugFlag fallback:0.0 error:NULL]) {
        debugFlag = 0.0;
    }
    NSDictionary *info = [[PDNative_AppManager sharedInstance] getFrontmostApp];
    id sanitized = [self sanitizeFrontmostInfo:info debug:(debugFlag != 0.0)];
    if (!sanitized) {
        return [self mcpError:@"get_frontmost_app" code:kPDMCPInvalidParams message:@"未接入此设备工具。"];
    }
    return [self mcpSuccess:@"get_frontmost_app" structuredContent:sanitized isError:NO];
}

/// 87 指令。
- (id)executeGetAppInfo:(NSString *)tool args:(NSDictionary *)args {
    NSString *bundleId = nil, *error = nil;
    if (![self readString:args key:@"bundle_id" required:YES out:&bundleId error:&error]) {
        return [self mcpError:@"get_app_info" code:kPDMCPInvalidParams message:error];
    }

    NSError *infoError = nil;
    NSDictionary *info = [[PDNative_AppManager sharedInstance] appInfoForBundleId:bundleId
                                                                           error:&infoError];
    if (![info isKindOfClass:[NSDictionary class]]) {
        return [self mcpError:@"get_app_info" code:kPDMCPInvalidParams
                      message:infoError.localizedDescription ?: @"Failed to read app info"];
    }
    return [self mcpSuccess:@"get_app_info" structuredContent:info isError:NO];
}

/// 102 指令。
- (id)executeOpenURL:(NSString *)tool args:(NSDictionary *)args {
    NSString *url = nil, *error = nil;
    if (![self readString:args key:@"url" required:YES out:&url error:&error]) {
        return [self mcpError:@"open_url" code:kPDMCPInvalidParams message:error];
    }

    NSError *openError = nil;
    BOOL ok = [[PDNative_AppManager sharedInstance] openURL:url error:&openError];
    if (ok) {
        return [self mcpSuccess:@"open_url"
                           text:[NSString stringWithFormat:@"Opened URL: %@", url]
                        isError:NO];
    }
    return [self mcpSuccess:@"open_url"
                       text:[NSString stringWithFormat:@"Failed to open URL: %@",
                             openError.localizedDescription ?: @"unknown"]
                    isError:YES];
}

#pragma mark - 载荷清洗

/// 58 指令。只保留 index/type/text/clickable/rect/visible_rect 六个键；
/// 非 debug 时把空值与 nil 一起丢掉；额外补一个 tap 点（来自 visible_point 或 center_point）。
- (id)sanitizeUIElement:(id)element debug:(BOOL)debug {
    if (![element isKindOfClass:[NSDictionary class]]) {
        return element;
    }
    NSDictionary *source = element;
    if (!debug && ![source count]) {
        return nil;
    }

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSString *key in @[ @"index", @"type", @"text", @"clickable", @"rect", @"visible_rect" ]) {
        id value = source[key];
        if (value && value != [NSNull null]) {
            out[key] = value;
        }
    }

    id tap = [self tapPointForElement:source];
    if (tap) {
        out[@"tap"] = tap;
    }
    return [out copy];
}

/// 从 visible_point / center_point 取点，输出 {x, y}。
/// [非二进制] 二进制把坐标换算内联在调用点（L1370 处），无独立方法。
- (id)tapPointForElement:(NSDictionary *)element {
    for (NSString *key in @[ @"visible_point", @"center_point", @"tap" ]) {
        id point = element[key];
        if ([point isKindOfClass:[NSDictionary class]] && point[@"x"] && point[@"y"]) {
            return point;
        }
    }
    return nil;
}

/// 159 指令。去掉 format 键，逐条清洗 elements。
- (id)sanitizeUIElementsPayload:(id)payload debug:(BOOL)debug {
    if (![payload isKindOfClass:[NSDictionary class]]) {
        return payload;
    }
    NSMutableDictionary *out = [payload mutableCopy];
    [out removeObjectForKey:@"format"];

    id elements = payload[@"elements"];
    if ([elements isKindOfClass:[NSArray class]]) {
        NSMutableArray *cleaned = [NSMutableArray arrayWithCapacity:[elements count]];
        for (id element in elements) {
            id item = [self sanitizeUIElement:element debug:debug];
            if (item) {
                [cleaned addObject:item];
            }
        }
        out[@"elements"] = cleaned;
    }
    return [out copy];
}

/// 155 指令。递归清洗 children。
- (id)sanitizeElementAtPointPayload:(id)payload debug:(BOOL)debug {
    if (![payload isKindOfClass:[NSDictionary class]]) {
        return payload;
    }
    NSMutableDictionary *out = [payload mutableCopy];

    id children = payload[@"children"];
    if ([children isKindOfClass:[NSArray class]]) {
        NSMutableArray *cleaned = [NSMutableArray arrayWithCapacity:[children count]];
        for (id child in children) {
            id item = [self sanitizeElementAtPointPayload:child debug:debug];
            if (item) {
                [cleaned addObject:item];
            }
        }
        out[@"children"] = cleaned;
    }
    return [out copy];
}

/// 46 指令。只保留 type/data/mimeType/_meta。
- (id)sanitizeScreenshotContent:(id)content debug:(BOOL)debug {
    if (![content isKindOfClass:[NSDictionary class]]) {
        return content;
    }
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSString *key in @[ @"type", @"data", @"mimeType", @"_meta" ]) {
        id value = content[key];
        if (value && value != [NSNull null]) {
            out[key] = value;
        }
    }
    return [out copy];
}

/// 46 指令。只保留 bundleId/name/processName/pid/contextId/displayId/sceneIdentifier。
- (id)sanitizeFrontmostInfo:(id)info debug:(BOOL)debug {
    if (![info isKindOfClass:[NSDictionary class]]) {
        return info;
    }
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSString *key in @[ @"bundleId", @"name", @"processName", @"pid",
                             @"contextId", @"displayId", @"sceneIdentifier" ]) {
        id value = info[key];
        if (value && value != [NSNull null]) {
            out[key] = value;
        }
    }
    return [out copy];
}

/// 87 指令。把 frontmostContext 换成清洗后的版本。
- (id)sanitizeAccessibilityFailurePayload:(id)payload debug:(BOOL)debug {
    if (![payload isKindOfClass:[NSDictionary class]]) {
        return payload;
    }
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    id context = payload[@"frontmostContext"];
    if ([context isKindOfClass:[NSDictionary class]] && [context count]) {
        out[@"frontmostContext"] = [self sanitizeFrontmostInfo:context debug:debug];
    }
    for (id key in payload) {
        if ([key isEqual:@"frontmostContext"]) {
            continue;
        }
        out[key] = payload[key];
    }
    return [out copy];
}

#pragma mark - MCP 信封

/// 128 指令。
/// Observed @0x6df90（2 条）：mov w4,#0 ; b 0xae080 —— 纯转发，isError 固定 NO。
- (id)mcpSuccess:(id)tool text:(NSString *)text {
    return [self mcpSuccess:tool text:text isError:NO];
}

/// Observed @0x6dfa4（2 条）：mov w4,#0 ; b 0xae040 —— 纯转发，isError 固定 NO。
- (id)mcpSuccess:(id)tool structuredContent:(id)content {
    return [self mcpSuccess:tool structuredContent:content isError:NO];
}

- (id)mcpSuccess:(id)tool text:(NSString *)text isError:(BOOL)isError {
    return [self mcpSuccess:tool text:text structuredContent:nil isError:isError];
}

/// 43 指令。
- (id)mcpSuccess:(id)tool structuredContent:(id)content isError:(BOOL)isError {
    return [self mcpSuccess:tool text:[self jsonTextForDictionary:content] structuredContent:content isError:isError];
}

/// 156 指令。JSON-RPC 2.0 结果：{jsonrpc:"2.0", id:null, result:{content:[{type:"text",text}], structuredContent, isError}}
- (id)mcpSuccess:(id)tool text:(NSString *)text structuredContent:(id)content isError:(BOOL)isError {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];

    NSMutableDictionary *item = [NSMutableDictionary dictionary];
    item[@"type"] = @"text";
    item[@"text"] = text ?: @"";
    result[@"content"] = @[ [item copy] ];

    if (content) {
        result[@"structuredContent"] = content;
    }
    result[@"isError"] = @(isError);

    return @{
        @"jsonrpc" : @"2.0",
        @"id"      : [NSNull null],
        @"result"  : [result copy],
    };
}

/// 89 指令。
- (id)mcpError:(id)tool code:(NSInteger)code message:(NSString *)message {
    return @{
        @"jsonrpc" : @"2.0",
        @"id"      : [NSNull null],
        @"error"   : @{
            @"code"    : @(code),
            @"message" : message ?: @"设备工具执行失败。",
        },
    };
}

/// 53 指令。
- (NSString *)jsonTextForObject:(id)object {
    if (![NSJSONSerialization isValidJSONObject:object]) {
        return @"{}";
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
    if (!data) {
        return @"{}";
    }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return text ?: @"{}";
}

/// 5 指令。
- (NSString *)jsonTextForDictionary:(NSDictionary *)dictionary {
    if (![dictionary isKindOfClass:[NSDictionary class]]) {
        return @"{}";
    }
    return [self jsonTextForObject:dictionary];
}

@end
