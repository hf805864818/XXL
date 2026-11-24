//
//  PDNative_MCPUIElementSerializer.h — 逆向还原
//
//  AX 组的序列化基础层：把 AXRuntime 的原始节点树压成给模型看的扁平字典。
//  无 ivar（实例大小 8 字节），纯函数式，可被任意线程调用。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

@interface PDNative_MCPUIElementSerializer : NSObject {
}

/// 437 指令。命中测试结果 → 单个元素字典（含 queryPoint / queryContext / resolverMetadata）。
- (NSDictionary *)normalizedElementFromRawElement:(NSDictionary *)raw
                                          context:(PDNative_MCPAXQueryContext *)context
                                            point:(CGPoint)point;

/// 1514 指令。递归序列化一棵 AX 节点树，产出扁平化的 children 数组。
- (NSDictionary *)normalizedNodeFromRawNode:(NSDictionary *)rawNode
                                 stablePath:(NSString *)stablePath
                                   parentId:(NSString *)parentId
                        inheritedContextId:(unsigned int)inheritedContextId
                        inheritedDisplayId:(unsigned int)inheritedDisplayId
                                 rootSource:(NSString *)rootSource
                                    context:(PDNative_MCPAXQueryContext *)context;

/// 104 指令。节点自身的 contextId，回退到继承值，再回退到 context.contextId。
- (unsigned int)contextIdentifierForNode:(NSDictionary *)node
                       inheritedContextId:(unsigned int)inheritedContextId
                                 context:(PDNative_MCPAXQueryContext *)context;

/// 104 指令。同上，displayId 版本。
- (unsigned int)displayIdentifierForNode:(NSDictionary *)node
                       inheritedDisplayId:(unsigned int)inheritedDisplayId
                                 context:(PDNative_MCPAXQueryContext *)context;

/// 345 指令。生成稳定的 element_id（pid / ctx / path / role / 标签 / frame 拼接）。
- (NSString *)elementIdentifierForNode:(NSDictionary *)node
                            stablePath:(NSString *)stablePath
                               context:(PDNative_MCPAXQueryContext *)context
                             contextId:(unsigned int)contextId;

/// 319 指令。把 NSValue(CGRect) / 字典{x,y,width,height} / "{{x,y},{w,h}}" / 四元数组
/// 统一成 {x,y,width,height}（整数点）。
- (NSDictionary *)normalizedFrameFromObject:(id)object;

@end
