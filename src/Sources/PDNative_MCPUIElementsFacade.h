//
//  PDNative_MCPUIElementsFacade.h — 逆向还原
//
//  AX 组的统一出口：把「谁去查、查不到怎么解释」收在一处。
//  实例 32 字节，3 个 ivar（contextResolver / serializer / directElementProvider）。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

/// 直连 AX 的取元素回调：(context, point, &error) → 原始节点字典。
/// 出参是 id*（错误可能是 NSError 也可能是字符串），与二进制一致。
typedef id (^PDDirectElementProvider)(PDNative_MCPAXQueryContext *context,
                                      CGPoint point,
                                      id *error);

@interface PDNative_MCPUIElementsFacade : NSObject {
    PDNative_MCPAXRemoteContextResolver * _contextResolver;
    PDNative_MCPUIElementSerializer * _serializer;
    PDDirectElementProvider _directElementProvider;
}

@property (nonatomic, strong) PDNative_MCPAXRemoteContextResolver * contextResolver;
@property (nonatomic, strong) PDNative_MCPUIElementSerializer * serializer;
@property (nonatomic, copy) PDDirectElementProvider directElementProvider;

- (id)initWithContextResolver:(PDNative_MCPAXRemoteContextResolver *)resolver
                   serializer:(PDNative_MCPUIElementSerializer *)serializer
        directElementProvider:(PDDirectElementProvider)provider;

/// 206 指令。命中测试主入口：拿前台上下文 → 试直连 provider → 归一化 → 装饰诊断信息。
/// error 出参是 id*：失败时存的是说明字符串（类型编码 `^@`）。
- (id)elementAtPoint:(CGPoint)point error:(id *)error;

/// 153 指令。把 provider 诊断信息（谁成功、试过谁、各自报了什么错）挂到结果上。
- (id)decorateResult:(id)result
        providerUsed:(NSString *)providerUsed
  attemptedProviders:(NSArray<NSString *> *)attempted
      providerErrors:(NSArray<NSString *> *)errors
           queryKind:(NSString *)queryKind;

/// 528 指令。把 accessibilityState 里的一堆运行时指标拼成一行人类可读的后缀。
- (NSString *)accessibilityStateErrorSuffixForContext:(PDNative_MCPAXQueryContext *)context;

@end
