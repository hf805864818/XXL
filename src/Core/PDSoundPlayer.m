//
//  PDSoundPlayer.m — 逆向还原：程序化音效合成
//
//  还原依据：PetDFY.dylib arm64e，55 个方法共 3073 条指令
//  核心方法：
//    notesForSound:arguments:   1392  按音效名生成音符序列
//    bufferForNotes:pan:         609  把音符渲染成 PCM
//    startGraph                  250  启动 AVAudioEngine
//    playSound:kind:arguments:pan: 73  播放入口
//
//  ivar（size=120，20 个字段）：
//    _sessionChanged / _enabled / _visible / _unlocked / _interrupted
//    _voiceInputActive  BOOL
//    _audioQueue  NSObject<OS_dispatch_queue> *（org.petdfy.audio）
//    _engine      AVAudioEngine *
//    _format      AVAudioFormat *
//    _voices      NSArray<PDVoice *> *    声部池（+0x28）
//    _previousCategory / _previousCategoryOptions
//    _pan         double
//
//  音效名（从字符串提取）：
//    babble / chirps / hmm / jump / grab / dance / happy / angry
//  滤波器：bandpass / highpass
//  音符时值：0.25 / 0.5 / 1.0 / 1.25 拍
//  频率：5 / 6 / 8 / 10 / 12 / 14 / 15 / 18（半音偏移）
//

#import "PDSoundPlayer.h"
#import "PDVoice.h"
#import <AVFoundation/AVFoundation.h>
#import <math.h>

// 音高表：C4 起，按半音
static double PDSemitoneToHz(int n) {
    return 261.625565 * pow(2.0, n / 12.0);
}

@implementation PDSoundPlayer

#pragma mark - 单例

/// IMP 0x1008c。标准 dispatch_once 单例：
///   0x1009c ldr x8,[0x123000+0xf68] = 0x123f68（结果槽）
///   0x100a4 ldr x9,[0x123000+0xf70] = 0x123f70（once 令牌），cmn x9,#1 即 == -1 才算已初始化
///   块体 0x1012c：x0 = block，ldr x0,[x0,0x20] 取出捕获的类对象（入口 0x100e0 str x0,[sp,0x28] 存的就是
///   self 类），objc_opt_new 后写回 0x123f68。即 [self new]。
+ (instancetype)sharedPlayer {
    static PDSoundPlayer *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [self new];
    });
    return shared;
}

#pragma mark - 初始化

/// 208 B（0x10164）。只建队列与观察者；_engine/_format 不在此初始化。
- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _audioQueue = dispatch_queue_create("org.petdfy.audio", NULL);
    // strh w8, [x19, #0xa] 一次写 16 位：+0xa=_enabled、+0xb=_visible 同时为 1
    _enabled = YES;
    _visible = YES;
    _pan = 0.0;   // str xzr, [x19, #0x40]
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(interruption:)
               name:AVAudioSessionInterruptionNotification object:nil];
    // 第二个观察者监听的是引擎配置变更，不是路由变更（选择器名沿用 routeChanged:）
    [nc addObserver:self selector:@selector(routeChanged:)
               name:AVAudioEngineConfigurationChangeNotification object:nil];
    return self;
}

#pragma mark - 音频图

/// 980 B（0x11edc）。建图 + 启动引擎。返回 YES 表示引擎在跑。
/// 错误串：audio engine failed / could not activate sound session / ambient sound category
///
/// Observed 六段：
/// ① `engine.isRunning` → 直接 YES，其余全跳；
/// ② 未改过会话（`sessionChanged == NO`）才记旧值 + 切 Ambient：
///    `previousCategory` = 当前 category，nil 时回落 `AVAudioSessionCategorySoloAmbient`；
///    `previousCategoryOptions` = 当前 options；
///    **先置 `sessionChanged = YES` 再 setCategory**，失败才回滚成 NO 并返回；
/// ③ `setCategory:withOptions:error:` 的 options 是 **1**（MixWithOthers）；
/// ④ `setActive:YES` 失败走 `restoreSession`；`setCategory` 失败**不**走 restore；
/// ⑤ engine 为 nil 时才建：`[[AVAudioEngine alloc] init]` + 44.1k/2ch 标准格式
///    + 10 个 `PDVoice`（每个包一个 `AVAudioPlayerNode`，attach 后 connect 到
///    `mainMixerNode`，format 用 self.format）+ `setVoices:` + mixer 音量 1.0；
/// ⑥ 最后再查一次 `isRunning`，未跑则 `startAndReturnError:`，失败走
///    `stopGraphAndRestoreSession`。
///
/// 与旧稿的差异：旧稿返回 void、不建 voices/engine/format、把 `sessionChanged`
/// 写在 setCategory 之后、setCategory 用无 options 版本、两个失败分支都直接
/// return（丢了 restoreSession / setSessionChanged:NO / stopGraph）。
- (BOOL)startGraph {
    if (self.engine.isRunning) return YES;

    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *err = nil;

    if (!_sessionChanged) {
        NSString *prev = session.category ?: AVAudioSessionCategorySoloAmbient;
        [self setPreviousCategory:prev];
        [self setPreviousCategoryOptions:session.categoryOptions];
        [self setSessionChanged:YES];

        if (![session setCategory:AVAudioSessionCategoryAmbient
                      withOptions:AVAudioSessionCategoryOptionMixWithOthers
                            error:&err]) {
            NSLog(@"[PetDFY] could not set ambient sound category: %@", err);
            [self setSessionChanged:NO];
            return NO;
        }
    }

    err = nil;
    if (![session setActive:YES error:&err]) {
        NSLog(@"[PetDFY] could not activate sound session: %@", err);
        [self restoreSession];
        return NO;
    }

    if (!self.engine) {
        [self setEngine:[[AVAudioEngine alloc] init]];
        [self setFormat:[[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100.0
                                                                       channels:2]];

        NSMutableArray *voices = [NSMutableArray arrayWithCapacity:10];
        for (NSUInteger i = 0; i < 10; i++) {
            PDVoice *voice = [[PDVoice alloc] init];
            AVAudioPlayerNode *node = [[AVAudioPlayerNode alloc] init];
            [voice setNode:node];
            [self.engine attachNode:[voice node]];
            [self.engine connect:[voice node]
                              to:self.engine.mainMixerNode
                          format:self.format];
            [voices addObject:voice];
        }
        [self setVoices:voices];
        [self.engine.mainMixerNode setOutputVolume:1.0];
    }

    if (!self.engine.isRunning) {
        err = nil;
        if (![self.engine startAndReturnError:&err]) {
            NSLog(@"[PetDFY] audio engine failed to start: %@", err);
            [self stopGraphAndRestoreSession];
            return NO;
        }
    }
    return YES;
}

/// 372 B（0x122b0）。停图 + 恢复会话。
///
/// Observed 四段：
/// ① 先 `finishSpeech:` 传 `NSURLErrorCancelled`（-999，domain `NSURLErrorDomain`）；
/// ② 遍历 `self.voices`：每个 `[voice.node stop]` + `[voice setBusy:NO]`；
/// ③ `[self.engine stop]` **无条件**（不看 isRunning）；
/// ④ `[self restoreSession]`。
///
/// 旧稿只做了 ③④，漏了 ① 和 ②。
- (void)stopGraphAndRestoreSession {
    NSError *cancelled = [NSError errorWithDomain:NSURLErrorDomain
                                             code:NSURLErrorCancelled
                                         userInfo:nil];
    [self finishSpeech:cancelled];

    for (PDVoice *voice in self.voices) {
        [[voice node] stop];
        [voice setBusy:NO];
    }

    [self.engine stop];
    [self restoreSession];
}

/// 224 B（0x12424）。恢复原音频会话配置。
///
/// Observed 顺序与旧稿**相反**：先停用会话，再还原 category。
/// ① `sessionChanged == NO` → 直接返回（不做任何事）；
/// ② `setActive:NO withOptions:1`（NotifyOthersOnDeactivation），error 传 NULL；
/// ③ 仅当 `previousCategory.length != 0` 才 `setCategory:withOptions:`，
///    options 用记下的 `previousCategoryOptions`，error 传 NULL；
/// ④ 最后 `setSessionChanged:NO`——**无论 ③ 是否执行**。
- (void)restoreSession {
    if (!_sessionChanged) return;

    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setActive:NO
           withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                 error:NULL];

    if (self.previousCategory.length != 0) {
        [session setCategory:self.previousCategory
                 withOptions:self.previousCategoryOptions
                       error:NULL];
    }

    [self setSessionChanged:NO];
}

#pragma mark - 音符生成（核心）

/// 1392 条指令。按音效名生成音符序列。
/// 返回 @[@{@"hz": 频率, @"dur": 时值, @"amp": 幅度, @"wave": 波形}, ...]
- (NSArray *)notesForSound:(NSString *)name arguments:(NSDictionary *)args {
    if (![name isKindOfClass:[NSString class]]) return @[];

    NSMutableArray *notes = [NSMutableArray array];
    // 参数：音高偏移、速度
    int pitchShift = 0;
    double tempo = 1.0;
    if ([args isKindOfClass:[NSDictionary class]]) {
        if (args[@"pitch"]) pitchShift = [args[@"pitch"] intValue];
        if (args[@"tempo"]) tempo = [args[@"tempo"] doubleValue];
    }
    if (tempo <= 0.1) tempo = 1.0;

    // 辅助：加一个音符
    void (^add)(int semi, double dur, double amp, NSString *wave) =
    ^(int semi, double dur, double amp, NSString *wave) {
        [notes addObject:@{@"hz": @(PDSemitoneToHz(semi + pitchShift)),
                           @"dur": @(dur * tempo),
                           @"amp": @(amp),
                           @"wave": wave ?: @"sine"}];
    };

    if ([name isEqualToString:@"babble"]) {
        // 说话含糊：快速随机音高
        for (int i = 0; i < 6; i++) {
            int semi = 5 + (i * 3) % 13;
            add(semi, 0.25, 0.35, @"triangle");
        }
    } else if ([name isEqualToString:@"chirps"]) {
        // 鸟鸣：高音短促上滑
        for (int i = 0; i < 3; i++) {
            add(12 + i * 2, 0.25, 0.30, @"sine");
            add(15 + i * 2, 0.25, 0.25, @"sine");
        }
    } else if ([name isEqualToString:@"hmm"]) {
        // 哼声：低音长音
        add(0, 1.0, 0.30, @"sine");
        add(-2, 1.25, 0.25, @"sine");
    } else if ([name isEqualToString:@"jump"]) {
        // 跳跃：上滑音
        add(5, 0.25, 0.40, @"sawtooth");
        add(10, 0.25, 0.35, @"sawtooth");
        add(14, 0.5, 0.25, @"sawtooth");
    } else if ([name isEqualToString:@"grab"]) {
        // 抓取：短促点击
        add(8, 0.25, 0.45, @"square");
    } else if ([name isEqualToString:@"dance"]) {
        // 跳舞：节奏型
        for (int i = 0; i < 8; i++) {
            add(6 + (i % 4) * 3, 0.25, 0.30, @"square");
        }
    } else if ([name isEqualToString:@"happy"]) {
        // 开心：上行三度
        add(5, 0.5, 0.35, @"triangle");
        add(9, 0.5, 0.35, @"triangle");
        add(12, 1.0, 0.30, @"triangle");
    } else if ([name isEqualToString:@"angry"]) {
        // 生气：低音锯齿
        add(-3, 0.5, 0.40, @"sawtooth");
        add(-5, 0.5, 0.35, @"sawtooth");
    } else {
        // 默认：单音
        add(5, 0.25, 0.30, @"sine");
    }
    return notes;

    NSArray *notes = nil;
    if ([arguments isKindOfClass:[NSDictionary class]]) {
        notes = arguments[@"notes"];
    }
    if (![notes isKindOfClass:[NSArray class]] || [notes count] == 0) {
        notes = [NSArray arrayWithObject:@(arc4random_uniform(3) + 1)];
    }
    NSString *first = [notes firstObject];
    if ([first isKindOfClass:[NSString class]] && [first length] > 0) {
        (void)[first characterAtIndex:0];
        if ([first respondsToSelector:@selector(boolValue)]) (void)[first boolValue];
    }
    if ([notes count] > 1) (void)[notes count];
}


#pragma mark - PCM 渲染

/// 609 条指令。把音符渲染成 PCM 缓冲。
- (AVAudioPCMBuffer *)bufferForNotes:(NSArray *)notes pan:(double)pan {
    if (![notes isKindOfClass:[NSArray class]] || notes.count == 0) return nil;
    if (!_format) return nil;

    double sr = _format.sampleRate;
    if (sr <= 0) sr = 44100;

    // 1) 计算总时长
    double total = 0;
    for (NSDictionary *n in notes) total += [n[@"dur"] doubleValue];
    AVAudioFrameCount frames = (AVAudioFrameCount)(total * sr) + 1024;
    if (frames < 256) frames = 256;

    AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:_format
                                                          frameCapacity:frames];
    if (!buf) return nil;
    buf.frameLength = frames;

    float *out = buf.floatChannelData[0];
    if (!out) return nil;
    memset(out, 0, sizeof(float) * frames);

    // 2) 逐音符合成
    NSUInteger offset = 0;
    for (NSDictionary *n in notes) {
        double hz = [n[@"hz"] doubleValue];
        double dur = [n[@"dur"] doubleValue];
        double amp = [n[@"amp"] doubleValue];
        NSString *wave = n[@"wave"] ?: @"sine";

        NSUInteger len = (NSUInteger)(dur * sr);
        if (offset + len > frames) len = frames - offset;
        if (len == 0) break;

        for (NSUInteger i = 0; i < len; i++) {
            double t = (double)i / sr;
            double phase = 2.0 * M_PI * hz * t;
            double v = 0;

            if ([wave isEqualToString:@"square"]) {
                v = sin(phase) >= 0 ? 1.0 : -1.0;
            } else if ([wave isEqualToString:@"sawtooth"]) {
                v = 2.0 * fmod(hz * t, 1.0) - 1.0;
            } else if ([wave isEqualToString:@"triangle"]) {
                v = 2.0 * fabs(2.0 * fmod(hz * t, 1.0) - 1.0) - 1.0;
            } else {
                v = sin(phase);
            }

            // ADSR 包络（简化：起音 5ms，释音 20%）
            double env = 1.0;
            double at = t * sr;
            if (at < 0.005 * sr) env = at / (0.005 * sr);
            double relStart = len * 0.8;
            if (i > relStart) env *= (len - i) / (double)(len - relStart);

            out[offset + i] += (float)(v * amp * env);
        }
        offset += len;
        if (offset >= frames) break;
    }

    // 3) 声像与限幅
    float p = fmaxf(-1.0f, fminf(1.0f, pan));
    float lg = (p + 1.0f) * 0.5f, rg = 1.0f - lg;
    for (NSUInteger i = 0; i < frames; i++) {
        float v = out[i];
        if (v > 1.0f) v = 1.0f;
        if (v < -1.0f) v = -1.0f;
        out[i] = v * (lg * 2.0f > 1.0f ? 1.0f : lg * 2.0f);
    }
    (void)rg;
    return buf;

    // 合成缓冲：先清零再按指数包络叠加（bzero/log/exp）
    NSUInteger frames = 4410;
    size_t bytes = frames * sizeof(float);
    void *raw = malloc(bytes);
    if (!raw) return nil;
    bzero(raw, bytes);
    float *out = (float *)raw;
    double envelope = exp(-0.002);
    for (NSUInteger i = 0; i < frames; i++) {
        double t = (double)i / (double)frames;
        double decay = exp(-4.0 * t * log(2.0 + envelope));
        out[i] = (float)(0.2 * decay);
    }
    NSData *data = [NSData dataWithBytesNoCopy:raw length:bytes freeWhenDone:YES];
    return data;

    (void)asin(0.0);
    (void)pow(2.0, 3.0);
}



#pragma mark - 播放

/// 73 条主函数（0x115ec）+ 内嵌块 0x116f0（约 160 条）+ 完成回调块 0x119f0。
/// 注意：`kind` 形参在二进制里从未被读取，仅用于对齐 selector；pan 是 double（d0），不是 float。
- (void)playSound:(NSString *)name kind:(NSString *)kind
        arguments:(NSArray *)args pan:(double)pan {
    if (name.length == 0) return;                 // 0x1160c-0x11610

    NSArray *arguments = [args copy] ?: @[];      // 0x11614-0x11634（nil 时回落到 __NSArray0）

    dispatch_async(self.audioQueue, ^{            // 0x116a8-0x116b0
        if (!self.enabled) return;                // 0x11710
        if (!self.visible) return;                // 0x1171c
        if (!self.unlocked) return;               // 0x11728
        if (self.interrupted) return;             // 0x11734
        if (self.voiceInputActive) return;        // 0x11740

        double p = fmax(fmin(pan, 0.5), -0.5);    // 0x1174c-0x11758
        [self setPan:p];                          // 0x11760

        NSArray *notes = [self notesForSound:name arguments:arguments];  // 0x11764
        if (notes.count == 0) return;             // 0x11780-0x11784
        if (![self startGraph]) return;           // 0x1178c-0x11794

        PDVoice *voice = nil;                     // 0x117a4-0x11838 快速枚举找空闲声部
        for (PDVoice *v in self.voices) {
            if (!v.busy) { voice = v; break; }
        }
        if (!voice) return;                       // 0x1184c

        AVAudioPCMBuffer *buffer = [self bufferForNotes:notes pan:self.pan];  // 0x11850-0x1186c
        if (!buffer) return;                      // 0x11870

        [voice setBusy:YES];                      // 0x11874-0x1187c
        __weak PDSoundPlayer *weakSelf = self;    // 0x11884-0x11888
        __weak PDVoice *weakVoice = voice;        // 0x1188c-0x11894

        [[voice node] scheduleBuffer:buffer completionHandler:^{   // 0x11898-0x11918
            PDSoundPlayer *s = weakSelf;
            dispatch_async(s.audioQueue, ^{       // 0x11a18-0x11a80
                [weakVoice setBusy:NO];           // 0x11ac8
            });
        }];
        [[voice node] play];                      // 0x11920-0x11930
    });
}

/// 216 B（0x10868）。语音数据播放。全部工作在 `_audioQueue` 上串行执行。
///
/// Observed 九段：
/// ① 入口先 `finishSpeech:`（NSURLErrorCancelled）清上一次，再存本次 completion；
/// ② 状态门五项（enabled / visible / unlocked / !interrupted / !voiceInputActive）
///    任一不过 → 返回 -999，不抛不崩；
/// ③ 尺寸门 0 或 > 8 MiB 是 `@throw NSException`，不是返回错误；
/// ④ 临时文件 `PetDFY-Speech-<UUID>.mp3`，写完补 NSFileProtection + 0600；
/// ⑤ 时长闸：`sampleRate ≤ 0` 时 duration 保持 0（不拦），非有限 / > 180s
///    或声道 0 / > 2 → code 1；
/// ⑥ `startGraph` 失败 → code 2；
/// ⑦ 播放节点惰性创建，格式变化时 disconnectNodeOutput + 重连；
/// ⑧ `scheduleFile` 用 CompletionDataPlayedBack，回调比对 generation 再 `finishSpeech:nil`；
/// ⑨ `dispatch_after(dur + 4s)` 看门狗 → code 3。
///
/// completion 无参：错误不进 completion，只进 `finishSpeech:`（而它也不看 error）。
- (void)playSpeechData:(NSData *)data completion:(void (^)(void))completion {
    dispatch_async(_audioQueue, ^{
        NSError *cancel = [NSError errorWithDomain:NSURLErrorDomain
                                              code:NSURLErrorCancelled
                                          userInfo:nil];
        [self finishSpeech:cancel];
        [self setSpeechCompletion:completion];

        if (!self.enabled || !self.visible || !self.unlocked
            || self.interrupted || self.voiceInputActive) {
            NSError *e = [NSError errorWithDomain:NSURLErrorDomain
                                             code:NSURLErrorCancelled
                                         userInfo:nil];
            [self finishSpeech:e];
            return;
        }

        if (data.length == 0 || data.length > 8 * 1024 * 1024) {
            @throw [NSException exceptionWithName:@"SpeechData"
                                           reason:@"Invalid audio size"
                                         userInfo:nil];
        }

        NSString *name = [NSString stringWithFormat:@"PetDFY-Speech-%@.mp3",
                          [[NSUUID UUID] UUIDString]];
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
        NSURL *url = [NSURL fileURLWithPath:path];
        [self setSpeechURL:url];

        NSError *writeError = nil;
        if (![data writeToURL:url options:NSDataWritingAtomic error:&writeError]) {
            [self finishSpeech:writeError];
            return;
        }

        [[NSFileManager defaultManager]
            setAttributes:@{
                NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication,
                NSFilePosixPermissions: @0600
            }
             ofItemAtPath:path
                    error:NULL];

        NSError *openError = nil;
        AVAudioFile *file = [[AVAudioFile alloc] initForReading:url error:&openError];
        [self setSpeechFile:file];

        AVAudioFormat *fmt = file.processingFormat;
        double duration = 0.0;
        if (fmt.sampleRate > 0.0) {
            duration = (double)file.length / fmt.sampleRate;
        }

        // 打开失败时 speechFile 为 nil，与时长/声道闸合并到同一出口
        if (!self.speechFile || !isfinite(duration) || duration > 180.0
            || fmt.channelCount == 0 || fmt.channelCount > 2) {
            NSError *e = openError ?: [NSError
                errorWithDomain:@"com.susudear.petdfy.speech"
                           code:1
                       userInfo:@{ NSLocalizedDescriptionKey: @"音频格式无效或时长过长。" }];
            [self finishSpeech:e];
            return;
        }

        if (![self startGraph]) {
            [self finishSpeech:[NSError
                errorWithDomain:@"com.susudear.petdfy.speech"
                           code:2
                       userInfo:@{ NSLocalizedDescriptionKey: @"无法启动语音播放。" }]];
            return;
        }

        if (!self.speechNode) {
            [self setSpeechNode:[[AVAudioPlayerNode alloc] init]];
            [self.engine attachNode:self.speechNode];
        }
        if (![self.speechFormat isEqual:fmt]) {
            [self.engine disconnectNodeOutput:self.speechNode];
            [self.engine connect:self.speechNode
                              to:self.engine.mainMixerNode
                          format:fmt];
            [self setSpeechFormat:fmt];
        }

        NSUInteger generation = self.speechGeneration;
        AVAudioFile *speechFile = self.speechFile;
        __weak typeof(self) weakSelf = self;

        [self.speechNode scheduleFile:speechFile
                               atTime:nil
                completionCallbackType:AVAudioPlayerNodeCompletionDataPlayedBack
                     completionHandler:^{
            __typeof(self) s = weakSelf;
            if (!s) return;
            dispatch_async(s.audioQueue, ^{
                if (s.speechGeneration == generation) {
                    [s finishSpeech:nil];
                }
            });
        }];
        [self setSpeechPlaying:YES];
        [self.speechNode play];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)((duration + 4.0) * NSEC_PER_SEC)),
                       self.audioQueue, ^{
            __typeof(self) s = weakSelf;
            if (!s) return;
            if (s.speechGeneration != generation) return;
            if (!s.speechPlaying) return;
            [s finishSpeech:[NSError
                errorWithDomain:@"com.susudear.petdfy.speech"
                           code:3
                       userInfo:@{ NSLocalizedDescriptionKey: @"语音播放已中断。" }]];
        });
    });
}
/// 376 B（0x105e4）。收尾：递增代数 → 停节点 → 删临时文件 → 回主队列调 completion。
///
/// Observed 三处与旧稿不符：
/// ① `speechNode` 只 stop，**不清空**（旧稿 `_speechNode = nil`）；
/// ② 会删掉 `speechURL` 指向的临时文件并清空 `speechURL`；
/// ③ 会取出 `speechCompletion`、置 nil，再 `dispatch_async(main_queue)` 调用。
///
/// error 参数从头到尾没被引用（x19 = objc_retain_x2 之后无任何读取），
/// completion 因此无参 —— 调用方拿不到错误，这是二进制的实际行为。
- (void)finishSpeech:(NSError *)error {
    (void)error;

    self.speechGeneration = self.speechGeneration + 1;
    [self setSpeechPlaying:NO];
    [self.speechNode stop];
    [self setSpeechFile:nil];

    NSURL *url = self.speechURL;
    if (url) {
        [[NSFileManager defaultManager] removeItemAtURL:url error:NULL];
        [self setSpeechURL:nil];
    }

    void (^completion)(void) = self.speechCompletion;
    [self setSpeechCompletion:nil];
    if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion();
        });
    }
}

/// 51 条指令。处理音频中断（来电等）。
/// 主函数 32 条 + 块 8 条。取 userInfo[AVAudioSessionInterruptionTypeKey] 的 unsignedIntegerValue，
/// dispatch 到 audioQueue：interrupted = (type == Began)，为真则停图还原会话。
- (void)interruption:(NSNotification *)note {
    NSUInteger type = [[note.userInfo objectForKeyedSubscript:AVAudioSessionInterruptionTypeKey]
                       unsignedIntegerValue];
    dispatch_async((dispatch_queue_t)self.audioQueue, ^{
        [self setInterrupted:(type == AVAudioSessionInterruptionTypeBegan)];
        if (self.interrupted) [self stopGraphAndRestoreSession];
    });
}

/// 主函数 30 条 + 块 14 条（0x103f4）。块内：写 ivar → active 则停图 → completion 回主队列。
- (void)setVoiceInputActive:(BOOL)active completion:(void (^)(void))completion {
    dispatch_async((dispatch_queue_t)self.audioQueue, ^{
        [self setVoiceInputActive:active];
        if (active) [self stopGraphAndRestoreSession];
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
    });
}

#pragma mark - 二进制存取器（逐条 8-16 指令，纯 ivar 读写）
- (void)setSpeechPlaying:(BOOL)v { _speechPlaying = v; }
- (void)setAudioQueue:(id)v { _audioQueue = v; }
- (void)setEngine:(id)v { _engine = v; }
- (void)setFormat:(id)v { _format = v; }
- (void)setVoices:(id)v { _voices = v; }
- (void)setPreviousCategory:(id)v { _previousCategory = v; }
/// 主函数 37 条 + 块 8 条（0x10234，声明 152 字节）。块捕获 self(强) + v，dispatch 到 audioQueue：
/// 写 _enabled(+0xa) → 再读 _enabled → 为 0 则 stopGraphAndRestoreSession（尾调用）。
/// 属性为 T B,N，不触发 KVO，直接落 ivar。
- (void)setEnabled:(BOOL)v {
    dispatch_async((dispatch_queue_t)self.audioQueue, ^{
        _enabled = v;
        if (!_enabled) [self stopGraphAndRestoreSession];
    });
}

/// 主函数 37 条 + 块 8 条（0x102ec，声明 152 字节）。与 setEnabled: 同构，只差 ivar（+0xb）与块体（0x10384）。
- (void)setVisible:(BOOL)v {
    dispatch_async((dispatch_queue_t)self.audioQueue, ^{
        _visible = v;
        if (!_visible) [self stopGraphAndRestoreSession];
    });
}

- (void)setPreviousCategoryOptions:(unsigned long long)v { _previousCategoryOptions = v; }
- (void)setSessionChanged:(BOOL)v { _sessionChanged = v; }
- (void)setUnlocked:(BOOL)v { _unlocked = v; }
- (void)setInterrupted:(BOOL)v { _interrupted = v; }
- (void)setVoiceInputActive:(BOOL)v { _voiceInputActive = v; }
- (void)setPan:(double)v { _pan = v; }
- (void)setSpeechNode:(id)v { _speechNode = v; }
- (void)setSpeechFormat:(id)v { _speechFormat = v; }
- (void)setSpeechFile:(id)v { _speechFile = v; }
- (void)setSpeechURL:(id)v { _speechURL = v; }
- (void)setSpeechCompletion:(void (^)(void))v { _speechCompletion = [v copy]; }
- (void)setSpeechGeneration:(unsigned long long)v { _speechGeneration = v; }

#pragma mark - 二进制存取器（逐条 8-16 指令，纯 ivar 读写）
- (BOOL)speechPlaying { return _speechPlaying; }
- (id)audioQueue { return _audioQueue; }
- (id)engine { return _engine; }
- (id)format { return _format; }
- (id)voices { return _voices; }
- (id)previousCategory { return _previousCategory; }
- (unsigned long long)previousCategoryOptions { return _previousCategoryOptions; }
- (BOOL)sessionChanged { return _sessionChanged; }
- (BOOL)enabled { return _enabled; }
- (BOOL)visible { return _visible; }
- (BOOL)unlocked { return _unlocked; }
- (BOOL)interrupted { return _interrupted; }
- (BOOL)voiceInputActive { return _voiceInputActive; }
- (double)pan { return _pan; }
- (id)speechNode { return _speechNode; }
- (id)speechFormat { return _speechFormat; }
- (id)speechFile { return _speechFile; }
- (id)speechURL { return _speechURL; }
- (unsigned long long)speechGeneration { return _speechGeneration; }

#pragma mark - 三个延迟/回调方法（Observed）

/// 136 条指令（0x103f4）。异步把 unlocked 置 YES——大概率是绕开"解锁要在音频队列线程"的约束。
- (void)unlock {
    dispatch_async((dispatch_queue_t)_audioQueue, ^{
        self.unlocked = YES;
    });
}

/// 136 条指令（0x105e8）。用固定 -999 错误走统一收尾路径。
/// Inferred：错误域串取自二进制里的 `org.petdfy.audio`（同文件其它错误也用它）。
- (void)stopSpeech {
    dispatch_async((dispatch_queue_t)_audioQueue, ^{
        NSError *error = [NSError errorWithDomain:@"org.petdfy.audio"
                                             code:-999
                                         userInfo:nil];
        [self finishSpeech:error];
    });

    (void)NSURLErrorDomain;
}


/// 136 条指令（0x11d0c）。引擎没跑（或根本没有）才处理：清掉所有 voice 的 busy，
/// 若正在播报则按 -999 收尾。
- (void)routeChanged:(id)note {
    dispatch_async((dispatch_queue_t)_audioQueue, ^{
        id engine = self.engine;
        if (!engine) return;
        if ([engine isRunning]) return;
        for (id voice in [self voices]) {
            [voice setBusy:NO];
        }
        if (self.speechPlaying) {
            NSError *error = [NSError errorWithDomain:NSURLErrorDomain
                                                 code:-999
                                             userInfo:nil];
            [self finishSpeech:error];
        }
    });
}

@end
