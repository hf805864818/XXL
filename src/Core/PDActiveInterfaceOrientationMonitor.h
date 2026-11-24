//
//  PDActiveInterfaceOrientationMonitor : NSObject
//  逆向还原：ivar/方法/属性来自二进制元数据
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

@interface PDActiveInterfaceOrientationMonitor : NSObject {
    BOOL _registeredAsObserver;
    long long _activeInterfaceOrientation;
    void (^_changeHandler)(UIInterfaceOrientation, double);
    id _springBoardApplication;
}

@property (nonatomic) long long activeInterfaceOrientation;
@property (nonatomic, strong) id springBoardApplication;
@property (nonatomic) BOOL registeredAsObserver;
@property (nonatomic, copy) void (^changeHandler)(UIInterfaceOrientation, double);

- (id)init;
- (void)pd_start;
- (void)pd_refresh;
- (long long)pd_readActiveInterfaceOrientation;
- (void)pd_updateOrientation:(long long)arg1 duration:(double)arg2 notify:(BOOL)arg3;
- (void)activeInterfaceOrientationWillChangeToOrientation:(long long)arg1;
- (void)activeInterfaceOrientationDidChangeToOrientation:(long long)arg1 willAnimateWithDuration:(double)arg2 fromOrientation:(long long)arg3;
- (void)dealloc;
- (long long)activeInterfaceOrientation;
- (void)setActiveInterfaceOrientation:(long long)arg1;
- (void (^)(UIInterfaceOrientation, double))changeHandler;
- (void)setChangeHandler:(void (^)(UIInterfaceOrientation, double))arg1;
- (BOOL)registeredAsObserver;
- (void)setRegisteredAsObserver:(BOOL)arg1;
@end
