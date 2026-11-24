//
//  PDReplySpeech : NSObject
//  逆向还原：ivar/方法/属性来自二进制元数据
//
//  method_t types（objc_full.json）：
//    startText:key:speaker:instruction:options:completion:
//        v80@0:8@16@24@32@40{?=qqq}48@?72
//    options      {?=qqq}16@0:8          ← 返回 24 字节结构体（sret）
//    setOptions:  v40@0:8{?=qqq}16       ← 结构体按值传，落在 sp+16
//    next         v16@0:8
//
//  ivar _options 类型：{?="pitch"q"speechRate"q"loudnessRate"q}，偏移 104，大小 24
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"
#import "PDDoubaoTTS.h"

/// {?="pitch"q"speechRate"q"loudnessRate"q}
// 二进制类型编码 {?=qqq}，与 PDDoubaoTTS 的 options 是同一形状的结构体
typedef PDDoubaoOptions PDReplySpeechOptions;

@interface PDReplySpeech : NSObject {
    BOOL _busy;
    NSURLSessionConfiguration * _sessionConfiguration;
    void (^_play)(NSString *, void (^)(NSError *));
    void (^_stop)(void);
    void (^_completion)(NSError *);
    PDDoubaoTTS * _client;
    NSMutableArray * _segments;
    NSString * _key;
    NSString * _speaker;
    NSString * _instruction;
    unsigned long long _generation;
    unsigned long long _index;
    PDReplySpeechOptions _options;
}

@property (nonatomic, copy) void (^play)(NSString *, void (^)(NSError *));
@property (nonatomic, copy) void (^stop)(void);
@property (nonatomic, copy) void (^completion)(NSError *);
@property (nonatomic, strong) PDDoubaoTTS * client;
@property (nonatomic, copy) NSArray * segments;
@property (nonatomic, copy) NSString * key;
@property (nonatomic, copy) NSString * speaker;
@property (nonatomic, copy) NSString * instruction;
@property (nonatomic) PDReplySpeechOptions options;
@property (nonatomic) unsigned long long generation;
@property (nonatomic) unsigned long long index;
@property (nonatomic) BOOL busy;
@property (nonatomic, strong) NSURLSessionConfiguration * sessionConfiguration;

- (id)initWithPlay:(void (^)(NSString *, void (^)(NSError *)))play stop:(void (^)(void))stop;
- (void)startText:(NSString *)text key:(NSString *)key speaker:(NSString *)speaker instruction:(NSString *)instruction options:(PDReplySpeechOptions)options completion:(void (^)(NSError *))completion;
- (void)finish:(NSError *)arg1;
- (void)next;
- (void)cancel;
- (void)dealloc;
- (BOOL)busy;
- (void)setBusy:(BOOL)arg1;
- (void (^)(NSString *, void (^)(NSError *)))play;
- (void)setPlay:(void (^)(NSString *, void (^)(NSError *)))arg1;
- (void (^)(void))stop;
- (void)setStop:(void (^)(void))arg1;
- (void (^)(NSError *))completion;
- (void)setCompletion:(void (^)(NSError *))arg1;
- (PDReplySpeechOptions)options;
- (void)setOptions:(PDReplySpeechOptions)arg1;
- (unsigned long long)generation;
- (void)setGeneration:(unsigned long long)arg1;
- (unsigned long long)index;
- (void)setIndex:(unsigned long long)arg1;
@end
