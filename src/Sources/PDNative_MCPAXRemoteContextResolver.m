//
//  PDNative_MCPAXRemoteContextResolver.m — 逆向还原
//
//  18 个方法 / 4863 指令。AX 组的「前台是谁」判定器。
//
//  ── 方法规模 ──────────────────────────────────────────────────────
//    populateContext:fromWorkspaceScenesWithTrace:metadata:   876
//    populateContext:fromAXFrontBoardWithTrace:metadata:      721
//    populateContext:fromApplicationObject:resolutionTrace:   613
//    populateAccessibilityActivationMetadata:context:trace:   563
//    populateSceneFieldsForContext:…:prefix:                  459
//    pidFromApplicationObject:bundleId:resolutionTrace:       252
//    invokeNumericSelector:onTarget:                          207
//    applicationObjectForPid:resolutionTrace:                 185
//    frontmostContext                                         181
//    axFrontBoardAvailability                                 178
//    preferredApplicationObjectFromCandidateValue:            172
//    firstNonEmptyStringSelectorValueFromTarget:…             101
//    firstPositiveNumericSelectorValueFromTarget:…             93
//    invokeObjectSelector:onTarget:                            87
//    populateContext:fromPid:resolutionTrace:                  77
//    legacyFrontmostApplicationObject                          46
//    contextHasIdentity                                        27
//    frontmostContextDictionary                                25
//
//  ── frontmostContext 的解析顺序（0x88318）───────────────────────
//    1. 新建 PDNative_MCPAXQueryContext + trace 数组 + metadata（用 axFrontBoardAvailability 起底）
//    2. 整段在主线程执行（isMainThread ? block() : dispatch_sync(main)）
//    3. 依次尝试，任一成功即停：
//         a. populateContext:fromAXFrontBoardWithTrace:metadata:   （AXFrontBoardUtils 私有函数）
//            失败 → trace += "axfrontboard:unavailable"
//         b. legacyFrontmostApplicationObject
//            非空 → trace += "springboard:_accessibilityFrontMostApplication"
//                 → populateContext:fromApplicationObject:…
//                 → 若拿到身份 → strategy = "springboard_accessibility_frontmost"
//         c. populateContext:fromWorkspaceScenesWithTrace:metadata:（FBSWorkspace scene 遍历）
//         d. 都没身份 → populateContext:fromPid:（用 SBApplicationController 猜）
//    4. displayId 为 0 时：CADisplay.mainDisplay.displayId 兜底
//       成功 → trace += "fallback:CADisplay.mainDisplay.displayId"
//    5. 仍无 bundleId → 硬编码 SpringBoard：
//         bundleId = "com.apple.springboard"
//         processName = "SpringBoard"
//         strategy = "springboard_default"
//         trace += "fallback:springboard_default"
//    6. strategy 为空 → "springboard_default" + trace += "resolver_completed_without_explicit_strategy"
//
//  ── AXFrontBoardUtils 的 8 个私有函数（dlsym 解析，0x8d4d8）──────
//    dlopen 先试 RTLD_LAZY(1)，失败再试 RTLD_NOW(2)
//    /System/Library/PrivateFrameworks/AXFrontBoardUtils.framework/AXFrontBoardUtils
//      AXFrontBoardFocusedAppPID
//      AXFrontBoardFocusedAppPIDs
//      AXFrontBoardFocusedAppPIDsIgnoringSiri
//      AXFrontBoardFocusedApps
//      AXFrontBoardFocusedAppProcess
//      AXFrontBoardFocusedAppProcesses
//      AXFrontBoardVisibleAppProcesses
//      AXFrontBoardFBSceneManager
//
//  标记：逆向还原
//

#import "PDNative_MCPAXRemoteContextResolver.h"
#import <mach-o/dyld.h>
#import "PDNative_MCPAXQueryContext.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>

static NSString * const kPDAXFrontBoardPath =
    @"/System/Library/PrivateFrameworks/AXFrontBoardUtils.framework/AXFrontBoardUtils";

/// 8 个私有 C 函数。返回值统一按 id 处理（可能是 NSArray / NSNumber / 对象）。
typedef id (*PDAXFrontBoardFn)(void);

static void *gAXFrontBoardHandle;
static PDAXFrontBoardFn gFocusedAppPID;
static PDAXFrontBoardFn gFocusedAppPIDs;
static PDAXFrontBoardFn gFocusedAppPIDsIgnoringSiri;
static PDAXFrontBoardFn gFocusedApps;
static PDAXFrontBoardFn gFocusedAppProcess;
static PDAXFrontBoardFn gFocusedAppProcesses;
static PDAXFrontBoardFn gVisibleAppProcesses;
static PDAXFrontBoardFn gFBSceneManager;

static void PDLoadAXFrontBoard(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen(kPDAXFrontBoardPath.UTF8String, RTLD_LAZY);
        if (!handle) {
            handle = dlopen(kPDAXFrontBoardPath.UTF8String, RTLD_NOW);
        }
        if (!handle) {
            return;
        }
        gAXFrontBoardHandle = handle;
        gFocusedAppPID               = (PDAXFrontBoardFn)dlsym(handle, "AXFrontBoardFocusedAppPID");
        gFocusedAppPIDs              = (PDAXFrontBoardFn)dlsym(handle, "AXFrontBoardFocusedAppPIDs");
        gFocusedAppPIDsIgnoringSiri  = (PDAXFrontBoardFn)dlsym(handle, "AXFrontBoardFocusedAppPIDsIgnoringSiri");
        gFocusedApps                 = (PDAXFrontBoardFn)dlsym(handle, "AXFrontBoardFocusedApps");
        gFocusedAppProcess           = (PDAXFrontBoardFn)dlsym(handle, "AXFrontBoardFocusedAppProcess");
        gFocusedAppProcesses         = (PDAXFrontBoardFn)dlsym(handle, "AXFrontBoardFocusedAppProcesses");
        gVisibleAppProcesses         = (PDAXFrontBoardFn)dlsym(handle, "AXFrontBoardVisibleAppProcesses");
        gFBSceneManager              = (PDAXFrontBoardFn)dlsym(handle, "AXFrontBoardFBSceneManager");
    });
}

/// 数值型返回值允许的编码字符（0x8c7dc 的位掩码：q i I Q d B c s）。
static BOOL PDIsNumericReturnType(const char *type) {
    if (!type || !*type) {
        return NO;
    }
    switch (*type) {
        case 'q': case 'i': case 'I': case 'Q':
        case 'd': case 'B': case 'c': case 's':
            return YES;
        default:
            return NO;
    }
}

/// 对象型返回值只接受 '@'（0x8c6d0 的 strcmp "@"）。
static BOOL PDIsObjectReturnType(const char *type) {
    return type && strcmp(type, "@") == 0;
}

/// 从 com.susudear.petdfyprefs 读一个布尔开关（定义在文件末尾）。
static BOOL PDReadBoolPreference(NSString *key);

@implementation PDNative_MCPAXRemoteContextResolver

#pragma mark - 入口

/// 181 指令。
- (PDNative_MCPAXQueryContext *)frontmostContext {
    PDNative_MCPAXQueryContext *context = [[PDNative_MCPAXQueryContext alloc] init];
    NSMutableArray<NSString *> *trace = [NSMutableArray array];
    NSMutableDictionary *metadata = [self.axFrontBoardAvailability mutableCopy] ?: [NSMutableDictionary dictionary];

    dispatch_block_t work = ^{
        // ── a. AXFrontBoardUtils ────────────────────────────
        BOOL resolved = [self populateContext:context
                    fromAXFrontBoardWithTrace:trace
                                     metadata:metadata];
        if (!resolved) {
            [trace addObject:@"axfrontboard:unavailable"];

            // ── b. 老式 SpringBoard 入口 ────────────────────
            id legacy = [self legacyFrontmostApplicationObject];
            if (legacy) {
                [trace addObject:@"springboard:_accessibilityFrontMostApplication"];
                [self populateContext:context
                fromApplicationObject:legacy
                      resolutionTrace:trace];

                if ([self contextHasIdentity:context]) {
                    context.resolverStrategy = @"springboard_accessibility_frontmost";
                }
            }

            // ── c. workspace scenes ─────────────────────────
            if (![self contextHasIdentity:context]) {
                [self populateContext:context
         fromWorkspaceScenesWithTrace:trace
                             metadata:metadata];
            }

            // ── d. 仅 pid 兜底 ──────────────────────────────
            if (![self contextHasIdentity:context] && context.pid > 0) {
                [self populateContext:context fromPid:context.pid resolutionTrace:trace];
            }
        }

        // ── displayId 兜底 ──────────────────────────────────
        if (context.displayId == 0) {
            id screen = [self invokeObjectSelector:@selector(mainDisplay)
                                          onTarget:NSClassFromString(@"CADisplay")];
            id displayId = [self invokeNumericSelector:@selector(displayId) onTarget:screen];
            if ([displayId respondsToSelector:@selector(unsignedIntValue)]) {
                unsigned int value = [displayId unsignedIntValue];
                if (value != 0) {
                    context.displayId = value;
                    [trace addObject:@"fallback:CADisplay.mainDisplay.displayId"];
                }
            }
        }

        // ── bundleId 兜底：直接认定 SpringBoard ─────────────
        if (!context.bundleId.length) {
            context.bundleId = @"com.apple.springboard";
            context.processName = @"SpringBoard";
            context.resolverStrategy = @"springboard_default";
            [trace addObject:@"fallback:springboard_default"];
        }

        if (!context.resolverStrategy.length) {
            context.resolverStrategy = @"springboard_default";
            [trace addObject:@"resolver_completed_without_explicit_strategy"];
        }

        // ── 运行时诊断写回 ──────────────────────────────────
        [self populateAccessibilityActivationMetadata:metadata context:context trace:trace];
        context.metadata = [metadata copy];
        context.resolutionTrace = [trace copy];
    };

    if ([NSThread isMainThread]) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }
    return context;
}

/// 25 指令。
- (NSDictionary *)frontmostContextDictionary {
    PDNative_MCPAXQueryContext *context = [self frontmostContext];
    if (!context) {
        return nil;
    }
    return [context dictionaryRepresentation];
}

#pragma mark - AXFrontBoard 路径

/// 721 指令。8 个候选按顺序试，任一拿到身份即停。
- (BOOL)populateContext:(PDNative_MCPAXQueryContext *)context
  fromAXFrontBoardWithTrace:(NSMutableArray *)trace
               metadata:(NSMutableDictionary *)metadata {
    // 721 指令：8 个 AXFrontBoard 候选按序试，任一拿到身份即停
    static dispatch_once_t loadOnce;
    dispatch_once(&loadOnce, ^{
        PDLoadAXFrontBoard();
    });
    if (!gAXFrontBoardHandle) return NO;

    struct {
        PDAXFrontBoardFn fn;
        NSString *name;
        NSString *traceName;
        NSString *strategy;
        BOOL isProcessList;
    } candidates[] = {
        { gFocusedApps,                @"AXFrontBoardFocusedApps",                @"axfrontboard:AXFrontBoardFocusedApps",                @"ax_frontboard_focused_apps",                YES },
        { gFocusedAppProcess,          @"AXFrontBoardFocusedAppProcess",          @"axfrontboard:AXFrontBoardFocusedAppProcess",          @"ax_frontboard_focused_app_process",         YES },
        { gFocusedAppProcesses,        @"AXFrontBoardFocusedAppProcesses",        @"axfrontboard:AXFrontBoardFocusedAppProcesses",        @"ax_frontboard_focused_app_processes",       YES },
        { gVisibleAppProcesses,        @"AXFrontBoardVisibleAppProcesses",        @"axfrontboard:AXFrontBoardVisibleAppProcesses",        @"ax_frontboard_visible_app_processes",       YES },
        { gFocusedAppPID,              @"AXFrontBoardFocusedAppPID",              @"axfrontboard:AXFrontBoardFocusedAppPID",              @"ax_frontboard_focused_app_pid",             NO  },
        { gFocusedAppPIDs,             @"AXFrontBoardFocusedAppPIDs",             @"axfrontboard:AXFrontBoardFocusedAppPIDs",             @"ax_frontboard_focused_app_pids",            NO  },
        { gFocusedAppPIDsIgnoringSiri, @"AXFrontBoardFocusedAppPIDsIgnoringSiri", @"axfrontboard:AXFrontBoardFocusedAppPIDsIgnoringSiri", @"ax_frontboard_focused_app_pids_ignoring_siri", NO },
        { gFBSceneManager,             @"AXFrontBoardFBSceneManager",             @"axfrontboard:AXFrontBoardFBSceneManager",             @"ax_frontboard_fb_scene_manager",            YES },
    };

    for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
        PDAXFrontBoardFn fn = candidates[i].fn;
        if (!fn) continue;

        id value = nil;
        @try {
            value = fn();
        } @catch (__unused NSException *e) {
            value = nil;
        }
        if (!value) continue;

        if (candidates[i].isProcessList) {
            id application = [self preferredApplicationObjectFromCandidateValue:value];
            if ([application isKindOfClass:[NSArray class]] || [application isKindOfClass:[NSSet class]]) {
                metadata[@"focusedAppsCount"] = @([application count]);
            }
            if (!application) continue;
            metadata[@"focusedAppsClass"] = NSStringFromClass([application class]) ?: @"<unknown>";
            [trace addObject:candidates[i].traceName];

            [self populateContext:context
            fromApplicationObject:application
                  resolutionTrace:trace];

            if (context.resolverStrategy.length) {
                context.resolverStrategy = candidates[i].strategy;
            }
            if ([self contextHasIdentity:context]) return YES;
        } else {
            int pid = 0;
            if ([value isKindOfClass:[NSNumber class]]) {
                pid = [value intValue];
            } else if ([value isKindOfClass:[NSArray class]] && [value count]) {
                id first = [value firstObject];
                if ([first respondsToSelector:@selector(intValue)]) {
                    pid = [first intValue];
                }
                metadata[@"focusedAppPIDsCount"] = @([value count]);
            }
            if (pid <= 0) continue;
            [trace addObject:candidates[i].traceName];
            [self populateContext:context fromPid:pid resolutionTrace:trace];
            if ([self contextHasIdentity:context]) {
                [context setResolverStrategy:candidates[i].strategy];
                return YES;
            }
        }
    }

    // 候选都失败：按 SpringBoard 场景再扫一遍
    [self populateSceneFieldsForContext:context
                             fromTarget:nil
                        resolutionTrace:trace
                                 prefix:@"axfrontboard"];
    return [self contextHasIdentity:context];
}




#pragma mark - 应用对象 → 上下文

/// 613 指令。
- (void)populateContext:(PDNative_MCPAXQueryContext *)context
  fromApplicationObject:(id)application
        resolutionTrace:(NSMutableArray *)trace {
    if (!context || !application) {
        return;
    }

    // pid
    int pid = [self pidFromApplicationObject:application bundleId:context.bundleId
                             resolutionTrace:trace];
    if (pid > 0) {
        context.pid = pid;
    }

    // bundleId / processName / sceneIdentifier
    NSString *bundleId = [self firstNonEmptyStringSelectorValueFromTarget:application
        selectors:@[ @"bundleIdentifier", @"applicationIdentifier", @"crs_applicationBundleIdentifier" ]
  matchedSelector:NULL];
    if (bundleId.length) {
        context.bundleId = bundleId;
    }

    NSString *processName = [self firstNonEmptyStringSelectorValueFromTarget:application
        selectors:@[ @"processName", @"displayName", @"name" ]
  matchedSelector:NULL];
    if (processName.length) {
        context.processName = processName;
    }

    [self populateSceneFieldsForContext:context
                             fromTarget:application
                        resolutionTrace:trace
                                 prefix:@"application"];

    // 应用对象解析：进程名校验 → 逐个 selector 试读数值 → 写 contextId/displayId/sceneIdentifier
    NSString *clsName = NSStringFromClass([[application class] ?: [NSObject class] class]);
    (void)getpid();
    if ([clsName hasPrefix:@"FB"]) {
        [trace addObject:[NSString stringWithFormat:@"app-class=%@", clsName]];
    }

    NSArray *numericSelectors = @[@"processIdentifier", @"pid", @"displayIdentifier"];
    NSString *matched = nil;
    unsigned long long numeric = [[self firstPositiveNumericSelectorValueFromTarget:application
                                                                         selectors:numericSelectors
                                                                   matchedSelector:&matched] unsignedLongLongValue];
    if (numeric == 0) {
        id raw = [self invokeObjectSelector:NSSelectorFromString(@"processIdentifier") onTarget:application];
        if ([raw respondsToSelector:@selector(unsignedIntValue)]) {
            numeric = (unsigned long long)[raw unsignedIntValue];
        }
    }

    NSString *sceneId = nil;
    id sceneValue = [self invokeObjectSelector:NSSelectorFromString(@"sceneIdentifier") onTarget:application];
    if ([sceneValue isKindOfClass:[NSString class]]) sceneId = sceneValue;
    if (![sceneId isKindOfClass:[NSString class]]) {
        id alt = [application performSelector:NSSelectorFromString(@"displayIdentifier")];
        if ([alt isKindOfClass:[NSString class]]) sceneId = alt;
    }
    if ([sceneId isEqualToString:@""]) sceneId = nil;
    [context setSceneIdentifier:sceneId];

    if (numeric > 0) {
        context.contextId = (unsigned int)numeric;
        context.displayId = (unsigned int)numeric;
    }
    unsigned int ctxId = [context contextId];
    unsigned int dspId = [context displayId];
    (void)ctxId; (void)dspId;
    (void)[[context sceneIdentifier] length];
}


/// 77 指令。只按 pid 填，进程名从 SBApplicationController 查；
/// 拿不到 bundleId 时直接认定 SpringBoard。
- (void)populateContext:(PDNative_MCPAXQueryContext *)context
                fromPid:(int)pid
        resolutionTrace:(NSMutableArray *)trace {
    // 77 指令：写 pid → 取应用对象 → 复用 fromApplicationObject；拿不到就认定 SpringBoard
    if (!context || pid <= 0) return;
    context.pid = pid;

    id application = [self applicationObjectForPid:pid resolutionTrace:trace];
    if (application) {
        [self populateContext:context fromApplicationObject:application resolutionTrace:trace];
    }

    if (!context.bundleId.length) {
        context.bundleId = @"com.apple.springboard";
        if (!context.processName.length) {
            context.processName = @"SpringBoard";
        }
    }
    if (pid == (int)getpid() && !context.resolverStrategy.length) {
        [context setResolverStrategy:@"self_process"];
    }
}


/// 459 指令。从 FBSWorkspace 的 scene 里挖 sceneIdentifier / contextId / displayId。
- (void)populateSceneFieldsForContext:(PDNative_MCPAXQueryContext *)context
                           fromTarget:(id)target
                      resolutionTrace:(NSMutableArray *)trace
                               prefix:(NSString *)prefix {
    if (!context || !target) {
        return;
    }

    // sceneIdentifier
    if (!context.sceneIdentifier.length) {
        NSString *scene = [self firstNonEmptyStringSelectorValueFromTarget:target
            selectors:@[ @"sceneIdentifier", @"_sceneIdentifier", @"_baseSceneIdentifier", @"identifier" ]
      matchedSelector:NULL];
        if (scene.length) {
            context.sceneIdentifier = scene;
            if (prefix.length) {
                [trace addObject:[NSString stringWithFormat:@"%@.%@", prefix, @"sceneIdentifier"]];
            }
        }
    }

    // contextId
    if (context.contextId == 0) {
        id ctxValue = [self firstPositiveNumericSelectorValueFromTarget:target
            selectors:@[ @"_accessibilityGetContextID", @"contextId", @"contextID", @"windowContextId" ]
      matchedSelector:NULL];
        if ([ctxValue respondsToSelector:@selector(unsignedIntValue)]) {
            unsigned int value = [ctxValue unsignedIntValue];
            if (value != 0) {
                context.contextId = value;
                if (prefix.length) {
                    [trace addObject:[NSString stringWithFormat:@"%@.%@", prefix, @"contextId"]];
                }
            }
        }
    }

    // displayId
    if (context.displayId == 0) {
        id dispValue = [self firstPositiveNumericSelectorValueFromTarget:target
            selectors:@[ @"displayId", @"displayID", @"windowDisplayId" ]
      matchedSelector:NULL];
        if ([dispValue respondsToSelector:@selector(unsignedIntValue)]) {
            unsigned int value = [dispValue unsignedIntValue];
            if (value != 0) {
                context.displayId = value;
                if (prefix.length) {
                    [trace addObject:[NSString stringWithFormat:@"%@.%@", prefix, @"displayId"]];
                }
            }
        }
    }

    if ([target isKindOfClass:[NSSet class]]) {
        (void)[(NSSet *)target allObjects];
    }
    NSArray *sceneIdKeys = @[@"identifier", @"sceneIdentifier", @"_sceneIdentifier"];
    for (NSString *key in sceneIdKeys) {
        id value = [self invokeObjectSelector:NSSelectorFromString(key) onTarget:target];
        if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
            (void)value;
            break;
        }
    }
    id numericId = [self invokeNumericSelector:NSSelectorFromString(@"contextID") onTarget:target];
    if (numericId == [NSNull null]) numericId = @0;
    (void)numericId;
}


#pragma mark - workspace scenes

/// 876 指令。遍历 FBSWorkspace 的 scene 列表。
/// 细节（0x8a91c）：
///   workspace = FBSWorkspace._sharedWorkspaceIfExists ?: FBSWorkspace.sharedWorkspace
///   scenes    = workspace.scenes
///   metadata["workspaceSceneCount"] = scenes.count
///   逐个 scene 取：
///       contextID / crs_applicationBundleIdentifier / sceneIdentifier / displayId
///   再按 scene 的进程名是否含 "AXUI" / "VOT" / "VoiceOver" 分类计数
///   最多只看 8 个 scene（cmp x0, 8）
- (void)populateContext:(PDNative_MCPAXQueryContext *)context
  fromWorkspaceScenesWithTrace:(NSMutableArray *)trace
               metadata:(NSMutableDictionary *)metadata {
    if (!context) {
        return;
    }

    Class workspaceClass = NSClassFromString(@"FBSWorkspace");
    if (!workspaceClass) {
        return;
    }
    id workspace = [self invokeObjectSelector:NSSelectorFromString(@"_sharedWorkspaceIfExists")
                                     onTarget:workspaceClass];
    if (!workspace) {
        workspace = [self invokeObjectSelector:NSSelectorFromString(@"sharedWorkspace")
                                      onTarget:workspaceClass];
    }
    if (!workspace) {
        return;
    }

    id scenes = [self invokeObjectSelector:@selector(scenes) onTarget:workspace];
    if (![scenes isKindOfClass:[NSArray class]] && ![scenes isKindOfClass:[NSSet class]]) {
        return;
    }
    NSArray *sceneList = [scenes isKindOfClass:[NSArray class]] ? scenes : [(NSSet *)scenes allObjects];
    if (![sceneList count]) {
        [trace addObject:@"workspace:scenes_empty"];
        return;
    }
    metadata[@"workspaceSceneCount"] = @([sceneList count]);

    NSUInteger limit = MIN([sceneList count], (NSUInteger)8);
    NSUInteger matchedIndex = NSNotFound;

    for (NSUInteger index = 0; index < limit; index++) {
        id scene = sceneList[index];

        // 场景类名 + pid 数值兜底（NSStringFromClass / invokeNumericSelector / unsignedIntValue）
        NSString *sceneCls = NSStringFromClass([scene class]);
        unsigned long long sceneValue = [[self invokeNumericSelector:@selector(pid) onTarget:scene] unsignedLongLongValue];
        if (sceneValue == 0) {
            id rawId = [self invokeObjectSelector:@selector(identifier) onTarget:scene];
            if ([rawId respondsToSelector:@selector(unsignedIntValue)]) {
                sceneValue = (unsigned long long)[rawId unsignedIntValue];
            }
        }
        if (sceneValue > 0) {
            context.pid = (int)sceneValue;
        }
        int pidBox = [context pid];
        (void)pidBox;
        if ([[[context sceneIdentifier] description] isEqualToString:sceneCls]) {
            [trace addObject:[NSString stringWithFormat:@"scene-class=%@", sceneCls]];
        }
        {
            NSArray *comps = [[context sceneIdentifier] componentsSeparatedByString:@"-"];
            if ([comps count] > 1) {
                NSArray *head = [comps subarrayWithRange:NSMakeRange(0, 1)];
                (void)[head firstObject];
            }
        }

        // sceneIdentifier / contextId / displayId
        [self populateSceneFieldsForContext:context
                                 fromTarget:scene
                            resolutionTrace:trace
                                     prefix:[NSString stringWithFormat:@"workspace.scenes[%lu]",
                                             (unsigned long)index]];

        // bundleId 从 crs_applicationBundleIdentifier 取
        if (!context.bundleId.length) {
            NSString *bundleId = [self firstNonEmptyStringSelectorValueFromTarget:scene
                selectors:@[ @"crs_applicationBundleIdentifier" ]
          matchedSelector:NULL];
            if (bundleId.length) {
                context.bundleId = bundleId;
            }
        }

        if ([self contextHasIdentity:context] && matchedIndex == NSNotFound) {
            matchedIndex = index;
            [trace addObject:@"workspace:matched_scene"];
            metadata[@"workspaceMatchedScene"] = @(index);
            if (!context.resolverStrategy.length) {
                context.resolverStrategy = @"workspace_scene";
            }
            break;
        }
    }

    if (matchedIndex == NSNotFound) {
        [trace addObject:@"workspace:no_matching_scene"];
    }
}

#pragma mark - 运行时诊断

/// 563 指令。探测 VoiceOver / AssistiveTouch / registrar 状态。
- (void)populateAccessibilityActivationMetadata:(NSMutableDictionary *)metadata
                                        context:(PDNative_MCPAXQueryContext *)context
                                          trace:(NSMutableArray *)trace {
    if (!metadata) {
        return;
    }

    NSMutableDictionary *state = [NSMutableDictionary dictionary];

    // ── 偏好层：辅助功能总开关 / VoiceOver / AssistiveTouch ──
    BOOL axEnabled = PDReadBoolPreference(@"AccessibilityEnabled");
    BOOL voEnabled = PDReadBoolPreference(@"VoiceOverTouchEnabled");
    BOOL atEnabled = PDReadBoolPreference(@"AssistiveTouchEnabled");
    BOOL atUIEnabled = PDReadBoolPreference(@"AssistiveTouchUIEnabled");

    state[@"voiceOverRunning"] = @(voEnabled);
    state[@"assistiveTouchRunning"] = @(atEnabled && atUIEnabled);

    // ── 运行时层：当前进程是否像 registrar ─────────────────
    Class votServerClass = NSClassFromString(@"VOTUIServer");
    Class curtainClass = NSClassFromString(@"VOTUIScreenCurtainViewController");
    BOOL hasVOTServer = (votServerClass != Nil);
    BOOL hasCurtain = (curtainClass != Nil);
    BOOL hasVOImage = (NSClassFromString(@"AXUIElement") != Nil);

    state[@"currentProcessHasVOTUIServerClass"] = @(hasVOTServer);
    state[@"currentProcessHasVOTScreenCurtainViewControllerClass"] = @(hasCurtain);
    state[@"currentProcessHasVoiceOverBundleImage"] = @(hasVOImage);

    NSString *processName = context.processName ?: [[NSProcessInfo processInfo] processName];
    BOOL looksLikeRegistrar = hasVOTServer || hasCurtain ||
        [processName containsString:@"VoiceOver"] ||
        [processName containsString:@"AccessibilityUIServer"];
    state[@"currentProcessLooksLikeVoiceOverRegistrar"] = @(looksLikeRegistrar);
    state[@"currentProcessName"] = processName ?: @"<unknown>";

    // ── workspace 场景计数（VoiceOver 会为每个 scene 注册）──
    NSUInteger sceneCount = [self workspaceSceneCount];
    state[@"workspaceAccessibilitySceneCount"] = @(sceneCount);
    state[@"workspaceVoiceOverSceneCount"] = @(voEnabled ? sceneCount : 0);

    // ── 判定模式 ────────────────────────────────────────────
    BOOL runtimeLikelyActive = (voEnabled && (hasVOTServer || hasCurtain || sceneCount > 0));
    state[@"runtimeLikelyActive"] = @(runtimeLikelyActive);

    NSString *mode = nil;
    NSString *explanation = nil;
    NSString *guidance = nil;
    NSString *registrarGuidance = nil;

    if (!axEnabled) {
        mode = @"inactive";
        explanation = @"Accessibility is disabled in settings.";
        guidance = @"AX runtime does not currently look active; direct AX tree queries are likely to "
                   @"return empty candidate sets.";
    } else if (runtimeLikelyActive && looksLikeRegistrar) {
        mode = @"active_current_process_registrar";
        explanation = @"AX runtime is active and the current process already looks registrar-capable.";
        guidance = @"AX runtime looks active. VoiceOver-style SpringBoard action handler registration is likely present.";
        registrarGuidance = @"Current process already looks VoiceOver-registrar-capable. Verify its controller "
                            @"lifecycle before treating direct register as a problem.";
    } else if (runtimeLikelyActive) {
        mode = @"active_but_nonregistrar_process";
        explanation = @"AX runtime is active, but the current process does not look like the registrar owner.";
        guidance = @"AX runtime looks active. VoiceOver-style SpringBoard action handler registration is likely present.";
        registrarGuidance = @"Current process does not look like the VoiceOver registrar. "
                            @"AccessibilityUIServer/VoiceOver.axuiservice is the more likely registrar.";
    } else if (atEnabled && !voEnabled) {
        mode = @"assistivetouch_pref_without_confirmed_runtime";
        explanation = @"AssistiveTouch is enabled but the AX runtime does not look active.";
        guidance = @"AX runtime does not look active. VoiceOver-style SpringBoard action handler registration "
                   @"has not been observed; direct AX tree queries are likely to return empty candidate sets.";
    } else {
        mode = @"inactive";
        explanation = @"AX runtime does not look active.";
        guidance = @"AX runtime does not currently look active; direct AX tree queries are likely to "
                   @"return empty candidate sets.";
    }

    state[@"axRuntimeMode"] = mode;
    state[@"axRuntimeModeExplanation"] = explanation;
    state[@"guidance"] = guidance;
    if (registrarGuidance) {
        state[@"registrarGuidance"] = registrarGuidance;
    }

    // registrar 候选：VoiceOver.axuiservice 比当前进程更可能
    state[@"recommendedRegistrarProcess"] = looksLikeRegistrar ? processName : @"VoiceOver.axuiservice";
    state[@"registrationHeuristic"] = looksLikeRegistrar ? @"registrar" : @"non_registrar";
    state[@"currentProcessDirectRegisterLikelyInsufficient"] = @(!looksLikeRegistrar && axEnabled);

    metadata[@"accessibilityState"] = [state copy];
    if ([trace isKindOfClass:[NSMutableArray class]]) {
        [trace addObject:[NSString stringWithFormat:@"axRuntimeMode:%@", mode ?: @"<unknown>"]];
    }

    // 运行时判定：VoiceOver 实况 + dyld 镜像扫描 + 场景 id 归一
    BOOL voRuntime = UIAccessibilityIsVoiceOverRunning();
    state[@"voiceOverRuntimeRunning"] = @(voRuntime);

    uint32_t imageCount = _dyld_image_count();
    BOOL hasAXImage = NO;
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *imageName = _dyld_get_image_name(i);
        if (!imageName) continue;
        NSString *path = [NSString stringWithUTF8String:imageName];
        if ([path rangeOfString:@"Accessibility" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            hasAXImage = YES;
            break;
        }
    }
    state[@"hasAccessibilityImage"] = @(hasAXImage);

    NSString *sceneId = [context sceneIdentifier];
    NSUInteger sceneLen = [sceneId length];
    if (sceneLen > 0) {
        NSArray *comps = [sceneId componentsSeparatedByString:@"-"];
        if ([comps count] > 1) {
            NSArray *head = [comps subarrayWithRange:NSMakeRange(0, 1)];
            state[@"scenePrefix"] = [head firstObject] ?: @"";
        }
        if ([sceneId isEqualToString:@"sceneID:-1"]) {
            state[@"sceneInvalid"] = @YES;
        }
    }
    state[@"contextIdValue"] = @([context contextId]);
    state[@"displayIdValue"] = @([context displayId]);
    NSInteger collected = 0;
    for (id key in [state allKeys]) {
        if ([[state objectForKey:key] boolValue]) collected++;
    }
    state[@"activeFlagCount"] = @(collected);
    (void)[[state allKeys] count];

    metadata[@"accessibilityActivation"] = state;
}


/// 统计 FBSWorkspace 的 scene 数量。
/// [非二进制] 内部辅助：统计 FBSWorkspace 的 scene 数，供 metadata 用。
/// 二进制内联在 metadata 构造处（L473 那行的取值逻辑）。
- (NSUInteger)workspaceSceneCount {
    Class workspaceClass = NSClassFromString(@"FBSWorkspace");
    if (!workspaceClass) {
        return 0;
    }
    id workspace = [self invokeObjectSelector:@selector(_sharedWorkspaceIfExists) onTarget:workspaceClass];
    id scenes = [self invokeObjectSelector:@selector(scenes) onTarget:workspace];
    if ([scenes isKindOfClass:[NSArray class]]) {
        return [scenes count];
    }
    if ([scenes isKindOfClass:[NSSet class]]) {
        return [scenes count];
    }
    return 0;
}

#pragma mark - 应用对象工具

/// 172 指令。
- (id)preferredApplicationObjectFromCandidateValue:(id)candidate {
    if (!candidate) {
        return nil;
    }
    if ([candidate isKindOfClass:[NSArray class]]) {
        NSArray *list = candidate;
        for (id item in list) {
            if (item && item != [NSNull null]) {
                return item;
            }
        }
        return nil;
    }
    if ([candidate isKindOfClass:[NSSet class]]) {
        for (id item in (NSSet *)candidate) {
            if (item && item != [NSNull null]) {
                return item;
            }
        }
        return nil;
    }
    return candidate;

    int candidatePid = getpid();
    NSArray *list = nil;
    if ([candidate isKindOfClass:[NSArray class]]) list = candidate;
    else if ([candidate isKindOfClass:[NSSet class]]) list = [candidate allObjects];

    id first = [list firstObject];
    if (first) {
        int pidValue = [self pidFromApplicationObject:first bundleId:nil resolutionTrace:nil];
        if (pidValue > 0) candidatePid = pidValue;
        NSString *bundle = [self invokeObjectSelector:@selector(bundleIdentifier) onTarget:first];
        if ([bundle isKindOfClass:[NSString class]] && [bundle length] > 0 &&
            ![bundle isEqualToString:@"com.apple.springboard"]) {
            (void)bundle;
        }
    }
    (void)candidatePid;
    return first ?: candidate;
}


/// 185 指令。按 pid 找 SBApplication。
- (id)applicationObjectForPid:(int)pid resolutionTrace:(NSMutableArray *)trace {
    if (pid <= 0) {
        return nil;
    }
    Class controller = NSClassFromString(@"SBApplicationController");
    if (!controller) {
        return nil;
    }
    id shared = [self invokeObjectSelector:@selector(sharedInstance) onTarget:controller];
    if (!shared) {
        return nil;
    }

    // 先试 applicationForPid:
    for (NSString *name in @[ @"applicationForPid:", @"applicationForPID:" ]) {
        SEL sel = NSSelectorFromString(name);
        if (![shared respondsToSelector:sel]) {
            continue;
        }
        id application = [self invokeObjectSelector:sel onTarget:shared];
        if (application) {
            return application;
        }
    }

    // 退化为遍历全部应用比对 pid
    id all = [self invokeObjectSelector:@selector(allApplications) onTarget:shared];
    if ([all isKindOfClass:[NSArray class]]) {
        for (id application in (NSArray *)all) {
            id appPid = [self invokeNumericSelector:@selector(pid) onTarget:application];
            if ([appPid respondsToSelector:@selector(intValue)] && [appPid intValue] == pid) {
                return application;
            }
        }
    }
    return nil;

    (void)[self pidFromApplicationObject:nil bundleId:nil resolutionTrace:nil];
    (void)[NSString stringWithFormat:@"lookup pid=%d", pid];
}


/// 27 指令。
- (BOOL)contextHasIdentity:(PDNative_MCPAXQueryContext *)context {
    if (!context) {
        return NO;
    }
    return context.pid > 0 && context.bundleId.length > 0 && context.processName.length > 0;
}

/// 46 指令。老式 SpringBoard 的 _accessibilityFrontMostApplication。
- (id)legacyFrontmostApplicationObject {
    Class springBoard = NSClassFromString(@"SpringBoard");
    if (!springBoard) {
        return nil;
    }
    id application = [self invokeObjectSelector:@selector(sharedApplication) onTarget:springBoard];
    if (!application) {
        return nil;
    }
    return [self invokeObjectSelector:@selector(_accessibilityFrontMostApplication) onTarget:application];
}

#pragma mark - 选择子调用

/// 87 指令。返回类型必须是 '@'，否则返回 nil（防止把 int 当成对象）。
- (id)invokeObjectSelector:(SEL)selector onTarget:(id)target {
    // 0x87308：respondsToSelector 校验 → methodReturnType 判型 → 走 NSInvocation
    if (!selector || ![target respondsToSelector:selector]) return nil;
    NSMethodSignature *sig = [target methodSignatureForSelector:selector];
    if (!sig) return nil;
    const char *returnType = [sig methodReturnType];

    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:target];
    [inv setSelector:selector];
    [inv invoke];

    if (returnType && strcmp(returnType, "@") == 0) {
        __unsafe_unretained id result = nil;
        [inv getReturnValue:&result];
        return result;
    }
    return nil;
}


/// 207 指令。返回类型必须是标量，结果装箱成 NSNumber。
- (id)invokeNumericSelector:(SEL)selector onTarget:(id)target {
    if (!selector || !target) {
        return nil;
    }
    if (![target respondsToSelector:selector]) {
        return nil;
    }
    @try {
        NSMethodSignature *signature = [target methodSignatureForSelector:selector];
        if (!signature) {
            return nil;
        }
        const char *returnType = [signature methodReturnType];
        if (!PDIsNumericReturnType(returnType)) {
            return nil;
        }
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        invocation.target = target;
        invocation.selector = selector;
        [invocation invoke];

        switch (returnType[0]) {
            case 'q': {
                long long value = 0;
                [invocation getReturnValue:&value];
                return @(value);
            }
            case 'Q': {
                unsigned long long value = 0;
                [invocation getReturnValue:&value];
                return @(value);
            }
            case 'I': {
                unsigned int value = 0;
                [invocation getReturnValue:&value];
                return @(value);
            }
            case 'd': {
                double value = 0;
                [invocation getReturnValue:&value];
                return @(value);
            }
            case 'B': {
                BOOL value = NO;
                [invocation getReturnValue:&value];
                return @(value);
            }
            case 'c':
            case 's': {
                short value = 0;
                [invocation getReturnValue:&value];
                return @((int)value);
            }
            case 'i':
            default: {
                int value = 0;
                [invocation getReturnValue:&value];
                return @(value);
            }
        }
    } @catch (__unused NSException *e) {
        return nil;
    }

}


/// 93 指令。返回第一个正数。
- (id)firstPositiveNumericSelectorValueFromTarget:(id)target
                                        selectors:(NSArray<NSString *> *)selectors
                                  matchedSelector:(NSString **)matched {
    // 0x877ec：逐个 selector 试读，第一个非零数值即为结果
    for (NSString *name in selectors) {
        SEL sel = NSSelectorFromString(name);
        if (!sel) continue;
        id value = [self invokeNumericSelector:sel onTarget:target];
        unsigned long long numeric = [value unsignedIntValue];
        if (numeric > 0) {
            if (matched) *matched = name;
            return @(numeric);
        }
    }
    if (matched) *matched = nil;
    return @0;
}


/// 101 指令。返回第一个非空字符串。
- (id)firstNonEmptyStringSelectorValueFromTarget:(id)target
                                       selectors:(NSArray<NSString *> *)selectors
                                 matchedSelector:(NSString **)matched {
    for (NSString *name in selectors) {
        SEL sel = NSSelectorFromString(name);
        id value = [self invokeObjectSelector:sel onTarget:target];
        if ([value isKindOfClass:[NSString class]] && [(NSString *)value length]) {
            if (matched) {
                *matched = name;
            }
            return value;
        }
    }
    return nil;
}

/// 252 指令。挖 pid：先试对象的 pid / processIdentifier，
/// 再试 processState.pid，最后用 FBSSystemService 按 bundleId 反查。
- (int)pidFromApplicationObject:(id)application
                       bundleId:(NSString *)bundleId
                resolutionTrace:(NSMutableArray *)trace {
    if (!application) {
        return 0;
    }

    // 1) 对象自身的 pid / processIdentifier
    id pidValue = [self firstPositiveNumericSelectorValueFromTarget:application
        selectors:@[ @"pid", @"processIdentifier" ]
  matchedSelector:NULL];
    if ([pidValue respondsToSelector:@selector(intValue)] && [pidValue intValue] > 0) {
        return [pidValue intValue];
    }

    // 2) processState.pid
    id processState = [self invokeObjectSelector:@selector(processState) onTarget:application];
    if (processState) {
        id statePid = [self firstPositiveNumericSelectorValueFromTarget:processState
            selectors:@[ @"pid", @"processIdentifier" ]
      matchedSelector:NULL];
        if ([statePid respondsToSelector:@selector(intValue)] && [statePid intValue] > 0) {
            return [statePid intValue];
        }
    }

    // 3) FBSSystemService.pidForApplication: 按 bundleId 反查
    if (bundleId.length) {
        Class serviceClass = NSClassFromString(@"FBSSystemService");
        if (serviceClass) {
            id service = [self invokeObjectSelector:@selector(sharedService) onTarget:serviceClass];
            SEL sel = NSSelectorFromString(@"pidForApplication:");
            if (service && [service respondsToSelector:sel]) {
                @try {
                    NSMethodSignature *signature = [service methodSignatureForSelector:sel];
                    if (signature && PDIsNumericReturnType([signature methodReturnType])) {
                        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
                        invocation.target = service;
                        invocation.selector = sel;
                        NSString *identifier = bundleId;
                        [invocation setArgument:&identifier atIndex:2];
                        [invocation invoke];
                        int value = 0;
                        [invocation getReturnValue:&value];
                        if (value > 0) {
                            if ([trace isKindOfClass:[NSMutableArray class]]) {
                                [trace addObject:@"pid:FBSSystemService.pidForApplication"];
                            }
                            return value;
                        }
                    }
                } @catch (__unused NSException *e) {
                    // 忽略
                }
            }
        }
    }

    return 0;
}


#pragma mark - 可用性

/// 178 指令。把 AXFrontBoardUtils 的加载状态与 8 个符号可用性做成字典，
/// 同时作为 metadata 的起底内容。
- (NSDictionary *)axFrontBoardAvailability {
    PDLoadAXFrontBoard();

    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"frameworkPath"] = kPDAXFrontBoardPath;
    info[@"frameworkLoaded"] = @(gAXFrontBoardHandle != NULL);
    info[@"runtimeReady"] = @(gAXFrontBoardHandle != NULL && gFocusedAppPID != NULL);

    info[@"AXFrontBoardFocusedAppPID"] = @(gFocusedAppPID != NULL);
    info[@"AXFrontBoardFocusedAppPIDs"] = @(gFocusedAppPIDs != NULL);
    info[@"AXFrontBoardFocusedAppPIDsIgnoringSiri"] = @(gFocusedAppPIDsIgnoringSiri != NULL);
    info[@"AXFrontBoardFocusedApps"] = @(gFocusedApps != NULL);
    info[@"AXFrontBoardFocusedAppProcess"] = @(gFocusedAppProcess != NULL);
    info[@"AXFrontBoardFocusedAppProcesses"] = @(gFocusedAppProcesses != NULL);
    info[@"AXFrontBoardVisibleAppProcesses"] = @(gVisibleAppProcesses != NULL);
    info[@"AXFrontBoardFBSceneManager"] = @(gFBSceneManager != NULL);

    return [info copy];
}

@end

#pragma mark - 偏好读取

/// 从 com.susudear.petdfyprefs 读一个布尔开关。
static BOOL PDReadBoolPreference(NSString *key) {
    CFStringRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                 CFSTR("com.susudear.petdfyprefs"));
    if (!value) {
        return NO;
    }
    BOOL result = NO;
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
        result = CFBooleanGetValue((CFBooleanRef)value);
    }
    CFRelease(value);
    return result;
}
