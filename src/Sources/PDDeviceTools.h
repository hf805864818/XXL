//
//  PDDeviceTools : NSObject
//  逆向还原：ivar/方法/属性来自二进制元数据
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

@interface PDDeviceTools : NSObject {
    BOOL _inFlight;
    void (^_prepareHandler)(void);
    NSObject<OS_dispatch_queue> * _queue;
    PDDeviceNativeExecutor * _executor;
    unsigned long long _generation;
    NSMutableDictionary * _tools;
}

@property (nonatomic, strong) NSObject<OS_dispatch_queue> * queue;
@property (nonatomic, strong) PDDeviceNativeExecutor * executor;
@property (nonatomic) unsigned long long generation;
@property (nonatomic) BOOL inFlight;
@property (nonatomic, copy) void (^prepareHandler)(void);

- (id)init;
- (void)cancel;
- (void)execute:(NSString *)arg1 arguments:(NSDictionary *)arg2 completion:(void (^)(BOOL ok, NSDictionary *result))arg3;
- (void (^)(void))prepareHandler;
- (void)setPrepareHandler:(void (^)(void))arg1;
- (unsigned long long)generation;
- (void)setGeneration:(unsigned long long)arg1;
- (BOOL)inFlight;
- (void)setInFlight:(BOOL)arg1;
@end
