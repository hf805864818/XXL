//
//  PDPreferences : NSObject
//  逆向还原：ivar/方法/属性来自二进制元数据
//
//  与二进制对齐说明（v2）：
//   - 二进制 domain = com.susudear.petdfyprefs
//   - 二进制只有 init / reload / 15 个 getter / .cxx_destruct
//   - 二进制没有任何 setter，写入由设置面板侧完成
//   - +shared 与 -stringForKey:fallback: 在二进制中不存在，
//     为尚未重写的调用点（PDChatController / PDAIPetRuntime）暂留，
//     见 RATIO_AUDIT.md「PDPreferences 修复记录」
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

@interface PDPreferences : NSObject {
    BOOL _enabled;
    BOOL _interactive;
    BOOL _responsive;
    BOOL _soundEnabled;
    BOOL _stroking;
    BOOL _keyboardAvoidanceEnabled;
    double _size;
    double _bottomInset;
    double _keyboardAvoidanceExtra;
    long long _framesPerSecond;
    NSString * _scheme;
    NSString * _outfit;
    NSString * _roam;
    NSString * _doubleTapAction;
    NSString * _longPressAction;
}

@property (nonatomic, readonly) BOOL enabled;
@property (nonatomic, readonly) BOOL interactive;
@property (nonatomic, readonly) BOOL responsive;
@property (nonatomic, readonly) BOOL soundEnabled;
@property (nonatomic, readonly) BOOL stroking;
@property (nonatomic, readonly) double size;
@property (nonatomic, readonly) double bottomInset;
@property (nonatomic, readonly) BOOL keyboardAvoidanceEnabled;
@property (nonatomic, readonly) double keyboardAvoidanceExtra;
@property (nonatomic, readonly) long long framesPerSecond;
@property (nonatomic, readonly, copy) NSString * scheme;
@property (nonatomic, readonly, copy) NSString * outfit;
@property (nonatomic, readonly, copy) NSString * roam;
@property (nonatomic, readonly, copy) NSString * doubleTapAction;
@property (nonatomic, readonly, copy) NSString * longPressAction;

- (id)init;
- (void)reload;

// ---- 兼容层：二进制中这些是内联的全局 C 调用，类方法本身不存在 ----
// 保留原因：PDChatController / PDAIPetRuntime 尚有调用点未重写。
// 实现走真实 domain（com.susudear.petdfyprefs），读写语义与二进制一致。
+ (instancetype)shared;                                                        // [非二进制]
- (NSString *)stringForKey:(NSString *)key fallback:(NSString *)fallback;      // [非二进制]
- (BOOL)boolForKey:(NSString *)key fallback:(BOOL)fallback;                    // [非二进制]
- (double)doubleForKey:(NSString *)key fallback:(double)fallback;              // [非二进制]
- (long long)integerForKey:(NSString *)key fallback:(long long)fallback
                       min:(long long)lo max:(long long)hi;                    // [非二进制]
- (void)setString:(NSString *)value forKey:(NSString *)key;                    // [非二进制]
- (void)setDouble:(double)value forKey:(NSString *)key;                        // [非二进制]

@end
