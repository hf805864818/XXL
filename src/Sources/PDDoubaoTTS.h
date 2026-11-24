//
//  PDDoubaoTTS : NSObject
//  逆向还原：ivar/方法/属性来自二进制元数据
//

// options 参数的类型编码段是 {?=qqq}：**匿名**结构体，3 个 qword，二进制里没有字段名。
// 因此只能按偏移命名，语义保持未知。
// Inferred: PDReplySpeech.h 把 PDReplySpeechOptions 定义为 PDDoubaoOptions 的 typedef，
//   并在注释里把三个字段记作 pitch / speechRate / loudnessRate。该命名在编码里没有依据
//   （编码是 {?=qqq} 而非 {?="pitch"q...}），故本类侧不采用，只保留 field0/1/2。
//
// 位置说明：此 typedef 必须早于下面的 #import "PetDFY.h"。PetDFY.h 会反向 include
//   本头文件与 PDReplySpeech.h，而 PDReplySpeech.h 里的
//   `typedef PDDoubaoOptions PDReplySpeechOptions;` 要求该类型在那一刻已可见
//   （本文件无 include guard，#import 在环内会被直接跳过）。
typedef struct PDDoubaoOptions {
    long long field0;   // offset 0x00
    long long field1;   // offset 0x08
    long long field2;   // offset 0x10
} PDDoubaoOptions;

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

@interface PDDoubaoTTS : NSObject {
    BOOL _cancelled;
    NSURLSessionConfiguration * _configuration;
    NSURLSession * _session;
    PDDoubaoSSEDecoder * _decoder;
    void (^_completion)(NSData *, NSError *);
    NSError * _failure;                 // setFailure: 编码 v24@0:8@16 → 对象，不是 block
}

@property (nonatomic, strong) NSURLSessionConfiguration * configuration;
@property (nonatomic, strong) NSURLSession * session;
@property (nonatomic, strong) PDDoubaoSSEDecoder * decoder;
@property (nonatomic, copy) void (^completion)(NSData *, NSError *);
@property (nonatomic) BOOL cancelled;
@property (nonatomic, readonly) unsigned long long hash;
@property (nonatomic, readonly) Class superclass;
@property (nonatomic, readonly, copy) NSString * description;
@property (nonatomic, readonly, copy) NSString * debugDescription;

- (id)initWithConfiguration:(id)arg1;
- (void)synthesizeText:(id)arg1 key:(id)arg2 speaker:(id)arg3 instruction:(id)arg4 options:(PDDoubaoOptions)arg5 completion:(void (^)(NSData *audio, NSError *error))arg6;
- (void)URLSession:(id)arg1 task:(id)arg2 willPerformHTTPRedirection:(id)arg3 newRequest:(id)arg4 completionHandler:(void (^)(NSURLRequest *))arg5;
- (void)URLSession:(id)arg1 dataTask:(id)arg2 didReceiveResponse:(id)arg3 completionHandler:(void (^)(NSURLSessionResponseDisposition))arg4;
- (void)URLSession:(id)arg1 dataTask:(id)arg2 didReceiveData:(id)arg3;
- (void)URLSession:(id)arg1 task:(id)arg2 didCompleteWithError:(id)arg3;
- (void)cancel;
- (void (^)(NSData *, NSError *))completion;
- (void)setCompletion:(void (^)(NSData *, NSError *))arg1;
- (NSError *)failure;
- (void)setFailure:(id)arg1;
- (BOOL)cancelled;
- (void)setCancelled:(BOOL)arg1;
@property (nonatomic, copy) void (^onAudioChunk)(NSData *);

@end
