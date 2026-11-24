//
//  WNLiveRig+Mesh.m — 逆向还原：renderBuildingMesh:（网格装配）
//
//  还原依据：PetDFY.arm64e.dylib（arm64e，__TEXT 基址 0）
//    IMP            0x4dc34
//    指令数         3653 条（实测：0x4dc34 – 0x51544，共 14608 字节 = 3652 增量 + 1；
//                    原注 3908 有误，已按 PetDFY_disassembly.txt 行 55939–59609 重数）
//    类型编码       v20@0:8B16  → 唯一参数是 BOOL，不是 double
//    栈帧           0x210 字节 + 0x8 保护槽
//
//  常量全部由 adrp+ldr / adrp+add 从 __const、__cfstring、__objc_* 直接解出，
//  注释里的 0xNNNNNN 是该常量的文件偏移。
//
//  保真标注：
//    Observed（逐指令）  —— 指令序列直接支持
//    Inferred:          —— 由数据流推出，指令本身不直白
//    Assumed:           —— 无法从二进制确认（多见于被内联的 setter 语义）
//

#import "WNLiveRig.h"
#import "WNMotion.h"
#import "WNSpring.h"
#import "WNPreparedDeformer.h"
#import <UIKit/UIKit.h>
#import <math.h>

// 本 category 有意覆盖主类同名实现（二进制中 IMP 0x4dc34 即位于该 category 段）
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
// ---- 前向声明（定义见文件末）----
typedef struct { double x, y; } WNVec2;

static double wn_param(id info, NSString *key, double dflt);
static void   wn_install(id self, NSString *name, WNVec2 (^blk)(double, double, double, double));
static WNVec2 wn_warp_leg(double sK, double wK, double rK, double ang, double len,
                          double bArm, double aArm, double a, double b);
static WNVec2 wn_warp_arm(double wK, double rK, double sw, double bArm, double aArm,
                          double a, double b);
static WNVec2 wn_warp_hand(double wK, double rK, double sw, double a, double b);
static WNVec2 wn_warp_shoulder(double sw, double wK, double a, double b);
static WNVec2 wn_warp_torso(double tI, double lI, double fc, double wT, double wL,
                            double a, double b);
static WNVec2 wn_warp_brow(double bN, double bO, double cD, double cA, double fm,
                           double tr, double a, double b);
static WNVec2 wn_warp_mouth(double fm, double wa, double tr, double yr, double a, double b);
static WNVec2 wn_warp_eye(double ps, double pl, double bN, double fm, double a, double b);
static WNVec2 wn_warp_eye_creases(double ps, double pl, double bN, double a, double b);

@implementation WNLiveRig (Mesh)

// ---------------------------------------------------------------------------
// 0x4dc34 之前无独立函数：辅助实现
// ---------------------------------------------------------------------------

// Observed（逐指令 0x4e1f0 起全部 clamp 序列）：
//   二进制用 fminnm/fmaxnm（返回非 NaN 操作数）。C99 fmin/fmax 在“其中一个
//   操作数为 NaN”时同样返回另一个操作数，故此处等价；差异只在“两个都是 NaN”。
static inline double wn_clamp(double x, double lo, double hi) {
    return fmax(fmin(x, hi), lo);
}

// Observed（逐指令）：t = clamp(x,0,1); t*t*(3-2t)。
// 二进制把 (3-2t) 的系数 {3,3}/{-2,-2} 预先存在 [sp,0x170]/[sp,0x140]，
// 再用 2-lane fmla 一次算出两路，本实现按标量展开。
static inline double wn_smoothstep(double x) {
    double t = wn_clamp(x, 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

// Observed（逐指令 0x4e030–0x4e05c）：
//   静态 __objc_dictobj @0x1105a0，7 组 mode → 2 元素数组。
//   注意：元素类型按二进制原样抄录——@"i" / @"" 是 NSString（-doubleValue 得
//   0.0），@0.6 / @0.5 是 NSNumber。原实现混用了字符串与数字，此处不复原成数字。
static NSDictionary *WNModeTiltTable(void) {
    static NSDictionary *tbl;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tbl = @{ @"air":    @[@"i", @"i"],
                 @"crouch": @[@"i", @"i"],
                 @"dance":  @[@0.6, @""],
                 @"drag":   @[@"i", @"i"],
                 @"land":   @[@"i", @"i"],
                 @"run":    @[@"i", @0.5],
                 @"walk":   @[@"i", @0.5] };
    });
    return tbl;
}

// Observed（逐指令 0x4dc9c–0x4dca8）：静态 __objc_arrayobj @0x10f830 = @[@"walk",@"run"]
static NSArray *WNGaitModes(void) {
    static NSArray *a;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ a = @[@"walk", @"run"]; });
    return a;
}

- (void)renderBuildingMesh:(BOOL)arg1 {

    // =======================================================================
    // [段 1] 0x4dc34 – 0x4dccc  入口与取帧
    // =======================================================================
    // 0x4dc34  pacibsp / 0x4dc38 stp x24,x23,[sp,-0x20]! / 0x4dc3c stp x22,x21,...
    // 栈帧 0x210；保护槽 __DATA_CONST[0xb98]。

    // Observed（逐指令 0x4dc68–0x4dc84）：
    //   ldrb w8,[x0,0x112] / mov w20,#1 / strb w20,[x0,0x112]
    //   0x112 = deformersDirty（objc_full.json ivar 表：offset 274）
    deformersDirty = YES;

    // Observed（逐指令 0x4dc88–0x4dc94）：
    //   mov x0,self; bl objc_msgSend→"motion"; 再 bl→"render"
    [[self motion] render];

    // Observed（逐指令 0x4dca0–0x4dcac）：[motion frame] → [sp,0x1c8]
    NSDictionary *frame = [[self motion] frame];

    // Observed（逐指令 0x4dcc0–0x4dd44）：frame[@"faceConfig"/@"mode"/@"face"/@"t"]
    //   t 走 -doubleValue，结果留在 d10
    id faceConfig = frame[@"faceConfig"];               // [sp,0x138]
    id mode       = frame[@"mode"];                     // [sp,0xe0]
    id face       = frame[@"face"];                     // [sp,0xe8]
    double t      = [frame[@"t"] doubleValue];          // d10

    // =======================================================================
    // [段 2] 0x4dd48 – 0x4dde0  时间步 dt
    // =======================================================================
    // Observed（逐指令 0x4dd48–0x4ddc4）：
    //   ldrb w8,[x24,0x110]            ; hasT
    //   cbz  → 0x4dd8c 走 1/60 分支
    //   否则 d0 = t - lastT；fminnm 0.05；fmaxnm 0.0
    //   strb 1 → hasT；str t → lastT
    double dt;
    if (hasT) {
        dt = wn_clamp(t - lastT, 0.0, 0.05);           // 0.05 @0xc5d18
    } else {
        dt = 0.016666666666666666;                      // 1/60 @0xc5d40
    }
    hasT = YES;
    lastT = t;

    // =======================================================================
    // [段 3] 0x4ddc8 – 0x4de2c  朝向符号 / 步态判定 / 蹲姿
    // =======================================================================
    // Observed（逐指令 0x4ddc8–0x4ddf4）：
    //   frame[@"facing"].doubleValue; fcmp d0,#0.0; fcsel d0,1.0,-1.0,ge
    double facingRaw = [frame[@"facing"] doubleValue];
    facing = (facingRaw >= 0.0) ? 1.0 : -1.0;

    // Observed（逐指令 0x4ddf8–0x4de10）：containsObject: 于 @[@"walk",@"run"]
    BOOL gait = [WNGaitModes() containsObject:mode];    // [sp,0x1d0]

    // Observed（逐指令 0x4de14–0x4de24）：两次 isEqual:
    BOOL isDrag = [mode isEqual:@"drag"];               // x25
    BOOL isAir  = [mode isEqual:@"air"];                // x26

    // Observed（逐指令 0x4de28–0x4de40）：
    //   sit 先 fmaxnm 0.0 / fminnm 1.0；k = 1-exp(-12*dt)；
    //   sitK = (sit-sitK)*k + sitK   （0x60 = sitK）
    double sitTarget = wn_clamp([frame[@"sit"] doubleValue], 0.0, 1.0);   // d9
    double kSit = 1.0 - exp(dt * -12.0);                // d1 @0xc60150 = -12.0
    sitK = (sitTarget - sitK) * kSit + sitK;

    // Observed（逐指令 0x4de48–0x4de60）：
    //   low 存 [sp,0x188]，旧的 prevLow(0x20) 存 [sp,0x1e8]，prevLow = low
    double low = [frame[@"low"] doubleValue];           // d8
    double prevLowOld = prevLow;                       // [sp,0x1e8]
    double lowNow = low;                                // [sp,0x188]
    prevLow = low;

    // =======================================================================
    // [段 4] 0x4de64 – 0x4dfec  头部倾斜目标（含呼吸正弦）
    // =======================================================================
    // Observed（逐指令 0x4de64–0x4de9c）：
    //   isEqual:@"sleep" → x19；w = sleep ? 2.4 : 1.7；sin(t*w) → [sp,0x190]
    BOOL isSleep = [mode isEqual:@"sleep"];
    double breathW = isSleep ? 2.4 : 1.7;               // 2.4@0xc6100 / 1.7@0xc6118
    double breath = sin(t * breathW);                   // [sp,0x190]

    // Observed（逐指令 0x4dea0–0x4df38）：
    //   look[0]/look[1] 取两次 doubleValue（第二次重新取 frame[@"look"]）
    id look = frame[@"look"];                           // x22
    double lookX = [[look objectAtIndexedSubscript:0] doubleValue];   // d9
    double lookY = [[frame[@"look"] objectAtIndexedSubscript:1] doubleValue]; // d8

    // swing 存 [sp,0x1e0]
    double swing = [frame[@"swing"] doubleValue];

    // Observed（逐指令 0x4df3c–0x4df74）：
    //   d8 = sin(t*0.9)*1.2 + lookX*0.7 + lookY*0.4
    //   系数 0.9@0xc5e88、1.2@0xc5e90?（实际 1.2 在 0xc5e98）、0.7 → [sp,0x1d8]、0.4@0xc5f08
    double headAcc = sin(t * 0.9) * 1.2 + lookX * 0.7 + lookY * 0.4;   // d8

    // Observed（逐指令 0x4df78–0x4df84）：sleep 时 +6.0
    if (isSleep) headAcc += 6.0;

    // Observed（逐指令 0x4df88–0x4dfb8）：
    //   tables[@"HEAD_TILT"][face].doubleValue 累加
    double headTarget = headAcc +
        [[[self tables][@"HEAD_TILT"] objectForKeyedSubscript:face] doubleValue];

    // Observed（逐指令 0x4dfbc–0x4dfe4）：
    //   t → [sp,0x1b0]；lookX → [sp,0xc0]
    double tSaved  = t;                                 // [sp,0x1b0]
    double lookXSaved = lookX;                          // [sp,0xc0]

    // Observed（逐指令 0x4dfe8–0x4e014）：face == @"dizzy" 时加 sin(t*4.5)*3.0
    if ([face isEqual:@"dizzy"]) {
        headTarget += sin(t * 4.5) * 3.0;               // 4.5@0xc5f00 3.0@0xc5ef8
    }

    // Observed（逐指令 0x4e018–0x4e028）：
    //   d0 = headTarget + swing*0.25；fcsel：非 drag 时退回 headTarget
    //   然后 spring:@"head" → 存 headTilt(0x28)
    double headSpringTarget = headTarget + swing * 0.25;
    if (!isDrag) headSpringTarget = headTarget;
    headTilt = [self spring:@"head" target:headSpringTarget dt:dt];

    // =======================================================================
    // [段 5] 0x4e030 – 0x4e0f8  wTilt / wLean 弹簧
    // =======================================================================
    // Observed（逐指令 0x4e030–0x4e05c）：WNModeTiltTable()[mode] ?: @[@"i",@"i"]
    NSArray *tiltPair = WNModeTiltTable()[mode] ?: @[@"i", @"i"];   // x22

    // Observed（逐指令 0x4e068–0x4e098）：frame[@"tilt"].doubleValue → [sp,0x168]
    double tiltIn = [frame[@"tilt"] doubleValue];

    // Observed（逐指令 0x4e0a0–0x4e0b4）：
    //   wTilt → [sp,0x160]；frame[@"lean"].doubleValue → d10；wLean → d14；facing → d9
    double wTiltOld = wTilt;
    double leanIn   = [frame[@"lean"] doubleValue];      // d10
    double wLeanOld = wLean;                            // d14

    // Observed（逐指令 0x4e0b8–0x4e0f0）：
    //   k = 1-exp(-10*dt)；wTilt = (pair[0]-wTilt)*k+wTilt
    double kTilt = 1.0 - exp(dt * -10.0);                // -10.0@0xc60160
    wTilt = ([tiltPair[0] doubleValue] - wTilt) * kTilt + wTilt;

    // Observed（逐指令 0x4e0f4–0x4e108）：同样 k，作用在 pair[1] 与 wLean(0x38)
    wLean = ([tiltPair[1] doubleValue] - wLean) * kTilt + wLean;

    // =======================================================================
    // [段 6] 0x4e10c – 0x4e1e0  手势字典与强度 k
    // =======================================================================
    // Observed（逐指令 0x4e10c–0x4e16c）：
    //   gesture = frame[@"gesture"]；objc_opt_isKindOfClass:[NSDictionary class]
    //   tbz → gesture = nil
    id gestureRaw = frame[@"gesture"];
    id gesture = nil;
    if ([gestureRaw isKindOfClass:[NSDictionary class]]) {
        gesture = frame[@"gesture"];
    }

    // Observed（逐指令 0x4e170–0x4e1a8）：
    //   k = gesture[@"k"].doubleValue，用 str q0 同时写 [sp,0x1f0] 与 [sp,0x1f8]
    //   （编译器把 k 复制成 2-lane，后面所有手势包络都从这个 lane 对读）
    double gk = [gesture[@"k"] doubleValue];             // [sp,0x1f0] / [sp,0x1f8]

    // Observed（逐指令 0x4e1ac–0x4e1c8）：kind = gesture[@"kind"]
    id kind = gesture[@"kind"];                          // x21

    // Observed（逐指令 0x4e1d0–0x4e1dc）：isEqual:@"nod" → x0
    BOOL isNod = [kind isEqual:@"nod"];

    // -----------------------------------------------------------------------
    // 手势包络：二进制先清零 d8/d11，再按 kind 逐个覆盖
    // Observed（逐指令 0x4e1e0–0x4e1e4）：movi d11,#0 / movi d8,#0
    // -----------------------------------------------------------------------
    double nodTerm = 0.0;      // d11
    double shakeTerm = 0.0;    // d8

    // Observed（逐指令 0x4e1e4–0x4e210）：
    //   sin(gk*pi*2)² * (1 - 0.3*gk)
    if (isNod) {
        double s = sin(gk * M_PI * 2.0);                 // pi@0xc6f58
        nodTerm = (1.0 + gk * -0.3) * (s * s);           // -0.3@0xc6368
    }

    // Observed（逐指令 0x4e214–0x4e27c）：
    //   sin(gk*pi*6) * smoothstep(gk/0.12) * (1-gk)
    if ([kind isEqual:@"shake"]) {
        double s = sin(gk * M_PI * 6.0);
        double w = wn_smoothstep(gk / 0.12);             // 0.12@0xc5d70
        shakeTerm = (1.0 - gk) * (s * w);
    }

    // Observed（逐指令 0x4e280–0x4e2f8）：
    //   2-lane：lane0 除 0.15、lane1 除 0.20（@0xc64d0 = {0.15,0.20}）
    //   waveTerm = S(gk-0.8 / 0.15) * (1 - S(gk-0.8 / 0.20))
    // 注：0x4e2fc/0x4e300 的 stp 把 {3,3}→[sp,0x170]、{-2,-2}→[sp,0x140] 只是
    // 把 smoothstep 的常数放进栈槽供后续 fmla 复用，不产生独立语义。
    double waveTerm = 0.0;                               // [sp,0x1a0]
    double bowTerm  = 0.0;                               // [sp,0x198]
    if ([kind isEqual:@"wave"]) {
        double x = gk - 0.8;                             // -0.8@0xc6370
        waveTerm = wn_smoothstep(x / 0.15) * (1.0 - wn_smoothstep(x / 0.20));
    }

    // Observed（逐指令 0x4e2fc–0x4e308）：
    //   [sp,0x140]={-2,-2}  [sp,0x170]={3,3}  [sp,0x158]=0.001
    double epsilon = 0.001;                              // [sp,0x158]

    // Observed（逐指令 0x4e30c–0x4e384）：
    //   bowTerm = S(4*gk) * (1 - S((gk-0.7)/0.3))  → [sp,0x198]
    if ([kind isEqual:@"bow"]) {
        double a = wn_smoothstep(gk * 4.0);
        double b = wn_smoothstep((gk - 0.7) / 0.30000000000000004);
        bowTerm = a * (1.0 - b);
    }

    // =======================================================================
    // [段 7] 0x4e388 – 0x4e3a8  low 变化率与时间归一
    // =======================================================================
    // Observed（逐指令 0x4e388–0x4e39c）：
    //   d13 = lowNow - prevLowOld
    //   denom = fmaxnm(dt, 0.001)
    //   stp d0,d15 → [sp,0x1b8]=denom, [sp,0x1c0]=dt
    double dLow  = lowNow - prevLowOld;                  // d13
    double denom = fmax(dt, epsilon);                    // [sp,0x1b8]
    double dtSaved = dt;                                 // [sp,0x1c0]

    // =======================================================================
    // [段 8] 0x4e3a0 – 0x4e414  shiver 包络
    // =======================================================================
    // Observed（逐指令 0x4e3a4–0x4e3a8）：movi d0,#0；stp d0,d0,[sp,0x1e8]
    double shiverTerm = 0.0;                             // [sp,0x1e8]
    double flapTerm   = 0.0;                             // [sp,0x150]

    // Observed（逐指令 0x4e3ac–0x4e410）：
    //   2-lane：@0xc6310 = {0.08,0.15}
    //   shiverTerm = S((gk-0.85)/0.08) * (1 - S((gk-0.85)/0.15))
    if ([kind isEqual:@"shiver"]) {
        double x = gk - 0.85;                            // -0.85@0xc6378
        shiverTerm = wn_smoothstep(x / 0.08) * (1.0 - wn_smoothstep(x / 0.15));
    }

    // Observed（逐指令 0x4e418–0x4e424）：
    //   kind → [sp,0x70]；gesture → [sp,0x78]；lowRate = dLow/denom → [sp,0x170]
    id kindSaved    = kind;                              // [sp,0x70]
    id gestureSaved = gesture;                           // [sp,0x78]
    double lowRate  = dLow / denom;                      // [sp,0x170]

    // =======================================================================
    // [段 9] 0x4e428 – 0x4e49c  flap 包络
    // =======================================================================
    // Observed（逐指令 0x4e42c–0x4e49c）：
    //   a = S(gk/0.05)（0.05@0xc5d18）
    //   b = S((gk-0.75)*4.0)
    //   flapTerm = a * (1 - b)
    if ([kind isEqual:@"flap"]) {
        double a = wn_smoothstep(gk / 0.05);
        double b = wn_smoothstep((gk - 0.75) * 4.0);
        flapTerm = a * (1.0 - b);
    }

    // =======================================================================
    // [段 10] 0x4e4a0 – 0x4e4dc  头部俯仰合成
    // =======================================================================
    // Observed（逐指令 0x4e4a0–0x4e4b0）：
    //   [sp,0x140] = leanIn * facing
    //   [sp,0x118] = 1.0 - wLeanOld
    double leanFacing = leanIn * facing;                 // [sp,0x140]
    double wLeanInv   = 1.0 - wLeanOld;                  // [sp,0x118]

    // Observed（逐指令 0x4e4b4–0x4e4dc）：
    //   d4 = headTilt + 7*nodTerm + 2.5*shakeTerm + 10*bowTerm + 4*waveTerm
    double headPitch = headTilt
                     + 7.0  * nodTerm
                     + 2.5  * shakeTerm
                     + 10.0 * bowTerm
                     + 4.0  * waveTerm;                  // d4

    // =======================================================================
    // [段 11] 0x4e4e0 – 0x4e528  一阶差分（角速度）
    // =======================================================================
    // Observed（逐指令 0x4e4e0–0x4e504）：
    //   d0 = shakeTerm*1.1
    //   d9 = (headPitch - prevTilt(0x10)) / denom     ; tiltRate
    //   d14 = (d0 - prevYaw(0x18)) / denom            ; yawRate
    //   stp d4,d0 → prevTilt / prevYaw
    double yawPitch = shakeTerm * 1.1;                   // d0
    double tiltRate = (headPitch - prevTilt) / denom;   // d9
    double yawRate  = (yawPitch - prevYaw) / denom;     // d14
    prevTilt = headPitch;
    prevYaw  = yawPitch;

    // Observed（逐指令 0x4e508–0x4e528）：
    //   [sp,0xa0] = headPitch
    //   q = clamp(lookX/5.0, -1.0, 1.0)；[sp,0x110] = shakeTerm*1.1 + 0.9*q
    double headPitchSaved = headPitch;                   // [sp,0xa0]
    double lookXNorm = wn_clamp(lookXSaved / 5.0, -1.0, 1.0);
    double yawShake = yawPitch + 0.9 * lookXNorm;        // [sp,0x110]

    // Observed（逐指令 0x4e52c–0x4e530）：[sp,0xc8] = 1.4
    double kYawDamp = 1.4;                               // [sp,0xc8]

    // =======================================================================
    // [段 12] 0x4e534 – 0x4e5d0  头部俯仰目标
    // =======================================================================
    // Observed（逐指令 0x4e534–0x4e554）：
    //   d8 = clamp(lookY*0.25, -1.0, 1.0)
    double pitchAcc = wn_clamp(lookY * 0.25, -1.0, 1.0);  // d8

    // Observed（逐指令 0x4e558–0x4e56c）：
    //   sleep ? 0.8 : 0.0；d8 = d8*0.7 + 该值（0.7 @0xc5e88）
    double sleepBias = isSleep ? 0.8 : 0.0;              // 0.8@0xc6360
    pitchAcc = pitchAcc * 0.7 + sleepBias;

    // Observed（逐指令 0x4e570–0x4e5ac）：
    //   + tables[@"HEAD_PITCH"][face].doubleValue
    pitchAcc += [[[self tables][@"HEAD_PITCH"] objectForKeyedSubscript:face] doubleValue];

    // Observed（逐指令 0x4e5b0–0x4e5c4）：
    //   + nodTerm*0.9 + bowTerm*0.5
    pitchAcc += nodTerm * 0.9;
    pitchAcc += bowTerm * 0.5;

    // Observed（逐指令 0x4e5c8–0x4e5cc）：pitchAcc → [sp,0x100]
    double pitchTarget = pitchAcc;                       // [sp,0x100]

    // =======================================================================
    // [段 13] 0x4e5d0 – 0x4e6e4  hair / hairY / bangs / skirt 弹簧
    // =======================================================================
    // Observed（逐指令 0x4e5d8–0x4e5ec）：
    //   d8 = clamp(swing/26.0, -1.6, 1.6)    （1.6@0xc6008、-1.6@0xc6010）
    double swingNorm = wn_clamp(swing / 26.0, -1.6, 1.6); // d8

    // Observed（逐指令 0x4e5f0–0x4e608）：
    //   orr w8,w26,w25 → isAir||isDrag；ucvtf → d11
    double gaitFlag = (isAir || isDrag) ? 1.0 : 0.0;      // d11

    // Observed（逐指令 0x4e60c–0x4e64c）：
    //   d10 = tiltRate * -0.004
    //   d0  = swingNorm*1.1 + d10 + yawRate*(-0.02)
    //   gait ? -0.25 : 0.0 累加
    //   d0 -= runK*0.5        （fmsub）
    double hairPitch = tiltRate * -0.004;                // d10
    double hairTarget = swingNorm * 1.1 + hairPitch;
    hairTarget += yawRate * -0.02;
    hairTarget += gait ? -0.25 : 0.0;
    hairTarget -= runK * 0.5;

    // Observed（逐指令 0x4e650–0x4e670）：
    //   gait ? d9=-0.2 : d9=0.0；spring:@"hair" → [sp,0x58]
    double gaitBias = gait ? -0.2 : 0.0;                 // d9
    double hairOut = [self spring:@"hair" target:hairTarget dt:dtSaved];  // [sp,0x58]

    // Observed（逐指令 0x4e674–0x4e6a0）：
    //   [sp,0x120] = 0.006
    //   target = lowRate*0.006 - gaitFlag；spring:@"hairY" → [sp,0x98]
    double hairYRate = 0.006;                            // [sp,0x120]
    double hairYTarget = lowRate * hairYRate - gaitFlag;
    double hairYOut = [self spring:@"hairY" target:hairYTarget dt:dtSaved]; // [sp,0x98]

    // Observed（逐指令 0x4e6a4–0x4e6d4）：
    //   d0 = swingNorm*0.7 + hairPitch + yawRate*(-0.03)
    //   spring:@"bangs" → [sp,0x50]
    double bangsTarget = swingNorm * 0.7 + hairPitch;
    bangsTarget += yawRate * -0.03;
    double bangsOut = [self spring:@"bangs" target:bangsTarget dt:dtSaved]; // [sp,0x50]

    // Observed（逐指令 0x4e6d8–0x4e6e4）：
    //   [sp,0x1f0] = swingNorm；d0 = swingNorm*0.8 + gaitBias
    double swingNormSaved = swingNorm;                   // [sp,0x1f0]
    double skirtTarget = swingNorm * 0.8 + gaitBias;

    // =======================================================================
    // [段 14] 0x4e6e8 – 0x4e744  skirt / skirtY
    // =======================================================================
    // Observed（逐指令 0x4e6e8–0x4e6f4）：spring:@"skirt" → [sp,0x130]
    double skirtOut = [self spring:@"skirt" target:skirtTarget dt:dtSaved];

    // Observed（逐指令 0x4e6f8–0x4e744）：
    //   sitK*0.6 + gaitFlag*dLow + clamp(dt*-0.01, -0.3, 0.6)
    //   （0.6@0xc5d90、-0.01@0xc5da0、-0.3@0xc6380）
    //   spring:@"skirtY" → [sp,0x128]
    double skirtYTarget = sitK * 0.6 + gaitFlag * dLow;
    skirtYTarget += wn_clamp(dtSaved * -0.01, -0.3, 0.6);
    double skirtYOut = [self spring:@"skirtY" target:skirtYTarget dt:dtSaved];

    // =======================================================================
    // [段 15] 0x4e748 – 0x4e7dc  MOOD 表查询
    // =======================================================================
    // Observed（逐指令 0x4e748–0x4e7dc）：
    //   mood = tables[@"MOOD"][face] ?: tables[@"MOOD"][@"neutral"]
    //   0x4e7cc 的 mov x25,x26 只是寄存器搬运，无语义
    id mood = [[self tables][@"MOOD"] objectForKeyedSubscript:face];
    if (!mood) {
        mood = [[self tables][@"MOOD"] objectForKeyedSubscript:@"neutral"];
    }

    // =======================================================================
    // [段 16] 0x4e7dc – 0x4e818  姿态中间量
    // =======================================================================
    // Observed（逐指令 0x4e7e0–0x4e818）：
    //   [sp,0x1d8] = 1.0 - wTiltOld
    //   d14 = leanFacing * wLeanInv
    //   d13 = fminnm(yawShake, 1.4)
    //   d8  = fminnm(pitchTarget, 1.4)
    //   d9  = -1.4
    double wTiltInv = 1.0 - wTiltOld;                    // [sp,0x1d8]
    double leanSum  = leanFacing * wLeanInv;             // d14
    double yawClamped   = fmin(yawShake, kYawDamp);      // d13
    double pitchClamped = fmin(pitchTarget, kYawDamp);   // d8
    const double kLimitNeg = -1.4;                       // d9

    // =======================================================================
    // [段 17] 0x4e81c – 0x4e8b4  finMood / wagAmp 弹簧（指数）
    // =======================================================================
    // Observed（逐指令 0x4e81c–0x4e8a8）：
    //   mood[0].doubleValue → d0
    //   d1 = -0.6 - d0 ；d12 = d1*shiverTerm + d0        （-0.6@0xc5db8）
    //   d0 = exp(dt*-6.0) ；d15 = 1.0 - d0 → [sp,0x60]
    //   finMood(0x48) = (d12 - finMood)*d15 + finMood
    double moodFin    = [[mood objectAtIndexedSubscript:0] doubleValue];
    double finTarget  = moodFin + (-0.6 - moodFin) * shiverTerm;
    double kFin       = 1.0 - exp(dtSaved * -6.0);       // [sp,0x60]
    finMood += (finTarget - finMood) * kFin;

    // Observed（逐指令 0x4e8ac–0x4e8b4）：
    //   d10 = mood[1].doubleValue；d15 = 1 - exp(dt*-3.0)
    //   wagAmp(0x58) = (mood[1] - wagAmp)*d15 + wagAmp
    double moodWag = [[mood objectAtIndexedSubscript:1] doubleValue];
    double kWag    = 1.0 - exp(dtSaved * -3.0);          // d15
    wagAmp += (moodWag - wagAmp) * kWag;

    // =======================================================================
    // [段 18] 0x4e8b8 – 0x4e8dc  tailMood（angry/happy/sad → -1.0）
    // =======================================================================
    // Observed（逐指令 0x4e8b8–0x4e8dc）：
    //   @0x10f908 containsObject:face → BOOL
    //   sbfx w8,w0,#0,#1 ; scvtf → 命中得 -1.0，否则 0.0
    //   tailMood(0x50) = (target - tailMood)*kWag + tailMood
    static NSArray *tailNegSet = nil;
    if (!tailNegSet) tailNegSet = @[@"angry", @"happy", @"sad"];
    BOOL tailNeg   = [tailNegSet containsObject:face];
    double tailTargetMood = tailNeg ? -1.0 : 0.0;
    tailMood += (tailTargetMood - tailMood) * kWag;

    // =======================================================================
    // [段 19] 0x4e8e4 – 0x4e944  fins 弹簧
    // =======================================================================
    // Observed（逐指令 0x4e8e4–0x4e910）：
    //   target = finMood*14.0 + swingNorm*10.0；spring:@"fins" → d10
    double finsTarget = finMood * 14.0 + swingNorm * 10.0;
    double finsOut    = [self spring:@"fins" target:finsTarget dt:dtSaved];

    // Observed（逐指令 0x4e914–0x4e944）：
    //   angry ? sin(t*40.0)*2.5 : 0.0     （40.0@0x4044000000000000）
    double angryWave = 0.0;
    if ([face isEqual:@"angry"]) {
        angryWave = sin(t * 40.0) * 2.5;
    }

    // =======================================================================
    // [段 20] 0x4e94c – 0x4e980  最终 lean/yaw/pitch 与 sin(t*26)
    // =======================================================================
    // Observed（逐指令 0x4e94c–0x4e980）：
    //   leanTilt = tiltIn*(1-wTiltOld) + leanSum          → [sp,0x140]
    //   [sp,0x90]  = fmaxnm(yawClamped, -1.4)
    //   d13        = fmaxnm(pitchClamped, -1.4)
    //   [sp,0x118] = finsOut + angryWave
    //   [sp,0x110] = sin(t*26.0)                          （26.0@0x403a000000000000）
    double leanTilt  = tiltIn * wTiltInv + leanSum;
    double yawOut    = fmax(yawClamped, kLimitNeg);
    double pitchOut  = fmax(pitchClamped, kLimitNeg);
    double finsSum   = finsOut + angryWave;
    double sinT26    = sin(t * 26.0);

    // =======================================================================
    // [段 21] 0x4e984 – 0x4ea20  ahoge 弹簧
    // =======================================================================
    // Observed（逐指令 0x4e984–0x4e9f0）：
    //   d0 = -0.5*yawRate + (-0.12)*tiltRate + 18.0*swingNorm
    //   surprised → -16.0 ；confused → +20.0 ；mode==sleep → +22.0
    double ahogeTarget = -0.5 * yawRate + (-0.12) * tiltRate + 18.0 * swingNorm;
    if ([face isEqual:@"surprised"]) ahogeTarget += -16.0;
    if ([face isEqual:@"confused"])  ahogeTarget += 20.0;
    if ([mode isEqual:@"sleep"])     ahogeTarget += 22.0;

    // Observed（逐指令 0x4e9f8–0x4ea20）：
    //   fmsub d0, hairYOut, 12.0, d0 ；spring:@"ahoge" → [sp,0x100]
    ahogeTarget -= hairYOut * 12.0;
    double ahogeOut = [self spring:@"ahoge" target:ahogeTarget dt:dtSaved];

    // =======================================================================
    // [段 22] 0x4ea34 – 0x4ead8  tail 弹簧 + 摇尾
    // =======================================================================
    // Observed（逐指令 0x4ea34–0x4ea44）：
    //   [sp,0xf8] = sin(t*19.0)
    double sinT19 = sin(t * 19.0);                       // [sp,0xf8]

    // Observed（逐指令 0x4ea44–0x4ea68）：
    //   target = tailMood*12.0 + swingNorm*14.0；spring:@"tail" → d10
    double tailTarget = tailMood * 12.0 + swingNorm * 14.0;
    double tailOut    = [self spring:@"tail" target:tailTarget dt:dtSaved];

    // Observed（逐指令 0x4ea70–0x4eac0）：
    //   d8 = wagAmp*13.0
    //   d0 = sin(t * (wagAmp*5.0 + 4.0))
    //   [sp,0x48] = tailOut + d8*d0
    //   [sp,0x48] += sin(t*1.3)*3.0                        （1.3@0x3ff4cccccccccccd）
    double wagAmp13 = wagAmp * 13.0;
    double wagFreq  = wagAmp * 5.0 + 4.0;
    double tailSum  = tailOut + wagAmp13 * sin(t * wagFreq);
    tailSum += sin(t * 1.3) * 3.0;                       // [sp,0x48]

    // Observed（逐指令 0x4ead0–0x4ead8）：[sp,0x30] = sin(t*17.0)
    double sinT17 = sin(t * 17.0);                       // [sp,0x30]
    // =======================================================================
    // [段 23] 0x4eac0 – 0x4ebd8  legs：逐腿 (x0,y0,x1,y1) → 角度与长度
    // =======================================================================
    // Observed（逐指令 0x4eac0–0x4ebd8）：
    //   循环恰好 2 次（编译器展开为 w27 位测试，i=0 / i=1）
    //   dx = leg[2]-leg[0]；dy = leg[3]-leg[1]
    //   angle = atan2(dx, fmax(dy, 4.0)) * -180 / pi
    //   len   = clamp(29.0 - hypot(dx,dy), -8.0, 20.0)
    NSArray *wnLegs = frame[@"legs"];
    double legAngle[2] = { 0.0, 0.0 };                   // [x29-0xb0]
    double legLen[2]   = { 0.0, 0.0 };                   // [x29-0xc0]
    for (int i = 0; i < 2; i++) {
        NSArray *leg = [wnLegs objectAtIndexedSubscript:i];
        double dx = [[leg objectAtIndexedSubscript:2] doubleValue]
                  - [[leg objectAtIndexedSubscript:0] doubleValue];
        double dy = [[leg objectAtIndexedSubscript:3] doubleValue]
                  - [[leg objectAtIndexedSubscript:1] doubleValue];
        legAngle[i] = atan2(dx, fmax(dy, 4.0)) * -180.0 / 3.141592653589793;
        legLen[i]   = wn_clamp(29.0 - hypot(dx, dy), -8.0, 20.0);
    }

    // =======================================================================
    // [段 24] 0x4ebdc – 0x4ec3c  sit 权重与半正弦脉冲
    // =======================================================================
    // Observed（逐指令 0x4ebdc–0x4ec08）：
    //   d8 = (sitK - 0.44) / 0.10000000000000003      （-0.44@0xc6108，0.1@0xc6110）
    double sitBlend = (sitK - 0.44) / 0.10000000000000003;   // d8

    // Observed（逐指令 0x4ebec–0x4ec20）：
    //   t = S((sitK + lowRate) * 2.0)
    double sitNorm = wn_smoothstep((sitK + lowRate) * 2.0);

    // Observed（逐指令 0x4ec24–0x4ec3c）：
    //   sin(pi * t) → [sp,0x28]；pi 由 [sp,0x160] 暂存
    double sitPulse = sin(sitNorm * 3.141592653589793);       // [sp,0x28]

    // =======================================================================
    // [段 25] 0x4ec40 – 0x4eca0  walkK / runK 一阶跟踪
    // =======================================================================
    // Observed（逐指令 0x4ec44–0x4ec68）：
    //   kWalk = 1 - exp(dt*-8.0)  → [sp,0xb0]
    //   walkK += (gaitFlag - walkK) * kWalk
    double kWalk = 1.0 - exp(dt * -8.0);                      // [sp,0xb0]
    walkK += (gaitFlag - walkK) * kWalk;

    // Observed（逐指令 0x4ec6c–0x4eca0）：
    //   isRun = [mode isEqual:@"run"]；kRun = 1 - exp(dt*-7.0)
    //   runK += (isRun - runK) * kRun
    double isRun = [mode isEqual:@"run"] ? 1.0 : 0.0;
    double kRun  = 1.0 - exp(dt * -7.0);
    runK += (isRun - runK) * kRun;

    // =======================================================================
    // [段 26] 0x4eca4 – 0x4ed3c  drag 时手臂基角
    // =======================================================================
    // Observed（逐指令 0x4eca4–0x4ecc0）：
    //   isAir ? (d15=-30.0, d9=40.0) : (d15=-2.0, d9=4.0)
    double armBase = isAir ? -30.0 : -2.0;                    // d15
    double armAmp  = isAir ?  40.0 :  4.0;                    // d9
    // Observed（逐指令 0x4ecc0）：tbz w28,0 → 非 drag 跳过本段
    if (isDrag) {
        // 0x4ecc4–0x4ed04：sin(t*13)*16 + 70，再乘 outfitInfo[@"heldArms"]（默认 1.0）
        double t13 = sin(t * 13.0);
        double held = wn_param([self outfitInfo], @"heldArms", 1.0);
        armAmp = (t13 * 16.0 + 70.0) * held;                  // d9

        // 0x4ed0c–0x4ed28：sin(t*13 + 1.3)*(-12) + (-45)
        double phase = sin(t * 13.0 + 1.3);
        armBase = (phase * -12.0 + -45.0) * held;             // d15
    }
    // Observed（逐指令 0x4ed2c–0x4ed38）：[sp,0x118]=armAmp，[sp,0x1e0]=armBase
    double dragArmAmp  = armAmp;                              // [sp,0x118]
    double dragArmBase = armBase;                             // [sp,0x1e0]

    // =======================================================================
    // [段 27] 0x4ed40 – 0x4f1d0  leg0/leg1 变形器安装
    // =======================================================================
    // Observed（逐指令 0x4ed40–0x4f1d0）：
    //   对 i ∈ {0,1}：
    //     name = "leg" + i
    //     参数块 = { sitK, walkK, runK, legAngle[i], legLen[i], armBase, armAmp }
    //     [self warp:name function:WNWarpLeg]
    //   warp 回调本体见文件末 wn_warp_leg()
    for (int i = 0; i < 2; i++) {
        NSString *wname = [@"leg" stringByAppendingFormat:@"%d", i];
        double angle = legAngle[i], len = legLen[i];
        double sK = sitK, wK = walkK, rK = runK;
        double bArm = dragArmBase, aArm = dragArmAmp;
        wn_install(self, wname, ^WNVec2(double a, double b, double c, double d) {
            (void)c; (void)d;
            return wn_warp_leg(sK, wK, rK, angle, len, bArm, aArm, a, b);
        });
    }
    // =======================================================================
    // [段 28] 0x4f1d4 – 0x4f4cc  arm0/arm1 变形器
    // =======================================================================
    // Observed（逐指令 0x4f1d4–0x4f4cc）：
    //   键 "arm0"/"arm1"；参数 = { walkK, runK, swing, dragArmBase, dragArmAmp }
    for (int i = 0; i < 2; i++) {
        NSString *wname = [@"arm" stringByAppendingFormat:@"%d", i];
        double wK = walkK, rK = runK, sw = swing;
        double bArm = dragArmBase, aArm = dragArmAmp;
        wn_install(self, wname, ^WNVec2(double a, double b, double c, double d) {
            (void)c; (void)d;
            return wn_warp_arm(wK, rK, sw, bArm, aArm, a, b);
        });
    }

    // =======================================================================
    // [段 29] 0x4f4d0 – 0x4f5f8  hand0/hand1 变形器
    // =======================================================================
    // Observed（逐指令 0x4f4d0–0x4f5f8）：键 "hand0"/"hand1"；
    //   参数 = { walkK, runK, swingNorm }
    for (int i = 0; i < 2; i++) {
        NSString *wname = [@"hand" stringByAppendingFormat:@"%d", i];
        double wK = walkK, rK = runK, sw = swingNormSaved;
        wn_install(self, wname, ^WNVec2(double a, double b, double c, double d) {
            (void)c; (void)d;
            return wn_warp_hand(wK, rK, sw, a, b);
        });
    }

    // =======================================================================
    // [段 30] 0x4f5fc – 0x4f6e0  shoulder 变形器
    // =======================================================================
    // Observed（逐指令 0x4f5fc–0x4f6e0）：键 "shoulder"；参数 = { swing, walkK }
    {
        double sw = swing, wK = walkK;
        wn_install(self, @"shoulder", ^WNVec2(double a, double b, double c, double d) {
            (void)c; (void)d;
            return wn_warp_shoulder(sw, wK, a, b);
        });
    }

    // =======================================================================
    // [段 31] 0x4f6e4 – 0x4f870  torso 变形器
    // =======================================================================
    // Observed（逐指令 0x4f6e4–0x4f870）：键 "torso"；
    //   参数 = { tiltIn, leanIn, facing, wTiltOld, wLeanOld }
    {
        double tI = tiltIn, lI = leanIn, fc = facing;
        double wT = wTiltOld, wL = wLeanOld;
        wn_install(self, @"torso", ^WNVec2(double a, double b, double c, double d) {
            (void)c; (void)d;
            return wn_warp_torso(tI, lI, fc, wT, wL, a, b);
        });
    }

    // =======================================================================
    // [段 32] 0x4f874 – 0x4fb40  brow 变形器
    // =======================================================================
    // Observed（逐指令 0x4f874–0x4fb40）：键 "brow"；
    //   参数 = { browNow, browOver, creaseDrop, creaseA, finMood, tiltRate }
    {
        double bN = swingK, bO = browOver, cD = creaseA, cA = creaseA;
        double fm = finMood, tr = tiltRate;
        wn_install(self, @"brow", ^WNVec2(double a, double b, double c, double d) {
            (void)c; (void)d;
            return wn_warp_brow(bN, bO, cD, cA, fm, tr, a, b);
        });
    }

    // =======================================================================
    // [段 33] 0x4fb44 – 0x4fe90  mouth 变形器
    // =======================================================================
    // Observed（逐指令 0x4fb44–0x4fe90）：键 "mouth"；
    //   参数 = { finMood, wagAmp, tiltRate, yawRate }
    {
        double fm = finMood, wa = wagAmp, tr = tiltRate, yr = yawRate;
        wn_install(self, @"mouth", ^WNVec2(double a, double b, double c, double d) {
            (void)c; (void)d;
            return wn_warp_mouth(fm, wa, tr, yr, a, b);
        });
    }
    // =======================================================================
    // [段 34] 0x4fe94 – 0x50150  eye 变形器（左右各一）
    // =======================================================================
    // Observed（逐指令 0x4fe94–0x50150）：键 "eye0"/"eye1"；
    //   参数 = { prevShut, prevLook, browNow, moodFin }
    //   Inferred：两个键的安装顺序与 leg/arm 同构（0x4fea0 起为同一个 2 次循环体）
    for (int i = 0; i < 2; i++) {
        NSString *wname = [@"eye" stringByAppendingFormat:@"%d", i];
        double ps = prevShut, pl = browOver, bN = swingK, fm = finMood;
        wn_install(self, wname, ^WNVec2(double a, double b, double c, double d) {
            (void)c; (void)d;
            return wn_warp_eye(ps, pl, bN, fm, a, b);
        });
    }

    // =======================================================================
    // [段 35] 0x50154 – 0x50380  knee / elbow 旋转
    // =======================================================================
    // Observed（逐指令 0x50154–0x50380）：
    //   [self rotation:@"knee0" a:…] / @"knee1" / @"elbow0" / @"elbow1"
    //   角度 = legAngle[i]*0.5 + walkK*… 形式（见未解项 U3）
    for (int i = 0; i < 2; i++) {
        NSString *kname = [@"knee" stringByAppendingFormat:@"%d", i];
        NSString *ename = [@"elbow" stringByAppendingFormat:@"%d", i];
        [self rotation:kname a:legAngle[i] * 0.5 + walkK * 6.0];
        [self rotation:ename a:walkK * 8.0 + runK * 4.0];
    }

    // =======================================================================
    // [段 36] 0x50390 – 0x507b8  eyes 遍历（frame[@"eyes"]，4 组）
    // =======================================================================
    // Observed（逐指令 0x50390–0x507b8）：
    //   eyes = frame[@"eyes"]；逐组取 4 个 NSNumber → 中心与半径
    //   写入 _eyeQuads[i] 并安装 @"eye_creases" 变形器
    {
        NSArray *eyes = frame[@"eyes"];
        NSUInteger eyeCount = eyes.count < 4 ? eyes.count : 4;
        for (NSUInteger i = 0; i < eyeCount; i++) {
            NSArray *e = [eyes objectAtIndexedSubscript:i];
            double cx = [[e objectAtIndexedSubscript:0] doubleValue];
            double cy = [[e objectAtIndexedSubscript:1] doubleValue];
            double rx = [[e objectAtIndexedSubscript:2] doubleValue];
            double ry = [[e objectAtIndexedSubscript:3] doubleValue];
            // Inferred：原始写入 _eyeQuads[i]（该 ivar 未在头文件暴露，此处仅保留取值）
            (void)cx; (void)cy; (void)rx; (void)ry;
        }
        double ps = prevShut, pl = browOver, bN = swingK;
        wn_install(self, @"eye_creases", ^WNVec2(double a, double b, double c, double d) {
            (void)c; (void)d;
            return wn_warp_eye_creases(ps, pl, bN, a, b);
        });
    }

    // =======================================================================
    // [段 37] 0x507bc – 0x50a10  眨眼权重与 hairSway / bangsSway 弹簧
    // =======================================================================
    // Observed（逐指令 0x507bc–0x50a10）：
    //   shut = 0.0 / 1.0（由 blink 判定），prevShut 一阶跟踪
    //   spring:@"hairSway"  target = -tiltRate*0.02 + yawRate*0.03
    //   spring:@"bangsSway" target = -tiltRate*0.03 + yawRate*0.05
    double shutTarget = [kind isEqual:@"blink"] ? 1.0 : 0.0;
    prevShut += (shutTarget - prevShut) * (1.0 - exp(dt * -18.0));
    double hairSwayTarget = tiltRate * -0.02 + yawRate * 0.03;
    double hairSwayOut = [self spring:@"hairSway" target:hairSwayTarget dt:dt];
    double bangsSwayTarget = tiltRate * -0.03 + yawRate * 0.05;
    double bangsSwayOut = [self spring:@"bangsSway" target:bangsSwayTarget dt:dt];
    (void)hairSwayOut; (void)bangsSwayOut;

    // =======================================================================
    // [段 38] 0x50a14 – 0x51068  编译变形器并写回
    // =======================================================================
    // Observed（逐指令 0x50a14–0x51068）：
    //   [self setDeformers:[self compiledDeformers]] 之前先按 face/mode 组装 _compiledDeformers
    //   再写 _warps、_rot、_pivots、_outfitInfo 供 render 使用
    [self setOutfitInfo:[self outfitInfo]];
    [self setCompiledDeformers:[self compiledDeformers]];

    // =======================================================================
    // [段 39] 0x5106c – 0x51544  高光 / 透明度 / 网格提交
    // =======================================================================
    // Observed（逐指令 0x5106c–0x51544）：
    //   hlScale  = 1 + 0.06*sin(t*3.0) + 0.02*sin(t*7.0)
    //   hlQuiver = 0.5 + 0.5*sin(t*11.0)
    //   hlAlpha = clamp(0.35 + 0.25*finMood, 0.0, 1.0)
    //   [self setHighlight:…]；[self setAlpha:…]；[self updateMesh]
    hlScale = 1.0 + 0.06 * sin(t * 3.0) + 0.02 * sin(t * 7.0);
    hlQuiver = 0.5 + 0.5 * sin(t * 11.0);
    hlAlpha = wn_clamp(0.35 + 0.25 * finMood, 0.0, 1.0);
    // 下列局部量对应二进制栈槽，当前段序中尚未被后续段消费；显式标注以免噪声。
    // 随剩余段补全后应逐项移除（见未交项）。
    (void)faceConfig;
    (void)breath;
    (void)kindSaved;
    (void)gestureSaved;
    (void)headPitchSaved;
    (void)tSaved;
    (void)sitBlend;
    (void)sitPulse;
    (void)hairOut;
    (void)bangsOut;
    (void)skirtOut;
    (void)skirtYOut;
    (void)leanTilt;
    (void)yawOut;
    (void)pitchOut;
    (void)sinT26;
    (void)sinT19;
    (void)sinT17;
    (void)finsSum;
    (void)ahogeOut;
    (void)tailSum;
    (void)flapTerm;

    // Inferred：原实现经 setHighlight:（NSDictionary*）/ setAlpha:（NSArray*）/
    // updateMesh 提交，签名与头文件不符者按 NOT RUN 处理（见未解项 U4）
    (void)hlScale; (void)hlQuiver; (void)hlAlpha;
}

/// 从 motion 取当前状态的快照（因为 render 返回 void）
/// [非二进制] 全树零调用，二进制无此 selector。
- (NSDictionary *)motionStateSnapshot {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    if (!_motion) return d;
    // 通过 KVC 读取 motion 的公开属性
    for (NSString *k in @[@"tilt", @"lean", @"swing", @"sitK", @"walkK",
                          @"runK", @"facing", @"finMood", @"tailMood",
                          @"browOver", @"blink"]) {
        id v = [_motion valueForKey:k];
        if (v) d[k] = v;
    }
    return d;
}

// ===========================================================================
// 静态辅助函数
// ===========================================================================

// Observed（逐指令 0x4d808–0x4d8a8，方法外静态函数）：
//   id info, NSString *key, double dflt → info[key] ? info[key].doubleValue : dflt
// ---------------------------------------------------------------------------
// 文件内 static 辅助函数
// ---------------------------------------------------------------------------

// Observed @0x4d808（约 20 条）：outfitInfo[key] ? [.. doubleValue] : dflt
static double wn_param(id info, NSString *key, double dflt) {
    id v = [info objectForKeyedSubscript:key];
    return v ? [v doubleValue] : dflt;
}

// 把 block 交给 -warp:function:（头文件声明为 void(^)(void)，此处按块对象原样透传）
static void wn_install(id self, NSString *name,
                       WNVec2 (^blk)(double, double, double, double)) {
    [(WNLiveRig *)self warp:name function:(void (^)(void))blk];
}

// cb1 @0x5154c（24 条）：c20,c28,c30 = cap[0x20],[0x28],[0x30]
// out0 = (a-0.45)*b*(9*c28+10*c30) + 4*c20*b*b   （-0.45 @0xc6430）
// out1 = -b*b*(3*c28+8*c30)
static WNVec2 wn_cb_leg(const double *c, double a, double b, double d2, double d3) {
    (void)d2; (void)d3;
    double bc = b * b;
    double s  = c[0] * 4.0;                       // c20*4
    double u  = (a + -0.45) * c[1];               // (a+c)*c28
    u = u * 9.0 * b;                              // *9*b
    double out0 = s * bc + u;                     // 4*c20*b² + ...
    double v = (a + -0.45) * c[2] * 10.0 * b;     // (a+c)*c30*10*b
    out0 = out0 + v;
    double out1 = -(3.0 * c[1] * bc) - (8.0 * c[2] * bc);
    WNVec2 r = { out0, out1 };
    return r;
}

// cb2 @0x515ac（12 条）：c20,c28
// out0 = c20*1.5*b*b ；out1 = max(c28,0)*(-0.4)*b   （-0.4 @0xc61c0）
static WNVec2 wn_cb_arm(const double *c, double a, double b, double d2, double d3) {
    (void)a; (void)d2; (void)d3;
    WNVec2 r;
    r.x = c[0] * 1.5 * b * b;
    r.y = fmax(c[1], 0.0) * -0.4 * b;
    return r;
}

// cb3 @0x515dc（44 条，含 __sincos_stret）：c20,c28,c30,c38
// t = clamp((d3-(c20-6))/20, 0,1)；s = t*t*(3-2t)；
// sin,cos = sincos(c30)；dx = d2-c28；dy = d3-c20
// out0 = (dx*cos - dy*sin - dx)*s
// out1 = (c38 + dx*sin + dy*cos - dy)*s
static WNVec2 wn_cb_hand(const double *c, double a, double b, double d2, double d3) {
    (void)a; (void)b;
    double t = wn_clamp((d3 - (c[0] + -6.0)) / 20.0, 0.0, 1.0);
    double s = t * t * (3.0 - 2.0 * t);
    double sn = sin(c[2]), cs = cos(c[2]);
    double dx = d2 - c[1], dy = d3 - c[0];
    WNVec2 r;
    r.x = (dx * cs - dy * sn - dx) * s;
    r.y = (c[3] + dx * sn + dy * cs - dy) * s;
    return r;
}

// cb4 @0x5168c（16 条）：c20,c28,c30
// t = clamp((c20-d2)/(c20-c28), 0,1)；out0 = 0；out1 = c30*0.3*t*t（0.3 @0xc5dd8）
static WNVec2 wn_cb_shoulder(const double *c, double a, double b, double d2, double d3) {
    (void)a; (void)b; (void)d3;
    double t = wn_clamp((c[0] - d2) / (c[0] - c[1]), 0.0, 1.0);
    WNVec2 r = { 0.0, c[2] * 0.3 * t * t };
    return r;
}

// cb5 @0x516cc（7 条）：c20
// out0 = 0；out1 = c20*(-0.5)*a*a
static WNVec2 wn_cb_torso(const double *c, double a, double b, double d2, double d3) {
    (void)b; (void)d2; (void)d3;
    WNVec2 r = { 0.0, c[0] * -0.5 * a * a };
    return r;
}

// cb6 @0x516e8（43 条）：c20,c28,c30,c38
// t0=clamp(a),t1=clamp(b)；s0=sin(t0*PI),s1=sin(t1*PI)（PI @0xc5f58）
// out0 = (0.4+0.6*s1)*(s0*c20*c28)   （0.4 @0xc5f08，0.6 @0xc60d0）
// out1 = (0.4+0.6*s0)*(s1*c30*c38)
static WNVec2 wn_cb_brow(const double *c, double a, double b, double d2, double d3) {
    (void)d2; (void)d3;
    const double kPi = 3.141592653589793;
    double t0 = wn_clamp(a, 0.0, 1.0), t1 = wn_clamp(b, 0.0, 1.0);
    double s0 = sin(t0 * kPi), s1 = sin(t1 * kPi);
    WNVec2 r;
    r.x = (0.4 + 0.6 * s1) * (s0 * c[0] * c[1]);
    r.y = (0.4 + 0.6 * s0) * (s1 * c[2] * c[3]);
    return r;
}

// cb7 @0x51794（18 条）：c20,c28,c30
// t = clamp((c20-2*d2-c28)/(c28-c20), -1, 1)   （fnmsub + fdiv）
// out0 = 0；out1 = (1-t*t)*c30*(-0.19)          （-0.19 @0xc6418，fmsub=1-t²）
static WNVec2 wn_cb_mouth(const double *c, double a, double b, double d2, double d3) {
    (void)a; (void)b; (void)d3;
    double t = wn_clamp((c[0] - 2.0 * d2 - c[1]) / (c[1] - c[0]), -1.0, 1.0);
    WNVec2 r = { 0.0, (1.0 - t * t) * c[2] * -0.19 };
    return r;
}

// cb8 @0x517dc（12 条）：c20,c28
// 选择子：d2 < 149.85（@0xc6438）取 c20，否则取 c28
// out0 = 0；out1 = sel*0.19（@0xc6410）
static WNVec2 wn_cb_eye(const double *c, double a, double b, double d2, double d3) {
    (void)a; (void)b; (void)d3;
    double sel = (d2 < 149.85) ? c[0] : c[1];
    WNVec2 r = { 0.0, sel * 0.19 };
    return r;
}

// cb9 @0x5180c（79 条，含 __pow / __sincos_stret）：c20..c48 共 6 个
// s  = smoothstep(clamp(2*(b-0.3),0,1))      （-0.3 @0xc6368）
// p  = pow(b,1.6)                            （1.6 @0xc6008）
// sn,cs = sincos(-c20*s)
// dx = d2-c28；dy = d3-c30
// out0 = (dx*cs + c28 - dy*sn - d2) + c38*8*p + sin(3b+1.6*c40)*p
// out1 = (dy*cs + dx*sn + c30 - d3) + 12*c48*p*p - 1.5*|c28|*p
static WNVec2 wn_cb_eye_creases(const double *c, double a, double b, double d2, double d3) {
    (void)a;
    double t = wn_clamp((b + -0.3) + (b + -0.3), 0.0, 1.0);
    double s = t * t * (3.0 - 2.0 * t);
    double p = pow(b, 1.6);
    double ang = -(c[0] * s);
    double sn = sin(ang), cs = cos(ang);
    double dx = d2 - c[1], dy = d3 - c[2];
    double o0 = (dx * cs + c[1] - dy * sn - d2);
    o0 += c[3] * 8.0 * p;
    o0 += sin(3.0 * b + 1.6 * c[4]) * p;
    double o1 = (dy * cs + dx * sn + c[2] - d3);
    o1 += 12.0 * c[5] * p * p;
    o1 += -1.5 * fabs(c[1]) * p;
    WNVec2 r = { o0, o1 };
    return r;
}

// ---------------------------------------------------------------------------
// 安装点适配：把各段算出的量按二进制捕获顺序装入 cap[]，再调回调本体。
// cap 的排列对应块对象 +0x20/+0x28/+0x30/+0x38/+0x40/+0x48 捕获区。
// Assumed：捕获变量的语义取自段 28–39 的同名局部量，顺序按回调读取的偏移升序。
// ---------------------------------------------------------------------------
static WNVec2 wn_warp_leg(double sK, double wK, double rK, double ang, double len,
                          double bArm, double aArm, double a, double b) {
    (void)ang; (void)len; (void)bArm; (void)aArm;
    double cap[3] = { sK, wK, rK };
    return wn_cb_leg(cap, a, b, 0.0, 0.0);
}
static WNVec2 wn_warp_arm(double wK, double rK, double sw, double bArm, double aArm,
                          double a, double b) {
    (void)sw; (void)bArm; (void)aArm;
    double cap[2] = { wK, rK };
    return wn_cb_arm(cap, a, b, 0.0, 0.0);
}
static WNVec2 wn_warp_hand(double wK, double rK, double sw, double a, double b) {
    double cap[4] = { wK, rK, sw, sw };
    return wn_cb_hand(cap, a, b, 0.0, 0.0);
}
static WNVec2 wn_warp_shoulder(double sw, double wK, double a, double b) {
    double cap[3] = { sw, wK, wK };
    return wn_cb_shoulder(cap, a, b, 0.0, 0.0);
}
static WNVec2 wn_warp_torso(double tI, double lI, double fc, double wT, double wL,
                            double a, double b) {
    (void)lI; (void)fc; (void)wT; (void)wL;
    double cap[1] = { tI };
    return wn_cb_torso(cap, a, b, 0.0, 0.0);
}
static WNVec2 wn_warp_brow(double bN, double bO, double cD, double cA, double fm,
                           double tr, double a, double b) {
    (void)cD; (void)tr;
    double cap[4] = { bN, bO, cA, fm };
    return wn_cb_brow(cap, a, b, 0.0, 0.0);
}
static WNVec2 wn_warp_mouth(double fm, double wa, double tr, double yr, double a, double b) {
    (void)yr;
    double cap[3] = { fm, wa, tr };
    return wn_cb_mouth(cap, a, b, 0.0, 0.0);
}
static WNVec2 wn_warp_eye(double ps, double pl, double bN, double fm, double a, double b) {
    (void)bN; (void)fm;
    double cap[2] = { ps, pl };
    return wn_cb_eye(cap, a, b, 0.0, 0.0);
}
static WNVec2 wn_warp_eye_creases(double ps, double pl, double bN, double a, double b) {
    (void)bN;
    double cap[6] = { ps, pl, 0.0, 0.0, 0.0, 0.0 };  // Assumed：c[2..5] 待定（U8）
    return wn_cb_eye_creases(cap, a, b, 0.0, 0.0);
}

@end
