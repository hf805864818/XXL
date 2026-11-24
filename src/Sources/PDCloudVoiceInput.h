//
//  PDCloudVoiceInput.h
//  PetDFY
//
//  云端语音输入采集器。
//
//  本文件按 PetDFY.arm64e.dylib（1.2.1，arm64e）逐指令还原：
//  实例方法 0x22ea8–0x25010，instanceSize 0xC8，ivar 0x08–0xC0。
//  方法集与 ivar 布局与二进制一一对应，无多余声明。
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>

#import "PDVoiceServiceConnection.h"

@interface PDCloudVoiceInput : NSObject {
@public
    /* ivar 布局对齐二进制 instanceSize 0xC8。
       声明为 @public 是为了让 PDChatController.h 里的
       `PDCloudVoiceInput * _dictation;` 能通过 @class 前向声明直接编过（本工程无 PCH）。
       对外仍只走属性，不直接碰 ivar。 */
}

#pragma mark - 属性（7/7，与二进制 props 表一一对应）

/// 0x98  B16@0:8 / v20@0:8B16   getter 手写：ldrb w0,[x0,0x98]
@property (nonatomic, assign, getter=isActive)    BOOL active;
/// 0x99  B16@0:8 / v20@0:8B16   getter 手写：ldrb w0,[x0,0x99]
@property (nonatomic, assign, getter=isFinishing) BOOL finishing;
/// 0xa0  @\"NSString\",C,N
@property (nonatomic, copy)   NSString *transcript;
/// 0xa8  @\"NSError\",&,N
@property (nonatomic, strong) NSError  *startError;
/// 0xb0  @?,C,N — 二进制调用点只传一个参数：text
@property (nonatomic, copy) void (^textHandler)(NSString *text);
/// 0xb8  @?,C,N — 二进制调用点只传一个 BOOL
@property (nonatomic, copy) void (^stateHandler)(BOOL active);
/// 0xc0  @?,C,N — setter 手写（2 条：直接 str x2,[x0,0xc0]，不 copy）
@property (nonatomic, copy) void (^completionHandler)(NSString *transcript, NSError *error);

/// 0x23074  B24@0:8@16
/// 权限检查通过后启动一次采集；失败原因写入 startError。仅主线程、非 active 时生效。
- (BOOL)startWithLanguage:(NSString *)language;

/// 0x23060  B24@0:8Q16
/// generation 是否仍等于当前 _epoch（取消/重启后旧回调据此自行作废）。
- (BOOL)current:(uint64_t)generation;

/// 0x23798  v16@0:8
/// 配置 AVAudioSession、建 AudioQueue、起 timer。只在 _workQueue 上调用。
- (void)beginCapture;

/// 0x2420c  v16@0:8
/// 请求正常收尾：置 finishing、通知 stateHandler，然后排空采集尾部。
- (void)finish;

/// 0x2461c  v16@0:8
/// 停止接收 PCM 并让 service 出 final。只在 _workQueue 上调用。
- (void)flushCaptureTail;

/// 0x24a08  v16@0:8
/// 取消，无回调。
- (void)cancel;

/// 0x24a10  v24@0:8@?16
/// 取消；completion 是**零参**块，cleanupOnQueue 之后被 dispatch 到主线程（不传实参）。
/// Observed @0x24b18（cleanup）/ @0x24b20（ldr x8,[block,0x28] → dispatch_async(main_q, completion)）。
- (void)cancelWithCompletion:(void (^)(void))completion;

@end
