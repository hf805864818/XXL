//
//  WNLiveRig : NSObject
//  逆向还原：ivar/方法/属性来自二进制元数据
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

// 球锚点：二进制编码 {?="x"d"y"d"vx"d"vy"d}，32 字节（0x120–0x140）
typedef struct WNBallAnchor {
    double x;
    double y;
    double vx;
    double vy;
} WNBallAnchor;

//  ivar 布局逐项对齐 objc_full.json（instanceSize 0x1E8 = 488）：
//  偏移全为 Observed（__objc_ivar 元数据 + 反汇编访问点交叉验证）。
@interface WNLiveRig : NSObject {
    double lastT;            // +0x008
    double prevTilt;         // +0x010
    double prevYaw;          // +0x018
    double prevLow;          // +0x020
    double headTilt;         // +0x028
    double wTilt;            // +0x030
    double wLean;            // +0x038
    double facing;           // +0x040
    double finMood;          // +0x048
    double tailMood;         // +0x050
    double wagAmp;           // +0x058
    double sitK;             // +0x060
    double walkK;            // +0x068
    double runK;             // +0x070
    double swingK;           // +0x078
    double browNow[2][4];    // +0x080 编码 [2[4d]]，64 字节（0x080–0x0C0）
    double browOver;         // +0x0C0
    double creaseDrop[2];    // +0x0C8 编码 [2d]，16 字节（0x0C8–0x0D8）
    double creaseA;          // +0x0D8
    double prevLook[2];      // +0x0E0 编码 [2d]，16 字节（0x0E0–0x0F0）
    double prevShut;         // +0x0F0
    double hlScale;          // +0x0F8
    double hlQuiver;         // +0x100
    double hlAlpha;          // +0x108
    BOOL hasT;               // +0x110  ldrb w8,[x24,0x110] @0x4dd2c
    BOOL hasLook;            // +0x111
    BOOL deformersDirty;     // +0x112  strb wzr,[x19,0x112] @0x4d7c4
    BOOL ballAnchored;       // +0x113
    double ballLastT;        // +0x118
    WNBallAnchor ballAnchor; // +0x120 32 字节（0x120–0x140）
    CGPoint ballHandShift;   // +0x140
    WNMotion * _motion;
    NSDictionary * _model;
    NSDictionary * _sourceModel;
    NSDictionary * _tables;
    NSData * _positions;
    NSArray * _alpha;
    NSArray * _order;
    NSString * _scheme;
    NSString * _outfit;
    id _highlight;
    id _toyBall;
    NSMutableDictionary * _springs;
    NSMutableDictionary * _rot;
    NSMutableDictionary * _warps;
    NSMutableDictionary * _rootWas;
    NSDictionary * _pivots;
    NSDictionary * _outfitInfo;
    NSDictionary * _compiledDeformers;
    NSMutableData * _localVertices;
    NSURL * _resourceURL;   // 【可编辑化扩展】资源根，供 PDTextureResolver 定位素材
}

@property (nonatomic, strong) WNMotion * motion;
@property (nonatomic, strong) NSURL * resourceURL;   // 【扩展】
@property (nonatomic, strong) NSDictionary * model;
@property (nonatomic, strong) NSDictionary * sourceModel;
@property (nonatomic, strong) NSDictionary * tables;
@property (nonatomic, strong) NSData * positions;
@property (nonatomic, strong) NSArray * alpha;
@property (nonatomic, strong) NSArray * order;
@property (nonatomic, strong) NSString * scheme;
@property (nonatomic, strong) NSString * outfit;
@property (nonatomic, strong) id highlight;
@property (nonatomic, strong) id toyBall;
@property (nonatomic, strong) NSMutableDictionary * springs;
@property (nonatomic, strong) NSMutableDictionary * rot;
@property (nonatomic, strong) NSMutableDictionary * warps;
@property (nonatomic, strong) NSMutableDictionary * rootWas;
@property (nonatomic, strong) NSDictionary * pivots;
@property (nonatomic, strong) NSDictionary * outfitInfo;
@property (nonatomic, strong) NSDictionary * compiledDeformers;
@property (nonatomic, strong) NSData * localVertices;

- (double)spring:(id)arg1 target:(double)arg2 dt:(double)arg3;
- (WNSpring *)newSpring:(NSString *)arg1 k:(double)arg2 c:(double)arg3 limit:(double)arg4;
- (id)initWithResourceURL:(id)arg1 scheme:(id)arg2 seed:(unsigned int)arg3 freeGround:(BOOL)arg4;
- (void)step:(double)arg1;
- (void)step:(double)arg1 buildMesh:(BOOL)arg2;
- (void)rotation:(id)arg1 a:(double)arg2;
- (void)warp:(id)arg1 function:(void (^)(void))arg2;
- (void)compileMesh;
- (void)prepareDeformers;
- (CGPoint)point:(CGPoint)arg1 deformer:(id)arg2;
- (CGPoint)renderPointToStage:(CGPoint)arg1;
- (void)render;
- (void)renderBuildingMesh:(BOOL)arg1;
- (CGPoint)ballHandAtAngle:(double)arg1;
- (CGPoint)ballContactAtAngle:(double)arg1;
- (void)updateToyBall;
- (void)updateMesh;
- (id)textureForPart:(id)arg1;
- (id)featurePath:(id)arg1;
@end
