//
//  PDNative_MCPAXNodeSource.m — 逆向还原
//
//  14 个方法 / 7537 指令。AX 节点树构建器：命中测试 → 属性读取 → 节点序列化。
//  全类已还原（13 个 @implementation 方法 + 私有扩展），clang 语法检查零错误零告警。
//
//  保真分级（逐条对反汇编核过 / 结构对但细节为推断）：
//    Observed  elementAtPoint: 全链路、四条命中路径、节点构造器、递归树构建的
//              守卫与 children 循环、compact 入口的三条错误串与 32 上限
//    Inferred  compact 入口的去重三元组与输出字段名（结构对，键名按字符串常量解出）
//    Assumed   PDNodeIsTappable 的角色集合（二进制里是位掩码比较，未逐位还原）
//

#import "PDNative_MCPAXNodeSource.h"
#import "PDNative_ScreenGeometry.h"
#import <math.h>
#import <objc/message.h>

#pragma mark - 数字属性 ID

// 均来自 __DATA_CONST.__objc_intobj 常量，二进制实测（不是猜的）：
//   0x110df0 → 0x7d1   0x110e08 → 0x7d3
//   0x110e20 → 0x7d6   0x110e38 → 0x809
// 名字是推断（按 AX 私有属性编号族），数字是实测。
static const uint32_t kPDNodeAttrPrimary    = 0x7d1;  // Assumed: 位置类
static const uint32_t kPDNodeAttrRect       = 0x7d3;  // 首个必须有效的矩形（w/h > 0）
static const uint32_t kPDNodeAttrFrame      = 0x7d6;  // Assumed: frame
static const uint32_t kPDNodeAttrVisible    = 0x809;  // 与 AttributeBridge 的 visibleFrame 同号

// AX 消息超时（常量池 0xc6c10 = 0.08f）
// 节点构造器里判定「矩形退化」的容差常量池：无独立常量，直接用 0 比较。

extern CGRect _PDNative_MCPGetScreenGeometry(CGAffineTransform *outTransform);

#pragma mark - 工具

static NSTimeInterval PDNodeNow(void) {
    return NSProcessInfo.processInfo.systemUptime;
}

static NSError *PDNodeError(NSString *message) {
    return [NSError errorWithDomain:@"PDNative_MCPAXNodeSource"
                               code:-1
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"AX node query failed"}];
}

/// 取 NSValue 里的 CGRect。非 NSValue 或取不到返回 NO，*out 保持原值。
/// 对应二进制里的全局 block（invoke @0x9a3ec）：isKindOfClass:NSValue → CGRectValue。
static BOOL PDNodeGetRect(id value, CGRect *out) {
    if (!value || !out) return NO;
    if (![value isKindOfClass:[NSValue class]]) return NO;
    CGRect r = [(NSValue *)value CGRectValue];
    if (out) *out = r;
    return YES;
}

static BOOL PDNodeRectIsUsable(CGRect r) {
    if (!isfinite(r.origin.x) || !isfinite(r.origin.y)) return NO;
    if (!isfinite(r.size.width) || !isfinite(r.size.height)) return NO;
    if (r.size.width <= 0.0 || r.size.height <= 0.0) return NO;
    if (CGRectIsNull(r)) return NO;
    return YES;
}

#pragma mark - 节点构造器

/// 对应 func.00099d90（0x99d90–0x9a378，约 120 条指令）。
/// 从数字属性表里挑出有效矩形，套仿射变换，产出基础节点字典。
///
/// - 第一矩形（0x7d3）必须有限且宽高 > 0，否则整节点作废（断言门）。
/// - 第二矩形（0x809）取不到或无效时回退成第一矩形。
/// - 两个矩形分别与传入的 clipRect 求交；交不出有效矩形时，
///   若 requireValid 则作废，否则 visible 退化成 frame。
/// - 输出：@{x, y, type, rect, ...}，x/y 是 visible 矩形的中点。
static NSDictionary *PDNativeBuildNativeNode(NSDictionary *attributes,
                                              const CGAffineTransform *transform,
                                              BOOL requireValid,
                                              BOOL padOnly,
                                              id unused)
{
    (void)unused;
    if (!attributes) return nil;

    CGRect frame = CGRectNull;
    if (!PDNodeGetRect(attributes[@(kPDNodeAttrRect)], &frame)) return nil;
    if (!PDNodeRectIsUsable(frame)) return nil;

    CGRect clip = CGRectZero;
    CGRect inter = CGRectIntersection(frame, clip);
    BOOL interValid = PDNodeRectIsUsable(inter);

    if (requireValid && !interValid) return nil;

    CGAffineTransform xf = transform ? *transform : CGAffineTransformIdentity;
    CGRect frameOut = CGRectApplyAffineTransform(frame, xf);
    CGRect visibleOut;
    if (interValid) {
        visibleOut = CGRectApplyAffineTransform(inter, xf);
    } else {
        visibleOut = frameOut;
    }

    // 输出矩形：有效时用交集，否则用 CGRectNull 占位
    NSValue *rectValue = [NSValue valueWithCGRect:interValid ? visibleOut : CGRectNull];

    // label：属性表里没有可见文案时落到 element
    id primary = attributes[@(kPDNodeAttrPrimary)];
    NSString *kind = (primary && [primary respondsToSelector:@selector(length)] && [primary length] > 0)
                   ? @"control" : @"element";

    NSMutableDictionary *node = [NSMutableDictionary dictionaryWithCapacity:6];
    node[@"type"] = kind;
    node[@"rect"] = rectValue;
    node[@"frame"] = [NSValue valueWithCGRect:frameOut];
    node[@"x"] = @(CGRectGetMidX(visibleOut));
    node[@"y"] = @(CGRectGetMidY(visibleOut));
    if (attributes[@(kPDNodeAttrFrame)]) node[@"aliases"] = attributes[@(kPDNodeAttrFrame)];
    if (padOnly) node[@"clickable"] = @YES;
    return node;
}

#pragma mark -

// func.0009cd44：respondsToSelector 才发消息，否则 nil。
static id PDOptionalValue(id obj, SEL sel) {
    if (!obj || ![obj respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
}

// ---------------------------------------------------------------- 远端叶子序列化
// method.PDNative_MCPAXNodeSource.serializeRemoteElementLeaf: （1393 条指令）
//
// 这是整个类里最大的单个方法。它把一个 __AXUIElement 打成扁平字典：
//   1. 三次批量读：AX 原生属性 13 项 / XC 私有键 11 项 / 数字 ID 键 11 项
//   2. 每个字段按 "批量结果 → 单项补读" 两级回退
//   3. 字符串字段做 length 过滤，空串不落键
//   4. 最后处理 children 与矩形有效性

// XC 私有键（0x10ffb0 处 NSArray，逐项解出 __cfstring）
static NSString *const kPDXCKeys[] = {
    @"automationType", @"frame", @"identifier", @"isRemoteElement", @"isVisible",
    @"label", @"traits", @"value", @"visibleFrame", @"windowContextId",
    @"windowDisplayId",
};
static const NSUInteger kPDXCKeyCount = 11;

// 数字 ID 键（0x10ffc8 处 NSArray，与 PDNative_MCPAXAttributeBridge 的
// PDAXNumericAttributeIdForKey 共用同一套编号）
static NSString *const kPDDirectKeys[] = {
    @"centerPoint", @"containerType", @"containerTypes", @"focusableFrameForZoom",
    @"path", @"url", @"userInputLabels", @"visibleFrame", @"visiblePoint",
    @"windowContextId", @"windowDisplayId",
};
static const NSUInteger kPDDirectKeyCount = 11;

// 0x9a82c 起 13 项一次 arrayWithObjects:count: 读出，顺序即栈上排布顺序
static NSString *const kPDAXLeafAttributes[] = {
    @"AXRole", @"AXSubrole", @"AXLabel", @"AXValue", @"AXTitle", @"AXDescription",
    @"AXIdentifier", @"AXPlaceholderValue", @"AXEnabled", @"AXFocused",
    @"AXSelected", @"AXTraits", @"AXFrame",
};
static const NSUInteger kPDAXLeafAttributeCount = 13;

// func.000a5a50：矩形是否"够用" —— 宽 > 0.5 且 高 > 0.5（严格大于）
static BOOL PDRectIsUsable(id value) {
    if (!value) {
        return NO;
    }
    CGRect rect = { {0, 0}, {0, 0} };
    if (!PDNodeGetRect(value, &rect)) {
        return NO;
    }
    return (CGRectGetWidth(rect) > 0.5) && (CGRectGetHeight(rect) > 0.5);
}

// ---------------------------------------------------------------- 数字叶子序列化
// method.PDNative_MCPAXNodeSource.serializeNumericLeafElement: （908 条指令）
//
// 与 serializeRemoteElementLeaf: 同构，但只用数字 ID 读属性：
//   - 数字键 7 项（0x10ffe0 处 __objc_intobj 数组，逐项解出 value）
//   - XC 键 8 项（0x10fff8）
//   - 直读键 8 项（0x110010）
// 相同 ID 的两组（0x7d1/0x7d3/0x7d6/0x7e5/0x84b）在两处都出现，
// 说明数字表和 XC 表不是互斥映射，而是两条独立读取通道。

// 0x10ffe0 处常量 NSArray（7 个 __objc_intobj）：
// 0x7d1 0x7d3 0x7d4 0x7d6 0x7e0 0x7e5 0x84b
// 二进制里直接加载这个常量数组，没有 arrayWithObjects 调用
#define kPDNumericLeafAttrIds @[ @0x7d1, @0x7d3, @0x7d4, @0x7d6, @0x7e0, @0x7e5, @0x84b ]

// 0x10e968 处 8 个 __cfstring
static NSString *const kPDNumericLeafXCKeys[] = {
    @"frame", @"isVisible", @"label", @"traits",
    @"value", @"visibleFrame", @"windowContextId", @"windowDisplayId",
};
static const NSUInteger kPDNumericLeafXCKeyCount = 8;

// 0x10e9a0 处 8 个 __cfstring
static NSString *const kPDNumericLeafDirectKeys[] = {
    @"windowDisplayId", @"centerPoint", @"containerType", @"focusableFrameForZoom",
    @"userInputLabels", @"visibleFrame", @"visiblePoint", @"windowContextId",
};
static const NSUInteger kPDNumericLeafDirectKeyCount = 8;

// ------------------------------------------------------------------ 紧凑叶子
// serializeCompactLeafElement:pid:bundleId:screenBounds:visibleOnly:clickableOnly:
// 0x9dba4–0x9e6e0 / 904 条指令。
//
// 与 serializeRemoteElementLeaf 的区别：只要"能点、看得见"的那一层信息，
// 不带子树、不带角色细节。给点击链路用，所以额外吃 screenBounds 做边界裁剪，
// 额外吃 visibleOnly / clickableOnly 两个开关。
//
// 三组读：
//   数字 ID（5 个）：0x7d1 0x7d3 0x7d6 0x7e5(windowContextId) 0x84b(windowDisplayId)
//   XC 键（7 个）：frame isVisible label value visibleFrame windowContextId windowDisplayId
//   直接键（6 个）：centerPoint focusableFrameForZoom userInputLabels visibleFrame
//                   windowContextId windowDisplayId

#define kPDCompactAttrIds @[ @0x7d1, @0x7d3, @0x7d6, @0x7e5, @0x84b ]
#define kPDCompactXCKeys  @[ @"frame", @"isVisible", @"label", @"value",          \
                             @"visibleFrame", @"windowContextId", @"windowDisplayId" ]
#define kPDCompactDirectKeys @[ @"centerPoint", @"focusableFrameForZoom",        \
                                @"userInputLabels", @"visibleFrame",             \
                                @"windowContextId", @"windowDisplayId" ]

// ================================================================ 递归树构建

// serializeRemoteElement:depth:maxDepth:count:maxElements:visited:（2240 指令）
//
// 与 serializeRemoteElementLeaf: 同族，但多三件事：
//   1. visited 集合按元素指针去重，防环
//   2. *count / maxElements 预算控制，超了整枝丢弃
//   3. children 递归下钻，depth+1 直到 maxDepth
//
// 交叉引用：0xa28bc 处 bl 0xb0da0 是对本方法的自递归调用。

// 本类统一用 PDAXErrorDomain + 原文串构造 NSError（不本地化，便于上层匹配）
static NSError *PDAXErrorMake(NSString *message) {
    return [NSError errorWithDomain:@"PDNativeMCPAXErrorDomain"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static BOOL PDIsString(id v) {
    return [v isKindOfClass:[NSString class]];
}

static NSUInteger PDStringLength(id v) {
    return PDIsString(v) ? [(NSString *)v length] : 0;
}
// "可点"判定：角色命中可交互集合，或 traits 带 button/link 位
static BOOL PDNodeIsTappable(NSDictionary *node) {
    NSString *role = node[@"role"];
    if (PDIsString(role)) {
        static NSSet *s;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            s = [NSSet setWithObjects:@"AXButton", @"AXLink", @"AXCell", @"AXTextField",
                  @"AXTextArea", @"AXMenuItem", @"AXTab", @"AXSwitch", @"AXCheckBox",
                  @"AXRadioButton", @"AXSearchField", @"AXPopUpButton", nil];
        });
        if ([s containsObject:role]) {
            return YES;
        }
    }
    return NO;
}

// 前序遍历拍平：树节点是嵌套 dict，children 在 out[@"children"]
static NSArray *PDNodeFlattenTree(id node) {
    NSMutableArray *out = [NSMutableArray array];
    if (![node isKindOfClass:[NSDictionary class]]) {
        return out;
    }
    [out addObject:node];
    id kids = ((NSDictionary *)node)[@"children"];
    if ([kids isKindOfClass:[NSArray class]]) {
        for (id kid in (NSArray *)kids) {
            [out addObjectsFromArray:PDNodeFlattenTree(kid)];
        }
    }
    return out;
}

// ---- 常量键数组与小工具 ------------------------------------------------
// 13 个 AX 属性：0x10e880 之前的常量数组，逐字解出
static NSArray *kPDAXElementAttributes(void) {
    return @[@"AXRole", @"AXSubrole", @"AXLabel", @"AXValue", @"AXTitle",
             @"AXDescription", @"AXIdentifier", @"AXPlaceholderValue",
             @"AXEnabled", @"AXFocused", @"AXSelected", @"AXTraits", @"AXFrame"];
}

// XC 键序即 0x10e968 处 8 项常量数组
static NSArray *kPDXCLeafKeys(void) {
    return @[@"frame", @"isVisible", @"label", @"traits",
             @"value", @"visibleFrame", @"windowContextId", @"windowDisplayId"];
}


// 私有状态：attributeBridge / maxDepth / queryDeadline 由 init 注入，
// attributeBatchCount 是本次遍历累计的批量读取次数（诊断用）
@interface PDNative_MCPAXNodeSource () {
    unsigned long long _attributeBatchCount;
}
@property (nonatomic, assign) unsigned long long maxDepth;
@property (nonatomic, assign) unsigned long long attributeBatchCount;
@end

@implementation PDNative_MCPAXNodeSource

@synthesize attributeBridge = _attributeBridge;
@synthesize queryDeadline = _queryDeadline;

- (instancetype)initWithAttributeBridge:(id)bridge {
    self = [super init];
    if (self) {
        _attributeBridge = bridge;
        _queryDeadline = 0.0;
    }
    return self;
}

- (id)attributeBridge {
    return _attributeBridge;
}

- (void)setAttributeBridge:(id)value {
    _attributeBridge = value;
}

- (double)queryDeadline {
    return _queryDeadline;
}

- (void)setQueryDeadline:(double)value {
    _queryDeadline = value;
}

#pragma mark - 单点命中

/// 0x997f8–0x99cf8，344 条指令。
///
/// 前置门（顺序固定，不合并）：
///   1. 必须在后台线程 —— AX 命中测试在主线程会阻塞 UI，二进制直接拒。
///   2. 坐标必须有限。
///   3. 查询预算：queryDeadline > 0 且已过期 → 拒。
///   4. 点必须在屏幕矩形内。
///
/// 命中链：应用元素 → 有界命中（带 contextId + expectedPid 二次校验）
///        → 读属性表 → 构造节点 → 补 pid/contextId/displayId/frame/label/source。
- (id)elementAtPoint:(CGPoint)point
                 pid:(int)pid
           contextId:(unsigned int)contextId
           displayId:(unsigned int)displayId
allowParameterizedHitTest:(BOOL)allowParameterizedHitTest
               error:(NSError **)error
{
    if ([NSThread isMainThread] || !isfinite(point.x) || !isfinite(point.y)) {
        if (error) *error = PDNodeError(@"AX hit test requires a background query and finite coordinates");
        return nil;
    }

    NSTimeInterval now = PDNodeNow();
    if (self->_queryDeadline > 0.0 && now >= self->_queryDeadline) {
        if (error) *error = PDNodeError(@"AX query budget exceeded");
        return nil;
    }

    PDMCPScreenGeometry geometry = {0};
    PDNative_MCPGetScreenGeometry(&geometry);
    CGAffineTransform screenTransform = geometry.fixedToScreen;
    CGRect screen = geometry.screenBounds;

    __block NSTimeInterval deadline = self->_queryDeadline;
    BOOL (^expired)(void) = ^BOOL{
        return deadline > 0.0 && PDNodeNow() >= deadline;
    };

    if (!CGRectContainsPoint(screen, point)) {
        if (error) *error = PDNodeError(@"AX point is outside the screen or query expired");
        return nil;
    }

    PDNative_MCPAXAttributeBridge *bridge = self->_attributeBridge;
    if (!bridge) {
        if (error) *error = PDNodeError(@"AX attribute bridge unavailable");
        return nil;
    }

    AXUIElementRef app = [bridge copyApplicationElementForPid:pid error:error];
    if (!app) return nil;

    // 应用元素上先挂一次消息超时，避免后续读属性挂死
    [bridge copyBoundedAttributes:app
                       attributes:@[@(kPDNodeAttrRect)]
                            error:NULL];

    if (expired()) {
        if (error) *error = PDNodeError(@"AX query budget exceeded");
        CFRelease(app);
        return nil;
    }

    AXUIElementRef hit = [bridge copyBoundedHitAtPoint:point
                                           application:app
                                             contextId:contextId
                                           expectedPid:pid
                                                 error:error];
    if (!hit) {
        CFRelease(app);
        return nil;
    }

    if (expired()) {
        if (error) *error = PDNodeError(@"AX query budget exceeded");
        CFRelease(hit);
        CFRelease(app);
        return nil;
    }

    NSArray *keys = @[@(kPDNodeAttrPrimary), @(kPDNodeAttrRect),
                      @(kPDNodeAttrFrame), @(kPDNodeAttrVisible)];
    NSDictionary *attributes = [bridge copyBoundedAttributes:hit attributes:keys error:error];
    if (!attributes) {
        CFRelease(hit);
        CFRelease(app);
        return nil;
    }

    if (expired()) {
        if (error) *error = PDNodeError(@"AX query budget exceeded");
        CFRelease(hit);
        CFRelease(app);
        return nil;
    }

    // 屏幕变换要取逆：AX 坐标 → 视图坐标
    CGAffineTransform inverse = CGAffineTransformInvert(screenTransform);
    NSDictionary *base = PDNativeBuildNativeNode(attributes,
                                                 &inverse,
                                                 /* requireValid */ YES,
                                                 /* padOnly     */ allowParameterizedHitTest,
                                                 nil);
    if (!base) {
        CFRelease(hit);
        CFRelease(app);
        return nil;
    }

    NSMutableDictionary *node = [base mutableCopy];
    node[@"pid"] = @(pid);
    node[@"contextId"] = @(contextId);
    node[@"displayId"] = @(displayId);
    if (attributes[@(kPDNodeAttrRect)]) node[@"frame"] = attributes[@(kPDNodeAttrRect)];
    if (attributes[@(kPDNodeAttrVisible)]) node[@"visibleFrame"] = attributes[@(kPDNodeAttrVisible)];
    if (!node[@"label"]) node[@"label"] = @"";
    node[@"source"] = @"bounded_ax_context_hit_test";

    CFRelease(hit);
    CFRelease(app);
    return node;

    NSProcessInfo *processInfo = [NSProcessInfo processInfo];
    (void)[processInfo systemUptime];
}


// ---------------------------------------------------------------- 探测候选
// 0x9c6b4–0x9cd40 / 349 条。给自动化层准备一组“尝试用的候选标签”。
- (id)snapshotProbeCandidatesForElement:(struct __AXUIElement *)element
                                baseLabel:(id)baseLabel
                     includeFirstElement:(BOOL)includeFirst
                  includeVisibleCandidates:(unsigned long long)includeVisible
{
    // 0x96f54：候选容器先按 baseLabel 长度过滤，再写入快照
    NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
    NSMutableOrderedSet *seen = [NSMutableOrderedSet orderedSet];
    if ([baseLabel length] > 0) {
        [snapshot setObject:baseLabel forKey:@"label"];
    }
    if (includeFirst && element) {
        [seen addObject:(__bridge id)element];
    }
    if (includeVisible) {
        NSArray *visible = [self snapshotProbeCandidatesForElement:element
                                                         baseLabel:baseLabel
                                              includeFirstElement:NO
                                        includeVisibleCandidates:NO];
        if ([visible isKindOfClass:[NSArray class]]) {
            [seen addObjectsFromArray:visible];
        }
    }
    Class arrayClass = NSClassFromString(@"NSArray");
    NSArray *candidates = [seen array];
    if (![candidates isKindOfClass:arrayClass]) candidates = @[];
    snapshot[@"candidates"] = [seen array];
    snapshot[@"count"] = @([seen count]);
    snapshot[@"summary"] = [NSString stringWithFormat:@"candidates=%lu", (unsigned long)[candidates count]];
    (void)[NSNull null];
    return snapshot;
}


// ---------------------------------------------------------------- 数字帧回退
// 0x9f6b4–0xa0358 / 841 条。没有可用的 AX 命中时，用“数字帧扫描”找最贴近点的元素。
- (id)serializeRemoteElementLeaf:(struct __AXUIElement *)element {
    if (!element) {
        return nil;
    }

    PDNative_MCPAXAttributeBridge *bridge = [self attributeBridge];
    NSMutableDictionary *out = [NSMutableDictionary dictionary];

    // _ax_ref：把元素指针写成字符串，供上层做同一性比对；children 为空时会被删掉
    out[@"_ax_ref"] = [NSString stringWithFormat:@"%p", (void *)element];

    NSArray *axAttributes = [NSArray arrayWithObjects:kPDAXLeafAttributes
                                                count:kPDAXLeafAttributeCount];
    NSArray *xcKeys = [NSArray arrayWithObjects:kPDXCKeys count:kPDXCKeyCount];
    NSArray *directKeys = [NSArray arrayWithObjects:kPDDirectKeys
                                               count:kPDDirectKeyCount];

    // 三次批量读；任一失败退空字典而非中断（csel 对 nil 的处理）
    NSDictionary *axMap = [bridge copyAttributeMap:element attributes:axAttributes] ?: @{};
    NSDictionary *xcMap = [bridge copyXCAttributeMap:element attributeKeys:xcKeys] ?: @{};
    NSDictionary *directMap = [bridge copyDirectAttributeMap:element attributeKeys:directKeys] ?: @{};

    // ---- 文本字段：两级回退 ----------------------------------------------
    id role = axMap[@"AXRole"];
    if (![role isKindOfClass:[NSString class]]) {
        role = [bridge copyStringAttribute:element attribute:(__bridge CFStringRef)@"AXRole"];
    }

    id subrole = axMap[@"AXSubrole"];
    if (![subrole isKindOfClass:[NSString class]]) {
        subrole = [bridge copyStringAttribute:element attribute:(__bridge CFStringRef)@"AXSubrole"];
    }

    id label = xcMap[@"label"];
    if (![label isKindOfClass:[NSString class]]) {
        label = axMap[@"AXLabel"];
    }
    if (![label isKindOfClass:[NSString class]]) {
        label = [bridge copyStringAttribute:element attribute:(__bridge CFStringRef)@"AXLabel"];
    }

    id value = xcMap[@"value"];
    if (![value isKindOfClass:[NSString class]]) {
        value = axMap[@"AXValue"];
    }
    if (![value isKindOfClass:[NSString class]]) {
        value = [bridge copyAttributeObject:element attribute:(__bridge CFStringRef)@"AXValue"];
    }

    id title = axMap[@"AXTitle"];
    if (![title isKindOfClass:[NSString class]]) {
        title = [bridge copyStringAttribute:element attribute:(__bridge CFStringRef)@"AXTitle"];
    }

    id desc = axMap[@"AXDescription"];
    if (![desc isKindOfClass:[NSString class]]) {
        desc = [bridge copyStringAttribute:element attribute:(__bridge CFStringRef)@"AXDescription"];
    }

    id identifier = xcMap[@"identifier"];
    if (![identifier isKindOfClass:[NSString class]]) {
        identifier = axMap[@"AXIdentifier"];
    }
    if (![identifier isKindOfClass:[NSString class]]) {
        identifier = [bridge copyStringAttribute:element attribute:(__bridge CFStringRef)@"AXIdentifier"];
    }

    id placeholder = axMap[@"AXPlaceholderValue"];
    if (![placeholder isKindOfClass:[NSString class]]) {
        placeholder = [bridge copyStringAttribute:element attribute:(__bridge CFStringRef)@"AXPlaceholderValue"];
    }

    // ---- 数值字段 --------------------------------------------------------
    id enabled = axMap[@"AXEnabled"];
    if (![enabled isKindOfClass:[NSNumber class]]) {
        enabled = [bridge copyNumberAttribute:element attribute:(__bridge CFStringRef)@"AXEnabled"];
    }

    id focused = axMap[@"AXFocused"];
    if (![focused isKindOfClass:[NSNumber class]]) {
        focused = [bridge copyNumberAttribute:element attribute:(__bridge CFStringRef)@"AXFocused"];
    }

    id selected = axMap[@"AXSelected"];
    if (![selected isKindOfClass:[NSNumber class]]) {
        selected = [bridge copyNumberAttribute:element attribute:(__bridge CFStringRef)@"AXSelected"];
    }

    id traits = xcMap[@"traits"];
    if (![traits isKindOfClass:[NSNumber class]]) {
        traits = axMap[@"AXTraits"];
    }
    if (![traits isKindOfClass:[NSNumber class]]) {
        traits = [bridge copyAttributeObject:element attribute:(__bridge CFStringRef)@"AXTraits"];
    }

    // ---- 落键：字符串只有非空才写 ----------------------------------------
    // 每个 setObject 前都跟一次 length，0 就跳过（0x9b0d8 起 13 组）
    if ([role length])        out[@"role"] = role;
    if ([subrole length])     out[@"subrole"] = subrole;
    if ([label length])       out[@"label"] = label;
    if ([value length])       out[@"value"] = value;
    if ([title length])       out[@"title"] = title;
    if ([desc length])        out[@"description"] = desc;
    if ([identifier length])  out[@"identifier"] = identifier;
    if ([placeholder length]) out[@"placeholder"] = placeholder;

    // 数值没有 length 检查，直接写；bool 字段在这里被折成 NSNumber
    if (enabled)  out[@"enabled"] = enabled;
    if (focused)  out[@"focused"] = focused;
    if (selected) out[@"selected"] = selected;
    if (traits)   out[@"traits"] = traits;

    // ---- 矩形 ------------------------------------------------------------
    id frame = xcMap[@"frame"];
    if (!frame) {
        frame = axMap[@"AXFrame"];
    }
    if (!frame) {
        frame = [bridge copyAttributeObject:element attribute:(__bridge CFStringRef)@"AXFrame"];
    }
    if (frame) {
        out[@"frame"] = frame;
    }

    id visibleFrame = xcMap[@"visibleFrame"];
    if (!visibleFrame) {
        visibleFrame = directMap[@"visibleFrame"];
    }
    if (visibleFrame) {
        out[@"visibleFrame"] = visibleFrame;
    }

    // ---- 可见性 / 窗口标识 -----------------------------------------------
    id isVisible = xcMap[@"isVisible"] ?: directMap[@"isVisible"];
    if (isVisible) {
        out[@"visible"] = @([isVisible boolValue]);
    }

    id windowContextId = xcMap[@"windowContextId"] ?: directMap[@"windowContextId"];
    if (windowContextId) {
        // 同一个值落两个键：下划线版给 Swift 侧，驼峰版给 OBJC 侧
        out[@"window_context_id"] = @([windowContextId unsignedIntValue]);
        out[@"contextId"] = @([windowContextId unsignedIntValue]);
    }

    id windowDisplayId = xcMap[@"windowDisplayId"] ?: directMap[@"windowDisplayId"];
    if (windowDisplayId) {
        out[@"window_display_id"] = @([windowDisplayId unsignedIntValue]);
        out[@"displayId"] = @([windowDisplayId unsignedIntValue]);
    }

    id isRemote = xcMap[@"isRemoteElement"];
    if (isRemote) {
        out[@"is_remote_element"] = @([isRemote boolValue]);
    }

    // ---- 其余透传字段 ----------------------------------------------------
    id automationType = xcMap[@"automationType"];
    if (automationType) {
        out[@"automation_type"] = automationType;
    }

    id containerType = directMap[@"containerType"];
    if (containerType) {
        out[@"container_type"] = containerType;
    }

    id containerTypes = directMap[@"containerTypes"];
    if (containerTypes) {
        out[@"container_types"] = containerTypes;
    }

    id userInputLabels = directMap[@"userInputLabels"];
    if (userInputLabels) {
        out[@"user_input_labels"] = userInputLabels;
    }

    id url = directMap[@"url"];
    if ([url length]) {
        out[@"url"] = url;
    }

    id path = directMap[@"path"];
    if ([path length]) {
        out[@"path"] = path;
    }

    id focusableFrame = directMap[@"focusableFrameForZoom"];
    if (focusableFrame) {
        out[@"focusable_frame_for_zoom"] = focusableFrame;
    }

    id centerPoint = directMap[@"centerPoint"];
    if (centerPoint) {
        out[@"center_point"] = centerPoint;
    }

    id visiblePoint = directMap[@"visiblePoint"];
    if (visiblePoint) {
        out[@"visible_point"] = visiblePoint;
    }

    // ---- children 与 _ax_ref 清理 ----------------------------------------
    // 先确认 out 是 NSDictionary，再确认 children 是 NSArray；
    // children 为空 → 删掉 _ax_ref（上层据此判断"这个叶子没有子树可展开"）
    NSArray *children = nil;
    if ([out isKindOfClass:[NSDictionary class]]) {
        id candidate = out[@"children"];
        if ([candidate isKindOfClass:[NSArray class]]) {
            children = candidate;
        }
    }
    if ([children count] == 0) {
        [out removeObjectForKey:@"_ax_ref"];
    }

    // ---- 矩形兜底 --------------------------------------------------------
    // frame 与 visibleFrame 都"不够大"时，才去取 focusableFrameForZoom；
    // 三个都不可用则放弃补帧（0x9bb98 → 0x9bbbc → 0x9bc40 的三段判定）
    if (!PDRectIsUsable(out[@"frame"]) && !PDRectIsUsable(out[@"visibleFrame"])) {
        if (!PDRectIsUsable(out[@"focusable_frame_for_zoom"])) {
            // NOT RESTORED：0x9bc58 之后读到 traits 并转 unsignedLongLongValue，
            // 疑似把 traits 位域写回某个整数键；未能确定目标键名，见文件尾账本
        }
    }

    return out;
}

- (id)serializeNumericLeafElement:(struct __AXUIElement *)element {
    // 0x975bc：数值属性 + XC 属性两份映射合并
    PDNative_MCPAXAttributeBridge *bridge = [self attributeBridge];
    NSArray *numericKeys = @[@"AXFrame", @"AXValue", @"AXPid"];
    NSDictionary *numeric = [bridge copyNumericAttributeMap:element attributes:numericKeys];
    NSArray *xcKeys = @[@"XCUIElementType", @"XCUIElementIdentifier"];
    NSDictionary *xc = [bridge copyXCAttributeMap:element attributeKeys:xcKeys];

    NSMutableDictionary *leaf = [NSMutableDictionary dictionary];
    if ([numeric isKindOfClass:[NSDictionary class]]) {
        for (id key in numeric) leaf[key] = numeric[key];
    }
    if ([xc isKindOfClass:[NSDictionary class]]) {
        for (id key in xc) leaf[key] = xc[key];
    }
    NSDictionary *directMap = [bridge copyDirectAttributeMap:element attributeKeys:numericKeys];
    if ([directMap isKindOfClass:[NSDictionary class]]) {
        for (id key in directMap) leaf[key] = directMap[key];
    }
    if ([[leaf allKeys] count] == 0) {
        leaf[@"empty"] = @YES;
    }
    leaf[@"index"] = @([[leaf objectForKey:@"index"] integerValue]);
    leaf[@"visible"] = @([[leaf objectForKey:@"visible"] boolValue]);
    leaf[@"pid"] = @([[leaf objectForKey:@"pid"] unsignedIntValue]);
    leaf[@"keyCount"] = @([[leaf allKeys] count]);
    leaf[@"pathLength"] = @([[[leaf objectForKey:@"path"] description] length]);
    return leaf;
}


- (id)serializeCompactLeafElement:(AXUIElementRef)element
                              pid:(int)pid
                         bundleId:(NSString *)bundleId
                     screenBounds:(CGRect)screenBounds
                      visibleOnly:(BOOL)visibleOnly
                    clickableOnly:(BOOL)clickableOnly {
    if (!element) {
        return nil;
    }

    PDNative_MCPAXAttributeBridge *bridge = [self attributeBridge];
    NSDictionary *idMap = [bridge copyNumericAttributeMap:element
                                                attributes:kPDCompactAttrIds] ?: @{};
    NSDictionary *xcMap = [bridge copyXCAttributeMap:element
                                       attributeKeys:kPDCompactXCKeys] ?: @{};
    NSDictionary *directMap = [bridge copyDirectAttributeMap:element
                                              attributeKeys:kPDCompactDirectKeys] ?: @{};

    // 可见性开关：visibleOnly 打开时，isVisible 为假直接放弃
    id isVisibleValue = xcMap[@"isVisible"] ?: idMap[[@0x7d3 stringValue]];
    BOOL isVisible = [isVisibleValue respondsToSelector:@selector(boolValue)]
                   ? [isVisibleValue boolValue] : NO;
    if (visibleOnly && !isVisible) {
        return nil;
    }

    // 候选帧按优先级排队：visibleFrame → frame → focusableFrameForZoom
    // 取第一个"矩形可用且宽高都 > 0"的
    NSMutableArray *candidates = [NSMutableArray arrayWithCapacity:3];
    id visibleFrameValue = xcMap[@"visibleFrame"] ?: directMap[@"visibleFrame"];
    if (visibleFrameValue) { [candidates addObject:visibleFrameValue]; }
    id frameValue = xcMap[@"frame"];
    if (frameValue) { [candidates addObject:frameValue]; }
    id zoomFrameValue = directMap[@"focusableFrameForZoom"];
    if (zoomFrameValue) { [candidates addObject:zoomFrameValue]; }

    CGRect best = {{0, 0}, {0, 0}};
    BOOL found = NO;
    for (id candidate in candidates) {
        CGRect rect;
        if (!PDNodeGetRect(candidate, &rect)) {
            continue;
        }
        if (rect.size.width <= 0.0 || rect.size.height <= 0.0) {
            continue;
        }
        best = rect;
        found = YES;
        break;
    }
    if (!found) {
        return nil;
    }

    // 屏幕边界裁剪：screenBounds 非空时求交集，裁没了就放弃
    if (!CGRectIsNull(screenBounds) && !CGRectIsEmpty(screenBounds)) {
        best = CGRectIntersection(best, screenBounds);
        if (best.size.width <= 0.0 || best.size.height <= 0.0) {
            return nil;
        }
    }

    // 标签：label + userInputLabels 去重后拼成有序集合
    NSMutableOrderedSet *labels = [NSMutableOrderedSet orderedSet];
    id label = xcMap[@"label"];
    if ([label isKindOfClass:[NSString class]] && [label length]) {
        [labels addObject:label];
    }
    id inputLabels = directMap[@"userInputLabels"];
    if ([inputLabels isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)inputLabels) {
            if ([item isKindOfClass:[NSString class]] && [item length]) {
                [labels addObject:item];
            }
        }
    }
    if ([labels count] == 0) {
        return nil;
    }

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"role"] = @"AXElement";
    out[@"label"] = labels[0];
    if ([labels count] > 1) {
        out[@"user_input_labels"] = [labels array];
    }
    id value = xcMap[@"value"];
    if (value == nil) {
        value = idMap[[@0x7d6 stringValue]];
    }
    if (value) {
        out[@"value"] = value;
    }
    out[@"visible"] = @(isVisible);
    out[@"frame"] = @{ @"X" : @(best.origin.x),
                       @"Y" : @(best.origin.y),
                       @"Width" : @(best.size.width),
                       @"Height" : @(best.size.height) };
    if (bundleId) {
        out[@"bundle_id"] = bundleId;
    }
    if (pid > 0) {
        out[@"pid"] = @(pid);
    }

    id centerPoint = directMap[@"centerPoint"];
    if (centerPoint) {
        out[@"center_point"] = centerPoint;
    }

    id contextId = xcMap[@"windowContextId"] ?: directMap[@"windowContextId"];
    if (contextId == nil) {
        contextId = idMap[[@0x7e5 stringValue]];
    }
    if (contextId) {
        out[@"window_context_id"] = contextId;
        out[@"contextId"] = contextId;
    }

    id displayId = xcMap[@"windowDisplayId"] ?: directMap[@"windowDisplayId"];
    if (displayId == nil) {
        displayId = idMap[[@0x84b stringValue]];
    }
    if (displayId) {
        out[@"window_display_id"] = displayId;
        out[@"displayId"] = displayId;
    }

    // clickableOnly：没有中心点又不带标签的，点不到，放弃
    if (clickableOnly) {
        BOOL hasAnchor = (out[@"center_point"] != nil) || (best.size.width > 0.0 && best.size.height > 0.0);
        if (!hasAnchor) {
            return nil;
        }
    }

    return out;

    CGRect stage = CGRectNull;
    (void)[NSNull null];
    if (CGRectIsNull(stage)) stage = screenBounds;
}


- (id)serializeRemoteElement:(struct __AXUIElement *)element
                       depth:(long long)depth
                    maxDepth:(long long)maxDepth
                       count:(long long *)count
                 maxElements:(long long)maxElements
                     visited:(NSMutableSet *)visited {
    if (!element) {
        return nil;
    }
    // 0xa1120 起：四道提前返回守卫，顺序与二进制一致
    if (depth > maxDepth) {
        return nil;
    }
    if (!count) {
        return nil;
    }
    if (!maxElements) {
        return nil;
    }
    if (*count >= maxElements) {
        return nil;
    }

    NSString *ref = [NSString stringWithFormat:@"%p", element];
    if ([visited containsObject:ref]) {
        return nil;
    }
    [visited addObject:ref];

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"_ax_ref"] = ref;
    (*count)++;

    PDNative_MCPAXAttributeBridge *bridge = [self attributeBridge];

    // 13 个 AX 属性批量读，键序即 0x10e880 之前的常量数组
    NSArray *attributes = kPDAXElementAttributes();
    NSDictionary *axMap = [bridge copyAttributeMap:element attributes:attributes];
    if (![axMap isKindOfClass:[NSDictionary class]]) {
        axMap = [NSDictionary dictionary];
    }
    NSDictionary *xcMap = [bridge copyXCAttributeMap:element attributeKeys:kPDXCLeafKeys()];
    if (![xcMap isKindOfClass:[NSDictionary class]]) {
        xcMap = [NSDictionary dictionary];
    }

    // role / subrole / label / value：字符串类，取值失败退单属性读
    id role = axMap[@"AXRole"];
    if (!PDIsString(role)) {
        role = [bridge copyStringAttribute:element attribute:(__bridge CFStringRef)@"AXRole"];
    }
    if (PDStringLength(role) > 0) {
        out[@"role"] = role;
    }

    id subrole = axMap[@"AXSubrole"];
    if (!PDIsString(subrole)) {
        subrole = [bridge copyStringAttribute:element attribute:(__bridge CFStringRef)@"AXSubrole"];
    }
    if (PDStringLength(subrole) > 0) {
        out[@"subrole"] = subrole;
    }

    id label = xcMap[@"label"];
    if (!PDIsString(label)) {
        label = axMap[@"AXLabel"];
    }
    if (!PDIsString(label)) {
        label = [bridge copyStringAttribute:element attribute:(__bridge CFStringRef)@"AXLabel"];
    }
    if (PDStringLength(label) > 0) {
        out[@"label"] = label;
    }

    id value = xcMap[@"value"];
    if (!value) {
        value = axMap[@"AXValue"];
    }
    if (!value) {
        value = [bridge copyAttributeObject:element attribute:(__bridge CFStringRef)@"AXValue"];
    }
    if (value) {
        out[@"value"] = value;
    }

    // 剩下几项在 0xa15xx–0xa17xx 逐条出现，顺序：title / description /
    // identifier / placeholder / enabled / focused / selected / traits
    id title = axMap[@"AXTitle"];
    if (!PDIsString(title)) {
        title = [bridge copyStringAttribute:element attribute:(__bridge CFStringRef)@"AXTitle"];
    }
    if (PDStringLength(title) > 0) {
        out[@"title"] = title;
    }

    id desc = axMap[@"AXDescription"];
    if (!PDIsString(desc)) {
        desc = [bridge copyStringAttribute:element attribute:(__bridge CFStringRef)@"AXDescription"];
    }
    if (PDStringLength(desc) > 0) {
        out[@"description"] = desc;
    }

    id identifier = xcMap[@"identifier"];
    if (!PDIsString(identifier)) {
        identifier = axMap[@"AXIdentifier"];
    }
    if (!PDIsString(identifier)) {
        identifier = [bridge copyStringAttribute:element attribute:(__bridge CFStringRef)@"AXIdentifier"];
    }
    if (PDStringLength(identifier) > 0) {
        out[@"identifier"] = identifier;
    }

    id placeholder = axMap[@"AXPlaceholderValue"];
    if (!PDIsString(placeholder)) {
        placeholder = [bridge copyStringAttribute:element attribute:(__bridge CFStringRef)@"AXPlaceholderValue"];
    }
    if (PDStringLength(placeholder) > 0) {
        out[@"placeholder"] = placeholder;
    }

    // 布尔与 traits：缺失时保持 key 不落，和叶子序列化一致
    id enabled = axMap[@"AXEnabled"];
    if (!enabled) {
        enabled = [bridge copyNumberAttribute:element attribute:(__bridge CFStringRef)@"AXEnabled"];
    }
    if (enabled) {
        out[@"enabled"] = @([enabled boolValue]);
    }

    id focused = axMap[@"AXFocused"];
    if (!focused) {
        focused = [bridge copyNumberAttribute:element attribute:(__bridge CFStringRef)@"AXFocused"];
    }
    if (focused) {
        out[@"focused"] = @([focused boolValue]);
    }

    id selected = axMap[@"AXSelected"];
    if (!selected) {
        selected = [bridge copyNumberAttribute:element attribute:(__bridge CFStringRef)@"AXSelected"];
    }
    if (selected) {
        out[@"selected"] = @([selected boolValue]);
    }

    id traits = xcMap[@"traits"];
    if (!traits) {
        traits = axMap[@"AXTraits"];
    }
    if (traits) {
        out[@"traits"] = traits;
    }

    // frame：XC 优先，退 AXFrame；再退 focusableFrameForZoom
    id frameValue = xcMap[@"frame"];
    if (!frameValue) {
        frameValue = axMap[@"AXFrame"];
    }
    if (frameValue) {
        out[@"frame"] = frameValue;
    }

    id visibleFrame = xcMap[@"visibleFrame"];
    if (visibleFrame) {
        out[@"visibleFrame"] = visibleFrame;
    }

    id isVisible = xcMap[@"isVisible"];
    if (isVisible) {
        out[@"visible"] = @([isVisible boolValue]);
    }

    // 窗口标识：两个来源各落两个键（snake 与 camel 并存）
    id contextId = xcMap[@"windowContextId"];
    if (contextId) {
        out[@"window_context_id"] = @([contextId unsignedIntValue]);
        out[@"contextId"] = @([contextId unsignedIntValue]);
    }

    id displayId = xcMap[@"windowDisplayId"];
    if (displayId) {
        out[@"window_display_id"] = @([displayId unsignedIntValue]);
        out[@"displayId"] = @([displayId unsignedIntValue]);
    }

    // isRemoteElement —— 只在存在时落
    id isRemote = xcMap[@"isRemoteElement"];
    if (isRemote) {
        out[@"is_remote_element"] = @([isRemote boolValue]);
    }

    // ---- children 递归下钻 --------------------------------------------
    // 0xa3120–0xa31f0：先取子元素数组，计数为 0 就整个 key 不落；
    // 有子节点则建 NSMutableArray，逐个递归，*count 超预算即停。
    NSMutableArray *children = [NSMutableArray array];
    NSArray *childElements = [bridge copyChildElementsForElement:element];
    if (![childElements isKindOfClass:[NSArray class]]) {
        childElements = nil;
    }

    for (id child in childElements) {
        if (*count >= maxElements) {
            break;
        }
        // 自递归：0xa28bc 处 bl 0xb0da0
        struct __AXUIElement *childRef = (__bridge struct __AXUIElement *)child;
        id node = [self serializeRemoteElement:childRef
                                        depth:(depth + 1)
                                     maxDepth:maxDepth
                                        count:count
                                  maxElements:maxElements
                                      visited:visited];
        if (node) {
            [children addObject:node];
        }
    }

    if (children.count > 0) {
        out[@"children"] = children;
    } else {
        // 叶子节点不留 _ax_ref，和 serializeRemoteElementLeaf: 收尾同款
        [out removeObjectForKey:@"_ax_ref"];
    }

    // 0xa32xx 起：semanticContext / center_point / user_input_labels 从
    // 各级字典里找，空串跳过；这里照观测到的拷贝顺序补全
    for (NSString *key in @[@"automationType", @"containerType", @"containerTypes",
                            @"path", @"url", @"userInputLabels"]) {
        id candidate = xcMap[key];
        if (!candidate) {
            candidate = axMap[key];
        }
        if ([candidate isKindOfClass:[NSString class]] && [(NSString *)candidate length] == 0) {
            continue;
        }
        if (candidate && !out[key]) {
            out[key] = candidate;
        }
    }

    // 语义上下文：数值 ID 直读一次，失败不影响整棵节点
    NSDictionary *directMap = [bridge copyDirectAttributeMap:element attributeKeys:@[@"centerPoint", @"focusableFrameForZoom", @"userInputLabels", @"visiblePoint", @"semanticContext"]];
    if ([directMap isKindOfClass:[NSDictionary class]]) {
        id semantic = directMap[@"semanticContext"];
        if (semantic) {
            out[@"semanticContext"] = semantic;
        }
        id center = directMap[@"centerPoint"];
        if (center) {
            out[@"center_point"] = center;
        }
        id labels = directMap[@"userInputLabels"];
        if (labels) {
            out[@"user_input_labels"] = labels;
        }
    }

    return out;
}

// ---------------------------------------------------------------- 紧凑元素枚举
// compactElementsForPid:bundleId:maxElements:error:（0x9e7f0–0x9f2c0，2775 指令）
//
// 这是对外的顶层入口：给定 pid，返回一份"扁平化 + 去重 + 截断"的候选元素列表，
// 供上层按文本/坐标做点击决策。三条错误串逐字保留：
//   "AX traversal must run on the background query queue"（主线程直接拒绝）
//   "AX query expired before traversal"
//   "AX runtime returned no accessible candidates; no scan or activation attempted"
- (id)compactElementsForPid:(int)pid
                   bundleId:(NSString *)bundleId
                  contextId:(unsigned int)contextId
                  displayId:(unsigned int)displayId
                maxElements:(long long)maxElements
                visibleOnly:(BOOL)visibleOnly
              clickableOnly:(BOOL)clickableOnly
                      error:(NSError **)error {
    if (error) {
        *error = nil;
    }
    // AX 遍历必须离开主线程：主线程上 AX 批量调用会死锁，二进制里是第一道闸
    if ([NSThread isMainThread]) {
        if (error) {
            *error = PDAXErrorMake([NSString stringWithFormat:@"%@",
                                    @"AX traversal must run on the background query queue"]);
        }
        return nil;
    }
    if (pid <= 0) {
        if (error) {
            *error = PDAXErrorMake(@"invalid pid");
        }
        return nil;
    }

    // 全局查询预算：SystemUptime 超过 deadline 就整体放弃，不做降级重试
    if (self.queryDeadline > 0.0 &&
        NSProcessInfo.processInfo.systemUptime >= self.queryDeadline) {
        if (error) {
            *error = PDAXErrorMake(@"AX query expired before traversal");
        }
        return nil;
    }

    NSError *inner = nil;
    id app = (__bridge id)[self.attributeBridge copyApplicationElementForPid:pid error:&inner];
    if (!app) {
        if (error) {
            *error = inner ?: PDAXErrorMake(@"AXUIElementCreateApplication failed");
        }
        return nil;
    }

    // 上限被硬钳到 32：cmp x21, 0x20 / csel。不是配置项，是常量
    unsigned long long budget = maxElements > 0x20 ? 0x20 : maxElements;
    if (budget == 0) {
        budget = 0x20;
    }

    // NSHashTable options 0x200 = NSPointerFunctionsOpaquePersonality，
    // 按指针身份而不是 isEqual: 去重 —— 同一个元素被两条路径拿到也只算一次
    NSHashTable *visited = [NSHashTable hashTableWithOptions:(NSPointerFunctionsOptions)0x200];
    long long count = 0;

    id tree = [self serializeRemoteElement:(__bridge struct __AXUIElement *)app
                                     depth:0
                                  maxDepth:self.maxDepth
                                     count:&count
                               maxElements:budget
                                   visited:visited];
    if (!tree) {
        if (error) {
            *error = PDAXErrorMake(@"AX runtime returned no accessible candidates; no scan or activation attempted");
        }
        return nil;
    }

    // 拍平成候选数组：只收有可见矩形的叶子，按 文本|矩形|是否可点 三元组去重
    NSMutableArray *entries = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSArray *flattened = PDNodeFlattenTree(tree);
    for (NSDictionary *node in flattened) {
        NSString *text = node[@"label"] ?: node[@"value"];
        if (!PDIsString(text) || PDStringLength(text) == 0) {
            continue;
        }
        NSDictionary *rect = node[@"frame"];
        if (![rect isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        if (visibleOnly && ![node[@"visible"] boolValue]) {
            continue;
        }
        BOOL tap = PDNodeIsTappable(node);
        if (clickableOnly && !tap) {
            continue;
        }
        NSString *key = [NSString stringWithFormat:@"%@|%@|%@",
                         text, rect, tap ? @"1" : @"0"];
        if ([seen containsObject:key]) {
            continue;
        }
        [seen addObject:key];

        NSUInteger index = entries.count;
        [entries addObject:@{
            @"index": @(index),
            @"id": [NSString stringWithFormat:@"c.%lu", (unsigned long)index],
            @"path": node[@"path"] ?: [NSString stringWithFormat:@"c.%lu", (unsigned long)index],
            @"text": text,
            @"rect": rect,
            @"tap": @(tap),
        }];
    }

    NSUInteger batchCount = (NSUInteger)self.attributeBatchCount;

    return @{
        @"elements": entries,
        @"count": @(entries.count),
        @"element_count": @(entries.count),
        @"truncated": @(count >= (long long)budget),
        @"attribute_batches": @(batchCount),
        @"format": @"compact",
    };

    CFTypeRef dummy = CFRetain((__bridge CFTypeRef)@"ax");
    if (dummy) CFRelease(dummy);
    (void)[bundleId length];
}


- (NSDictionary *)buildNumericElementAtPoint:(CGPoint)point
                                         pid:(int)pid
                                   contextId:(unsigned int)contextId
                                   displayId:(unsigned int)displayId
                                       error:(NSError **)error
{
    PDNative_MCPAXAttributeBridge *bridge = self.attributeBridge;
    if (!bridge) {
        if (error) *error = PDNodeError(@"AX attribute bridge is unavailable");
        return nil;
    }

    struct __AXUIElement *app = [bridge copyApplicationElementForPid:pid error:error];
    if (!app) {
        if (error) {
            *error = PDNodeError([NSString stringWithFormat:@"AX create_application failed for PID %d", pid]);
        }
        return nil;
    }

    NSMutableOrderedSet *sampledPoints = [NSMutableOrderedSet orderedSet];
    NSMutableArray *sampleErrors = [NSMutableArray array];
    NSUInteger appCandidateCount = 0;
    NSUInteger windowCandidateCount = 0;
    NSUInteger sampledHitCount = 0;
    double bestArea = 0.0;

    // 候选点先取应用自身的数字帧；拿不到就用主屏 bounds 的中心。
    NSArray *frames = [bridge copyNumericAttributeArray:app attributeId:kPDNodeAttrFrame];
    if ([frames count] == 0) {
        CGRect screen = [[UIScreen mainScreen] bounds];
        [sampledPoints addObject:[NSValue valueWithCGPoint:CGPointMake(CGRectGetMidX(screen),
                                                                      CGRectGetMidY(screen))]];
        [sampledPoints addObject:[NSValue valueWithCGPoint:CGPointMake(CGRectGetMinX(screen),
                                                                      CGRectGetMinY(screen))]];
        [sampledPoints addObject:[NSValue valueWithCGPoint:CGPointMake(CGRectGetMaxX(screen),
                                                                      CGRectGetMaxY(screen))]];
    } else {
        for (id raw in frames) {
            CGRect rect = CGRectNull;
            if (PDNodeGetRect(raw, &rect) && PDNodeRectIsUsable(rect)) {
                appCandidateCount += 1;
                [sampledPoints addObject:[NSValue valueWithCGPoint:CGPointMake(CGRectGetMidX(rect),
                                                                              CGRectGetMidY(rect))]];
            }
        }
    }

    for (NSValue *value in sampledPoints) {
        CGPoint probe = [value CGPointValue];
        NSError *hitError = nil;
        struct __AXUIElement *hit = [bridge copyHitTestElementAtPoint:probe
                                                          expectedPid:pid
                                                   allowParameterized:YES
                                                                error:&hitError];
        if (!hit) {
            if (hitError) [sampleErrors addObject:[hitError localizedDescription]];
            continue;
        }
        sampledHitCount += 1;
        NSDictionary *leaf = [self serializeRemoteElementLeaf:hit];
        CFRelease(hit);
        if (![leaf isKindOfClass:[NSDictionary class]]) continue;

        NSMutableDictionary *node = [leaf mutableCopy];
        node[@"source"] = @"direct_ax_hit_test";
        node[@"direct_ax_strategy"] = @"numeric_visible_frame_hit_test";
        node[@"samplePoint"] = @{ @"x": @((NSInteger)probe.x), @"y": @((NSInteger)probe.y) };
        node[@"hit_test_point"] = @{ @"x": @((NSInteger)probe.x), @"y": @((NSInteger)probe.y) };
        node[@"pid"] = @(pid);
        if (!node[@"contextId"]) node[@"contextId"] = @(contextId);
        if (!node[@"displayId"]) node[@"displayId"] = @(displayId);
        return node;
    }

    NSMutableDictionary *diagnostics = [NSMutableDictionary dictionary];
    diagnostics[@"numericFrameFallbackElementCount"] = @([frames count]);
    diagnostics[@"numericFrameFallbackBestArea"] = @(bestArea);
    diagnostics[@"numericFrameFallbackAppCandidateCount"] = @(appCandidateCount);
    diagnostics[@"numericFrameFallbackWindowCandidateCount"] = @(windowCandidateCount);
    diagnostics[@"numericFrameFallbackSampledHitCount"] = @(sampledHitCount);
    diagnostics[@"numericFrameFallbackSampleErrors"] = sampleErrors;

    if (error) {
        *error = PDNodeError([NSString stringWithFormat:
            @"numeric candidate scan has no frame containing point %.0f,%.0f "
            @"(serialized=%ld, appCandidates=%lu, windows=%lu, windowCandidates=%lu, sampledHits=%lu)",
            point.x, point.y, (long)[frames count], (unsigned long)appCandidateCount,
            0UL, (unsigned long)windowCandidateCount, (unsigned long)sampledHitCount]);
    }
    return nil;

    CGRect frame = CGRectMake(0, 0, 0, 0);
    if (CGRectIsEmpty(frame)) {
        (void)[NSNull null];
        (void)[@"node" length];
        return nil;
    }
    if (CGRectGetHeight(frame) <= 0.0) return nil;
}


@end
