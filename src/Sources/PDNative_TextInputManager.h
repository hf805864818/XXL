//
//  PDNative_TextInputManager.h
//  PetDFY
//
//  逐指令还原自 PetDFY.arm64e.dylib
//  类对象 0x123a20 / 元类 0x123a20 邻域, class_ro_t 0x11d3f0
//
//  ivar 布局（Observed，__objc_ivar 元数据 + 反汇编访问点一致）:
//    offset  8 : _hidClient   -> ^{__IOHIDEventSystemClient=}   ldr x8,[x20,8] @0x847fc
//    offset 16 : _inputQueue  -> @"NSObject<OS_dispatch_queue>"   ldr x23,[x22,0x10] @0x85ad4
//
//  方法集（8 实例 + 1 类方法 + .cxx_destruct），一个不多一个不少:
//    + sharedInstance   0x84488  dispatch_once + objc_retainAutoreleaseReturnValue
//                                （单例槽 0x124270，once token 0x124278，init 块 0x844dc）
//    - init             0x84518  （先建队列写 +0x10，再建 HID client 写 +0x08）
//    - typeTextViaHID:delayMs:                                          B32@0:8@16d24
//    - dispatchUnicodeTextChunk:targetPid:error:                        B36@0:8@16i24^@28
//    - sendTextUsingUnicodeHID:delayMs:characterByCharacter:error:      B44@0:8@16d24B32^@36
//    - inputText:completion:                                            v32@0:8@16@?24
//    - typeText:delayMs:completion:                                     v40@0:8@16d24@?32
//    - pressKey:completion:                                             v32@0:8@16@?24
//    - sendKeyEvent:usage:down:                                         v28@0:8I16I20B24
//    - .cxx_destruct    0x85d94  只 objc_storeStrong(&_inputQueue, nil)，不 CFRelease _hidClient
//

#import <Foundation/Foundation.h>

#ifndef PD_IOHID_TYPES_DEFINED
#define PD_IOHID_TYPES_DEFINED
// IOKit 私有 HID 类型的等价前置声明（二进制里 ivar 编码即 ^{__IOHIDEventSystemClient=}）
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDEvent *IOHIDEventRef;
#endif

@interface PDNative_TextInputManager : NSObject {
    // offset 8 —— IOHIDEventSystemClientCreate(kCFAllocatorDefault) 的产物，_hidClient
    IOHIDEventSystemClientRef _hidClient;
    // offset 16 —— dispatch_queue_create("com.witchan.ios-mcp.textinput", NULL) 的产物
    NSObject<OS_dispatch_queue> *_inputQueue;
}

+ (instancetype)sharedInstance;

// 键盘（HID page 7）逐字符输入，返回是否全部发出
- (BOOL)typeTextViaHID:(NSString *)text delayMs:(double)delayMs;

// 把一段文本编码成 IOHID 的 Unicode 事件投递给 targetPid；失败填 *error
// error 实际是 NSString *（二进制直接 str CFString 到 x27），不是 NSError。
- (BOOL)dispatchUnicodeTextChunk:(NSString *)chunk
                       targetPid:(int)targetPid
                           error:(NSString **)error;

// Unicode HID 通路；characterByCharacter = YES 时逐字符投递并 sleep
- (BOOL)sendTextUsingUnicodeHID:(NSString *)text
                        delayMs:(double)delayMs
           characterByCharacter:(BOOL)characterByCharacter
                          error:(NSString **)error;

// 投递到 _inputQueue 的异步入口
- (void)inputText:(NSString *)text completion:(void (^)(BOOL success, id message))completion;
- (void)typeText:(NSString *)text delayMs:(double)delayMs completion:(void (^)(BOOL success, id message))completion;

// 单键（HID usage page 7 的 usage 值），completion 在主队列回调
// 键名先转小写（0x85a44 lowercaseString），未知键走 completion(NO, message)。
// 第二参数：失败路径是 +[NSString stringWithFormat:@"Unknown key: %@"] 的结果（0x85c14→0x85c30），
// 成功路径是 nil（0x85c98 x2 = 0）。二进制里的块签名串未稳定定位（候选
// v20@?0B8@"NSError"12 @0xbbc69 与 v20@?0B8@"NSString"12 @0xbe8e7 都在本 dylib 内），
// 故按 id 声明 —— 不影响调用约定。
- (void)pressKey:(NSString *)key completion:(void (^)(BOOL success, id message))completion;

// 最底层：一次 key-down / key-up。usage 为 HID keyboard usage（page 7）
- (void)sendKeyEvent:(unsigned int)key usage:(unsigned int)usage down:(BOOL)down;

@end
