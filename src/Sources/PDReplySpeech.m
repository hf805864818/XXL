//
//  Batch5.m — 逆向还原：4 个类
//
//  PDActiveInterfaceOrientationMonitor (15 方法 / 277 指令)
//  PDReplySpeech                       (32 方法 / 332 指令)
//  PDNative_MCPAXQueryContext          (21 方法 / 332 指令)
//  PDComposerTextView                  (13 方法 / 364 指令)
//

#import "PDActiveInterfaceOrientationMonitor.h"
#import "PDReplySpeech.h"
#import "PDNative_MCPAXQueryContext.h"
#import "PDComposerTextView.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>

#pragma mark - PDReplySpeech

static NSArray *_PDDoubaoSpeechSegments(NSString *text) {
    return text.length ? @[text] : @[];
}

@implementation PDReplySpeech

/// 46 条（0x16670）。`+0x18`=_play、`+0x20`=_stop（objc_retainBlock，即对 block 做 copy）；
/// `+0x10`=_sessionConfiguration = [NSURLSessionConfiguration defaultSessionConfiguration]（0x121ea8）。
- (instancetype)initWithPlay:(void (^)(NSString *, void (^)(NSError *)))play
                       stop:(void (^)(void))stop {
    self = [super init];
    if (!self) return nil;
    _play = [play copy];                                      // 0x166c8-0x166d4
    _stop = [stop copy];                                      // 0x166dc-0x166e8
    _sessionConfiguration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    return self;
}

/// 73 条（0x16728）。options 是 24 字节结构体（q0 + [x5+0x10]，走栈传参）。
/// 二进制无入参校验、无文本切分、无 token 比对——纯存取 + 触发 `-[self next]`。
/// 段切分在 `_PDDoubaoSpeechSegments(...)`（0x167e0 的 `bl`，全局 C 函数）里做。
- (void)startText:(NSString *)text key:(NSString *)key speaker:(NSString *)speaker
      instruction:(NSString *)instruction options:(PDReplySpeechOptions)options
       completion:(void (^)(NSError *))completion {
    [self cancel];                              // 0x1678c
    [self setKey:key];                          // 0x16798
    [self setSpeaker:speaker];                  // 0x167a8
    [self setInstruction:instruction];          // 0x167b8
    [self setOptions:options];                  // 0x167d8（24B 栈结构）
    [self setSegments:_PDDoubaoSpeechSegments(text)];   // 0x167e0 → 0x167f8
    [self setIndex:0];                          // 0x16808
    [self setCompletion:completion];            // 0x16814
    [self setBusy:YES];                         // 0x16824
    [self next];                                // 0x1682c
}

/// 43 条（0x1684c）。收尾：清 busy/client/key/segments → 取 completion 块 → 清 completion → 回调 → 返回 error。
- (void)finish:(NSError *)error {
    [self setBusy:NO];                                        // 0x16874
    [self setClient:nil];                                     // 0x16880
    [self setKey:nil];                                        // 0x1688c
    [self setSegments:nil];                                   // 0x16898
    void (^completion)(NSError *) = [self completion];        // 0x168a0
    [self setCompletion:nil];                                 // 0x168b4
    if (completion) completion(error);                        // 0x168b8-0x168cc
}

/// 0x168f8，约 500 条指令。取下一段 → 起一次合成 → 播放回调后再递归。
/// 主流程（地址为二进制偏移）：
///   0x16918  [self index]            → x19
///   0x1692c  [self segments]         → x21 ; 0x16938 [segments count] → x22
///   0x16944  cmp x19,x22 / b.hs 0x16ad8 → [self finish:nil]   越界即收尾
///   0x16954  objc_initWeak(sp+0x48, self)                     内部用了 __weak
///   0x1695c  [self generation]       → x19（本轮 token）
///   0x16970  objc_alloc(0x122ee0 = PDDoubaoTTS 类对象)
///   0x1697c  [self sessionConfiguration] → initWithConfiguration: → 0x16998 [self setClient:]
///   0x169a4  [self client] → x21 ; 0x169b8 [self segments] → x22
///   0x169d4  [segments objectAtIndexedSubscript:[self index]] → x23
///   0x169e0  [self key] / [self speaker] / [self instruction] → x24 / x25 / x26
///   0x16a10  [self options] 以 sret 写 sp+0x30（24 字节结构体）→ x6 = &struct
///   0x16a30  块 0x16b30 建在 sp（invoke 0x16b30 / desc 0xf9238，捕获 weak self + token）
///   0x16a64  synthesizeText:key:speaker:instruction:options:completion:
/// 块 0x16b30（x1 = 合成结果对象，x2 = NSError）：
///   weak self 取不到 / generation 变了 / 已不 busy → 返回
///   [self setClient:nil]；error 非空 → [self finish:error]
///   否则取出 [self play]，play(段, 块 0x16c84)
/// 块 0x16c84（x1 = NSError）：建块 0x16d48（捕获 weak self + token + err）后
///   dispatch_async(主队列, 块 0x16d48)
/// 块 0x16d48：weak self / generation / busy 三重校验后
///   err ? [self finish:err] : ([self setIndex:[self index]+1]; [self next])
- (void)next {
    NSUInteger idx = [self index];
    if (idx >= [[self segments] count]) {
        [self finish:nil];
        return;
    }

    NSUInteger token = [self generation];
    __weak PDReplySpeech *weakSelf = self;

    [self setClient:[[PDDoubaoTTS alloc] initWithConfiguration:[self sessionConfiguration]]];

    PDDoubaoTTS *client = [self client];
    NSArray *segments = [self segments];
    id segment = segments[[self index]];
    NSString *key = [self key];
    NSString *speaker = [self speaker];
    NSString *instruction = [self instruction];
    PDReplySpeechOptions options = [self options];

    [client synthesizeText:segment
                       key:key
                   speaker:speaker
               instruction:instruction
                   options:options
                completion:^(NSData *audio, NSError *error) {
        PDReplySpeech *s = weakSelf;
        if (!s) return;
        if ([s generation] != token) return;
        if (![s busy]) return;

        [s setClient:nil];
        if (error) {
            [s finish:error];
            return;
        }

        void (^play)(NSString *, void (^)(NSError *)) = [s play];
        play((NSString *)audio, ^(NSError *playError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                PDReplySpeech *inner = weakSelf;
                if (!inner) return;
                if ([inner generation] != token) return;
                if (![inner busy]) return;

                if (playError) {
                    [inner finish:playError];
                    return;
                }
                [inner setIndex:[inner index] + 1];
                [inner next];
            });
        });
    }];
}

/// 57 条（0x16df0）。generation++ → 取消 client → 清 client/completion/busy/key/segments → 调 stop 块。
- (void)cancel {
    [self setGeneration:[self generation] + 1];      // 0x16e08-0x16e14
    [[self client] cancel];                          // 0x16e1c-0x16e2c
    [self setClient:nil];                            // 0x16e38
    [self setCompletion:nil];                        // 0x16e44
    [self setBusy:NO];                               // 0x16e50
    [self setKey:nil];                               // 0x16e5c
    [self setSegments:nil];                          // 0x16e68
    void (^stop)(void) = [self stop];                // 0x16e70
    if (stop) stop();                                // 0x16e80-0x16e9c
}

- (void)dealloc {
    [self cancel];

    (void)[self client];
}


- (PDReplySpeechOptions)options { return _options; }
- (void)setOptions:(PDReplySpeechOptions)v { _options = v; }

#pragma mark - 二进制存取器（逐条 8-16 指令，纯 ivar 读写）
- (void)setBusy:(BOOL)v { _busy = v; }
- (void)setSessionConfiguration:(id)v { _sessionConfiguration = v; }
- (void)setPlay:(id)v { _play = v; }
- (void)setStop:(id)v { _stop = v; }
- (void)setCompletion:(id)v { _completion = v; }
- (void)setClient:(id)v { _client = v; }
- (void)setSegments:(id)v { _segments = v; }
- (void)setKey:(id)v { _key = v; }
- (void)setSpeaker:(id)v { _speaker = v; }
- (void)setInstruction:(id)v { _instruction = v; }
- (void)setGeneration:(unsigned long long)v { _generation = v; }
- (void)setIndex:(unsigned long long)v { _index = v; }

#pragma mark - 二进制存取器（逐条 8-16 指令，纯 ivar 读写）
- (BOOL)busy { return _busy; }
- (id)sessionConfiguration { return _sessionConfiguration; }
- (id)client { return _client; }
- (id)segments { return _segments; }
- (id)key { return _key; }
- (id)speaker { return _speaker; }
- (id)instruction { return _instruction; }
- (unsigned long long)generation { return _generation; }
- (unsigned long long)index { return _index; }

@end

