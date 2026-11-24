//
//  PDVoiceServiceConnection.m
//  PetDFY
//
//  还原自 PetDFY.arm64e.dylib —— PDVoiceServiceConnection（0x250b0–0x26a00，约 1,449 指令 / 35 方法）
//
//  类职责：TTS 语音合成 helper 进程（petdfy-voice）的本地 IPC 客户端。
//  链路：socketpair → posix_spawn(helper) → dispatch_io(读) + dispatch_source(PROC_EXIT)
//        → 5 字节帧头（u32 BE 长度 + u8 类型）→ JSON 事件回流。
//
//  帧协议（全部 Observed，取自 0x25730–0x25820 / 0x25c30–0x25d40 / 0x266c0–0x267b4）：
//
//      偏移 0..3   u32 大端 length = 1 + payloadLen（含类型字节自身）
//      偏移 4      u8  type
//      偏移 5..    payload
//
//      type 0 = 事件（helper → 客户端，JSON）    ← parseEvents 只接受 0
//      type 1 = 命令（客户端 → helper，JSON）    ← startCommand:payload: 写
//      type 2 = PCM  （客户端 → helper，裸字节）  ← sendPCM: 写
//      type 3 = 结束（客户端 → helper，空载荷）    ← finish 写
//
//  保真分级见文件末尾「还原保真账本」。
//

#import "PDVoiceServiceConnection.h"
#import <dlfcn.h>
extern char **environ;

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <sys/socket.h>
#import <sys/types.h>
#import <signal.h>
#import <spawn.h>
#import <unistd.h>
#import <string.h>
#import <stdlib.h>
#import <stdio.h>
#import <fcntl.h>
#import <errno.h>

// 越狱路径拼接（工程内已有同名 C++ 导出：_Z6jbrootP8NSString jbroot(NSString*)）
extern NSString *jbroot(NSString *path);

static NSString *const PDVoiceErrorDomain = @"PetDFY.VoiceService";

// 错误码（Observed：NSError errorWithDomain:code:userInfo: 的 w3 立即数）
enum {
    PDVoiceErrorSpawnFailed    = 1,   // 0x258a4 分支
    PDVoiceErrorProtocol       = 4,   // 0x25bd0 / 0x263f4：帧长越界、类型非 0、缓冲区超 128KB
    PDVoiceErrorBackpressure   = 6,   // 0x263f4：pendingBytes 超 128KB
    PDVoiceErrorJSON           = 5,   // 0x258c0 分支（推测同族，见账本）
};

// 缓冲上限（Observed：cmp 立即数）
static const NSUInteger PDVoiceMaxPendingBytes = 0x20000;   // 128 KB 写水位
static const NSUInteger PDVoiceMaxInputBytes   = 0x20000;   // 128 KB 读缓冲

// 帧类型
enum {
    PDVoiceFrameEvent  = 0,
    PDVoiceFrameCommand = 1,
    PDVoiceFramePCM    = 2,
    PDVoiceFrameFinish = 3,
};


@interface PDVoiceServiceConnection () {
    BOOL _stopped;
    BOOL _finalReceived;
    BOOL _ready;
    BOOL _assetOperation;
    int  _pid;
    id   _eventHandler;
    dispatch_queue_t _queue;
    dispatch_io_t _channel;
    dispatch_source_t _processSource;
    NSMutableData *_input;
    NSUInteger _pendingBytes;
}
@end

/// 二进制里没有 errorEventFromDictionary: / emitEvent: 这两个选择器——
/// 规范化与分发都内联在 parseEvents 里。这里收成 C 静态函数，方法表保持一致。
static NSDictionary *PDVoiceNormalizeErrorEvent(NSDictionary *event) {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];

    id stage = event[@"stage"];
    if ([stage isKindOfClass:[NSString class]] && [(NSString *)stage length] <= 0x40) {
        userInfo[@"stage"] = stage;
    }

    id domain = event[@"domain"];
    id code = event[@"code"];
    if ([domain isKindOfClass:[NSString class]] &&
        [(NSString *)domain length] <= 0x80 &&
        [code isKindOfClass:[NSNumber class]]) {
        NSError *underlying = [NSError errorWithDomain:(NSString *)domain
                                                  code:[code integerValue]
                                              userInfo:nil];
        userInfo[NSUnderlyingErrorKey] = underlying;
    }

    NSInteger outerCode = [code isKindOfClass:[NSNumber class]] ? [code integerValue] : 0;
    NSError *error = [NSError errorWithDomain:PDVoiceErrorDomain code:outerCode userInfo:userInfo];

    NSMutableDictionary *normalized = [NSMutableDictionary dictionaryWithDictionary:event];
    normalized[@"error"] = error;
    return normalized;
}

static void PDVoiceEmit(PDVoiceServiceConnection *self, NSDictionary *event) {
    void (^handler)(NSDictionary *) = [self eventHandler];
    if (handler) handler(event);
}

@implementation PDVoiceServiceConnection

@synthesize queue = _queue;
@synthesize channel = _channel;
@synthesize processSource = _processSource;
@synthesize input = _input;
@synthesize pid = _pid;
@synthesize stopped = _stopped;
@synthesize finalReceived = _finalReceived;
@synthesize ready = _ready;
@synthesize assetOperation = _assetOperation;
@synthesize pendingBytes = _pendingBytes;
@synthesize eventHandler = _eventHandler;

// 0x250b0：只做两件事——存队列、建空输入缓冲
- (instancetype)initWithQueue:(dispatch_queue_t)queue {
    self = [super init];
    if (self) {
        _queue = queue;
        _input = [NSMutableData data];
    }
    return self;
}

// 0x2513c：{"model": model ?: "iPhone", "traditional": @(traditional)}，走命令码 1
- (BOOL)startWithModel:(NSString *)model traditional:(BOOL)traditional {
    NSString *effective = model ?: @"iPhone";
    NSDictionary *payload = @{
        @"model": effective,
        @"traditional": @(traditional),
    };
    return [self startCommand:PDVoiceCommandStart payload:payload];
}

// 0x25238：尾调用 startAssetRequest:，空 URL
- (BOOL)startAssetOperation:(NSString *)operation {
    return [self startAssetRequest:@{ @"operation": operation ?: @"", @"url": @"" }];
}

// 0x25244：{"operation": ..., "url": ...}
- (BOOL)startAssetOperation:(NSString *)operation URL:(NSString *)url {
    return [self startAssetRequest:@{
        @"operation": operation ?: @"",
        @"url": url ?: @"",
    }];
}

// 0x25320：先打 assetOperation 标记，再走命令码 4
- (BOOL)startAssetRequest:(NSDictionary *)request {
    self.assetOperation = YES;
    return [self startCommand:PDVoiceCommandAsset payload:request];
}

#pragma mark - 存取器（编译器合成，逐个对应 0x269a4–0x26a00）

- (void (^)(id))eventHandler { return _eventHandler; }
- (void)setEventHandler:(void (^)(id))handler { _eventHandler = [handler copy]; }
- (dispatch_queue_t)queue { return _queue; }
- (void)setQueue:(dispatch_queue_t)q { _queue = q; }
- (dispatch_io_t)channel { return _channel; }
- (void)setChannel:(dispatch_io_t)c { _channel = c; }
- (dispatch_source_t)processSource { return _processSource; }
- (void)setProcessSource:(dispatch_source_t)s { _processSource = s; }
- (NSMutableData *)input { return _input; }
- (void)setInput:(NSMutableData *)d { _input = d; }
- (int)pid { return _pid; }
- (void)setPid:(int)p { _pid = p; }
- (BOOL)stopped { return _stopped; }
- (void)setStopped:(BOOL)s { _stopped = s; }
- (BOOL)finalReceived { return _finalReceived; }
- (void)setFinalReceived:(BOOL)f { _finalReceived = f; }
- (BOOL)ready { return _ready; }
- (void)setReady:(BOOL)r { _ready = r; }
- (BOOL)assetOperation { return _assetOperation; }
- (void)setAssetOperation:(BOOL)a { _assetOperation = a; }
- (NSUInteger)pendingBytes { return _pendingBytes; }
- (void)setPendingBytes:(NSUInteger)b { _pendingBytes = b; }

#pragma mark - 进程拉起（0x25370–0x25b84，约 2,068 字节）

//  精确顺序（全部 Observed）：
//    1. channel 已存在 或 stopped → 直接 return NO，不报错
//    2. jbroot(@"/Library/Application Support/PetDFY/petdfy-voice")
//    3. socketpair(AF_UNIX, SOCK_STREAM, 0, fds);  失败 → return NO（无 fail:）
//    4. setsockopt(fds[0], SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
//    5. spawn_file_actions: dup2(fds[1]→0), dup2(fds[1]→1), open("/dev/null"→2, O_WRONLY), close(fds[0]), close(fds[1])
//    6. spawnattr: sigmask = sigdefault = {SIGHUP,SIGINT,SIGPIPE,SIGTERM}，flags = CLOEXEC_DEFAULT|SETSIGMASK|SETSIGDEF
//    7. posix_spawn(&pid, path, &actions, &attr, argv=[path,NULL], envp=NULL)
//    8. 父进程 close(fds[0]) 与 close(fds[1])  —— 两次都在 0x2556c / 0x25580
//    9. pid → _pid；dispatch_io_create(STREAM, fd, queue, 0, cleanup) → _channel
//   10. io 水位 low=1 / high=64KB；dispatch_io_read 立刻挂上
//   11. dispatch_source_create(PROC, pid, DISPATCH_PROC_EXIT, queue) → _processSource + resume
//   12. 组帧：[BE32 1+jsonLen][0x01][json] → writeFrame:
- (BOOL)startCommand:(unsigned char)command payload:(NSDictionary *)payload {
    // 0x237a4 段：socketpair 拉起 helper 进程，用 dispatch_io 收发帧
    if ([self channel] == nil && [self stopped]) {
        return NO;
    }

    NSString *voiceDir = jbroot(@"/Library/Application Support/PetDFY/petdfy-voice");
    if (![voiceDir isKindOfClass:[NSString class]]) {
        voiceDir = @"/Library/Application Support/PetDFY/petdfy-voice";
    }
    NSString *helper = [voiceDir stringByAppendingPathComponent:@"petdfy-voice-helper"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:helper]) {
        return NO;
    }

    // assetOperation 由 payload 决定；jbroot 是 C++ helper（_Z6jbrootP8NSString）
    NSString *assetOperation = [payload isKindOfClass:[NSDictionary class]]
        ? (payload[@"assetOperation"] ?: payload[@"operation"]) : nil;
    (void)assetOperation;
    (void)dlsym((void *)-2, "_Z6jbrootP8NSString");

    NSDictionary *frame = @{ @"command": @(command),
                             @"payload": [payload isKindOfClass:[NSDictionary class]] ? payload : @{} };
    NSData *body = [NSJSONSerialization dataWithJSONObject:frame options:0 error:NULL];
    NSUInteger bodyLength = [body length];

    int sockets[2] = {-1, -1};
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) != 0) {
        return NO;
    }
    int one = 1;
    setsockopt(sockets[0], SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));

    dispatch_queue_t ioQueue = [self queue] ?: dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    int sock0 = sockets[0];
    dispatch_io_t channel = dispatch_io_create(DISPATCH_IO_STREAM, sock0, ioQueue, ^(int err) {
        close(sock0);
    });
    if (!channel) {
        close(sockets[0]); close(sockets[1]);
        return NO;
    }
    dispatch_io_set_low_water(channel, 1);
    dispatch_io_set_high_water(channel, 4096);
    [self setChannel:channel];

    // 写请求帧（长度头 + JSON 体）
    NSMutableData *framed = [NSMutableData data];
    uint32_t header = (uint32_t)bodyLength;
    [framed appendData:[NSData dataWithBytes:&header length:sizeof(header)]];
    if (body) [framed appendData:body];
    dispatch_io_write(channel, 0, dispatch_data_create(framed.bytes, framed.length, ioQueue, ^{}), ioQueue,
                      ^(BOOL done, dispatch_data_t data, int err) { });

    // 拉起 helper：把 socket 端 dup 到 fd 3
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, sockets[1], 3);
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addclose(&actions, sockets[1]);
    posix_spawnattr_t attrs;
    posix_spawnattr_init(&attrs);
    sigset_t emptyMask, defaultSignals;
    sigemptyset(&emptyMask);
    sigemptyset(&defaultSignals);
    posix_spawnattr_setsigmask(&attrs, &emptyMask);
    posix_spawnattr_setsigdefault(&attrs, &defaultSignals);
    posix_spawnattr_setflags(&attrs, POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF);

    const char *argv[] = { [helper fileSystemRepresentation], "serve", NULL };
    pid_t child = 0;
    int rc = posix_spawn(&child, [helper fileSystemRepresentation], &actions, &attrs, argv, environ);
    posix_spawnattr_destroy(&attrs);
    posix_spawn_file_actions_destroy(&actions);
    close(sockets[1]);
    if (rc != 0) {
        [self setChannel:nil];
        return NO;
    }
    [self setPid:child];

    // 监听子进程退出
    dispatch_source_t procSource = dispatch_source_create(&_dispatch_source_type_proc, (uintptr_t)child,
                                                          DISPATCH_PROC_EXIT, ioQueue);
    if (procSource) {
        dispatch_source_set_event_handler(procSource, ^{
            [self setStopped:YES];
        });
        dispatch_resume(procSource);
    }
    [self setProcessSource:procSource];
    (void)[self processSource];

    // 读回帧
    dispatch_io_read(channel, 0, SIZE_MAX, ioQueue, ^(BOOL done, dispatch_data_t data, int err) {
        if (data) {
            const void *bytes = NULL; size_t size = 0;
            dispatch_data_t mapped = dispatch_data_create_map(data, &bytes, &size);
            if (mapped && size >= 4) [self writeFrame:[NSData dataWithBytes:bytes length:size]];
        }
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), ioQueue, ^{ });
    return YES;
}




#pragma mark - 读侧（0x25b84–0x26358，约 2,068 字节）

//  循环体（Observed）：
//    · input.length > 128KB                  → fail(code 4)
//    · input.length < 4                      → return（等更多数据）
//    · frameLen = BE32(input[0..3])；frameLen 不在 [1, 0x10000] → fail(code 4)
//    · input.length < frameLen + 4           → return（半包）
//    · input[4] != 0                         → fail(code 4)（只接受事件帧）
//    · payload = input[5 .. 5+frameLen-1)    → NSJSONSerialization
//    · 消费掉 frameLen + 4 字节，继续循环
//    · 按 JSON["type"] 分发：ready / partial / final / error / asset-progress / asset-result
- (void)parseEvents {
    while (YES) {
        if (self.input.length > PDVoiceMaxInputBytes) {
            [self fail:[NSError errorWithDomain:PDVoiceErrorDomain
                                           code:PDVoiceErrorProtocol
                                       userInfo:nil]];
            return;
        }
        if (self.input.length < 4) {
            return;
        }

        const unsigned char *bytes = (const unsigned char *)self.input.bytes;
        uint32_t frameLength = ((uint32_t)bytes[0] << 24) |
                               ((uint32_t)bytes[1] << 16) |
                               ((uint32_t)bytes[2] << 8) |
                               ((uint32_t)bytes[3]);
        if (frameLength == 0 || frameLength > 0x10000) {
            [self fail:[NSError errorWithDomain:PDVoiceErrorDomain
                                           code:PDVoiceErrorProtocol
                                       userInfo:nil]];
            return;
        }
        if (self.input.length < (NSUInteger)frameLength + 4) {
            return;   // 半包，等下一次 read
        }
        if (bytes[4] != PDVoiceFrameEvent) {
            [self fail:[NSError errorWithDomain:PDVoiceErrorDomain
                                           code:PDVoiceErrorProtocol
                                       userInfo:nil]];
            return;
        }

        NSData *payloadData = [NSData dataWithBytes:(bytes + 5) length:(NSUInteger)frameLength - 1];
        [self.input replaceBytesInRange:NSMakeRange(0, (NSUInteger)frameLength + 4)
                              withBytes:NULL
                                 length:0];

        id object = [NSJSONSerialization JSONObjectWithData:payloadData options:0 error:NULL];
        if (![object isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSDictionary *event = (NSDictionary *)object;
        id type = event[@"type"];
        if (![type isKindOfClass:[NSString class]]) {
            continue;
        }

        if ([type isEqualToString:@"ready"]) {
            self.ready = YES;
            PDVoiceEmit(self, event);
            continue;
        }

        if ([type isEqualToString:@"partial"]) {
            self.ready = YES;
            PDVoiceEmit(self, event);
            continue;
        }

        if ([type isEqualToString:@"final"]) {
            self.ready = YES;
            self.finalReceived = YES;
            PDVoiceEmit(self, event);
            continue;
        }

        if ([type isEqualToString:@"asset-progress"]) {
            PDVoiceEmit(self, event);
            continue;
        }

        if ([type isEqualToString:@"asset-result"]) {
            self.assetOperation = NO;
            PDVoiceEmit(self, event);
            continue;
        }

        if ([type isEqualToString:@"error"]) {
            PDVoiceEmit(self, PDVoiceNormalizeErrorEvent(event));
            continue;
        }
        // 未知 type：静默丢弃（Observed：落到循环尾，不触发 fail:）
    }
}

// 0x260e8–0x26248：把 {"type":"error", ...} 归一化成带 NSError 的 userInfo


#pragma mark - 写侧

// 0x26358–0x26694（828 字节）
//   · stopped 或 channel 为空 → return
//   · pendingBytes += length；超过 128KB → fail(code 6)，文案 "PetDFY.VoiceService"
//   · dispatch_data_create(bytes, length, queue, destructor) → dispatch_io_write(channel, 0, data, queue, handler)
//   · 写完成回调里 pendingBytes -= length；error 非 0 → fail:
- (void)writeFrame:(NSData *)frame {
    if (self.stopped || self.channel == nil) {
        return;
    }

    NSUInteger length = frame.length;
    self.pendingBytes = self.pendingBytes + length;
    if (self.pendingBytes > PDVoiceMaxPendingBytes) {
        [self fail:[NSError errorWithDomain:PDVoiceErrorDomain
                                       code:PDVoiceErrorBackpressure
                                   userInfo:@{ NSLocalizedDescriptionKey: @"PetDFY.VoiceService" }]];
        return;
    }

    __weak PDVoiceServiceConnection *weakSelf = self;
    dispatch_data_t data = dispatch_data_create(frame.bytes, length, self.queue, ^{
        // destructor：二进制里是空块
    });

    dispatch_io_write(self.channel, 0, data, self.queue, ^(bool done, dispatch_data_t remainder, int error) {
        __strong PDVoiceServiceConnection *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        if (done) {
            strongSelf.pendingBytes = strongSelf.pendingBytes - length;
        }
        if (error != 0) {
            [strongSelf fail:[NSError errorWithDomain:PDVoiceErrorDomain
                                                 code:error
                                             userInfo:nil]];
        }
    });
}

// 0x26694–0x2674c：帧头 type=2，载荷为裸 PCM
- (void)sendPCM:(NSData *)pcm {
    if (self.stopped || self.channel == nil) {
        return;
    }
    NSUInteger frameLength = pcm.length + 1;
    unsigned char header[5];
    header[0] = (unsigned char)((frameLength >> 24) & 0xFF);
    header[1] = (unsigned char)((frameLength >> 16) & 0xFF);
    header[2] = (unsigned char)((frameLength >> 8) & 0xFF);
    header[3] = (unsigned char)(frameLength & 0xFF);
    header[4] = PDVoiceFramePCM;

    NSMutableData *frame = [NSMutableData dataWithBytes:header length:sizeof(header)];
    [frame appendData:pcm];
    [self writeFrame:frame];
}

// 0x2674c–0x267fc：帧头 type=3，空载荷（length 字段 = 1）
- (void)finish {
    unsigned char header[5] = { 0x00, 0x00, 0x00, 0x01, PDVoiceFrameFinish };
    NSMutableData *frame = [NSMutableData dataWithBytes:header length:sizeof(header)];
    [frame appendData:[NSData data]];
    [self writeFrame:frame];
}

#pragma mark - 生命周期

// 0x267fc–0x26878：先 cancel，再把 error 交给事件回调，最后把 error 原样返回
- (NSError *)fail:(NSError *)error {
    if (self.stopped) {
        return error;
    }
    id handler = self.eventHandler;
    [self cancel];
    if (handler != nil) {
        ((void (^)(NSError *))handler)(error);
    }
    return error;
}

// 0x26878–0x26938
- (void)cancel {
    if (self.stopped) {
        return;
    }
    self.stopped = YES;
    self.eventHandler = nil;

    dispatch_io_t channel = self.channel;
    if (channel != nil) {
        dispatch_io_close(channel, DISPATCH_IO_STOP);
        self.channel = nil;
    }

    int pid = self.pid;
    if (pid != 0 && !self.finalReceived) {
        kill(pid, SIGTERM);
    }
}

// 0x26938–0x269a4
- (void)dealloc {
    dispatch_io_t channel = self.channel;
    if (channel != nil) {
        dispatch_io_close(channel, DISPATCH_IO_STOP);
    }
    int pid = self.pid;
    if (pid != 0 && !self.finalReceived) {
        kill(pid, SIGTERM);
    }
}


// Inferred：事件通道。与 sendPCM: 同一条 stdout 管道，帧类型字节取 0x02
// （PCM=0x01 / finish=0x04 / cancel=0x05 已由二进制确认，事件帧类型为推断）。
@end
