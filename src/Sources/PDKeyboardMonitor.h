//
//  PDKeyboardMonitor : NSObject
//  逆向还原：ivar/方法/属性来自二进制元数据
//  方法体来自 PetDFY.arm64e.dylib 反汇编（见各方法注释的 IMP 地址）
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

/// 键盘状态结构体。二进制 ivar 编码 `{?="visible"B"height"d"orientation"q}`，24 字节。
typedef struct PDKeyboardState {
    BOOL      visible;      // +0x00
    double    height;       // +0x08
    long long orientation;  // +0x10
} PDKeyboardState;

@interface PDKeyboardMonitor : NSObject {
    BOOL _hooked;
    void (^_changeHandler)(void);
    PDKeyboardState _state;
}

@property (nonatomic) PDKeyboardState state;
@property (nonatomic) BOOL hooked;
@property (nonatomic, copy) void (^changeHandler)(void);

- (void)start;
- (void)refresh;
- (void)acceptState:(PDKeyboardState)state;
+ (id)sharedMonitor;
@end
