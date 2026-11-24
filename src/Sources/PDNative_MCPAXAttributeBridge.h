#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ApplicationServices/ApplicationServices.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * AX 桥接层：把 AXUIElement 的同步 API 包成可判错、可诊断的读取接口。
 *
 * 命中测试三条路，按开销从低到高：
 *   1) AXUIElementCopyElementAtPosition（公共，很多进程不实现）
 *   2) 参数化属性 "hitTest"（私有，allowParameterized 才走）
 *   3) 上下文链 AXUIElementCopyElementUsingContextIdAtPosition（跨 UIScene / 多窗口）
 *
 * 所有 copy 前缀方法遵循 CF 所有权约定：返回对象由调用方持有，需自行 CFRelease。
 */
@interface PDNative_MCPAXAttributeBridge : NSObject

#pragma mark - 运行时闸门

/// 解析 AX 私有符号表。失败时 error 给出缺哪个符号，之后所有调用返回 nil。
- (BOOL)ensureRuntimeAvailable:(NSError **)error;

/// AX API 必须在主线程批量调用；非主线程走同步转投。
- (void)performOnMainThreadSync:(dispatch_block_t)block;

#pragma mark - 元素构造

/// 把本进程与目标 pid 的 AX 连接登记进系统级元素，否则跨进程 hitTest 会返回别的 app。
- (void)ensureAssociationWithRemotePid:(pid_t)pid;

/// create_application 包装。pid<=0 时返回 nil。
- (AXUIElementRef)copyApplicationElementForPid:(pid_t)pid error:(NSError **)error;

/// 系统级元素（AXUIElementCreateSystemWide）。
- (AXUIElementRef)copySystemWideElement;

/// 用 AXUIElementGetPid 反查归属进程。
- (BOOL)getPid:(int *)outPid fromElement:(AXUIElementRef)element;

/// AXError → 可读串（success/failure/illegal argument/...）。
- (NSString *)errorStringForAXError:(AXError)axError;

#pragma mark - 属性读取（批量）

/// 按属性名批量读，遇到不支持/无值的属性跳过而不是整体失败。
- (NSDictionary *)copyBoundedAttributes:(AXUIElementRef)element
                             attributes:(NSArray<NSString *> *)attributes
                                  error:(NSError **)error;

#pragma mark - 命中测试

/// 有界命中：只读 frame/label/role 等有限属性，避免整棵树快照。
- (AXUIElementRef)copyBoundedHitAtPoint:(CGPoint)point
                            application:(AXUIElementRef)application
                              contextId:(unsigned int)contextId
                            expectedPid:(pid_t)expectedPid
                                  error:(NSError **)error;

/// 上下文绑定：按 pid 找到承载它的 UIScene，返回该 scene 下的 app 元素。
- (AXUIElementRef)copyContextBoundApplicationElementForPid:(pid_t)pid
                                               diagnostics:(NSDictionary **)diagnostics
                                                     error:(NSError **)error;

/// 上下文链命中：枚举 display / UIScene contextId，逐个试 CopyElementUsingContextIdAtPosition。
- (AXUIElementRef)copyContextChainHitElementAtPoint:(CGPoint)point
                                        expectedPid:(pid_t)expectedPid
                                        diagnostics:(NSMutableDictionary *)diagnostics
                                              error:(NSError **)error;

/// 已知 contextId 的定向命中，失败不自动扩大范围。
- (AXUIElementRef)copyElementAtPoint:(CGPoint)point
                 usingKnownContextId:(unsigned int)contextId
                         expectedPid:(pid_t)expectedPid
                         diagnostics:(NSMutableDictionary *)diagnostics
                               error:(NSError **)error;

/// 单点 hitTest：公共 API → 参数化 hitTest → nil。
- (AXUIElementRef)copyHitTestElementAtPoint:(CGPoint)point
                                expectedPid:(pid_t)expectedPid
                         allowParameterized:(BOOL)allowParameterized
                                      error:(NSError **)error;

#pragma mark - 属性读取（单点 / 分层）

/// 直接 copyAttributeValue 包装，返回 nil 表示该属性不可读。
- (id)copyAttributeObject:(AXUIElementRef)element attribute:(CFStringRef)attribute;

/// 同上，支持 "key=AXLabel" 形式的外部键名。
- (NSDictionary *)copyAttributeMap:(AXUIElementRef)element
                        attributes:(NSArray<NSString *> *)attributes;

/// XCUITest 风格键（identifier/label/value/frame/traits/children）→ AX 属性。
- (NSDictionary *)copyXCAttributeMap:(AXUIElementRef)element
                       attributeKeys:(NSArray<NSString *> *)attributeKeys;

/// XCUITest 单键直读，attributeKey 不在映射表里时按字面当 AX 属性名。
- (id)copyXCAttributeObject:(AXUIElementRef)element attributeKey:(NSString *)attributeKey;

/// 数字属性 ID 直读（AXUIElementCopyAttributeValue 的 CFStringRef 位置传整数 ID）。
- (NSDictionary *)copyDirectAttributeMap:(AXUIElementRef)element
                           attributeKeys:(NSArray<NSString *> *)attributeKeys;

/// 单个数字属性 ID 直读。
- (id)copyDirectAttributeObject:(AXUIElementRef)element attributeKey:(NSString *)attributeKey;

/// 参数化属性：attributeKey 走数字 ID，parameter 走 AXValue/NSNumber 自动装箱。
- (id)copyXCParameterizedAttributeObject:(AXUIElementRef)element
                           attributeKey:(NSString *)attributeKey
                              parameter:(id)parameter;

/// 子树快照：label/identifier/role/value/enabled/frame/pid/children。
- (NSDictionary *)copyUserTestingSnapshotForElement:(AXUIElementRef)element
                                           options:(NSDictionary *)options;

/// 只探可用性，不返回树。用于能力自检。
- (NSDictionary *)probeUserTestingSnapshotForElement:(AXUIElementRef)element
                                            options:(NSDictionary *)options;

/// 数字 ID 批量读。
- (NSDictionary *)copyNumericAttributeMap:(AXUIElementRef)element
                               attributes:(NSArray<NSString *> *)attributes;

/// 数字 ID 读数组（例如 AXChildren 的 raw 值）。
- (NSArray<NSNumber *> *)copyNumericAttributeArray:(AXUIElementRef)element
                                      attributeId:(unsigned int)attributeId;

/// 子元素：先 AXChildren，空则退私有 privateChildren。
- (NSArray *)copyChildElementsForElement:(AXUIElementRef)element;

#pragma mark - 标量便捷读取

- (id)copyStringAttribute:(AXUIElementRef)element attribute:(CFStringRef)attribute;
- (id)copyNumberAttribute:(AXUIElementRef)element attribute:(CFStringRef)attribute;

@end

NS_ASSUME_NONNULL_END
