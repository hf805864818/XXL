//
//  PDNative_MCPUIElementSerializer.m — 逆向还原
//
//  6 个方法 / 2823 指令。AX 组的序列化基础层。
//
//  ── 方法规模 ──────────────────────────────────────────────────────
//    normalizedNodeFromRawNode:…      1514  递归序列化 + role 启发式
//    normalizedElementFromRawElement:  437  命中测试结果包装
//    elementIdentifierForNode:…        345  稳定 id 拼接
//    normalizedFrameFromObject:        319  frame 归一化（4 种输入）
//    contextIdentifierForNode:…        104  contextId 回退链
//    displayIdentifierForNode:…        104  displayId 回退链
//
//  ── frame 归一化的 4 种输入（0x9003c）─────────────────────────────
//    1. NSValue         → [obj CGRectValue]
//    2. NSDictionary    → {x|X, y|Y, width|Width, height|Height}（两套大小写都认）
//    3. NSString        → CGRectFromString；解析出 CGRectZero 且串里不含 "0" 时丢弃
//    4. NSArray(≥4)     → [0..3] 依次 doubleValue
//    输出统一为 {x,y,width,height}，取整（CGRectGetMinX/MinY/Width/Height → numberWithInt:）
//
//  ── element_id 拼接（0x8fb58）────────────────────────────────────
//    若节点自带 id 且非空 → 直接用它
//    否则按顺序拼接，用 "|" 连接：
//        pid:%d     （pid >= 1 才加）
//        ctx:%u     （contextId != 0 才加）
//        path:%@    （stablePath 非空才加）
//        role:%@    （role 是字符串则用，否则 "AXElement"）
//        <attr>:%@  逐个属性键（identifier/label/title/value）
//        frame:%@   （frame 字典格式化 "%.0f,%.0f,%.0f,%.0f" 非空才加）
//
//  ── role 启发式（0x8e8f0 → 0x8f344）─────────────────────────────
//    先看 snapshot_element_type；再按 traits 顺序判：
//        button → search_field → keyboard_key → link → image → header → adjustable
//    都没命中：
//        placeholder 存在            → text_field
//        url 或 path 非空且长度>0     → url_path + link
//        有 children                  → group / container
//        role == "Image" 且 user_input_labels 空且 text 空 → image
//        否则                          → control
//    判定来源写入 elementTypeSource：snapshot / traits / heuristic
//
//  标记：逆向还原
//

#import "PDNative_MCPUIElementSerializer.h"
#import "PDNative_MCPAXQueryContext.h"

/// 元素 id 里参与拼接的属性键（0x10fe60）。
static NSArray<NSString *> *PDIdentifierAttributeKeys(void) {
    static NSArray *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[ @"identifier", @"label", @"title", @"value" ];
    });
    return keys;
}

/// 判定 container 时看的子节点键。二进制里只认 `children`。
static NSString *PDChildKey(void) {
    return @"children";
}

/// traits 顺序判定表（顺序即二进制顺序，命中即停）。
static NSArray<NSArray<NSString *> *> *PDTraitRoleRules(void) {
    static NSArray *rules;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        rules = @[
            @[ @"button",       @"button" ],
            @[ @"search_field", @"search_field" ],
            @[ @"keyboard_key", @"keyboard_key" ],
            @[ @"link",         @"link" ],
            @[ @"image",        @"image" ],
            @[ @"header",       @"header" ],
            @[ @"adjustable",   @"adjustable" ],
        ];
    });
    return rules;
}

static id PDValueOrNil(NSDictionary *dict, NSString *key) {
    id value = dict[key];
    if (!value || value == [NSNull null]) {
        return nil;
    }
    return value;
}

static NSString *PDStringOrNil(NSDictionary *dict, NSString *key) {
    id value = PDValueOrNil(dict, key);
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static BOOL PDBoolValue(NSDictionary *dict, NSString *key) {
    id value = PDValueOrNil(dict, key);
    return [value isKindOfClass:[NSNumber class]] && [value boolValue];
}

@implementation PDNative_MCPUIElementSerializer

#pragma mark - frame

/// 319 指令。
- (NSDictionary *)normalizedFrameFromObject:(id)object {
    if (!object) {
        return nil;
    }

    CGRect rect = CGRectZero;
    BOOL valid = NO;

    if ([object isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = object;
        id vx = PDValueOrNil(dict, @"x") ?: PDValueOrNil(dict, @"X");
        id vy = PDValueOrNil(dict, @"y") ?: PDValueOrNil(dict, @"Y");
        id vw = PDValueOrNil(dict, @"width") ?: PDValueOrNil(dict, @"Width");
        id vh = PDValueOrNil(dict, @"height") ?: PDValueOrNil(dict, @"Height");
        if (vx && vy && vw && vh) {
            rect = CGRectMake([vx doubleValue], [vy doubleValue],
                              [vw doubleValue], [vh doubleValue]);
            valid = YES;
        }
        // 注意：字典缺键时不像其它分支那样回落，直接返回 nil
        if (!valid) {
            return nil;
        }
    } else if ([object isKindOfClass:[NSValue class]]) {
        rect = [(NSValue *)object CGRectValue];
    } else if ([object isKindOfClass:[NSString class]]) {
        NSString *text = object;
        rect = CGRectFromString(text);
        if (CGRectEqualToRect(rect, CGRectZero) && ![text containsString:@"0"]) {
            return nil;
        }
    } else if ([object isKindOfClass:[NSArray class]]) {
        NSArray *list = object;
        if ([list count] < 4) {
            return nil;
        }
        rect = CGRectMake([list[0] doubleValue], [list[1] doubleValue],
                          [list[2] doubleValue], [list[3] doubleValue]);
    } else {
        return nil;
    }

    return @{
        @"x"      : @((int)CGRectGetMinX(rect)),
        @"y"      : @((int)CGRectGetMinY(rect)),
        @"width"  : @((int)CGRectGetWidth(rect)),
        @"height" : @((int)CGRectGetHeight(rect)),
    };
}

#pragma mark - 标识符

/// 104 指令。contextId 回退链：node.contextId / window_context_id → 继承值 → context.contextId。
- (unsigned int)contextIdentifierForNode:(NSDictionary *)node
                       inheritedContextId:(unsigned int)inheritedContextId
                                 context:(PDNative_MCPAXQueryContext *)context {
    id own = PDValueOrNil(node, @"contextId") ?: PDValueOrNil(node, @"window_context_id");
    if (inheritedContextId != 0) {
        own = @(inheritedContextId);
    }
    id resolved = nil;
    if (context && [context respondsToSelector:@selector(contextId)]) {
        unsigned int ctxId = [context contextId];
        if (ctxId != 0) {
            resolved = @(ctxId);
        }
    }

    // 依次取第一个能被解析成非零 unsignedInt 的候选
    for (id candidate in @[ own ?: [NSNull null], resolved ?: [NSNull null] ]) {
        if ([candidate respondsToSelector:@selector(unsignedIntValue)]) {
            unsigned int value = [candidate unsignedIntValue];
            if (value != 0) {
                return value;
            }
        }
    }
    return 0;
}

/// 104 指令。displayId 回退链：node.displayId / window_display_id → 继承值 → context.displayId。
- (unsigned int)displayIdentifierForNode:(NSDictionary *)node
                       inheritedDisplayId:(unsigned int)inheritedDisplayId
                                 context:(PDNative_MCPAXQueryContext *)context {
    id own = PDValueOrNil(node, @"displayId") ?: PDValueOrNil(node, @"window_display_id");
    if (inheritedDisplayId != 0) {
        own = @(inheritedDisplayId);
    }
    id resolved = nil;
    if (context && [context respondsToSelector:@selector(displayId)]) {
        unsigned int dispId = [context displayId];
        if (dispId != 0) {
            resolved = @(dispId);
        }
    }

    for (id candidate in @[ own ?: [NSNull null], resolved ?: [NSNull null] ]) {
        if ([candidate respondsToSelector:@selector(unsignedIntValue)]) {
            unsigned int value = [candidate unsignedIntValue];
            if (value != 0) {
                return value;
            }
        }
    }
    return 0;
}

/// 345 指令。自带 id 优先；否则按 pid|ctx|path|role|属性|frame 拼。
- (NSString *)elementIdentifierForNode:(NSDictionary *)node
                            stablePath:(NSString *)stablePath
                               context:(PDNative_MCPAXQueryContext *)context
                             contextId:(unsigned int)contextId {
    NSString *ownId = PDStringOrNil(node, @"id");
    if (ownId.length) {
        return ownId;
    }

    NSMutableArray<NSString *> *parts = [NSMutableArray array];

    NSInteger pid = 0;
    if (context && [context respondsToSelector:@selector(pid)]) {
        pid = [context pid];
    }
    if (pid >= 1) {
        [parts addObject:[NSString stringWithFormat:@"pid:%d", (int)pid]];
    }
    if (contextId != 0) {
        [parts addObject:[NSString stringWithFormat:@"ctx:%u", contextId]];
    }
    if (stablePath.length) {
        [parts addObject:[NSString stringWithFormat:@"path:%@", stablePath]];
    }

    NSString *role = PDStringOrNil(node, @"role") ?: @"AXElement";
    [parts addObject:[NSString stringWithFormat:@"role:%@", role]];

    // 属性键：只取第一个非空值
    for (NSString *key in PDIdentifierAttributeKeys()) {
        NSString *value = PDStringOrNil(node, key);
        if (value.length) {
            [parts addObject:[NSString stringWithFormat:@"%@:%@", key, value]];
            break;
        }
    }

    NSDictionary *frame = [self normalizedFrameFromObject:PDValueOrNil(node, @"frame")];
    if (frame) {
        NSString *frameText = [NSString stringWithFormat:@"%.0f,%.0f,%.0f,%.0f",
                               [frame[@"x"] doubleValue], [frame[@"y"] doubleValue],
                               [frame[@"width"] doubleValue], [frame[@"height"] doubleValue]];
        if (frameText.length) {
            [parts addObject:[NSString stringWithFormat:@"frame:%@", frameText]];
        }
    }

    return [parts componentsJoinedByString:@"|"];
}

#pragma mark - 递归序列化

/// 1514 指令。这是 AX 组的核心：把一棵 AXRuntime 节点树压成扁平字典。
- (NSDictionary *)normalizedNodeFromRawNode:(NSDictionary *)rawNode
                                 stablePath:(NSString *)stablePath
                                   parentId:(NSString *)parentId
                        inheritedContextId:(unsigned int)inheritedContextId
                        inheritedDisplayId:(unsigned int)inheritedDisplayId
                                 rootSource:(NSString *)rootSource
                                    context:(PDNative_MCPAXQueryContext *)context {
    if (![rawNode isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    unsigned int contextId = [self contextIdentifierForNode:rawNode
                                          inheritedContextId:inheritedContextId
                                                    context:context];
    unsigned int displayId = [self displayIdentifierForNode:rawNode
                                          inheritedDisplayId:inheritedDisplayId
                                                    context:context];

    NSString *elementId = [self elementIdentifierForNode:rawNode
                                              stablePath:stablePath
                                                 context:context
                                               contextId:contextId];

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"id"] = elementId;
    out[@"element_id"] = elementId;
    if (parentId) {
        out[@"parent"] = parentId;
        out[@"parentId"] = parentId;
    }
    if (stablePath) {
        out[@"path"] = stablePath;
        out[@"stablePath"] = stablePath;
    }

    out[@"contextId"] = @(contextId);
    out[@"displayId"] = @(displayId);

    NSInteger pid = 0;
    if (context && [context respondsToSelector:@selector(pid)]) {
        pid = [context pid];
    }
    out[@"pid"] = @((int)pid);

    if (context) {
        NSString *bundleId = nil;
        NSString *processName = nil;
        if ([context respondsToSelector:@selector(bundleId)]) {
            bundleId = [context bundleId];
        }
        if ([context respondsToSelector:@selector(processName)]) {
            processName = [context processName];
        }
        if (bundleId.length) {
            out[@"bundleId"] = bundleId;
        }
        if (processName.length) {
            out[@"processName"] = processName;
        }
        if ([context respondsToSelector:@selector(sceneIdentifier)]) {
            NSString *scene = [context sceneIdentifier];
            if (scene.length) {
                out[@"sceneIdentifier"] = scene;
            }
        }
    }
    if (rootSource.length) {
        out[@"source"] = rootSource;
    }

    // ── role 判定 ────────────────────────────────────────────
    NSString *snapshotType = PDStringOrNil(rawNode, @"snapshot_element_type");
    NSString *role = nil;
    NSString *roleSource = nil;

    if (snapshotType.length) {
        role = snapshotType;
        roleSource = @"snapshot";
    } else {
        NSArray *traits = PDValueOrNil(rawNode, @"traits");
        if (![traits isKindOfClass:[NSArray class]]) {
            traits = @[];
        }
        for (NSArray<NSString *> *rule in PDTraitRoleRules()) {
            if ([traits containsObject:rule[0]]) {
                role = rule[1];
                roleSource = @"traits";
                break;
            }
        }
        if (!role) {
            // placeholder → text_field
            NSString *placeholder = PDStringOrNil(rawNode, @"placeholder");
            if (placeholder) {
                role = @"text_field";
                roleSource = @"heuristic";
            } else {
                NSString *url = PDStringOrNil(rawNode, @"url") ?: PDStringOrNil(rawNode, @"path");
                if (url.length) {
                    role = @"link";
                    roleSource = @"url_path";
                }
            }
        }
        if (!role) {
            // 有子节点 → 2..6 个算 collection_item，否则 container；再否则 group
            id rawChildren = PDValueOrNil(rawNode, PDChildKey());
            NSArray *children = [rawChildren isKindOfClass:[NSArray class]] ? rawChildren : nil;
            if ([children count]) {
                if ([children count] >= 2 && [children count] <= 6) {
                    role = @"collection_item";
                    out[@"container_hints"] = @"child_mix_image_text";
                } else if ([children count] > 6) {
                    role = @"group";
                } else {
                    role = @"container";
                    out[@"container_hints"] = @"children";
                }
                roleSource = @"heuristic";
            }
        }
        if (!role) {
            // role == "Image" 且没有 user_input_labels、没有 text → image
            NSString *rawRole = PDStringOrNil(rawNode, @"role");
            NSArray *labels = PDValueOrNil(rawNode, @"user_input_labels");
            NSString *text = PDStringOrNil(rawNode, @"text");
            if ([rawRole isEqualToString:@"Image"] &&
                ![labels isKindOfClass:[NSArray class]] && !text.length) {
                role = @"image";
                roleSource = @"heuristic";
            } else {
                role = @"control";
                roleSource = @"heuristic";
            }
        }
    }

    out[@"role"] = role ?: @"AXElement";
    out[@"rawRole"] = PDStringOrNil(rawNode, @"role") ?: @"AXElement";
    out[@"elementType"] = role ?: @"AXElement";
    if (roleSource) {
        out[@"elementTypeSource"] = roleSource;
    }

    // ── 属性透传 ────────────────────────────────────────────
    NSDictionary *frame = [self normalizedFrameFromObject:PDValueOrNil(rawNode, @"frame")];
    if (frame) {
        out[@"frame"] = frame;
        out[@"rect"] = frame;
    }
    NSDictionary *visibleFrame = [self normalizedFrameFromObject:PDValueOrNil(rawNode, @"visibleFrame")];
    if (visibleFrame) {
        out[@"visible_rect"] = visibleFrame;
    }

    if (PDValueOrNil(rawNode, @"hidden")) {
        out[@"hidden"] = @(PDBoolValue(rawNode, @"hidden"));
    }
    if (PDValueOrNil(rawNode, @"visible")) {
        out[@"visible"] = @(PDBoolValue(rawNode, @"visible"));
    }
    if (PDValueOrNil(rawNode, @"hittable")) {
        out[@"hittable"] = @(PDBoolValue(rawNode, @"hittable"));
    }
    if (PDValueOrNil(rawNode, @"enabled")) {
        out[@"enabled"] = @(PDBoolValue(rawNode, @"enabled"));
    }

    if (PDValueOrNil(rawNode, @"traits")) {
        id traits = rawNode[@"traits"];
        if ([traits isKindOfClass:[NSArray class]]) {
            out[@"traits"] = traits;
            out[@"trait_names"] = traits;
        }
    }

    NSString *label = PDStringOrNil(rawNode, @"label");
    if (label.length) {
        out[@"text"] = label;
        out[@"label"] = label;
    }
    NSString *value = PDStringOrNil(rawNode, @"value");
    if (value.length) {
        out[@"value"] = value;
    }
    NSString *identifier = PDStringOrNil(rawNode, @"identifier");
    if (identifier.length) {
        out[@"identifier"] = identifier;
    }
    NSString *placeholder = PDStringOrNil(rawNode, @"placeholder");
    if (placeholder.length) {
        out[@"placeholder"] = placeholder;
    }

    if (PDValueOrNil(rawNode, @"semanticContext")) {
        out[@"semanticContext"] = rawNode[@"semanticContext"];
    }

    BOOL isRemote = PDBoolValue(rawNode, @"is_remote_element");
    if (isRemote) {
        out[@"is_remote_element"] = @(YES);
        out[@"remote_element"] = @(YES);
    }

    // ── 子节点递归 ──────────────────────────────────────────
    id rawChildValue = PDValueOrNil(rawNode, PDChildKey());
    NSArray *rawChildren = [rawChildValue isKindOfClass:[NSArray class]] ? rawChildValue : nil;
    if ([rawChildren count]) {
        NSMutableArray *children = [NSMutableArray arrayWithCapacity:[rawChildren count]];
        NSUInteger index = 0;
        for (id child in rawChildren) {
            NSString *childPath = stablePath.length
                ? [NSString stringWithFormat:@"%@/%lu", stablePath, (unsigned long)index]
                : [NSString stringWithFormat:@"%lu", (unsigned long)index];
            NSDictionary *normalized = [self normalizedNodeFromRawNode:child
                                                           stablePath:childPath
                                                             parentId:elementId
                                                  inheritedContextId:contextId
                                                  inheritedDisplayId:displayId
                                                           rootSource:rootSource
                                                              context:context];
            if (normalized) {
                NSMutableDictionary *mutable = [normalized mutableCopy];
                mutable[@"index"] = @((int)index);
                [children addObject:[mutable copy]];
            }
            index++;
        }
        out[@"children"] = [children copy];
        out[@"child_count"] = @((int)[children count]);
    }

    return [out copy];

    // 归一化：继承上层 contextId/displayId，补充 resolver 与子节点
    NSMutableDictionary *node = [NSMutableDictionary dictionary];
    if ([rawNode isKindOfClass:[NSDictionary class]]) {
        [node addEntriesFromDictionary:rawNode];
    }
    if (inheritedContextId) {
        node[@"contextId"] = @(inheritedContextId);
    } else {
        node[@"contextId"] = @([node[@"contextId"] integerValue]);
    }
    if (inheritedDisplayId) {
        node[@"displayId"] = @(inheritedDisplayId);
    }
    node[@"resolverStrategy"] = [context resolverStrategy] ?: @"unspecified";
    if ([node[@"visible"] respondsToSelector:@selector(boolValue)]) {
        (void)[node[@"visible"] boolValue];
    }
    if ([node[@"frame"] respondsToSelector:@selector(doubleValue)]) {
        (void)[node[@"frame"] doubleValue];
    }
    NSArray *children = node[@"children"];
    if ([children isKindOfClass:[NSArray class]]) {
        NSMutableArray *normalized = [NSMutableArray array];
        [children enumerateObjectsUsingBlock:^(id child, NSUInteger idx, BOOL *stop) {
            if ([child isKindOfClass:[NSDictionary class]]) [normalized addObject:child];
        }];
        node[@"children"] = normalized;
    }
    return node;
}


#pragma mark - 命中测试元素

/// 437 指令。单元素包装：归一化后补 queryPoint / queryContext / resolverMetadata / axRuntimeSummary。
- (NSDictionary *)normalizedElementFromRawElement:(NSDictionary *)raw
                                          context:(PDNative_MCPAXQueryContext *)context
                                            point:(CGPoint)point {
    if (![raw isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    unsigned int contextId = [self contextIdentifierForNode:raw inheritedContextId:0 context:context];
    unsigned int displayId = [self displayIdentifierForNode:raw inheritedDisplayId:0 context:context];

    NSDictionary *base = [self normalizedNodeFromRawNode:raw
                                              stablePath:@"hit"
                                                parentId:nil
                                     inheritedContextId:contextId
                                     inheritedDisplayId:displayId
                                              rootSource:PDStringOrNil(raw, @"source") ?: @"direct_ax_hit_test"
                                                 context:context];
    if (!base) {
        return nil;
    }

    NSMutableDictionary *out = [base mutableCopy];
    out[@"architecture"] = @"ax_runtime_facade_v1";

    if (context && [context respondsToSelector:@selector(dictionaryRepresentation)]) {
        NSDictionary *contextDict = [context dictionaryRepresentation];
        if ([contextDict isKindOfClass:[NSDictionary class]]) {
            out[@"queryContext"] = contextDict;
        }
    }

    out[@"queryPoint"] = @{
        @"x" : @((int)point.x),
        @"y" : @((int)point.y),
    };

    // metadata 里的解析轨迹 / 运行时状态
    NSDictionary *metadata = nil;
    if (context && [context respondsToSelector:@selector(metadata)]) {
        metadata = [context metadata];
    }
    if ([metadata isKindOfClass:[NSDictionary class]] && [metadata count]) {
        out[@"resolverMetadata"] = metadata;

        id strategy = metadata[@"resolverStrategy"];
        if (strategy) {
            out[@"resolverStrategy"] = strategy;
        }
        id accessibility = metadata[@"accessibilityState"];
        if ([accessibility isKindOfClass:[NSDictionary class]] && [accessibility count]) {
            out[@"accessibilityState"] = accessibility;
        }

        // 运行时模式摘要：mode / registrar / directRegisterLikelyInsufficient / why
        NSString *mode = metadata[@"axRuntimeMode"];
        if ([mode isKindOfClass:[NSString class]] && mode.length) {
            NSMutableDictionary *summary = [NSMutableDictionary dictionary];
            summary[@"mode"] = mode;

            NSString *registrar = metadata[@"recommendedRegistrarProcess"];
            if ([registrar isKindOfClass:[NSString class]] && registrar.length) {
                summary[@"registrar"] = registrar;
            }
            id insufficient = metadata[@"currentProcessDirectRegisterLikelyInsufficient"];
            if (insufficient) {
                summary[@"directRegisterLikelyInsufficient"] = @([insufficient boolValue]);
            }
            NSString *explanation = metadata[@"axRuntimeModeExplanation"];
            if ([explanation isKindOfClass:[NSString class]] && explanation.length) {
                summary[@"why"] = explanation;
            }
            if ([summary count]) {
                out[@"axRuntimeSummary"] = [summary copy];
            }
        }
    }

    return [out copy];
}

@end
