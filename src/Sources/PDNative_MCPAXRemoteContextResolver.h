//
//  PDNative_MCPAXRemoteContextResolver.h — 逆向还原
//
//  AX 上下文解析器：判断「前台是谁」，并沿途记录解析轨迹与运行时诊断。
//  无 ivar（实例大小 8 字节），8 个 AXFrontBoardUtils 函数指针存在全局静态区。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

@interface PDNative_MCPAXRemoteContextResolver : NSObject {
}

/// 25 指令。frontmostContext 的字典形式（供直接序列化用）。
- (NSDictionary *)frontmostContextDictionary;

/// 181 指令。解析当前前台 App 的上下文：AXFrontBoard → SpringBoard → workspace → pid 兜底。
- (PDNative_MCPAXQueryContext *)frontmostContext;

#pragma mark - 填充路径（按优先级）

/// 721 指令。走 AXFrontBoardUtils 的私有 C 函数，按 8 个候选依次尝试。
- (BOOL)populateContext:(PDNative_MCPAXQueryContext *)context
  fromAXFrontBoardWithTrace:(NSMutableArray *)trace
               metadata:(NSMutableDictionary *)metadata;

/// 613 指令。从 SBApplication 对象取 pid / bundleId / 进程名。
- (void)populateContext:(PDNative_MCPAXQueryContext *)context
  fromApplicationObject:(id)application
        resolutionTrace:(NSMutableArray *)trace;

/// 77 指令。只按 pid 填。
- (void)populateContext:(PDNative_MCPAXQueryContext *)context
                fromPid:(int)pid
        resolutionTrace:(NSMutableArray *)trace;

/// 459 指令。从 FBSWorkspace 的 scene 里取 sceneIdentifier / contextId / displayId。
- (void)populateSceneFieldsForContext:(PDNative_MCPAXQueryContext *)context
                           fromTarget:(id)target
                      resolutionTrace:(NSMutableArray *)trace
                               prefix:(NSString *)prefix;

/// 876 指令。遍历 workspace 的 scene 列表找匹配的那个。
- (void)populateContext:(PDNative_MCPAXQueryContext *)context
  fromWorkspaceScenesWithTrace:(NSMutableArray *)trace
               metadata:(NSMutableDictionary *)metadata;

/// 563 指令。探测 VoiceOver / AssistiveTouch / registrar 状态，写进 metadata[@"accessibilityState"]。
- (void)populateAccessibilityActivationMetadata:(NSMutableDictionary *)metadata
                                        context:(PDNative_MCPAXQueryContext *)context
                                          trace:(NSMutableArray *)trace;

#pragma mark - 应用对象工具

/// 172 指令。候选值可能是数组、集合或单个对象，挑出最像 SBApplication 的那个。
- (id)preferredApplicationObjectFromCandidateValue:(id)candidate;

/// 185 指令。按 pid 找 SBApplication。
- (id)applicationObjectForPid:(int)pid resolutionTrace:(NSMutableArray *)trace;

/// 27 指令。context 是否已经有足够身份信息（pid + bundleId + processName）。
- (BOOL)contextHasIdentity:(PDNative_MCPAXQueryContext *)context;

/// 46 指令。老式 SpringBoard 的 _accessibilityFrontMostApplication。
- (id)legacyFrontmostApplicationObject;

#pragma mark - 选择子调用工具

/// 87 指令。安全地调一个返回对象的选择子。
- (id)invokeObjectSelector:(SEL)selector onTarget:(id)target;

/// 207 指令。安全地调一个返回数值的选择子。
- (id)invokeNumericSelector:(SEL)selector onTarget:(id)target;

/// 93 指令。按顺序试一批选择子，返回第一个正数。
- (id)firstPositiveNumericSelectorValueFromTarget:(id)target
                                        selectors:(NSArray<NSString *> *)selectors
                                  matchedSelector:(NSString **)matched;

/// 101 指令。按顺序试一批选择子，返回第一个非空字符串。
- (id)firstNonEmptyStringSelectorValueFromTarget:(id)target
                                       selectors:(NSArray<NSString *> *)selectors
                                 matchedSelector:(NSString **)matched;

/// 252 指令。从 SBApplication 对象里挖 pid（必要时按 bundleId 反查）。
- (int)pidFromApplicationObject:(id)application
                       bundleId:(NSString *)bundleId
                resolutionTrace:(NSMutableArray *)trace;

#pragma mark - 可用性

/// 178 指令。返回 AXFrontBoardUtils 的加载状态与 8 个符号是否可用。
- (NSDictionary *)axFrontBoardAvailability;

@end
