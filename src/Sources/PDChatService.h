//
//  PDChatService : NSObject
//  逆向还原：ivar/方法/属性来自二进制元数据
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

@interface PDChatService : NSObject {
    BOOL _busy;
    BOOL _wakePending;
    BOOL _maintainingData;
    NSURL * _historyURL;
    id (^_stateProvider)(void);
    void (^_toolHandler)(NSString *, NSDictionary *, void (^)(id, NSError *));
    void (^_deviceToolHandler)(NSString *, NSDictionary *, void (^)(id, NSError *));
    void (^_turnStateHandler)(BOOL, NSError *);
    void (^_interruptionHandler)(void);
    void (^_historyClearedHandler)(void);
    NSMutableArray * _mutableHistory;
    NSMutableArray * _pendingEvents;
    NSMutableArray * _pendingAttachments;
    NSString * _dataDirectory;
    NSURLSession * _session;
    NSURLSessionDataTask * _task;
    NSObject<OS_dispatch_queue> * _storageQueue;
    PDAIMemory * _memory;
    NSArray * _calls;
    NSMutableDictionary * _toolMedia;
    NSMutableDictionary * _refusedImages;
    unsigned long long _callIndex;
    unsigned long long _round;
    unsigned long long _generation;
    NSString * _lastMaintenanceID;
    unsigned long long _contextStart;
    NSString * _handoffFile;
    NSString * _handoffText;
    NSString * _lastStampDay;
    NSString * _lastText;
    void (^_legacyCompletion)(NSError *);
}

@property (nonatomic, strong) NSMutableArray * mutableHistory;
@property (nonatomic, strong) NSMutableArray * pendingEvents;
@property (nonatomic, strong) NSMutableArray *pendingAttachments;
@property (nonatomic, copy) NSString * dataDirectory;
@property (nonatomic, strong) NSURL * historyURL;
@property (nonatomic, strong) NSURLSession * session;
@property (nonatomic, strong) NSURLSessionDataTask * task;
@property (nonatomic, strong) NSObject<OS_dispatch_queue> * storageQueue;
@property (nonatomic, strong) PDAIMemory * memory;
@property (nonatomic, strong) NSArray * calls;
@property (nonatomic, strong) NSMutableDictionary * toolMedia;
@property (nonatomic, strong) NSMutableDictionary * refusedImages;
@property (nonatomic) unsigned long long callIndex;
@property (nonatomic) unsigned long long round;
@property (nonatomic) unsigned long long generation;
@property (nonatomic) BOOL busy;
@property (nonatomic) BOOL wakePending;
@property (nonatomic) BOOL maintainingData;
@property (nonatomic, copy) NSString * lastMaintenanceID;
@property (nonatomic) unsigned long long contextStart;
@property (nonatomic, copy) NSString * handoffFile;
@property (nonatomic, copy) NSString * handoffText;
@property (nonatomic, copy) NSString * lastStampDay;
@property (nonatomic, copy) NSString * lastText;
@property (nonatomic, copy) void (^legacyCompletion)(NSError *);
@property (nonatomic, strong) NSMutableArray *history;
@property (nonatomic, copy) id (^stateProvider)(void);
@property (nonatomic, copy) void (^toolHandler)(NSString *, NSDictionary *, void (^)(id, NSError *));
@property (nonatomic, copy) void (^deviceToolHandler)(NSString *, NSDictionary *, void (^)(id, NSError *));
@property (nonatomic, copy) void (^turnStateHandler)(BOOL, NSError *);
@property (nonatomic, copy) void (^interruptionHandler)(void);
@property (nonatomic, copy) void (^historyClearedHandler)(void);

- (void)handleDataMaintenanceRequest:(id)arg1;
- (id)init;
- (id)initWithDataDirectory:(id)arg1 sessionConfiguration:(id)arg2;
- (id)error:(id)arg1 code:(long long)arg2;
- (BOOL)isConfigured;
- (id)stamp:(id)arg1;
- (void)sendText:(id)arg1 completion:(void (^)(NSError *))arg2;  // 元数据写 void，但直接存入 _legacyCompletion(NSError*)
- (void)enqueueEvent:(id)arg1 wake:(BOOL)arg2 preempt:(BOOL)arg3;
- (void)persistHistory;
- (void)appendPendingEvents;
- (void)startTurn;
- (void)enqueueUserText:(id)arg1 images:(id)arg2;
- (NSError *)requestRound;
- (void)sendPreparedRequest:(id)arg1 settings:(id)arg2 retryBytes:(id)arg3 sentImages:(id)arg4 endpoint:(id)arg5 generation:(unsigned long long)arg6 recovering:(BOOL)arg7;
- (void)handleMessage:(id)arg1;
- (void)recordTool:(id)arg1 receipt:(id)arg2;
- (void)runNextTool;
- (id)saveImage:(id)arg1;
- (void)skipRemaining:(id)arg1;
- (void)finish:(id)arg1;
- (void)cancel;
- (void)clearHistory;
- (void)performDataMaintenance:(NSString *)action path:(NSString *)path completion:(void (^)(NSError *error))completion;
- (BOOL)busy;
- (void)setBusy:(BOOL)arg1;
- (id (^)(void))stateProvider;
- (void)setStateProvider:(id (^)(void))arg1;
- (void (^)(NSString *, NSDictionary *, void (^)(id, NSError *)))toolHandler;
- (void)setToolHandler:(void (^)(NSString *, NSDictionary *, void (^)(id, NSError *)))arg1;
- (void (^)(NSString *, NSDictionary *, void (^)(id, NSError *)))deviceToolHandler;
- (void)setDeviceToolHandler:(void (^)(NSString *, NSDictionary *, void (^)(id, NSError *)))arg1;
- (void (^)(BOOL, NSError *))turnStateHandler;
- (void)setTurnStateHandler:(void (^)(BOOL, NSError *))arg1;
- (void (^)(void))interruptionHandler;
- (void)setInterruptionHandler:(void (^)(void))arg1;
- (void (^)(void))historyClearedHandler;
- (void)setHistoryClearedHandler:(void (^)(void))arg1;
- (unsigned long long)callIndex;
- (void)setCallIndex:(unsigned long long)arg1;
- (unsigned long long)round;
- (void)setRound:(unsigned long long)arg1;
- (unsigned long long)generation;
- (void)setGeneration:(unsigned long long)arg1;
- (BOOL)wakePending;
- (void)setWakePending:(BOOL)arg1;
- (BOOL)maintainingData;
- (void)setMaintainingData:(BOOL)arg1;
- (unsigned long long)contextStart;
- (void)setContextStart:(unsigned long long)arg1;
- (void (^)(NSError *))legacyCompletion;
- (void)setLegacyCompletion:(void (^)(NSError *))arg1;
+ (void)requestDataMaintenance:(NSString *)action path:(NSString *)path completion:(void (^)(NSString *errorMessage))completion;
+ (id)defaultPromptTemplate;
+ (id)normalizedPromptTemplate:(id)arg1;
+ (id)promptVariables;
+ (id)renderedPromptForTemplate:(id)arg1;
+ (void)fetchModelsAtBaseURL:(NSString *)baseURL apiKey:(NSString *)apiKey completion:(void (^)(id models, NSError *error))completion;
+ (void)fetchModelCatalogAtBaseURL:(NSString *)baseURL apiKey:(NSString *)apiKey completion:(void (^)(id models, NSError *error))completion;
@end
