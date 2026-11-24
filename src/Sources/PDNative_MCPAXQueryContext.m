//
//  PDNative_MCPAXQueryContext.m
//  PetDFY 1.2.1 逆向还原
//
//  反汇编（class PDNative_MCPAXQueryContext，20 个方法 / 634 指令）
//  角色：一次 AX 查询的「上下文快照」——把 pid / bundleId / 场景 ID /
//        contextId / displayId 和解析策略打包，供 MCP 侧回放与诊断。
//  纯数据类，无副作用；唯一有逻辑的是 copyWithZone: 与 dictionaryRepresentation。
//

#import "PDNative_MCPAXQueryContext.h"

@implementation PDNative_MCPAXQueryContext

#pragma mark - 存取器

// Observed（0xb0700–0xb07d0）：9 组 getter/setter 均为 8 条以内的直接读写，
// 与 @synthesize 生成物一致，这里交给自动合成，不手写。

#pragma mark - 复制

// Observed（0x87d70，68 指令）：
//   [[[self class] allocWithZone:zone] init] 后逐个走 setter。
//   走 setter 而不是 ivar 直拷，说明依赖 setter 的 copy 语义（字符串深拷贝）。
- (id)copyWithZone:(struct _NSZone *)zone {
    PDNative_MCPAXQueryContext *copy =
        [[[self class] allocWithZone:zone] init];
    copy.pid = self.pid;
    copy.contextId = self.contextId;
    copy.displayId = self.displayId;
    copy.bundleId = self.bundleId;
    copy.processName = self.processName;
    copy.sceneIdentifier = self.sceneIdentifier;
    copy.resolverStrategy = self.resolverStrategy;
    copy.resolutionTrace = self.resolutionTrace;
    copy.metadata = self.metadata;
    return copy;
}

#pragma mark - 序列化

// Observed（0x87eb0，190 指令）：
//   逐字段「有值才写」——字符串看 length>0，数值看 !=0，容器看 count>0。
//   两个细节照抄：
//   1) processName 写两次，第二次用别名键 "name"（同一对象，非拷贝）；
//   2) pid 只在 > 0 时写（0 与负值都跳过），contextId/displayId 只在 != 0 时写。
- (id)dictionaryRepresentation {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];

    if (self.pid > 0) {
        dict[@"pid"] = @(self.pid);
    }
    if (self.bundleId.length > 0) {
        dict[@"bundleId"] = self.bundleId;
    }
    if (self.processName.length > 0) {
        dict[@"processName"] = self.processName;
        dict[@"name"] = self.processName;
    }
    if (self.sceneIdentifier.length > 0) {
        dict[@"sceneIdentifier"] = self.sceneIdentifier;
    }
    if (self.contextId != 0) {
        dict[@"contextId"] = @(self.contextId);
    }
    if (self.displayId != 0) {
        dict[@"displayId"] = @(self.displayId);
    }
    if (self.resolverStrategy.length > 0) {
        dict[@"resolverStrategy"] = self.resolverStrategy;
    }
    if (self.resolutionTrace.count > 0) {
        dict[@"resolutionTrace"] = self.resolutionTrace;
    }
    if (self.metadata.count > 0) {
        dict[@"metadata"] = self.metadata;
    }

    return dict;
}

#pragma mark - 生命周期

// Observed（0xb07d8）：.cxx_destruct，5 个对象 ivar 置 nil。
// [无法验证] 反汇编全文只含 9 个 dealloc，其余被工具链折叠。此实现按 ivar 布局推断。
- (void)dealloc {
    // ARC 下自动生成，此处仅记录反汇编事实。
}

#pragma mark - 二进制存取器（逐条 8-16 指令，纯 ivar 读写）
- (void)setBundleId:(id)v { _bundleId = v; }
- (void)setProcessName:(id)v { _processName = v; }
- (void)setSceneIdentifier:(id)v { _sceneIdentifier = v; }
- (void)setContextId:(unsigned int)v { _contextId = v; }
- (void)setDisplayId:(unsigned int)v { _displayId = v; }
- (void)setResolverStrategy:(id)v { _resolverStrategy = v; }
- (void)setResolutionTrace:(id)v { _resolutionTrace = v; }
- (void)setMetadata:(id)v { _metadata = v; }

#pragma mark - 二进制存取器（逐条 8-16 指令，纯 ivar 读写）
- (id)bundleId { return _bundleId; }
- (id)processName { return _processName; }
- (id)sceneIdentifier { return _sceneIdentifier; }
- (unsigned int)contextId { return _contextId; }
- (unsigned int)displayId { return _displayId; }
- (id)resolverStrategy { return _resolverStrategy; }
- (id)resolutionTrace { return _resolutionTrace; }
- (id)metadata { return _metadata; }

@end
