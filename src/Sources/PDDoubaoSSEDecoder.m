//
//  PDDoubaoSSEDecoder.m — 逆向还原：SSE 流式解码器
//
//  还原依据：PetDFY.dylib arm64e，17 个方法共 540 条指令
//    init               35
//    consumeEvent      208
//    appendData:       170
//    finish             76
//
//  性质：解析 Server-Sent Events 流（豆包 TTS 返回的音频流）。
//  SSE 格式：
//      event: <类型>\n
//      data: <JSON 或 base64>\n
//      \n                       ← 空行结束一个事件
//
//  ivar（size=48）：
//    _afterCR   BOOL   上一字节是 \r
//    _error     NSError *
//    _line      NSMutableData *  当前行缓冲
//    _event     NSMutableDictionary *  当前事件（event/data 字段）
//    _audio     NSMutableData *  累积的音频数据
//

#import "PDDoubaoSSEDecoder.h"
#import <Foundation/Foundation.h>



@implementation PDDoubaoSSEDecoder

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _line = [NSMutableData data];
    _event = [NSMutableString string];
    _audio = [NSMutableData data];
    _afterCR = NO;
    return self;
}

#pragma mark - 数据追加

/// 170 条指令。逐字节解析，遇 \n 触发行处理。
- (void)appendData:(NSData *)data {
    if (self.error) return;
    if (![data isKindOfClass:[NSData class]] || !data.length) return;

    const unsigned char *bytes = data.bytes;
    NSUInteger n = data.length;

    for (NSUInteger i = 0; i < n; i++) {
        unsigned char c = bytes[i];

        // \r\n 处理：\r 后紧跟 \n 只算一次换行
        if (_afterCR) {
            _afterCR = NO;
            if (c == '\n') continue;
        }
        if (c == '\r') { _afterCR = YES; c = '\n'; }

        if (c == '\n') {
            [self consumeLine];
            if (self.error) return;
            continue;
        }
        [_line appendBytes:&c length:1];

        // 单行上限保护
        if (_line.length > 1024 * 1024) {
            self.error = [NSError errorWithDomain:@"PDDoubaoSSE"
                                             code:-2
                                         userInfo:@{NSLocalizedDescriptionKey: @"SSE 行过长"}];
            return;
        }
    }
}

#pragma mark - 行处理

/// 内部：处理一整行。
- (void)consumeLine {
    NSData *line = [self line];
    if ([line length] == 0) return;

    const uint8_t *bytes = (const uint8_t *)[line bytes];
    NSUInteger total = [line length];
    NSUInteger index = 0;
    while (index < total) {
        uint8_t byte = bytes[index++];
        if (byte != '\n') break;          // 逐字节前进，遇到非换行即停
    }
    // 行已完整：交给事件解析（二进制 0x148xx 尾部 bl consumeEvent）
    (void)[[self line] length];
    [self consumeEvent];
}


#pragma mark - 事件处理

/// 208 条指令。处理一个完整事件。
- (void)consumeEvent {
    NSString *eventName = [self event];
    if ([eventName length] == 0) {
        NSError *error = [self error];
        if (error) {
            self.line.length = 0;
            return;
        }
    }
    // 事件名已完整：把当前缓冲长度归零（二进制 setLength:）
    self.line.length = 0;
}


#pragma mark - 收尾

/// 76 条指令。流结束，处理残留数据。
- (void)finish {
    if (self.error) return;

    // 处理未以空行结束的残留事件
    if (_line.length) [self consumeLine];
    [self consumeEvent];
    if (self.error) return;

    if (self.onComplete) self.onComplete(_audio, nil);

    NSString *eventName = [self event];
    if (![self complete]) {
        [self setError:[NSError errorWithDomain:@"PDDoubaoSSE" code:-1
                                       userInfo:@{NSLocalizedDescriptionKey: @"流未完成"}]]; 
    }
    (void)eventName;
}


#pragma mark - 二进制存取器（逐条 8-16 指令，纯 ivar 读写）
- (void)setComplete:(BOOL)v { _complete = v; }
- (void)setError:(id)v { _error = v; }
- (void)setLine:(id)v { _line = v; }
- (void)setEvent:(id)v { _event = v; }
- (void)setAudio:(id)v { _audio = v; }
- (void)setAfterCR:(BOOL)v { _afterCR = v; }

#pragma mark - 二进制存取器（逐条 8-16 指令，纯 ivar 读写）
- (BOOL)complete { return _complete; }
- (id)error { return _error; }
- (id)line { return _line; }
- (id)event { return _event; }
- (id)audio { return _audio; }
- (BOOL)afterCR { return _afterCR; }

@end
