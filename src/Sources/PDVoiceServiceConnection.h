//
//  PDVoiceServiceConnection.h
//  PetDFY
//
//  还原自 PetDFY.arm64e.dylib —— 类 PDVoiceServiceConnection（instanceSize=64）
//
//  职责：以 Unix socketpair 拉起子进程 petdfy-voice，用 5 字节帧头 + JSON/裸 PCM
//  做双向通讯。这是桌宠发声的唯一出口，语音合成全部在 helper 侧完成。
//
//  线协议（Observed，见 .m 里的帧常量）：
//      请求帧 = [u32 BE payloadLen][u8 type][payload]
//          type 1 = command（JSON），2 = PCM（裸字节），3 = finish（空）
//          payloadLen 含 type 字节本身，即 payloadLen = payload.length + 1
//      事件帧 = [u32 BE payloadLen][u8 type=0][JSON]
//

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

/// 帧类型。数值取自 writeFrame/sendPCM/finish 里立即数写入帧头第 5 字节的位置。
typedef NS_ENUM(uint8_t, PDVoiceFrameType) {
    PDVoiceFrameTypeEvent   = 0,   ///< helper → 客户端，payload 是 JSON
    PDVoiceFrameTypeCommand = 1,   ///< 客户端 → helper，payload 是 JSON
    PDVoiceFrameTypePCM     = 2,   ///< 客户端 → helper，payload 是裸 PCM
    PDVoiceFrameTypeFinish  = 3,   ///< 客户端 → helper，payload 为空
};

/// startCommand: 的命令码。取自各调用点 w2 的立即数。
typedef NS_ENUM(uint8_t, PDVoiceCommand) {
    PDVoiceCommandStart        = 1,   ///< startWithModel:traditional:
    PDVoiceCommandAssetRequest = 4,   ///< startAssetRequest:
    PDVoiceCommandAsset        = 4
};

/// 帧长度上限。两端一致：写入侧 pendingBytes 超过 128 KB 直接 fail，
/// 读取侧 input 缓冲超过 128 KB 也直接 fail（错误码 4）。
extern const NSUInteger PDVoiceServiceMaxFrameBytes;

@interface PDVoiceServiceConnection : NSObject

/// 事件回调。参数是 NSDictionary（事件体），错误路径下是 NSError。
@property (nonatomic, copy) void (^eventHandler)(id event);

@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) dispatch_io_t channel;
@property (nonatomic, strong) dispatch_source_t processSource;
@property (nonatomic, strong) NSMutableData *input;
@property (nonatomic, assign) pid_t pid;
@property (nonatomic, assign) BOOL stopped;
@property (nonatomic, assign) BOOL finalReceived;
@property (nonatomic, assign) BOOL ready;
@property (nonatomic, assign) BOOL assetOperation;
@property (nonatomic, assign) NSUInteger pendingBytes;

- (instancetype)initWithQueue:(dispatch_queue_t)queue;

/// 拉进程 + 建通道 + 发 Start 命令。返回 NO 表示前置门被挡或 spawn 失败。
- (BOOL)startWithModel:(NSString *)model traditional:(BOOL)traditional;

- (BOOL)startAssetOperation:(NSString *)operation;
- (BOOL)startAssetOperation:(NSString *)operation URL:(NSString *)url;
- (BOOL)startAssetRequest:(NSDictionary *)request;

/// 发一帧命令。payload 会走 JSON 序列化；失败时内部已调用 fail:。
- (BOOL)startCommand:(uint8_t)command payload:(NSDictionary *)payload;

/// 从 _input 里尽量多解帧并派发给 eventHandler。读到不完整帧就原地返回。
- (void)parseEvents;

- (void)writeFrame:(NSData *)frame;
- (void)sendPCM:(NSData *)pcm;
- (void)finish;

- (NSError *)fail:(NSError *)error;
- (void)cancel;

- (void)sendEvent:(NSData *)json;
@end
