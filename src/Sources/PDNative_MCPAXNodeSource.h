//
//  PDNative_MCPAXNodeSource : NSObject
//  逆向还原：ivar/方法/属性来自二进制元数据
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

@interface PDNative_MCPAXNodeSource : NSObject {
    double _queryDeadline;
    PDNative_MCPAXAttributeBridge * _attributeBridge;
}

@property (nonatomic, strong) PDNative_MCPAXAttributeBridge * attributeBridge;
@property (nonatomic) double queryDeadline;

- (id)initWithAttributeBridge:(PDNative_MCPAXAttributeBridge *)arg1;
- (id)elementAtPoint:(CGPoint)arg1 pid:(int)arg2 contextId:(unsigned int)arg3 displayId:(unsigned int)arg4 allowParameterizedHitTest:(BOOL)arg5 error:(NSError **)arg6;
- (id)serializeRemoteElementLeaf:(struct __AXUIElement *)arg1;
- (id)snapshotProbeCandidatesForElement:(struct __AXUIElement *)arg1 baseLabel:(id)arg2 includeFirstElement:(BOOL)arg3 includeVisibleCandidates:(unsigned long long)arg4;
- (id)serializeNumericLeafElement:(struct __AXUIElement *)arg1;
- (id)serializeCompactLeafElement:(struct __AXUIElement *)arg1 pid:(int)arg2 bundleId:(id)arg3 screenBounds:(CGRect)arg4 visibleOnly:(BOOL)arg5 clickableOnly:(BOOL)arg6;
- (id)compactElementsForPid:(int)arg1 bundleId:(id)arg2 contextId:(unsigned int)arg3 displayId:(unsigned int)arg4 maxElements:(long long)arg5 visibleOnly:(BOOL)arg6 clickableOnly:(BOOL)arg7 error:(NSError **)arg8;
- (id)buildNumericElementAtPoint:(CGPoint)arg1 pid:(int)arg2 contextId:(unsigned int)arg3 displayId:(unsigned int)arg4 error:(NSError **)arg5;
- (id)serializeRemoteElement:(struct __AXUIElement *)arg1 depth:(long long)arg2 maxDepth:(long long)arg3 count:(long long *)arg4 maxElements:(long long)arg5 visited:(id)arg6;
- (double)queryDeadline;
- (void)setQueryDeadline:(double)arg1;
- (PDNative_MCPAXAttributeBridge *)attributeBridge;
- (void)setAttributeBridge:(PDNative_MCPAXAttributeBridge *)arg1;
@end
