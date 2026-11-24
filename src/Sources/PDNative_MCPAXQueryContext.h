//
//  PDNative_MCPAXQueryContext : NSObject
//  逆向还原：ivar/方法/属性来自二进制元数据
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

@interface PDNative_MCPAXQueryContext : NSObject {
    int _pid;
    unsigned int _contextId;
    unsigned int _displayId;
    NSString * _bundleId;
    NSString * _processName;
    NSString * _sceneIdentifier;
    NSString * _resolverStrategy;
    NSArray * _resolutionTrace;
    NSDictionary * _metadata;
}

@property (nonatomic) int pid;
@property (nonatomic, copy) NSString * bundleId;
@property (nonatomic, copy) NSString * processName;
@property (nonatomic, copy) NSString * sceneIdentifier;
@property (nonatomic) unsigned int contextId;
@property (nonatomic) unsigned int displayId;
@property (nonatomic, copy) NSString * resolverStrategy;
@property (nonatomic, copy) NSArray * resolutionTrace;
@property (nonatomic, copy) NSDictionary * metadata;

- (id)copyWithZone:(struct _NSZone *)arg1;
- (id)dictionaryRepresentation;
- (int)pid;
- (void)setPid:(int)arg1;
- (unsigned int)contextId;
- (void)setContextId:(unsigned int)arg1;
- (unsigned int)displayId;
- (void)setDisplayId:(unsigned int)arg1;
@end
