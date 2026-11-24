//
//  PDAssetManager : NSObject
//  逆向还原：ivar/方法/属性来自二进制元数据
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

@interface PDAssetManager : NSObject {
    BOOL _ready;
    BOOL _active;
    BOOL _busy;
    NSDictionary * _state;
    void (^_readyHandler)(BOOL, NSDictionary *);
    void (^_willChangeHandler)(NSDictionary *);
    NSObject<OS_dispatch_queue> * _queue;
    NSString * _url;
    NSString * _retry;
    NSString * _attemptedKey;
    NSDictionary * _request;
    PDVoiceServiceConnection * _helper;
    unsigned long long _generation;
}

@property (nonatomic) BOOL ready;
@property (nonatomic, copy) NSDictionary * state;
@property (nonatomic, strong) NSObject<OS_dispatch_queue> * queue;
@property (nonatomic, copy) NSString * url;
@property (nonatomic, copy) NSString * retry;
@property (nonatomic, copy) NSString * attemptedKey;
@property (nonatomic, copy) NSDictionary * request;
@property (nonatomic, strong) PDVoiceServiceConnection * helper;
@property (nonatomic) BOOL active;
@property (nonatomic) BOOL busy;
@property (nonatomic) unsigned long long generation;
@property (nonatomic, copy) void (^readyHandler)(BOOL, NSDictionary *);
@property (nonatomic, copy) void (^willChangeHandler)(NSDictionary *);

- (id)init;
- (id)attemptKey;
- (void)status:(NSString *)status progress:(long long)progress;
- (void)configureActive:(BOOL)active URL:(NSString *)url retry:(NSString *)retry;
- (void)configureActive:(BOOL)active URL:(NSString *)url retry:(NSString *)retry request:(NSDictionary *)request;
- (void)advance;
- (BOOL)ready;
- (void)setReady:(BOOL)arg1;
- (void (^)(BOOL, NSDictionary *))readyHandler;
- (void)setReadyHandler:(void (^)(BOOL, NSDictionary *))arg1;
- (void (^)(NSDictionary *))willChangeHandler;
- (void)setWillChangeHandler:(void (^)(NSDictionary *))arg1;
- (BOOL)active;
- (void)setActive:(BOOL)arg1;
- (BOOL)busy;
- (void)setBusy:(BOOL)arg1;
- (unsigned long long)generation;
- (void)setGeneration:(unsigned long long)arg1;
@end
