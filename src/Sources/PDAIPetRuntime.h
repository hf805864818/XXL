//
//  PDAIPetRuntime : NSObject
//  逆向还原：ivar/方法/属性来自二进制元数据
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

@interface PDAIPetRuntime : NSObject {
    BOOL _visible;
    BOOL _confirmationShown;
    BOOL _touchWoke;
    BOOL _touchEnabled;
    BOOL _configured;
    BOOL _baseSound;
    BOOL _quietSound;
    PDChatService * _service;
    WNMotion * _motion;
    void (^_presentationHandler)(NSDictionary *);
    void (^_turnHandler)(NSString *);
    void (^_preferencesHandler)(void);
    void (^_devicePreparationHandler)(void (^)(void));
    PDDeviceTools * _deviceTools;
    PDAIAlarms * _alarms;
    NSMutableArray * _actions;
    NSString * _activeAction;
    NSString * _walkID;
    NSString * _user;
    NSString * _displayedAppearance;
    NSString * _botAppearance;
    NSString * _pendingFigureEvent;
    double _figureUntil;
    double _actionUntil;
    double _walkUntil;
    double _sayUntil;
    double _touchUntil;
    double _confirmUntil;
    void (^_walkCompletion)(void);
    NSMutableDictionary * _touch;
    NSString * _touchMode;
    NSString * _baseRoam;
    NSString * _quietRoam;
    NSSet * _touchCustom;
    NSDictionary * _ask;
    NSDictionary * _confirmation;
    NSDictionary * _pendingSettings;
    void (^_confirmCompletion)(void);
    double _quietUntil;
    double _bubbleSpeed;
    double _heartbeatMinutes;
    double _lastActivity;
    double _lastFire;
    double _nextHeartbeat;
    unsigned long long _idleTicks;
}

@property (nonatomic, strong) PDChatService * service;
@property (nonatomic, strong) PDDeviceTools * deviceTools;
@property (nonatomic, strong) PDAIAlarms * alarms;
@property (nonatomic, strong) NSMutableArray * actions;
@property (nonatomic, copy) NSString * activeAction;
@property (nonatomic, copy) NSString * walkID;
@property (nonatomic, copy) NSString * user;
@property (nonatomic, copy) NSString * displayedAppearance;
@property (nonatomic, copy) NSString * botAppearance;
@property (nonatomic, copy) NSString * pendingFigureEvent;
@property (nonatomic) double figureUntil;
@property (nonatomic) double actionUntil;
@property (nonatomic) double walkUntil;
@property (nonatomic) double sayUntil;
@property (nonatomic) double touchUntil;
@property (nonatomic) double confirmUntil;
@property (nonatomic) BOOL confirmationShown;
@property (nonatomic, copy) void (^walkCompletion)(void);
@property (nonatomic, strong) NSMutableDictionary * touch;
@property (nonatomic) BOOL touchWoke;
@property (nonatomic) BOOL touchEnabled;
@property (nonatomic) BOOL configured;
@property (nonatomic) BOOL baseSound;
@property (nonatomic) BOOL quietSound;
@property (nonatomic, copy) NSString * touchMode;
@property (nonatomic, copy) NSString * baseRoam;
@property (nonatomic, copy) NSString * quietRoam;
@property (nonatomic, strong) NSSet * touchCustom;
@property (nonatomic, strong) NSDictionary * ask;
@property (nonatomic, strong) NSDictionary * confirmation;
@property (nonatomic, strong) NSDictionary * pendingSettings;
@property (nonatomic, copy) void (^confirmCompletion)(void);
@property (nonatomic) double quietUntil;
@property (nonatomic) double bubbleSpeed;
@property (nonatomic) double heartbeatMinutes;
@property (nonatomic) double lastActivity;
@property (nonatomic) double lastFire;
@property (nonatomic) double nextHeartbeat;
@property (nonatomic) unsigned long long idleTicks;
@property (nonatomic, strong) WNMotion * motion;
@property (nonatomic) BOOL visible;
@property (nonatomic, copy) void (^presentationHandler)(NSDictionary *);
@property (nonatomic, copy) void (^turnHandler)(NSString *);
@property (nonatomic, copy) void (^preferencesHandler)(void);
@property (nonatomic, copy) void (^devicePreparationHandler)(void (^)(void));
@property (nonatomic, readonly) BOOL effectiveSound;
@property (nonatomic, readonly, copy) NSString * effectiveRoam;

- (id)initWithDataDirectory:(id)arg1;
- (BOOL)effectiveSound;
- (void)reloadPreferences;
- (void)didDisplayAppearance:(id)arg1;
- (void)setVisible:(BOOL)arg1;
- (BOOL)bodyBusy;
- (void)hold:(double)arg1;
- (void)activity;
- (id)state;
- (void)enqueueActions:(id)arg1;
- (void)tick;
- (void)tickAt:(double)arg1;
- (void)onTouch:(id)arg1 at:(double)arg2;
- (void)flushTouch;
- (void)sendText:(id)arg1;
- (void)sendText:(id)arg1 images:(id)arg2;
- (void)present:(id)arg1;
- (void)confirmationDidShow:(id)arg1;
- (void)answer:(id)arg1 index:(long long)arg2 text:(id)arg3 dismissed:(BOOL)arg4;
- (void)interrupt;
- (void)poll;
- (void)executeTool:(id)arg1 arguments:(id)arg2 completion:(void (^)(id, NSError *))arg3;
// 二进制签名：completion(x1=id, x2=NSError*)
//   成功无改动 → completion(@"没有需要修改的项目。", nil)
//   权限关闭   → completion(@"用户关闭了自主修改权限。", 非 nil)
//   有改动     → completion(确认请求字典, nil)
- (void)setSettings:(NSDictionary *)arg1 completion:(void (^)(id, NSError *))arg2;
- (BOOL)visible;
- (void (^)(NSDictionary *))presentationHandler;
- (void)setPresentationHandler:(void (^)(NSDictionary *))arg1;
- (void (^)(NSString *))turnHandler;
- (void)setTurnHandler:(void (^)(NSString *))arg1;
- (void (^)(void))preferencesHandler;
- (void)setPreferencesHandler:(void (^)(void))arg1;
- (void (^)(void (^)(void)))devicePreparationHandler;
- (void)setDevicePreparationHandler:(void (^)(void (^)(void)))arg1;
- (double)figureUntil;
- (void)setFigureUntil:(double)arg1;
- (double)actionUntil;
- (void)setActionUntil:(double)arg1;
- (double)walkUntil;
- (void)setWalkUntil:(double)arg1;
- (double)sayUntil;
- (void)setSayUntil:(double)arg1;
- (double)touchUntil;
- (void)setTouchUntil:(double)arg1;
- (double)confirmUntil;
- (void)setConfirmUntil:(double)arg1;
- (BOOL)confirmationShown;
- (void)setConfirmationShown:(BOOL)arg1;
- (void (^)(void))walkCompletion;
- (void)setWalkCompletion:(void (^)(void))arg1;
- (BOOL)touchWoke;
- (void)setTouchWoke:(BOOL)arg1;
- (BOOL)touchEnabled;
- (void)setTouchEnabled:(BOOL)arg1;
- (BOOL)configured;
- (void)setConfigured:(BOOL)arg1;
- (BOOL)baseSound;
- (void)setBaseSound:(BOOL)arg1;
- (BOOL)quietSound;
- (void)setQuietSound:(BOOL)arg1;
- (void (^)(void))confirmCompletion;
- (void)setConfirmCompletion:(void (^)(void))arg1;
- (double)quietUntil;
- (void)setQuietUntil:(double)arg1;
- (double)bubbleSpeed;
- (void)setBubbleSpeed:(double)arg1;
- (double)heartbeatMinutes;
- (void)setHeartbeatMinutes:(double)arg1;
- (double)lastActivity;
- (void)setLastActivity:(double)arg1;
- (double)lastFire;
- (void)setLastFire:(double)arg1;
- (double)nextHeartbeat;
- (void)setNextHeartbeat:(double)arg1;
- (unsigned long long)idleTicks;
- (void)setIdleTicks:(unsigned long long)arg1;

@property (nonatomic, copy) void (^soundHandler)(NSString *, NSString *);
@property (nonatomic, copy) void (^alarmHandler)(NSString *);
@property (nonatomic, copy) void (^heartbeatHandler)(void);
@property (nonatomic, copy) void (^touchHandler)(NSString *);

@end
