//
//  PDNative_AccessibilityManager : NSObject
//  逆向还原：ivar/方法/属性来自二进制元数据
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

@interface PDNative_AccessibilityManager : NSObject {
    NSObject<OS_dispatch_queue> * _axQueue;
    BOOL _queryInFlight;
    PDNative_MCPAXAttributeBridge * _axAttributeBridge;
    PDNative_MCPAXNodeSource * _axNodeSource;
    PDNative_MCPAXRemoteContextResolver * _contextResolver;
    PDNative_MCPUIElementSerializer * _uiElementSerializer;
    PDNative_MCPUIElementsFacade * _uiElementsFacade;
}

- (id)init;
- (id)directAXElementAtPoint:(CGPoint)arg1 pid:(int)arg2 contextId:(unsigned int)arg3 displayId:(unsigned int)arg4 error:(NSError **)arg5;
- (BOOL)hasOutstandingQuery;
- (id)compactPayloadForContext:(PDNative_MCPAXQueryContext *)arg1 maxElements:(long long)arg2 visibleOnly:(BOOL)arg3 clickableOnly:(BOOL)arg4 error:(NSError **)arg5;
- (void)performQuery:(id (^)(NSError **error))arg1 completion:(void (^)(NSDictionary *payload, NSError *error))arg2;
- (void)getCompactUIElementsWithMaxElements:(long long)arg1 visibleOnly:(BOOL)arg2 clickableOnly:(BOOL)arg3 completion:(void (^)(NSDictionary *payload, NSError *error))arg4;
- (void)getElementAtPoint:(CGPoint)arg1 completion:(void (^)(NSDictionary *payload, NSError *error))arg2;
- (id)frontmostApplicationInfo;
+ (id)sharedInstance;
@end
