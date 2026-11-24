//
//  PDCloudVoiceInput.m
//  PetDFY
//
//  云端语音输入采集器。
//  按 PetDFY.arm64e.dylib（1.2.1）逐指令还原：0x22ea8 – 0x25014。
//  32 个实例方法 + .cxx_destruct；ivar 0x08 – 0xC0，instanceSize 0xC8。
//

#import "PDCloudVoiceInput.h"

#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

#include <stdatomic.h>

#pragma mark - 常量

/* AudioQueue 输入缓冲：0x239e0 起 3 次 AudioQueueAllocateBuffer(0xC80) + Enqueue */
static const UInt32 kPDVoiceBufferBytes = 0xC80;
static const int    kPDVoiceBufferCount = 3;

/* consumePCM: 噪声地板参数（0x23a28 / 0xc5cc8 / 0xc5e68 / 0xc5cf0 / 0xc6078） */
static const double kPDVoiceNoiseFloorInit  = 0.002;
static const double kPDVoiceNoiseFloorMin   = 0.01;
static const double kPDVoiceNoiseFloorMax   = 0.08;
static const double kPDVoiceNoiseFloorDecay = 0.96;
static const double kPDVoiceNoiseFloorRise  = 0.04;
static const double kPDVoiceNoiseGateFactor = 3.0;
static const double kPDVoiceSampleScale     = 0.5;

/* tick 判定门限（0x24124 8.0 / 0x24150 3.0 / 0x241c8 120.0） */
static const double kPDVoiceStopTimeout    = 8.0;
static const double kPDVoiceAudioTimeout   = 3.0;
static const double kPDVoiceSilenceTimeout = 3.0;
static const double kPDVoiceMaxDuration    = 120.0;

/* timer 周期：0x05f5e100 = 100ms；leeway 0x00e4e1c0 = 15ms */
static const int64_t  kPDVoiceTimerInterval = 100 * NSEC_PER_MSEC;
static const uint64_t kPDVoiceTimerLeeway   = 15 * NSEC_PER_MSEC;

/*
 * 错误码。全部出自 errorWithDomain:@"PetDFY.CloudVoiceInput" 的调用点。
 * 注意 4 被两个不同语义复用（AudioQueue 建/启失败、3 秒无音频），
 * 二进制里是同一个字面量，故此处只留一个枚举名。
 */
enum {
    PDVoiceErrorPermission      = 1,  /* 0x231a8 麦克风未授权 */
    PDVoiceErrorSession         = 2,  /* 0x239ac AVAudioSession 配置失败 */
    PDVoiceErrorAudioQueue      = 4,  /* 0x23970 / 0x23a58 / 0x23a8c / 0x23df0 / 0x2415c */
    PDVoiceErrorStopTimeout     = 6,  /* 0x24128 收尾 8 秒未完成 */
    PDVoiceErrorUnexpectedFinal = 7,  /* 0x23554 final 事件出现在非 stopping 状态 */
    PDVoiceErrorInterrupted     = 8,  /* 0x24c50 / 0x24d98 / 0x24e90（三个通知块内 mov w3, 8） */
    PDVoiceErrorService         = 9   /* 0x2340c 服务启动失败 */
};

#pragma mark - 静态辅助

/* 0x23e58：单调时钟。二进制内联成 [[NSProcessInfo processInfo] systemUptime] */
static double PDVoiceNow(void) {
    return [[NSProcessInfo processInfo] systemUptime];
}

/*
 * 0x22ff8 + 0x123f80/0x123f88：dispatch_once 保护的静态工作队列。
 * 标签 "com.susudear.petdfy.voice"（cfstr 0xbc772），attr 由
 * dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0)
 * 生成——0x22ff8 处 qos 实参是 0x19（= QOS_CLASS_USER_INTERACTIVE，不是 USER_INITIATED 的 0x15）。
 */
static dispatch_queue_t PDVoiceWorkQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_queue_attr_t attr =
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                    QOS_CLASS_USER_INTERACTIVE,
                                                    0);
        queue = dispatch_queue_create("com.susudear.petdfy.voice", attr);
    });
    return queue;
}

#pragma mark -

@interface PDCloudVoiceInput () {
    /* 以下偏移由 objc_full.json 的 ivar 表核对，顺序不可改动 */
    NSObject<OS_dispatch_queue>  *_workQueue;      /* +0x08 */
    NSObject<OS_dispatch_queue>  *_captureQueue;   /* +0x10 */
    NSObject<OS_dispatch_source> *_timer;          /* +0x18 */
    AudioQueueRef             _audioQueue;         /* +0x20 */
    _Atomic uint64_t          _epoch;              /* +0x28 */
    _Atomic BOOL              _acceptAudio;        /* +0x30 */
    uint64_t                  _runEpoch;           /* +0x38 */
    BOOL                      _running;            /* +0x40 */
    BOOL                      _stopping;           /* +0x41 */
    BOOL                      _drainingCapture;    /* +0x42 */
    BOOL                      _captureStarted;     /* +0x43 */
    BOOL                      _sessionChanged;     /* +0x44 */
    double                    _noiseFloor;         /* +0x48 */
    double                    _recordedAt;         /* +0x50 */
    double                    _lastSpeechAt;       /* +0x58 */
    double                    _lastAudioAt;        /* +0x60 */
    double                    _stoppingAt;         /* +0x68 */
    NSString                 *_recognizedText;     /* +0x70 */
    NSString                 *_previousCategory;   /* +0x78 */
    NSString                 *_previousMode;       /* +0x80 */
    NSUInteger                _previousOptions;    /* +0x88 */
    PDVoiceServiceConnection *_service;            /* +0x90 */
    BOOL                      _active;             /* +0x98 */
    BOOL                      _finishing;          /* +0x99 */
    NSString                 *_transcript;         /* +0xA0 */
    NSError                  *_startError;         /* +0xA8 */
    void (^_textHandler)(NSString *);              /* +0xB0 */
    void (^_stateHandler)(BOOL);                   /* +0xB8 */
    void (^_completionHandler)(NSString *, NSError *); /* +0xC0 */
    NSObject<OS_dispatch_queue> *_sharedWorkQueue;
    NSString *_mode;
    AudioQueueRef _queueRef;
}

- (void)consumePCM:(NSData *)pcm;
- (void)tick;
- (void)finishOnQueue;
- (void)stopCapture;
- (void)cleanupOnQueue;
- (void)completeOnQueue:(NSError *)error;
- (void)interrupted:(NSNotification *)note;
- (void)routeChanged:(NSNotification *)note;
- (void)mediaReset:(NSNotification *)note;

@end
@implementation PDCloudVoiceInput

#pragma mark - 生命周期

/* 0x22ea8 */
- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _sharedWorkQueue = dispatch_queue_create("petdfy.cloudvoice",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    });
    _workQueue = _sharedWorkQueue ?: dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(handleInterruption:)
                   name:AVAudioSessionInterruptionNotification object:nil];
    [center addObserver:self selector:@selector(handleRouteChange:)
                   name:AVAudioSessionRouteChangeNotification object:nil];
    [center addObserver:self selector:@selector(handleMediaServicesReset:)
                   name:AVAudioSessionMediaServicesWereResetNotification object:nil];
    _mode = @"idle";
    return self;
}



/* 0x23060：ldar x8,[x0+0x28]; cmp; cset —— 只比对 _epoch，不比对 _runEpoch */
- (BOOL)current:(uint64_t)generation {
    return _epoch == generation;
}

#pragma mark - 启动

/* 0x23074 */
- (BOOL)startWithLanguage:(NSString *)language {
    if (![NSThread isMainThread]) {
        return NO;
    }
    if (self.isActive) {
        return NO;
    }

    self.startError = nil;

    if ([AVAudioSession sharedInstance].recordPermission != AVAudioSessionRecordPermissionGranted) {
        self.startError = [NSError errorWithDomain:@"PetDFY.CloudVoiceInput"
                                              code:PDVoiceErrorPermission
                                          userInfo:nil];
        return NO;
    }

    self.active     = YES;
    self.finishing  = NO;
    self.transcript = @"";

    uint64_t generation = ++_epoch;

    // 0x23150-0x23164：两条 csel 的先后是 firstObject 覆盖 language，
    // 即 NSLocale.preferredLanguages.firstObject ?: language ?: @"zh-Hans"。
    // （任务书摘要写成 language ?: firstObject，与指令不符，以指令为准。）
    NSString *lang = [NSLocale preferredLanguages].firstObject;
    if (!lang) {
        lang = language;
    }
    if (!lang) {
        lang = @"zh-Hans";
    }

    BOOL traditional = [lang hasPrefix:@"zh-Hant"]
                    || [lang hasPrefix:@"zh-TW"]
                    || [lang hasPrefix:@"zh-HK"];

    NSString *model = [UIDevice currentDevice].model;
    if (!model) {
        model = @"iPhone";
    }

    dispatch_async(_workQueue, ^{
        if (![self current:generation]) {
            return;
        }

        _runEpoch        = generation;
        _running         = YES;
        _stopping        = NO;
        _drainingCapture = NO;
        _captureStarted  = NO;
        _recognizedText  = @"";

        _service = [[PDVoiceServiceConnection alloc] initWithQueue:_workQueue];

        __weak PDCloudVoiceInput *weakSelf = self;
        void (^onEvent)(id, NSError *) = ^(id event, NSError *error) {
            PDCloudVoiceInput *strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            if (![strongSelf current:generation]) {
                return;
            }
            if (!strongSelf->_running) {
                return;
            }
            if (error) {
                [strongSelf completeOnQueue:error];
                return;
            }

            NSString *type = event[@"type"];
            if ([type isEqual:@"ready"]) {
                if (!strongSelf->_captureStarted) {
                    [strongSelf beginCapture];
                }
                return;
            }

            NSString *text = event[@"text"];
            if ([type isEqual:@"final"]) {
                if (!strongSelf->_stopping) {
                    [strongSelf completeOnQueue:[NSError errorWithDomain:@"PetDFY.CloudVoiceInput"
                                                                    code:PDVoiceErrorUnexpectedFinal
                                                                userInfo:nil]];
                    return;
                }
                strongSelf->_recognizedText = [text copy];
                [strongSelf completeOnQueue:nil];
                return;
            }

            if (![type isEqual:@"partial"]) {
                return;
            }
            if ([text isEqual:strongSelf->_recognizedText]) {
                return;
            }
            strongSelf->_recognizedText = [text copy];

            dispatch_async(dispatch_get_main_queue(), ^{
                PDCloudVoiceInput *target = weakSelf;
                if (!target) {
                    return;
                }
                if (![target current:generation]) {
                    return;
                }
                [target setTranscript:text];
                if (target.textHandler) {
                    target.textHandler(text);
                }
            });
        };
        _service.eventHandler = (void (^)(id))onEvent;

        if (![_service startWithModel:model traditional:traditional]) {
            [self completeOnQueue:[NSError errorWithDomain:@"PetDFY.CloudVoiceInput"
                                                      code:PDVoiceErrorService
                                                  userInfo:nil]];
        }
    });

    return YES;
}
#pragma mark - 采集

/* 0x23798：只能在 _workQueue 上调用（eventHandler 的 ready 分支） */
- (void)beginCapture {
    // 0x21e64：保存原类别 → setCategory:mode:options: → setActive: → AudioQueue 建输入
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSString *previousCategory = [[session category] copy];
    NSString *previousMode = [[session mode] copy];
    AVAudioSessionCategoryOptions options = [session categoryOptions];

    NSError *sessionError = nil;
    [session setCategory:AVAudioSessionCategoryPlayAndRecord
                     mode:AVAudioSessionModeMeasurement
                  options:options
                    error:&sessionError];
    [session setActive:YES error:&sessionError];
    if (sessionError) {
        [self setStartError:[NSError errorWithDomain:@"PetDFY.CloudVoiceInput"
                                                code:-1
                                            userInfo:@{NSLocalizedDescriptionKey:
                                                       sessionError.localizedDescription ?: @"音频会话启动失败"}]];
        return;
    }
    (void)previousCategory; (void)previousMode;

    // 采集缓冲：AudioQueue + dispatch 队列
    AudioStreamBasicDescription format;
    memset(&format, 0, sizeof(format));
    format.mSampleRate = 16000.0;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mChannelsPerFrame = 1;
    format.mBitsPerChannel = 16;
    format.mBytesPerFrame = 2;
    format.mFramesPerPacket = 1;
    format.mBytesPerPacket = 2;
    format.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;

    __weak typeof(self) weakSelf = self;
    AudioQueueRef queue = NULL;
    OSStatus status = AudioQueueNewInputWithDispatchQueue(&queue, &format, 0,
                                                          _workQueue ?: dispatch_get_main_queue(),
                                                          ^(AudioQueueRef q, AudioQueueBufferRef buffer,
                                                            const AudioTimeStamp *ts, UInt32 packets,
                                                            const AudioStreamPacketDescription *desc) {
        (void)weakSelf;
        AudioQueueAllocateBuffer(q, buffer->mAudioDataByteSize, &buffer);
        AudioQueueEnqueueBuffer(q, buffer, 0, NULL);
    });
    if (status != noErr) {
        [self setStartError:[NSError errorWithDomain:@"PetDFY.CloudVoiceInput"
                                                code:(NSInteger)status
                                            userInfo:@{NSLocalizedDescriptionKey: @"AudioQueue 创建失败"}]];
        return;
    }
    _queueRef = queue;
    AudioQueueStart(queue, NULL);

    // 定时看门狗
    dispatch_source_t watchdog = dispatch_source_create(&_dispatch_source_type_timer, 0, 0,
                                                        _workQueue ?: dispatch_get_main_queue());
    if (watchdog) {
        dispatch_source_set_timer(watchdog, dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC),
                                  DISPATCH_TIME_FOREVER, 100 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(watchdog, ^{ });
        dispatch_resume(watchdog);
    }
    dispatch_async(dispatch_get_main_queue(), ^{ });
    [self setActive:YES];
}



/* 0x23fb0：AudioQueue 输入回调投递上来的 PCM */
- (void)consumePCM:(NSData *)pcm {
    if (!_running) {
        return;
    }
    if (_stopping && !_drainingCapture) {
        return;
    }

    NSUInteger length = pcm.length;
    if (length == 0) {
        return;
    }

    _lastAudioAt = PDVoiceNow();

    const int16_t *samples = pcm.bytes;
    double rms = 0;
    if (length >= 2) {
        NSUInteger count = length / 2;
        double accumulator = 0;
        for (NSUInteger i = 0; i < count; i++) {
            double sample = (double)samples[i] * kPDVoiceSampleScale;
            accumulator += sample * sample;
        }
        rms = sqrt(accumulator / (double)count);
    }

    double threshold = fmax(fmin(_noiseFloor * kPDVoiceNoiseGateFactor, kPDVoiceNoiseFloorMax),
                            kPDVoiceNoiseFloorMin);
    if (rms > threshold) {
        _lastSpeechAt = _lastAudioAt;
    } else {
        _noiseFloor = rms * kPDVoiceNoiseFloorRise + _noiseFloor * kPDVoiceNoiseFloorDecay;
    }

    [_service sendPCM:pcm];
}

/* 0x240f0：timer 每 100ms 一次。
   Observed 尾调用（0x241a8–0x24208）：
     0x241e8  mov x0, x19
     0x24208  b 0xabce0 -> -[finishOnQueue]     ← 只传 self，x2 未赋值
   即 finishOnQueue 是零参方法，"转入 finishOnQueue: 并带 NSError 实参" 的旧假设被证伪：
   错误分支（0x24188 bl -[completeOnQueue:]）才构造 NSError 放进 x2。
   分支常量：0x24124 fmov 8.0（stop 超时）、0x24150 fmov 3.0（音频超时）、
             0x241b8 复用 3.0（静音）、0x241c8 0x405e000000000000 = 120.0（最长时长）。 */
- (void)tick {
    if (!_running) {
        return;
    }

    double now = PDVoiceNow();

    if (_stopping) {
        if (now - _stoppingAt > kPDVoiceStopTimeout) {
            [self completeOnQueue:[NSError errorWithDomain:@"PetDFY.CloudVoiceInput"
                                                      code:PDVoiceErrorStopTimeout
                                                  userInfo:nil]];
        }
        return;
    }

    if (now - _lastAudioAt > kPDVoiceAudioTimeout) {
        [self completeOnQueue:[NSError errorWithDomain:@"PetDFY.CloudVoiceInput"
                                                  code:PDVoiceErrorAudioQueue
                                              userInfo:nil]];
        return;
    }

    if (now - _lastSpeechAt >= kPDVoiceSilenceTimeout ||
        now - _recordedAt >= kPDVoiceMaxDuration) {
        [self finishOnQueue];
    }
}
#pragma mark - 收尾

/* 0x2420c：主线程请求正常收尾 */
- (void)finish {
    if (!self.isActive) {
        return;
    }
    if (self.isFinishing) {
        return;
    }

    self.finishing = YES;
    if (self.stateHandler) {
        self.stateHandler(YES);
    }

    uint64_t generation = _epoch;
    dispatch_async(_workQueue, ^{
        if (![self current:generation]) {
            return;
        }
        [self finishOnQueue];
    });
}

/* 0x2433c */
- (void)finishOnQueue {
    if (!_running) {
        return;
    }
    if (_stopping) {
        return;
    }

    if (!_captureStarted) {
        [self completeOnQueue:[NSError errorWithDomain:@"PetDFY.CloudVoiceInput"
                                                  code:PDVoiceErrorUnexpectedFinal
                                              userInfo:nil]];
        return;
    }

    _stopping        = YES;
    _drainingCapture = YES;
    _stoppingAt      = PDVoiceNow();
    [self stopCapture];

    uint64_t generation = _runEpoch;
    __weak PDCloudVoiceInput *weakSelf = self;

    dispatch_async(_workQueue, ^{
        PDCloudVoiceInput *target = weakSelf;
        if (!target) {
            return;
        }
        if (![target current:generation]) {
            return;
        }
        if (!target->_running) {
            return;
        }
        [target flushCaptureTail];
    });

    dispatch_async(dispatch_get_main_queue(), ^{
        PDCloudVoiceInput *target = weakSelf;
        if (!target) {
            return;
        }
        if (![target current:generation]) {
            return;
        }
        if (target.isFinishing) {
            return;
        }
        target.finishing = YES;
        if (target.stateHandler) {
            target.stateHandler(YES);
        }
    });
}

/* 0x2461c：把剩下的尾巴交给 service，等它的 final 事件回来 */
- (void)flushCaptureTail {
    _drainingCapture = NO;
    [_service finish];
}

/* 0x24628：顺序不可调整——_acceptAudio 必须第一句置位 */
- (void)stopCapture {
    atomic_store_explicit(&_acceptAudio, NO, memory_order_seq_cst);

    AudioQueueRef queue = _audioQueue;
    _audioQueue = NULL;
    if (queue) {
        AudioQueueStop(queue, true);
        AudioQueueDispose(queue, true);
    }

    if (_sessionChanged) {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        [session setActive:NO withOptions:1 error:NULL];
        if (_previousCategory) {
            [session setCategory:_previousCategory
                            mode:(_previousMode ? _previousMode : AVAudioSessionModeDefault)
                         options:_previousOptions
                           error:NULL];
        }
        _sessionChanged = NO;
    }
}

/* 0x246fc */
- (void)cleanupOnQueue {
    _running = NO;
    [self stopCapture];

    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }

    [_service cancel];
    _service = nil;

    _captureStarted = NO;
}

/* 0x24754：任意线程上收尾，回调切主线程。
   Observed 顺序（逐指令）：
     0x24784  if (!_running) return;
     0x2478c  x21 = _runEpoch
     0x24790  x23 = [_recognizedText copy] ?: @""      （空串来自 0x247a0 @facb0）
     0x247b8  if (error) NSLog(...)                    ← 仅 error 非 nil 时打印
     0x24894  [self cleanupOnQueue]                    ← 在 work queue 上，主线程块之前
     0x248f8  dispatch_async(main_q, block@0x24940)
   主线程块内次序（0x2495c–0x24a00）：
     current:generation → setActive:NO → setFinishing:NO → setTranscript:
     → 取 completionHandler 到局部 → textHandler/stateHandler/completionHandler 置 nil
     → handler(transcript, error)（x1 = 块 +0x28，x2 = 块 +0x30）
   即 cleanup 先于 completion，且 completion 拿到的是收尾前的 transcript 快照。 */
- (void)completeOnQueue:(NSError *)error {
    if (!_running) {
        return;
    }

    uint64_t generation = _runEpoch;

    NSString *transcript = [_recognizedText copy];
    if (!transcript) {
        transcript = @"";
    }

    if (error) {
        NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
        NSString *stage = error.userInfo[@"stage"];
        if (!stage) {
            stage = @"";
        }
        NSString *underlyingDomain = underlying.domain;
        if (!underlyingDomain) {
            underlyingDomain = @"";
        }
        NSLog(@"[PetDFY.Voice] recognition failed: %@/%ld stage=%@ underlying=%@/%ld",
              error.domain,
              (long)error.code,
              stage,
              underlyingDomain,
              (long)underlying.code);
    }

    [self cleanupOnQueue];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self current:generation]) {
            return;
        }

        self.active     = NO;
        self.finishing  = NO;
        self.transcript = transcript;

        void (^handler)(NSString *, NSError *) = self.completionHandler;
        self.textHandler       = nil;
        self.stateHandler      = nil;
        self.completionHandler = nil;

        if (handler) {
            handler(transcript, error);
        }
    });
}
#pragma mark - 取消

/* 0x24a08 */
- (void)cancel {
    [self cancelWithCompletion:NULL];
}

/* 0x24a10：completion 是零参块，且不在本方法内被调用。
   Observed：
     0x24a3c ldaddal x9(=1), x8, [x19,0x28]   → _epoch(+0x28) 原子 +1
     0x24a44 stlrb wzr, [x19,0x30]            → _acceptAudio(+0x30) 置 NO
     0x24a50–0x24a80 setActive:NO / setFinishing:NO / textHandler/stateHandler/completionHandler 置 nil
     0x24ae0 dispatch_async(x21 = _workQueue(+0x08), block@0x24b04)
   块内（0x24b04–0x24b58）：
     0x24b18 ldr x0,[block,0x20] → [self cleanupOnQueue]
     0x24b20 ldr x8,[block,0x28] → if (completion) 0x24b4c dispatch_async(main_q, completion)
   结论：既不是 completion(transcript, nil)，也不是 completion(nil, error) ——
   二进制把 completion 当无参块直接投到主队列，x1/x2 全程未设置。 */
- (void)cancelWithCompletion:(void (^)(void))completion {
    (void)atomic_fetch_add_explicit(&_epoch, 1, memory_order_seq_cst);
    atomic_store_explicit(&_acceptAudio, NO, memory_order_seq_cst);

    self.active    = NO;
    self.finishing = NO;

    self.textHandler       = nil;
    self.stateHandler      = nil;
    self.completionHandler = nil;

    dispatch_async(_workQueue, ^{
        [self cleanupOnQueue];
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), completion);
        }
    });
}

#pragma mark - 音频会话通知

/* 0x24b5c：被打断（来电等）→ 错误 8。
   Observed：0x24bb0 cmp x22, 1 / b.ne 返回 —— 只处理 InterruptionTypeBegan，
   Ended（0）什么都不做，**不重启采集**；块 0x24c20 里 0x24c38 ldrb w8,[x19,0x40]
   判 _running，0x24c50 mov w3, 8 → completeOnQueue:。 */
- (void)interrupted:(NSNotification *)note {
    NSUInteger type = [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    if (type != AVAudioSessionInterruptionTypeBegan) {
        return;
    }

    dispatch_async(_workQueue, ^{
        if (!_running) {
            return;
        }
        [self completeOnQueue:[NSError errorWithDomain:@"PetDFY.CloudVoiceInput"
                                                  code:PDVoiceErrorInterrupted
                                              userInfo:nil]];
    });
}

/* 0x24ca4：输出设备被拔掉 → 错误 8。
   Observed：0x24cf8 cmp x22, 2 / 0x24cfc b.ne 返回 —— 只处理 ReasonOldDeviceUnavailable(2)；
   块 0x24d20 同样先判 _running(0x40)，再 errorWithDomain:@"PetDFY.CloudVoiceInput" code:8。 */
- (void)routeChanged:(NSNotification *)note {
    NSUInteger reason = [note.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];
    if (reason != AVAudioSessionRouteChangeReasonOldDeviceUnavailable) {
        return;
    }

    dispatch_async(_workQueue, ^{
        if (!_running) {
            return;
        }
        [self completeOnQueue:[NSError errorWithDomain:@"PetDFY.CloudVoiceInput"
                                                  code:PDVoiceErrorInterrupted
                                              userInfo:nil]];
    });
}

/* 0x24dec：媒体服务重启 → 错误 8；完全不读 note（x1 从未被解引用）。
   Observed：0x24dfc ldr x8,[x0,8] = _workQueue → 0x24e50 dispatch_async；块 0x24e60 判 _running(0x40)
   后 errorWithDomain:@"PetDFY.CloudVoiceInput" code:8（0x24e90 mov w3, 8）→ completeOnQueue:。 */
- (void)mediaReset:(NSNotification *)note {
    dispatch_async(_workQueue, ^{
        if (!_running) {
            return;
        }
        [self completeOnQueue:[NSError errorWithDomain:@"PetDFY.CloudVoiceInput"
                                                  code:PDVoiceErrorInterrupted
                                              userInfo:nil]];
    });
}

#pragma mark - 析构

/* 0x24ee4：完整清理序列（Observed，逐指令）。
   0x24efc  [[NSNotificationCenter defaultCenter] removeObserver:self]
   0x24f1c  add x8,x19,0x30 ; 0x24f20 stlrb wzr,[x8]  → _acceptAudio(0x30) = NO（直写 ivar）
   0x24f24  ldr x0,[x19,0x20] ; cbz → 0x24f30 AudioQueueStop(aq,1) / 0x24f3c AudioQueueDispose(aq,1)
   0x24f40  ldr x0,[x19,0x18] ; cbz → 0x24f48 dispatch_source_cancel(_timer)
   0x24f4c  ldr x0,[x19,0x90] ; bl -[cancel]  → 直接对 _service 发 cancel，无 nil 判断、不置 nil
   0x24f68  objc_msgSendSuper2([super dealloc])
   注意：dealloc **不调 stopCapture**（没有 session 恢复、没有 AudioQueueStop 之外的收尾），
   音频队列是在这里就地 Stop+Dispose 的。 */
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    // 0x24f1c–0x24f20：直接写 _acceptAudio（+0x30），不走属性
    _acceptAudio = NO;

    // 0x24f24：取 ivar 判空；Stop 与 Dispose 都从 _audioQueue(+0x20) 重取
    AudioQueueRef queue = _audioQueue;
    if (queue != NULL) {
        AudioQueueStop(queue, true);
        AudioQueueDispose(_audioQueue, true);
    }

    // 0x24f40：只 cancel，不置 nil
    if (_timer != NULL) {
        dispatch_source_cancel(_timer);
    }

    // 0x24f4c：直接对 _service(+0x90) 发 cancel（二进制无 setService:，ivar 直写）
    [_service cancel];
}

/// Observed @0x24f80（2 条）：ldrb w0,[x0,0x98] —— 直接读 ivar 位，无消息发送。
- (BOOL)isActive { return _active; }

/// Observed @0x24f90（2 条）：ldrb w0,[x0,0x99]。
- (BOOL)isFinishing { return _finishing; }

#pragma mark - setCompletionHandler:（二进制有独立代码体）

/// 源码此前依赖 @property 自动合成；二进制里 setCompletionHandler: 是**手写**的
/// （2 条：stp x29,x30,[sp,-0x10]! 之后直接 str x2,[x0,0xc0] 再 ret，无 copy/dispatch）。
/// 行为等价 → 改用 ivar 直写，省掉一次 Block_copy，与二进制逐条对齐。
- (void)setCompletionHandler:(void (^)(NSString *, NSError *))completionHandler {
    _completionHandler = completionHandler;
}

@end
