//
//  WNMotion : NSObject
//  逆向还原：ivar/方法/属性来自二进制元数据
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

@interface WNMotion : NSObject {
    // 注：p 是 @protected，类外无法直读。0x8de0 处 OverlayController 的 talkHandler 会直接写
    // p.talkK（WNMotion.p=+8，字段偏移 +0x1b0），故下方补一个语义等价的写入口 setTalkPulse:。
    WNMotionState p;
    double time;
    double scale;
    double floorY;
    double width;
    double height;
    double strokeAcc;
    double petCool;
    double pointerX;
    double pointerY;
    double pointerVX;
    double pressX;
    double pressY;
    double pressT;
    BOOL pressing;
    BOOL pointerInside;
    BOOL freeGround;
    unsigned int randomState;
    BOOL _enteringFromTop;
    BOOL _responsiveInteraction;
    BOOL _thinking;
    BOOL _thoughtShown;
    int _tearNumber;
    NSString * _mode;
    NSString * _expression;
    NSString * _faceName;
    NSDictionary * _face;
    NSDictionary * _frame;
    NSDictionary * _transform;
    NSDictionary * _pulse;
    NSMutableArray * _events;
    NSMutableArray * _particles;
    NSMutableArray * _samples;
    NSMutableArray * _soundEvents;
    NSArray * _eyeCur;
    NSArray * _eyePrev;
    NSMutableArray * _eyeDims;
    NSString * _eyeSig;
    NSString * _airKind;
    NSString * _roamMode;
    double _roamHoldUntil;
    double _snoreSeconds;
    double (^_groupTilt)(NSString *, double, double);   // render 内实测签名
    NSDictionary * _faces;
    NSString * _walkWord;
    NSString * _walkIdentifier;
    double _lastPointerTime;
    NSString * _lastAction;
}

@property (nonatomic, strong) NSDictionary * faces;
@property (nonatomic, copy) NSString * walkWord;
@property (nonatomic, copy) NSString * walkIdentifier;
@property (nonatomic) int tearNumber;
@property (nonatomic) double lastPointerTime;
@property (nonatomic, copy) NSString * lastAction;
@property (nonatomic) BOOL enteringFromTop;
@property (nonatomic, copy) NSString * mode;
@property (nonatomic, copy) NSString * expression;
@property (nonatomic, copy) NSString * faceName;
@property (nonatomic, strong) NSDictionary * face;
@property (nonatomic, strong) NSDictionary * frame;
@property (nonatomic, strong) NSDictionary * transform;
@property (nonatomic, strong) NSDictionary * pulse;
@property (nonatomic, strong) NSMutableArray * events;
@property (nonatomic, strong) NSMutableArray * particles;
@property (nonatomic, strong) NSMutableArray * samples;
@property (nonatomic, strong) NSMutableArray * soundEvents;
@property (nonatomic, strong) NSArray * eyeCur;
@property (nonatomic, strong) NSArray * eyePrev;
@property (nonatomic, strong) NSMutableArray * eyeDims;
@property (nonatomic, copy) NSString * eyeSig;
@property (nonatomic, copy) NSString * airKind;
@property (nonatomic) BOOL responsiveInteraction;
@property (nonatomic) BOOL thinking;
@property (nonatomic) BOOL thoughtShown;
@property (nonatomic, copy) NSString * roamMode;
@property (nonatomic) double roamHoldUntil;
@property (nonatomic) double snoreSeconds;
@property (nonatomic, copy) double (^groupTilt)(NSString *, double, double);

- (double)random;
- (double)rnd:(double)arg1 to:(double)arg2;
- (double)minX;
- (double)maxX;
- (double)minY;
- (BOOL)is:(id)arg1;
- (BOOL)busy;
- (id)initWithSeed:(unsigned int)arg1 freeGround:(BOOL)arg2;
- (void)setFaceDefinitions:(id)arg1;
- (double)pickRoamingTarget;
- (void)decideAutonomousAction;
- (void)event:(id)arg1 detail:(id)arg2;
- (void)sound:(id)arg1 kind:(id)arg2 arguments:(id)arg3;
- (id)drainSoundEvents;
- (void)setModeTo:(id)arg1;
- (void)pulse:(id)arg1 duration:(double)arg2;
- (void)enterFromTop;
- (void)holdFace:(id)arg1 seconds:(double)arg2;
- (void)setExpr:(id)arg1 seconds:(double)arg2;
- (BOOL)walkTo:(double)arg1 run:(BOOL)arg2 identifier:(id)arg3;
- (void)stopWalk:(NSString *)identifier;
- (BOOL)doWord:(id)arg1;
- (id)currentFaceName;
- (id)faceAt:(NSString *)name;
- (CGPoint)toStage:(CGPoint)arg1;
- (BOOL)hit:(CGPoint)arg1;
- (void)emit:(id)arg1 point:(CGPoint)arg2 vx:(double)arg3 vy:(double)arg4 life:(double)arg5;
- (void)emitHeart;
- (void)dust:(int)arg1 spread:(double)arg2;
- (void)land;
- (void)step:(double)arg1;
- (void)render;
- (CGPoint)velocity;
- (void)samplePointer:(CGPoint)arg1 milliseconds:(double)arg2;
- (void)syncDragPointer;
- (void)grab;
- (BOOL)pointerDown:(CGPoint)arg1 milliseconds:(double)arg2;
- (BOOL)pointerDown:(CGPoint)arg1 milliseconds:(double)arg2 hitConfirmed:(BOOL)arg3;
- (void)pointerMove:(CGPoint)arg1 milliseconds:(double)arg2;
- (void)pointerUp:(CGPoint)arg1 milliseconds:(double)arg2;
- (void)poke;
- (void)pointerHover:(CGPoint)arg1;
- (void)cancelAt:(CGPoint)arg1;
- (void)pointerLeave;
- (id)snapshot;
- (BOOL)enteringFromTop;
- (void)setEnteringFromTop:(BOOL)arg1;
- (BOOL)responsiveInteraction;
- (void)setResponsiveInteraction:(BOOL)arg1;
- (BOOL)thinking;
- (void)setThinking:(BOOL)arg1;
- (BOOL)thoughtShown;
- (void)setThoughtShown:(BOOL)arg1;
- (double)roamHoldUntil;
- (void)setRoamHoldUntil:(double)arg1;
- (double)snoreSeconds;
- (void)setSnoreSeconds:(double)arg1;
- (double (^)(NSString *, double, double))groupTilt;
- (void)setGroupTilt:(void (^)(void))arg1;
- (int)tearNumber;
- (void)setTearNumber:(int)arg1;
- (double)lastPointerTime;
- (void)setLastPointerTime:(double)arg1;
@property (nonatomic) double width;
@property (nonatomic) double height;
@property (nonatomic) double scale;
@property (nonatomic) double floorY;
@property (nonatomic) double time;

@property (nonatomic) double x;
@property (nonatomic) double gy;
@property (nonatomic) BOOL quietSound;

// 非二进制方法（补）：等价于直接写 ivar 区 p.talkK。二进制里由 PDOverlayController 的
// talkHandler（0x8de0）在类外直接写 ivar；还原稿里 p 是 @protected，故以此写入口代替。
- (void)setTalkPulse:(double)value;

@end


#pragma mark - 编译补齐

/// 原版有、还原遗漏的访问器：返回随机种子（ivar randomState）
- (id)seed;
