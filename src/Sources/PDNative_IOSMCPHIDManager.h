//
//  PDNative_IOSMCPHIDManager : NSObject
//  逆向还原：ivar/方法/属性来自二进制元数据
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

struct __IOHIDEvent;

@interface PDNative_IOSMCPHIDManager : NSObject {
    struct __IOHIDEventSystemClient * _hidClient;
    NSObject<OS_dispatch_queue> * _hidQueue;
    double _screenScale;
    double _screenWidth;
    double _screenHeight;
}

- (id)init;
- (void)pressButton:(unsigned long long)arg1 duration:(double)arg2 completion:(void (^)(BOOL success, NSError *error))arg3;
- (BOOL)sendKeyboardEventWithPage:(unsigned int)arg1 usage:(unsigned int)arg2 down:(BOOL)arg3 error:(NSError **)arg4;
- (BOOL)postHIDEvent:(struct __IOHIDEvent *)arg1 error:(NSError **)arg2;
- (BOOL)performTouchAtPoint:(CGPoint)arg1 phase:(unsigned long long)arg2 error:(NSError **)arg3;
- (void)sendTouchAtPoint:(CGPoint)arg1 phase:(unsigned long long)arg2;
- (BOOL)performTapSequenceAtPoint:(CGPoint)arg1 error:(NSError **)arg2;
- (void)tapAtPoint:(CGPoint)arg1 completion:(void (^)(BOOL success, NSError *error))arg2;
- (void)swipeFromPoint:(CGPoint)arg1 toPoint:(CGPoint)arg2 duration:(double)arg3 steps:(long long)arg4 completion:(void (^)(BOOL success, NSError *error))arg5;
- (void)longPressAtPoint:(CGPoint)arg1 duration:(double)arg2 completion:(void (^)(BOOL success, NSError *error))arg3;
- (void)doubleTapAtPoint:(CGPoint)arg1 interval:(double)arg2 completion:(void (^)(BOOL success, NSError *error))arg3;
- (void)dragAlongPoints:(id)arg1 holdDuration:(double)arg2 moveDuration:(double)arg3 steps:(long long)arg4 completion:(void (^)(BOOL success, NSError *error))arg5;
- (void)dragFromPoint:(CGPoint)arg1 toPoint:(CGPoint)arg2 holdDuration:(double)arg3 moveDuration:(double)arg4 steps:(long long)arg5 completion:(void (^)(BOOL success, NSError *error))arg6;
+ (id)sharedInstance;
@end
