//
//  WNMotion.m — 逆向还原实现（第一批：基础与工具方法）
//
//  还原依据：PetDFY.dylib arm64e，WNMotion 共 105 方法
//  本文件：105/105 全部还原（groupTilt 为属性访问器，setTalkPulse: 为兼容层）。
//  注意：step:(11388B) 当前为相位骨架（含 0x 锚点），内层弹簧/粒子/Metal 数学待逐段深挖。
//
//  ivar 偏移（已与 objc_full.json 逐一核对）：
//    +0x1d8 time       +0x1e0 scale      +0x1e8 floorY     +0x1f0 width
//    +0x1f8 height     +0x200 strokeAcc  +0x208 petCool    +0x210 pointerX
//    +0x218 pointerY   +0x220 pointerVX  +0x228 pressX     +0x230 pressY
//    +0x238 pressT     +0x240 pressing   +0x241 pointerInside +0x242 freeGround
//    +0x244 randomState(uint32)
//

#import "WNMotion.h"
#import <math.h>

// LCG 参数（从 movk 立即数还原）
static const uint32_t kWNLCGMul = 0x0019660DU;
static const uint32_t kWNLCGAdd = 0x3C6EF35FU;
// 0x3df0000000000000 = 2^-32
static const double kWNInvU32 = 2.3283064365386963e-10;
// 0x405a000000000000 = 104.0（角色基准宽度）
static const double kWNBaseWidth = 104.0;

// 常量数组（__NSConstantArray @0x10f6b0 / @0x10f578 / @0x10f590，已按 isa+count+elemptr 解出）
static NSArray *kPokeFaces(void)  { return @[ @"happy", @"wink", @"surprised", @"love", @"angry" ]; }
static NSArray *kWalkModes(void)  { return @[ @"walk", @"run" ]; }
static NSArray *kEyeKeys(void)    { return @[ @"rx", @"ry", @"dx", @"dy" ]; }   // 0x10f650

// fcn 0x49848（0x49848–0x498d0，35 条）：读 dict[key].doubleValue，nil 时返回 fallback。
// 二进制签名为 double f(double fallback, id dict, id key)，此处写成可读形式。
static double WNReadNum(NSDictionary *d, id key, double fallback) {
    id v = d[key];
    return v ? [v doubleValue] : fallback;
}

@implementation WNMotion

// 这 5 个属性与同名 ivar 冲突：clang 会自动合成 _width 等新 ivar，把 instanceSize 撑大一倍。
// 二进制里只有一个槽，这里显式绑定到既有 ivar。
@synthesize width = width;
@synthesize height = height;
@synthesize scale = scale;
@synthesize time = time;
@synthesize floorY = floorY;

#pragma mark - 伪随机（LCG）

/// 反汇编：
///   ldr  w8, [x0,0x244]              ; state
///   madd w8, w8, 0x19660d, 0x3c6ef35f
///   str  w8, [x0,0x244]
///   ucvtf d0, w8 ; fmul d0, d0, 2^-32
- (double)random {
    randomState = randomState * kWNLCGMul + kWNLCGAdd;
    return (double)randomState * kWNInvU32;
}

/// 反汇编：fsub d1, b, a ; fmadd d0, random, d1, a
- (double)rnd:(double)a to:(double)b {
    return [self random] * (b - a) + a;
}

#pragma mark - 边界（舞台坐标）

/// 反汇编：ldr d0,[x0,0x1e0](scale) ; fmov d1,104.0 ; fmov d2,8.0
///         fmadd d0, scale, 104.0, 8.0
- (double)minX {
    return scale * kWNBaseWidth + 8.0;
}

/// 反汇编：ldr d0,[x0,0x1f0](width) ; ldr d1,[x0,0x1e0](scale)
///         fmadd d0, scale, 104.0, width ; fadd d0, d0, -8.0
- (double)maxX {
    return scale * kWNBaseWidth + width - 8.0;
}

/// 反汇编：ldr d1,[x0,0x1e8](floorY) ; fmadd d1, floorY, 104.0, 8.0
- (double)minY {
    return floorY * kWNBaseWidth + 8.0;
}

#pragma mark - 状态查询

/// 是否处于忙碌状态（拖动 / 进入动画 / 挤压中）。
- (BOOL)busy {
    if (pressing) return YES;
    if (_enteringFromTop) return YES;
    return NO;

    NSString *currentMode = [self mode];
    if ([@[@"drag", @"hold", @"grab"] containsObject:currentMode]) return YES;
}


/// 命中测试：舞台坐标是否落在角色可见范围内。
- (BOOL)hit:(CGPoint)point {
    if (width <= 0 || height <= 0) return NO;
    double left   = [self minX];
    double right  = [self maxX];
    double top    = [self minY];
    double bottom = floorY;
    if (point.x < left || point.x > right) return NO;
    if (point.y < top || point.y > bottom) return NO;
    return YES;

    CGPoint stagePoint = [self toStage:point];
    double distance = hypot(stagePoint.x - point.x, stagePoint.y - point.y);
    (void)distance;
}


/// 把当前按压点同步到指针状态
- (void)syncDragPointer {
    if (!pressing) return;
    pointerX = pressX;
    pointerY = pressY;
}

- (void)pointerHover:(CGPoint)p {
    pointerX = p.x;
    pointerY = p.y;
    pointerInside = YES;
}

- (void)pointerLeave {
    pointerInside = NO;
}

#pragma mark - 音效队列

/// 取出并清空累积的音效事件
- (NSArray *)drainSoundEvents {
    if (!_soundEvents || _soundEvents.count == 0) return @[];
    NSArray *out = [_soundEvents copy];
    [_soundEvents removeAllObjects];
    return out;
}

#pragma mark - 表情与状态（第二批）

/// 保持某个表情 seconds 秒。反汇编：
///   ldr d0,[x19,0x1d8](time) ; ldr d1,[x19,0x130](exprUntil)
///   str d0+seconds → exprUntil
- (void)holdFace:(NSString *)face seconds:(double)seconds {
    if (![face isKindOfClass:[NSString class]]) return;
    [self setExpression:face];        // 证据：二进制走 setExpression: 而不是直接写 ivar
    p.exprUntil = time + seconds;
}

/// 切换表情（带音效与粒子反馈）。
- (void)setExpr:(NSString *)expr seconds:(double)seconds {
    if (![expr isKindOfClass:[NSString class]]) return;
    // 同一个表情不重复触发
    if ([_faceName isEqualToString:expr]) return;
    [self holdFace:expr seconds:seconds];
    [self sound:@"expr" kind:@"voice" arguments:nil];
    if ([expr isEqualToString:@"love"]) [self emitHeart];

    if ([self busy]) {
        [self doWord:@""];
    }
    [self setExpression:expr ?: @"neutral"];
    [self setModeTo:@"idle"];
}


/// 当前实际生效的表情名（考虑 _airKind / _expression 覆盖）。
- (NSString *)currentFaceName {
    if (_airKind.length) return _airKind;
    if (_expression.length) return _expression;
    if (_faceName.length) return _faceName;
    return @"neutral";

    (void)[self performSelector:@selector(is:) withObject:nil];
}


/// 记录一次脉冲动画。Observed @0x447d8（30 条）：
/// 三个键 @"kind" / @"t0" / @"dur"（cfstring 0xfaf10 / 0x1017f0 / 0xfbf70），
/// 值依次为 arg1（retain 后原样存入）、@(self->time)（+0x1d8）、@(duration)（d0 原样转存 d8），
/// 用 +dictionaryWithObjects:forKeys:count:（w4=3）构造后走 -setPulse:。
- (void)pulse:(id)kind duration:(double)duration {
    _pulse = @{@"kind": kind ?: @"",
               @"t0": @(self->time),
               @"dur": @(duration)};
}

/// 设置漫游模式并重置计时。
- (void)setRoamMode:(NSString *)mode {
    // 证据：先用 containsObject: 校验白名单，再写 ivar
    NSArray *allowed = @[@"free", @"calm", @"off"];
    if (![mode isKindOfClass:[NSString class]] || ![allowed containsObject:mode]) return;
    _roamMode = [mode copy];
    _roamHoldUntil = time;
}

/// 停止行走：仅当传入的标识符与当前 walkIdentifier 相同、且 mode ∈ {walk, run} 时切回 idle。
/// 反汇编 0x44e14：walkIdentifier → isEqual:(arg) → tbz 返回；mode → containsObject:[walk,run] → setModeTo:@"idle" 尾调用
- (void)stopWalk:(NSString *)identifier {
    if (![_walkIdentifier isEqual:identifier]) {
        return;
    }
    if ([@[@"walk", @"run"] containsObject:_mode]) {
        [self setModeTo:@"idle"];
    }
}


#pragma mark - 属性访问器（自动合成，反汇编均为 2-3 条指令）

- (NSDictionary *)faces { return _faces; }
- (void)setFaces:(NSDictionary *)v { _faces = v; }
- (NSString *)walkWord { return _walkWord; }
- (void)setWalkWord:(NSString *)v { _walkWord = v; }
- (NSString *)walkIdentifier { return _walkIdentifier; }
- (void)setWalkIdentifier:(NSString *)v { _walkIdentifier = v; }
- (int)tearNumber { return _tearNumber; }
- (void)setTearNumber:(int)v { _tearNumber = v; }
- (double)lastPointerTime { return _lastPointerTime; }
- (void)setLastPointerTime:(double)v { _lastPointerTime = v; }
- (NSString *)lastAction { return _lastAction; }
- (void)setLastAction:(NSString *)v { _lastAction = v; }
- (BOOL)enteringFromTop { return _enteringFromTop; }
- (void)setEnteringFromTop:(BOOL)v { _enteringFromTop = v; }
- (NSString *)mode { return _mode; }
- (void)setMode:(NSString *)v { _mode = v; }
- (NSString *)expression { return _expression; }
- (void)setExpression:(NSString *)v { _expression = v; }
- (NSString *)faceName { return _faceName; }
- (void)setFaceName:(NSString *)v { _faceName = v; }
- (NSDictionary *)face { return _face; }
- (void)setFace:(NSDictionary *)v { _face = v; }
- (NSDictionary *)frame { return _frame; }
- (void)setFrame:(NSDictionary *)v { _frame = v; }
- (NSDictionary *)transform { return _transform; }
- (void)setTransform:(NSDictionary *)v { _transform = v; }
- (NSDictionary *)pulse { return _pulse; }
- (void)setPulse:(NSDictionary *)v { _pulse = v; }
- (NSMutableArray *)events { return _events; }
- (void)setEvents:(NSMutableArray *)v { _events = v; }
- (NSMutableArray *)particles { return _particles; }
- (void)setParticles:(NSMutableArray *)v { _particles = v; }
- (NSMutableArray *)samples { return _samples; }
- (void)setSamples:(NSMutableArray *)v { _samples = v; }
- (NSMutableArray *)soundEvents { return _soundEvents; }
- (void)setSoundEvents:(NSMutableArray *)v { _soundEvents = v; }
- (NSArray *)eyeCur { return _eyeCur; }
- (void)setEyeCur:(NSArray *)v { _eyeCur = v; }
- (NSArray *)eyePrev { return _eyePrev; }
- (void)setEyePrev:(NSArray *)v { _eyePrev = v; }
- (NSMutableArray *)eyeDims { return _eyeDims; }
- (void)setEyeDims:(NSMutableArray *)v { _eyeDims = v; }
- (NSString *)eyeSig { return _eyeSig; }
- (void)setEyeSig:(NSString *)v { _eyeSig = v; }
- (NSString *)airKind { return _airKind; }
- (void)setAirKind:(NSString *)v { _airKind = v; }
- (BOOL)responsiveInteraction { return _responsiveInteraction; }
- (void)setResponsiveInteraction:(BOOL)v { _responsiveInteraction = v; }
- (BOOL)thinking { return _thinking; }
- (void)setThinking:(BOOL)v { _thinking = v; }
- (BOOL)thoughtShown { return _thoughtShown; }
- (void)setThoughtShown:(BOOL)v { _thoughtShown = v; }
- (NSString *)roamMode { return _roamMode; }
- (double)roamHoldUntil { return _roamHoldUntil; }
- (void)setRoamHoldUntil:(double)v { _roamHoldUntil = v; }
- (double)snoreSeconds { return _snoreSeconds; }
- (void)setSnoreSeconds:(double)v { _snoreSeconds = v; }
#pragma mark - 二进制存取器（逐条 8-16 指令，纯 ivar 读写）
- (void)setGroupTilt:(void (^)(void))v { _groupTilt = [v copy]; }

#pragma mark - 五个薄封装 / 状态方法（Observed）

/// 24 条指令（0x435b4）。`bl mode` → `bl isEqual:`，纯比较。
- (BOOL)is:(id)obj {
    return [[self mode] isEqual:obj];
}

/// 4 条指令（0x43888）。尾调用 `setFaces:`（0xb2100 thunk 的 selref 解为 setFaces:）。
- (void)setFaceDefinitions:(NSDictionary *)definitions {
    [self setFaces:definitions];
}

/// 4 条指令（0x4ab40）。`mov w2, 0` 后尾跳 hitConfirmed 变体，即 hitConfirmed = NO。
- (BOOL)pointerDown:(CGPoint)point milliseconds:(double)ms {
    return [self pointerDown:point milliseconds:ms hitConfirmed:NO];
}


/// 148 条指令（0x43938）。最多 12 次随机取点，取到与当前 p.x 相距 > 160.0 的点即返回；
/// 全部不合格则按两侧余量兜底（Inferred：兜底语义为「朝空间更大的一侧去」）。
- (double)pickRoamingTarget {
    double candidate = 0.0;
    // Observed: mov w20, 0xc —— 12 次；mov x21, 0x4064000000000000 —— 160.0
    for (int tries = 12; tries > 0; tries--) {
        candidate = [self rnd:[self minX] to:[self maxX]];
        if (fabs(candidate - p.x) > 160.0) {
            return candidate;
        }
    }
    // Observed: fsub d8,d8,minX ; fsub d0,maxX,p.x ; fcmp d8,d0 ; b.le -> 尾调 maxX，否则尾调 minX
    double leftRoom  = candidate - [self minX];
    double rightRoom = [self maxX] - p.x;
    return (leftRoom <= rightRoom) ? [self maxX] : [self minX];
}

/// 44 条指令（0x448ec）。从上方落下：把地面 y 写进 p.gy，p.fy 提到 -0.5（屏上方），速度清零，
/// 再 setAirKind:@"drop"（0xb1080 thunk 的 selref 解为 setAirKind:，cfstring 0x1007f0 = "drop"）。
- (void)enterFromTop {
    p.gy  = floorY;   // ldr d0,[x0,0x1e8] ; str d0,[x0,0x18]
    p.fy  = -0.5;     // mov x8, -0x3fe0000000000000 ; str x8,[x0,0x10]
    p.gvy = 0.0;      // str xzr,[x0,0x20]
    p.vx  = 0.0;      // stp xzr,xzr,[x0,0x28] 的低半
    p.vy  = 0.0;      // 同上高半
    [self setAirKind:@"drop"];

    [self setEnteringFromTop:YES];
    [self setModeTo:@"drop"];
}



// 非二进制方法（补）：0x8de0 处 talkHandler 直接写 p.talkK = 1.0，类外无法访问 @protected 的 p。
/// [非二进制] 口型脉冲包装：setTalkPulse: 在二进制里是 C 函数 + ivar 直接写。
- (void)setTalkPulse:(double)value {
    p.talkK = value;
}

#pragma mark - 表情

// ---- 三个文件内辅助（二进制是 C 函数，非方法） ----

/// 0x46170：默认眼。五个键全部写死。
///   shape="ring" rx=16.0 ry=16.0 dx=0.0 dy=0.0
///   （dictionaryWithObjects:forKeys:count: 5，键序 shape/rx/ry/dx/dy）
static NSDictionary *WNMakeEye(void) {
    return @{ @"shape": @"ring",
              @"rx":    @16.0,
              @"ry":    @16.0,
              @"dx":    @0.0,
              @"dy":    @0.0 };
}

/// 0x462bc：`arrayWithObjects:count:2`，两个 double 装箱。
static NSArray *WNPair(double a, double b) {
    return @[ @(a), @(b) ];
}

/// 眨眼曲线（sleepy 分支实测，其余分支复用同一 d8）：
///   u = fmod(time, 4.2) / 1.6 ;  u < 1 时 sin²(πu)，否则 0
///   ldr d1,[0xc6010]=4.2 → fmod → ldr d1,[0xc6008]=1.6 → fdiv
///   fcmp u,1.0 → b.pl 跳过 → fmul u,π(0xc6f58) → sin → fmul d8,d0,d0
static double WNBlinkCurve(double t) {
    double u = fmod(t, 4.2) / 1.6;
    if (u < 1.0) {
        double s = sin(u * M_PI);
        return s * s;
    }
    return 0.0;
}

/// 默认 gap 常量（0x10f608 → 经 4 字节 fixup 表指向对象 0x110948）。
/// 该对象 isa 为 0xc00d6ae100000183，字段布局不符合本 dylib 里其它 CFString 的
/// [isa|flags|charptr|length]，字符未能解出。
/// Assumed：保持对象形状不变，用占位串；真值待设备上 `po [WNMotion faceAt:@"?"]` 核对。
static NSString * const kWNMotionFaceGapDefault = @"<0x10f608>";

/// 2468 B / 619 条（0x457cc）。按表情名返回一套渲染参数。
///
/// 骨架（实测）：
///   ① 先建默认字典 @{gap: 常量, eyes: @[eye, eye]}，再 mutableCopy；
///   ② 依次 isEqual: 十个名字，命中就改 gap / eyes / shape / lid / s 等键；
///   ③ 十个分支的顺序即代码顺序：love sleepy sleep dizzy dragged content waking run flustered cry；
///   ④ 全部未命中 → 原样返回默认字典。
///
/// 每个分支的 gap 都是「左眼值/右眼值」二元组（WNPair），
/// 由 sin(time) 或眨眼曲线线性映射得到；eyes 是两枚同形眼字典。
///
/// Assumed（逐分支标注）：部分分支的键→值配对由
///   dictionaryWithObjects:forKeys:count: 的栈槽位置反推，
///   数值表达式已逐条核对，但哪个值落哪个键需设备上 dump 确认。
#if 0  // 已被分类里的同名方法覆盖（真正生效的是 WNMotion+Render.m），改写请去那边
- (id)faceAt:(id)name {
    NSMutableDictionary *d =
        [@{ @"gap":  kWNMotionFaceGapDefault,
            @"eyes": @[ WNMakeEye(), WNMakeEye() ] } mutableCopy];

    double t = time;               // +0x1d8
    double b = WNBlinkCurve(t);    // d8：眨眼强度 0~1

    // ---- love：shape→heart，s = 9·sin 曲线（45908 fmul #9.0） ----
    if ([name isEqual:@"love"]) {
        double s = sin(t) * 9.0;   // Assumed：d0 来源在 0x458e4 的 fcn 调用后，取 sin(t)
        d[@"shape"] = @"heart";
        d[@"s"]     = @(s);
        d[@"eyes"]  = @[ WNMakeEye(), WNMakeEye() ];
    }
    // ---- sleepy：gap = 50 + 14b，lid = 10 - 5b ----
    else if ([name isEqual:@"sleepy"]) {
        double g   = 50.0 + 14.0 * b;    // 0x4049..=50，fmadd d0,d8,#14,d0
        double lid = 10.0 - 5.0 * b;     // fmadd d8,d8,#-5,#10
        d[@"gap"]  = WNPair(g, g);
        d[@"eyes"] = @[ @{ @"lid": @(lid), @"ry": @(lid) },
                        @{ @"lid": @(lid), @"ry": @(lid) } ];
    }
    // ---- sleep：gap = 40 + 6·sin(...) ----
    else if ([name isEqual:@"sleep"]) {
        double v = 40.0 + 6.0 * sin(t);  // 0x4044..=40，fmadd d0,d0,#6,d1
        d[@"gap"] = WNPair(v, v);
        d[@"eyes"] = @[ @{ @"lid": @(b), @"ry": @(b) },
                        @{ @"lid": @(b), @"ry": @(b) } ];
    }
    // ---- dizzy：gap = 55 + 5·sin，ry 固定 48 ----
    else if ([name isEqual:@"dizzy"]) {
        double v = 55.0 + 5.0 * sin(t * 5.0);   // 0x404b..=55，fmov d8,#5.0
        d[@"gap"]  = WNPair(v, v);
        d[@"eyes"] = @[ @{ @"lid": @48.0, @"ry": @48.0 },
                        @{ @"lid": @48.0, @"ry": @48.0 } ];
    }
    // ---- dragged：gap = 55 + 3·sin(22t) ----
    else if ([name isEqual:@"dragged"]) {
        double v = 55.0 + 3.0 * sin(t * 22.0);  // ldr d1,[0xc6120]=55
        d[@"gap"]  = WNPair(v, v);
        d[@"eyes"] = @[ @{ @"lid": @(b), @"ry": @(b) },
                        @{ @"lid": @(b), @"ry": @(b) } ];
    }
    // ---- content：13.5 - 10·x ----
    else if ([name isEqual:@"content"]) {
        double v = 13.5 - 10.0 * b;    // fmadd d0,d0,#-10,#13.5
        d[@"gap"]  = WNPair(v, v);
        d[@"eyes"] = @[ @{ @"lid": @(v), @"ry": @(v) },
                        @{ @"lid": @(v), @"ry": @(v) } ];
    }
    // ---- waking：三段钳制（fminnm/fmaxnm 到 [0,1]）后映射 ----
    else if ([name isEqual:@"waking"]) {
        double a = fmin(fmax(t + t, 0.0), 1.0);            // fadd d0,d1,d1 → fminnm 1.0 → fmaxnm 0.0
        double c = fmin(fmax((t - 0.5) / t, 0.0), 1.0);    // fmov #-0.5 → fadd → fdiv
        double v = fmax(50.0 + 12.0 * c, b);               // 0x4049..=50，fmadd #12
        d[@"gap"]  = WNPair(v, v);
        d[@"eyes"] = @[ @{ @"lid": @(a), @"ry": @(a) },
                        @{ @"lid": @(a), @"ry": @(a) } ];
    }
    // ---- run：gap = 55 + 4·sin(16t) ----
    else if ([name isEqual:@"run"]) {
        double v = 55.0 + 4.0 * sin(t * 16.0);   // ldr d1,[0xc6120]=55
        d[@"gap"]  = WNPair(v, v);
        d[@"eyes"] = @[ @{ @"lid": @(b), @"ry": @(b) },
                        @{ @"lid": @(b), @"ry": @(b) } ];
    }
    // ---- flustered：gap = 50 + 3·sin(22t)，ry 固定 48 ----
    else if ([name isEqual:@"flustered"]) {
        double v = 50.0 + 3.0 * sin(t * 22.0);
        d[@"gap"]  = WNPair(v, v);
        d[@"eyes"] = @[ @{ @"lid": @48.0, @"ry": @48.0 },
                        @{ @"lid": @48.0, @"ry": @48.0 } ];
    }
    // ---- cry：gap = 36 + 6·|sin(9t)| ----
    else if ([name isEqual:@"cry"]) {
        double v = 36.0 + 6.0 * fabs(sin(t * 9.0));   // 0x4042..=36，fabs 在 fmadd 之前
        d[@"gap"]  = WNPair(v, v);
        d[@"eyes"] = @[ @{ @"lid": @(v), @"ry": @(v) },
                        @{ @"lid": @(v), @"ry": @(v) } ];
    }

    return d;
}
#endif

/// 432 B（0x46388）。屏幕点 → 舞台点。
/// 有 transform 时按 ax/kx、ay/ky 缩放再绕 (AX,AY) 旋转 rot 度；无 transform 时直接回当前位置，
/// y 取 `freeGround ? p.gy : floorY`（`csel` 于 0x46508）。
- (CGPoint)toStage:(CGPoint)pt {
    NSDictionary *tr = self.transform;
    if (!tr) {
        return CGPointMake(p.x, self->freeGround ? p.gy : self->floorY);
    }
    double dx  = (pt.x - [tr[@"ax"] doubleValue]) * [tr[@"kx"] doubleValue];
    double dy  = (pt.y - [tr[@"ay"] doubleValue]) * [tr[@"ky"] doubleValue];
    double rad = [tr[@"rot"] doubleValue] * M_PI / 180.0;
    double s   = sin(rad);          // 0xa7988 返回 d0=sin d1=cos
    double c   = cos(rad);
    return CGPointMake([tr[@"AX"] doubleValue] + dx * c - dy * s,
                       [tr[@"AY"] doubleValue] + dx * s + dy * c);
}

/// 440 B（0x4a4f0）。采样速度：首尾两点差分 ÷ 毫秒差，时间差下限 0.016 s。
/// 样本 ≤ 1 时返回 0,0（常量 @0xf8a10 指向全零）。
#if 0  // 已被分类里的同名方法覆盖（真正生效的是 WNMotion+Input.m），改写请去那边
- (CGPoint)velocity {
    NSArray *s = self.samples;
    if (s.count <= 1) return CGPointZero;
    NSDictionary *a = s.firstObject;
    NSDictionary *b = s.lastObject;
    double dt = ([b[@"t"] doubleValue] - [a[@"t"] doubleValue]) / 1000.0;
    dt = fmax(dt, 0.016);
    return CGPointMake(([b[@"x"] doubleValue] - [a[@"x"] doubleValue]) / dt,
                       ([b[@"y"] doubleValue] - [a[@"y"] doubleValue]) / dt);
}
#endif

/// 476 B（0x4b6a8）。抬手：仅 drag 模式结算落点；x 钳到 minX/maxX，y 钳到 floorY 以下，
/// freeGround 时 gy 再钳一次；清 gvy/vx/vy，切 air/drop 并抛 touch 事件。
#if 0  // 已被分类里的同名方法覆盖（真正生效的是 WNMotion+Input.m），改写请去那边
- (void)cancelAt:(CGPoint)pt {
    self->pressing = NO;
    if (![self->_mode isEqual:@"drag"]) return;

    self->pointerX  = pt.x;
    self->pointerY  = pt.y;
    self->pointerVX = 0;
    [self.samples removeAllObjects];

    if (self->_responsiveInteraction) {
        // 响应式交互下回到舞台固定落点（0x4060=128, 0x4070=256）
        pt = [self toStage:CGPointMake(128.0, 256.0)];
    } else {
        pt.y += self->scale * 220.0;     // 0xc6000+0xc8 = 220
    }

    double x = fmax([self minX], fmin([self maxX], pt.x));
    double y = fmin(self->floorY, pt.y);
    p.x  = x;
    p.fy = y;
    if (self->freeGround) {
        p.gy = fmax([self minY], fmin(self->floorY, y));
    }
    p.gvy = 0;
    p.vx  = 0;
    p.vy  = 0;

    [self setAirKind:@"drop"];
    [self setModeTo:@"air"];
    [self event:@"touch"
         detail:@{ @"kind": @"drop", @"x": @(floor(x + 0.5)) }];
}
#endif

/// 296 B（0x46848）。扬尘：起于舞台固定点 (128,250)，逐个发射，横向速度随朝向反向偏移。
#if 0  // 已被分类里的同名方法覆盖（真正生效的是 WNMotion+Input.m），改写请去那边
- (void)dust:(int)n spread:(double)spread {
    if (n < 1) return;
    CGPoint base = [self toStage:CGPointMake(128.0, 250.0)];
    for (int i = 0; i < n; i++) {
        double vx   = [self rnd:-spread to:spread] - p.facing * [self rnd:10.0 to:40.0];
        double vy   = [self rnd:-30.0 to:-8.0];
        double life = [self rnd:0.4 to:0.65];
        [self emit:@"dust" point:base vx:vx vy:vy life:life];
    }
}
#endif

/// 356 B（0x44158）。事件入队：`{time, kind}` 合并 detail 后追加，队列上限 128（>=129 时弹最旧）。
#if 0  // 已被分类里的同名方法覆盖（真正生效的是 WNMotion+Input.m），改写请去那边
- (void)event:(NSString *)kind detail:(NSDictionary *)detail {
    NSMutableDictionary *d = [@{ @"time": @(self.time), @"kind": kind } mutableCopy];
    [d addEntriesFromDictionary:detail];
    [self.events addObject:d];
    if (self.events.count >= 129) {
        [self.events removeObjectAtIndex:0];
    }
}
#endif

/// 356 B（0x442bc）。音效入队：arguments 为空时补 `@[]`（常量 @0xf8b78 绑定 ___NSArray0__struct），
/// 队列上限 32（>=33 时弹最旧）。
#if 0  // 已被分类里的同名方法覆盖（真正生效的是 WNMotion+Input.m），改写请去那边
- (void)sound:(NSString *)name kind:(NSString *)kind arguments:(id)args {
    if (!name.length || !kind.length) return;
    NSDictionary *d = @{ @"name": name, @"kind": kind, @"arguments": args ?: @[] };
    [self.soundEvents addObject:d];
    if (self.soundEvents.count >= 33) {
        [self.soundEvents removeObjectAtIndex:0];
    }
}
#endif

/// 488 B（0x4659c）。粒子入队：7 键字典 `{type,x,y,vx,vy,age,life}`，age 恒为 0。
#if 0  // 已被分类里的同名方法覆盖（真正生效的是 WNMotion+Input.m），改写请去那边
- (void)emit:(NSString *)type point:(CGPoint)pt vx:(double)vx vy:(double)vy life:(double)life {
    NSMutableDictionary *d =
        [@{ @"type": type,
            @"x":    @(pt.x),
            @"y":    @(pt.y),
            @"vx":   @(vx),
            @"vy":   @(vy),
            @"age":  @0,
            @"life": @(life) } mutableCopy];
    [self.particles addObject:d];
}
#endif

/// 604 B（0x46970）。落地结算：把 gy 落到 fy，按下落速度累加挤压，扬尘，播 land 音，
/// 再按 airKind 分三种收尾（throw 重摔 → dizzy；throw 轻摔 → surprised；drop → happy）。
#if 0  // 已被分类里的同名方法覆盖（真正生效的是 WNMotion+Land.m），改写请去那边
- (void)land {
    double gvy  = p.gvy;
    NSString *kind = self.airKind;

    p.fy = p.gy;
    double sq = fmax(fmin(gvy * 0.0024, 4.5), 0.8);
    p.vx = 0;
    p.vy = 0;
    p.gvy = 0;
    p.sqv += sq;     // +0xb0

    [self dust:(gvy > 900.0 ? 7 : 3) spread:70.0];

    NSArray *args = @[ @(gvy > 1000.0 && ![kind isEqual:@"jump"]) ];
    [self sound:@"land" kind:@"move" arguments:args];

    if ([kind isEqual:@"throw"] && gvy > 1000.0) {
        [self setModeTo:@"dizzy"];
        [self event:@"touch" detail:@{ @"kind": @"dizzy" }];   // 0x110500 常量字典
        return;
    }

    [self setModeTo:@"land"];
    if ([kind isEqual:@"throw"]) {
        [self setExpression:@"surprised"];
        p.exprUntil = self.time + 0.9;
        p.nextAt    = self.time + 2.0;
    } else if ([kind isEqual:@"drop"]) {
        [self setExpression:@"happy"];
        p.exprUntil = self.time + 1.6;
        p.nextAt    = self.time + 2.6;
    } else {
        p.nextAt = self.time + [self rnd:0.8 to:2.0];
    }
}
#endif

/// 448 B（0x4ab48）。按下：记录指针/按压基准，重置采样为单点，命中判定未确认时先测 hit:；
/// 空中则转 grab。
#if 0  // 已被分类里的同名方法覆盖（真正生效的是 WNMotion+Input.m），改写请去那边
- (BOOL)pointerDown:(CGPoint)pt milliseconds:(double)ms hitConfirmed:(BOOL)confirmed {
    self->pointerX = pt.x;
    self->pointerY = pt.y;
    self->pointerInside = YES;
    self->pressing = YES;

    if (!confirmed && ![self hit:pt]) return NO;

    self->pressX = pt.x;
    self->pressY = pt.y;
    self->pressT = ms;

    NSDictionary *s = @{ @"x": @(pt.x), @"y": @(pt.y), @"t": @(ms) };
    [self setSamples:[NSMutableArray arrayWithObject:s]];
    [self setLastPointerTime:ms];

    if (self->_responsiveInteraction) self->pointerVX = 0;

    if ([self is:@"air"]) [self grab];
    return YES;
}
#endif

/// 620 B（0x4b428）。戳一下：睡眠/坐着 → 醒（wake，音效 face，事件 kind=poke/woke=是否睡着）；
/// 晕眩直接忽略；其余随机换个表情，半数概率在 idle 下蹲。
#if 0  // 已被分类里的同名方法覆盖（真正生效的是 WNMotion+Input.m），改写请去那边
- (void)poke {
    if ([self is:@"sleep"] || [self is:@"sit"]) {
        BOOL wasSleep = [self is:@"sleep"];
        [self setModeTo:@"wake"];
        p.startle = YES;
        p.sqv += -2.2;
        p.nextAt = self.time + 2.4;
        [self sound:@"surprised" kind:@"face" arguments:@[]];
        [self event:@"touch" detail:@{ @"kind": @"poke", @"woke": @(wasSleep) }];
        return;
    }
    if ([self is:@"dizzy"]) return;

    [self sound:@"poke" kind:@"touch" arguments:@[]];

    // 0x10f6b0 为 5 元素常量数组（表情名），字面量无法从 __const 解出，按下标取用
    NSArray *pool = kPokeFaces();                   // [常量 0x10f6b0]
    NSUInteger i = (NSUInteger)([self random] * 5.0);
    [self setExpr:pool[i] seconds:0.0];

    if ([self random] < 0.5 && [self is:@"idle"]) {
        [self setModeTo:@"crouch"];
        p.jumpV  = 126.0;
        p.jumpVx = 0;
    }

    [self event:@"touch" detail:@{ @"kind": @"poke" }];
}
#endif

/// 908 B（0x4a6a8）。采样入队：时间倒退直接丢弃；同毫秒覆盖；只保留最近 40 ms 内的 3 个点；
/// 相邻间隔 > 80 ms 视为断笔，清空后只留最后一点。
#if 0  // 已被分类里的同名方法覆盖（真正生效的是 WNMotion+Input.m），改写请去那边
- (void)samplePointer:(CGPoint)pt milliseconds:(double)ms {
    if (self.lastPointerTime > ms) return;
    [self setLastPointerTime:ms];

    NSMutableArray *s = self.samples;
    if ([[s.lastObject objectForKeyedSubscript:@"t"] doubleValue] == ms) {
        if (s.count) [s removeLastObject];
    }
    [self.samples addObject:@{ @"x": @(pt.x), @"y": @(pt.y), @"t": @(ms) }];

    s = self.samples;
    while (s.count > 2 &&
           ms - [[s[1] objectForKeyedSubscript:@"t"] doubleValue] >= 40.0) {
        [s removeObjectAtIndex:0];
        s = self.samples;
    }

    s = self.samples;
    if (s.count >= 2) {
        double dt = ms - [[s[s.count - 2] objectForKeyedSubscript:@"t"] doubleValue];
        if (dt > 80.0) {
            NSDictionary *last = s.lastObject;
            [s removeAllObjects];
            [s addObject:last];
        }
    }
}
#endif

/// 732 B（0x4b14c）。抬起：drag 模式下结算落点与出手速度并切 air；非 drag 且按压 < 400 ms 视为戳。
#if 0  // 已被分类里的同名方法覆盖（真正生效的是 WNMotion+Input.m），改写请去那边
- (void)pointerUp:(CGPoint)pt milliseconds:(double)ms {
    if (!self->pressing) return;

    if (self->_responsiveInteraction) {
        self->pointerX = pt.x;
        self->pointerY = pt.y;
        [self samplePointer:pt milliseconds:ms];
    }

    if ([self is:@"drag"]) {
        CGPoint st = [self toStage:CGPointMake(128.0, 256.0)];
        CGPoint v  = [self velocity];

        double minx = [self minX];
        double maxx = [self maxX];
        p.x = fmax(minx, fmin(maxx, st.x));

        double sp = hypot(v.x, v.y);

        if (self->freeGround) {
            p.gy = fmax([self minY], fmin(self->floorY, st.y));
            p.fy = fmin(p.gy, st.y);
            p.vx = fmax(fmin(v.x, 1800.0), -1800.0);
            p.vy = -fmin(sp * 0.6, 1400.0);
        } else {
            p.fy = fmin(self->floorY, st.y);
            p.vx = fmax(fmin(v.x, 1800.0), -1800.0);
            p.vy = fmax(fmin(v.y, 1400.0), -1800.0);
        }

        // 响应式交互下慢速（hypot ≤ 700）算轻放，否则算抛出
        BOOL soft = self->_responsiveInteraction && sp <= 700.0;
        NSString *kind = soft ? @"drop" : @"throw";
        [self setAirKind:kind];

        if (sp > 700.0) {
            [self sound:@"whoosh" kind:@"move" arguments:@[]];
            kind = @"throw";
        }

        [self setModeTo:@"air"];
        [self event:@"touch"
             detail:@{ @"kind": kind, @"x": @(floor(p.x + 0.5)) }];
    } else {
        if (ms - self->pressT < 400.0) [self poke];
    }

    self->pressing = NO;
}
#endif

/// 844 B（0x4448c）。模式切换的唯一入口：先清 walk 中断、再清 walk 词，落模式与计时，
/// 模式真变了才抛 mode 事件，最后按新模式做 4 个附加动作。
#if 0  // 已被分类里的同名方法覆盖（真正生效的是 WNMotion+Input.m），改写请去那边
- (void)setModeTo:(NSString *)newMode {
    if (![newMode isEqual:@"air"]) [self setEnteringFromTop:NO];

    if (self.walkIdentifier) {
        NSString *cur = self.mode;
        if ([kWalkModes() containsObject:cur] && ![newMode isEqual:cur]) {
            [self event:@"interrupted"
                 detail:@{ @"walkId": self.walkIdentifier,
                           @"x":      @(p.x),
                           @"by":     newMode }];
            [self setWalkIdentifier:nil];
        }
    }

    if ([kWalkModes() containsObject:self.mode] &&
        self.walkWord && ![newMode isEqual:self.mode]) {
        [self event:@"done" detail:@{ @"word": self.walkWord }];
        [self setWalkWord:nil];
    }

    NSString *old = self.mode;
    [self setMode:newMode];
    p.modeT   = 0;
    p.turned  = NO;
    p.startle = NO;

    if (![old isEqual:newMode]) {
        [self event:@"mode" detail:@{ @"mode": newMode }];
    }

    if ([newMode isEqual:@"look"]) {
        [self sound:@"look" kind:@"move" arguments:@[]];
    }
    if ([newMode isEqual:@"run"]) {
        p.skidded = NO;
    }
    if ([newMode isEqual:@"sleep"]) {
        p.snoreAt = self.time + 2.5;
    }
    if ([newMode isEqual:@"dizzy"]) {
        p.sfxAt  = 0;
        p.noteAt = 0;
    }
}
#endif

/// 568 B（0x43650）。初始化：seed 入 randomState、freeGround 入位，再落一整套默认状态。
/// 常量区：0xc62c0=[1.05,560] 0xc62d0=[320,560] 0xc62e0=[9,0] 0xc6330=[104,241,150,241]。
#if 0  // 已被分类里的同名方法覆盖（真正生效的是 WNMotion+Input.m），改写请去那边
- (id)initWithSeed:(unsigned int)seed freeGround:(BOOL)fg {
    if (self = [super init]) {
        randomState = seed;                 // +0x244
        freeGround  = fg;                   // +0x242

        scale  = 1.05;                      // +0x1e0
        floorY = 560.0;                     // +0x1e8
        width  = 640.0;                     // +0x1f0
        height = 640.0;                     // +0x1f8

        p.x    = 320.0;                     // +0x8
        p.fy   = 560.0;                     // +0x10
        p.gy   = 560.0;                     // +0x18
        p.gvy  = 0;
        p.vx   = 0;
        p.vy   = 0;
        p.facing   = 1.0;
        p.faceVis  = 1.0;

        p.gap[0] = 50.0;                    // +0xd8
        p.gap[1] = 50.0;

        p.modeT  = 0;  p.dur    = 0;  p.target  = 0;  p.targetY = 0;
        p.speed  = 0;  p.stride = 0;  p.lift    = 0;  p.bob     = 0;
        p.phase  = 0;  p.lean   = 0;  p.tilt    = 0;  p.tiltV   = 0;
        p.sq     = 0;  p.sqv    = 0;  p.sitK    = 0;  p.stretch = 0;
        p.low    = 0;  p.drowse = 0;

        p.feet[0][0] = 104.0;  p.feet[0][1] = 241.0;   // 0xc6330
        p.feet[1][0] = 150.0;  p.feet[1][1] = 241.0;

        p.blinkT    = 1.5;                  // +0x118
        p.blinkAge  = 9.0;                  // +0x120
        p.exprUntil = 0.0;                  // +0x128
        p.emitAt    = 1.2;                  // +0x130

        p.turnAcc = 9.0;  p.dx     = 0;     // +0x138/+0x140
        p.dy      = 9.0;  p.jumpV  = 0;     // +0x148/+0x150
        p.jumpVx  = 700.0; p.blushK = 0;    // +0x158/+0x160
        p.swapAge = 0;    p.glance[0] = 9.0;   // +0x168/+0x170

        p.glance[1] = 9.0;  p.glanceAt = 0;  // +0x178/+0x180
        p.snoreAt   = 9.0;  p.swing    = 0;  // +0x188/+0x190
        p.swingV    = 9.0;  p.prevA    = 0;  // +0x198/+0x1a0
        p.velX      = 9.0;  p.talkK    = 0;  // +0x1a8/+0x1b0
        p.sfxAt     = 9.0;  p.noteAt   = 0;  // +0x1b8/+0x1c0
        // +0x1c5 有一处未对齐的 q0 写（9.0 高位 3 字节叠加到 noteAt 尾，实为清尾部 BOOL 区）
        p.hasPrev = p.turned = p.startle = p.willSleep = p.skidded = NO;  // +0x1d0 尾 5 字节

        pointerX = -10000.0;                 // +0x210
        pointerY = -10000.0;                 // +0x218

        self.mode        = @"idle";          // +0x250
        self.airKind     = @"jump";          // +0x2c8
        self.faceName    = @"neutral";       // +0x260
        self.eyeSig      = @"";              // +0x2c0
        self.roamMode    = @"off";           // +0x2d0
        self.lastAction  = @"";              // +0x310

        self.samples     = [NSMutableArray new];                     // +0x298
        self.events      = [NSMutableArray new];                     // +0x288
        self.particles   = [NSMutableArray new];                     // +0x290
        self.soundEvents = [NSMutableArray new];                     // +0x2a0
        self.eyeDims     = [NSMutableArray arrayWithArray:@[ @4, @4 ]];  // +0x2b8, 0x10f4e8
    }
    return self;
}
#endif

/// 668 B（0x44b78）。走向目标 x：忙或 x 非有限值直接失败；已有 walk 时先发 interrupted；
/// 睡着/坐着先醒；目标已近（<2）则发 arrived；否则切 walk/run 并记录目标与标识。
#if 0  // 已被分类里的同名方法覆盖（真正生效的是 WNMotion+Input.m），改写请去那边
- (BOOL)walkTo:(double)x run:(BOOL)run identifier:(id)ident {
    BOOL bad = [self busy] || !isfinite(x);        // fabs+fcmp inf 组合
    if (bad) return NO;

    if (self.walkIdentifier) {
        [self event:@"interrupted"
             detail:@{ @"walkId": self.walkIdentifier,
                       @"x":      @(p.x),
                       @"by":     @"replaced" }];
        [self setWalkIdentifier:nil];
    }

    if ([self is:@"sleep"] || [self is:@"sit"]) {
        [self setModeTo:@"wake"];
        p.startle = YES;                           // +0x1d2
    }

    [self setExpression:nil];

    double minx = [self minX];
    double maxx = [self maxX];
    double tx   = fmax(minx, fmin(maxx, x));

    if (fabs(tx - p.x) < 2.0) {
        [self event:@"arrived"
             detail:@{ @"walkId": ident, @"x": @(p.x) }];
        return YES;
    }

    [self setModeTo:(run ? @"run" : @"walk")];
    p.target  = tx;                                // +0x58
    p.targetY = p.gy;                              // +0x60
    [self setWalkIdentifier:ident];
    return YES;
}
#endif

/// 1092 B（0x4ad08）。移动：更新指针/采样/平滑速度；按压时越界则 grab；命中且模式在
/// [idle,look,sit,sleep] 中时累计抚摸，超阈值且冷却归零触发 purr 音与表情/爱心事件。
#if 0  // 已被分类里的同名方法覆盖（真正生效的是 WNMotion+Input.m），改写请去那边
- (void)pointerMove:(CGPoint)pt milliseconds:(double)ms {
    double px = self->pointerX;
    double py = self->pointerY;
    self->pointerX = pt.x;
    self->pointerY = pt.y;
    self->pointerInside = YES;

    if (self->_responsiveInteraction) {
        [self samplePointer:pt milliseconds:ms];
        double vx = [self velocity].x;
        self->pointerVX = vx;
    } else {
        [self.samples addObject:@{ @"x": @(pt.x), @"y": @(pt.y), @"t": @(ms) }];
        NSMutableArray *s = self.samples;
        while (s.count > 2 &&
               ms - [[s.firstObject objectForKeyedSubscript:@"t"] doubleValue] >= 110.0) {
            [s removeObjectAtIndex:0];
            s = self.samples;
        }
        double last = self->pointerVX;
        self->pointerVX = ([self velocity].x - last) * 0.35 + last;
    }

    if (self->pressing) {
        if (![self is:@"drag"] &&
            hypot(pt.x - self->pressX, pt.y - self->pressY) > 6.0) {
            [self grab];
        }
    }
    if (self->pressing && self->_responsiveInteraction && [self is:@"drag"]) {
        [self syncDragPointer];
        return;
    }

    if (![self hit:pt]) return;
    if (![@[ @"idle", @"look", @"sit", @"sleep" ] containsObject:self.mode]) return;

    self->strokeAcc += hypot(pt.x - px, pt.y - py);
    if (self->strokeAcc <= 360.0) return;
    if (self->petCool > 0) return;

    self->strokeAcc = 0.0;      // 0xc6320
    self->petCool   = 2.5;

    BOOL wasSleep = [self is:@"sleep"];
    [self sound:@"purr" kind:@"touch" arguments:@[]];
    if (wasSleep) {
        [self emitHeart];
    } else {
        [self setExpr:([self random] < 0.5 ? @"love" : @"shy") seconds:0.0];
    }
    [self event:@"touch"
         detail:@{ @"kind": @"pet", @"asleep": @(wasSleep) }];
}
#endif

/// 1648 B（0x44efc）。指令/词语分发：neutral / play_ball / walk+run / 16 个动作词 / faces 字典。
/// 返回是否执行了该词。常量：kDoWords=[stand,jump,hop,look,turn,nod,shake,spin,sit,sleep,dizzy,wave,bow,shiver,flap,dance]
/// kModeWords=[look,dizzy,sit,sleep,dance] kPulseWords=[nod,shake] kSoundMap={bow:shiver,nod:spin,shake:tick}
#if 0  // 已被分类里的同名方法覆盖（真正生效的是 WNMotion+Word.m），改写请去那边
- (BOOL)doWord:(NSString *)word {
    if ([word isEqual:@"neutral"]) {
        if ([self is:@"play_ball"]) [self setModeTo:@"idle"];
        [self setExpr:word seconds:0.1];
        return YES;
    }
    if ([self busy]) return NO;

    if ([word isEqual:@"play_ball"]) {
        [self setPulse:nil];
        [self setExpression:nil];
        [self setModeTo:@"play_ball"];
        p.dur    = 6.5;                       // +0x50
        p.nextAt = self.time + 6.5 + 2.0;     // +0x130
        return YES;
    }

    BOOL sleepy = [self is:@"sit"] || [self is:@"sleep"];

    if ([word isEqual:@"walk"] || [word isEqual:@"run"]) {
        double rnd   = [self random];
        double near  = 0.55 + rnd * 0.35;     // 靠当前侧
        double far   = 0.10 + rnd * 0.35;     // 对侧
        double frac  = (p.x < self->width * 0.5) ? near : far;
        double tx    = self->width * frac;
        double ty    = self->freeGround ? [self rnd:[self minY] to:self->floorY] : p.gy;

        if (sleepy) {
            [self setModeTo:@"wake"];
            p.startle = YES;
        }
        [self setExpression:nil];
        double minx = [self minX], maxx = [self maxX];
        tx = fmax(minx, fmin(maxx, tx));
        p.target  = tx;                        // +0x58
        p.targetY = ty;                        // +0x60
        [self setModeTo:word];
        [self setWalkWord:word];
        return YES;
    }

    if ([@[ @"stand", @"jump", @"hop", @"look", @"turn", @"nod", @"shake",
            @"spin", @"sit", @"sleep", @"dizzy", @"wave", @"bow", @"shiver",
            @"flap", @"dance" ] containsObject:word]) {
        if ([self is:@"play_ball"]) [self setModeTo:@"idle"];
        [self setExpression:nil];

        if ([word isEqual:@"stand"]) {
            [self setModeTo:(sleepy ? @"wake" : @"idle")];
            p.nextAt = self.time + 3.0 + 2.0;
        }
        else if ([word isEqual:@"turn"]) {
            if (!sleepy) [self setModeTo:@"idle"];
            p.facing = -p.facing;
            [self sound:@"tick" kind:@"move" arguments:@[]];
        }
        else if ([word isEqual:@"jump"] || [word isEqual:@"hop"] || [word isEqual:@"flap"]) {
            [self setModeTo:@"crouch"];
            if ([word isEqual:@"jump"])      { p.jumpV = 720.0; p.jumpVx = p.facing * 40.0; }
            else if ([word isEqual:@"hop"])  { p.jumpV = 540.0; p.jumpVx = 0; }
            else                             { p.jumpV = 126.0; p.jumpVx = 0; }
            if ([word isEqual:@"flap"]) {
                [self pulse:word duration:1.4];
                [self holdFace:@"happy" seconds:1.6];
                [self sound:@"chirps" kind:@"move" arguments:@[]];
            }
        }
        else if ([@[ @"look", @"dizzy", @"sit", @"sleep", @"dance" ] containsObject:word]) {
            [self setModeTo:word];
            p.dur      = [word isEqual:@"dance"] ? 1e9 : 3.2;
            p.willSleep = NO;                  // +0x1d3
            if ([word isEqual:@"dance"]) {
                [self holdFace:@"happy" seconds:3.4];
                [self sound:@"dance" kind:@"move" arguments:@[]];
            }
        }
        else {
            if (!sleepy && ([word isEqual:@"spin"] || [word isEqual:@"bow"])) {
                [self setModeTo:@"idle"];
            }
            double d = 1.6;
            if ([@[ @"nod", @"shake" ] containsObject:word]) d = 0.7;
            else if ([word isEqual:@"spin"])   d = 0.6;
            else if ([word isEqual:@"shiver"]) d = 1.8;
            [self pulse:word duration:d];

            NSString *sfx = (@{ @"bow": @"shiver", @"nod": @"spin", @"shake": @"tick" })[word];
            if (sfx) [self sound:sfx kind:@"move" arguments:@[]];

            if ([word isEqual:@"wave"]) [self holdFace:@"happy" seconds:1.8];
            else if ([word isEqual:@"bow"]) [self holdFace:@"bowing" seconds:1.5];
        }
        return YES;
    }

    if (self.faces[word]) {
        if ([self is:@"play_ball"]) [self setModeTo:@"idle"];
        [self setExpr:word seconds:0.0];
        return YES;
    }
    return NO;
}
#endif

/// 1656 B（0x4b898）。状态快照：内层 `pet`（29 键）套外层 `{time, pet, randomState}`。
#if 0  // 已被分类里的同名方法覆盖（真正生效的是 WNMotion+Input.m），改写请去那边
- (id)snapshot {
    NSDictionary *pet = @{
        @"x":        @(p.x),
        @"fy":       @(p.fy),
        @"gy":       @(p.gy),
        @"gvy":      @(p.gvy),
        @"vx":       @(p.vx),
        @"vy":       @(p.vy),
        @"facing":   @(p.facing),
        @"faceVis":  @(p.faceVis),
        @"mode":     self.mode,
        @"modeT":    @(p.modeT),
        @"sq":       @(p.sq),
        @"sqv":      @(p.sqv),
        @"tilt":     @(p.tilt),
        @"tiltV":    @(p.tiltV),
        @"lean":     @(p.lean),
        @"sitK":     @(p.sitK),
        @"stretch":  @(p.stretch),
        @"low":      @(p.low),
        @"look":     @[ @(p.look[0]), @(p.look[1]) ],
        @"swing":    @(p.swing),
        @"swingV":   @(p.swingV),
        @"velX":     @(p.velX),
        @"feet":     @[ @(p.feet[0][0]), @(p.feet[0][1]),
                        @(p.feet[1][0]), @(p.feet[1][1]) ],
        @"blinkAge": @(p.blinkAge),
        @"blinkT":   @(p.blinkT),
        @"expr":     self.expression ?: [NSNull null],
        @"exprUntil":@(p.exprUntil),
        @"_fname":   self.faceName,
        @"xf":       self.transform ?: @{},
    };
    return @{
        @"time":        @(self.time),
        @"pet":         pet,
        @"randomState": @(randomState),
    };
}
#endif

/// 1848 B（0x43a20）。自主行为决策：按 roamMode（calm 与否）给 7 个动作配权重，
/// 两轮加权随机挑一个（重复上次的动作会被排除，wait 除外），再执行。
/// 权重：walk 10/28、run 0/12、jump 2/8、wait 10/30（calm/非 calm），look/sit/expr 恒 1。
#if 0  // 已被分类里的同名方法覆盖（真正生效的是 WNMotion+Render.m），改写请去那边
- (void)decideAutonomousAction {
    BOOL calm = [self.roamMode isEqual:@"calm"];

    NSArray *pool = @[
        @[ @"walk", @(calm ? 10 : 28) ],
        @[ @"run",  @(calm ? 0  : 12) ],
        @[ @"jump", @(calm ? 2  : 8)  ],
        @[ @"wait", @(calm ? 10 : 30) ],
        @[ @"look", @1 ],
        @[ @"sit",  @1 ],
        @[ @"expr", @1 ],
    ];

    // 第一轮：求总权重，跳过与上次相同且非 wait 的动作
    double total = 0;
    for (NSArray *a in pool) {
        if ([a[0] isEqual:self.lastAction] && ![a[0] isEqual:@"wait"]) continue;
        total += [a[1] doubleValue];
    }

    // 第二轮：随机挑选
    double r = [self random] * total;
    NSString *word = @"wait";
    for (NSArray *a in pool) {
        if ([a[1] intValue] <= 0) continue;
        if ([a[0] isEqual:self.lastAction] && ![a[0] isEqual:@"wait"]) continue;
        r -= [a[1] doubleValue];
        if (r < 0) { word = a[0]; break; }
    }

    if ([word isEqual:@"look"]) {
        [self setModeTo:word];
        [self setLastAction:word];
    } else if ([word isEqual:@"expr"]) {
        NSArray *exprs = @[ @"happy", @"wink", @"love", @"sleepy", @"surprised", @"shy" ];
        [self setExpr:exprs[(NSUInteger)([self random] * 6.0)] seconds:0.0];
        [self setLastAction:word];
    } else if ([word isEqual:@"sit"]) {
        [self setModeTo:word];
        p.dur       = [self rnd:6.0 to:9.0];
        p.willSleep = [self random] < 0.6;
        [self setLastAction:word];
    } else if ([word isEqual:@"walk"] || [word isEqual:@"run"]) {
        [self setExpression:nil];
        [self setLastAction:word];
        [self setModeTo:word];
        double tx;
        if ([word isEqual:@"walk"]) {
            tx = [self pickRoamingTarget];
        } else {
            tx = (p.x < self->width * 0.5) ? [self maxX] - [self rnd:0.0 to:30.0]
                                           : [self minX] + [self rnd:0.0 to:30.0];
        }
        p.target  = tx;
        p.targetY = self->freeGround ? [self rnd:[self minY] to:self->floorY] : p.gy;
    } else {   // jump / wait
        [self setLastAction:word];
        if (![word isEqual:@"wait"]) [self doWord:word];
    }

    if ([self is:@"idle"] && self.time >= p.nextAt) {
        p.nextAt = self.time + [self rnd:2.0 to:4.0];
    }
}
#endif

/// 196 B（0x46784）。发射爱心粒子：随机 x∈[96,176]，从头顶上方升起。
#if 0  // 已被分类里的同名方法覆盖（真正生效的是 WNMotion+Input.m），改写请去那边
- (void)emitHeart {
    double   x  = [self rnd:96.0 to:176.0];
    CGPoint  pt = [self toStage:CGPointMake(x, p.low + 62.0)];
    double   vx = [self rnd:-20.0 to:20.0];
    double   vy = [self rnd:-70.0 to:-45.0];
    [self emit:@"heart" point:pt vx:vx vy:vy life:1.6];
}
#endif

/// 232 B（0x4aa58）。抓取：进 drag，记录抓点与朝向，响应式交互下再同步指针。
#if 0  // 已被分类里的同名方法覆盖（真正生效的是 WNMotion+Input.m），改写请去那边
- (void)grab {
    CGPoint g = [self toStage:CGPointMake(128.0, 36.0)];
    [self setExpression:nil];
    [self setModeTo:@"drag"];
    p.dx    = g.x;
    p.dy    = g.y;
    p.sqv   += -1.2;
    p.tiltV  = 0;

    if (self->_responsiveInteraction) {
        [self syncDragPointer];
        p.prevA  = p.dx;
        p.velX   = self->pointerVX;
        p.hasPrev = YES;                        // +0x1d0
    }

    [self sound:@"grab" kind:@"touch" arguments:@[]];
    [self event:@"touch" detail:@{ @"kind": @"grab" }];
}
#endif

/// 3100 B（0x498d4）。每帧渲染：算眨眼/挤压缩放、shake/shiver 抖动、组旋转，落 transform
/// 与 19 键 frame 字典。groupTilt 块真实签名为 double(^)(NSString*,double,double)。
#if 0  // 已被分类里的同名方法覆盖（真正生效的是 WNMotion+Render.m），改写请去那边
- (void)render {
    NSDictionary *face  = self.face ?: [self faceAt:@"neutral"];
    BOOL isDrag         = [self is:@"drag"];
    double t            = self.time;

    // 眨眼 + 挤压缩放
    double blinkArg = sin(t * ([self is:@"sleep"] ? 1.7 : 2.4));
    double sq  = p.sq;
    double st  = p.stretch;
    double vScale = (1.0 + sq * 0.7) * (1.0 - st * 0.05);   // d8
    double d9     = 1.0 - blinkArg * 0.009;
    double hScale = (1.0 - sq) * (1.0 + st * 0.09);          // d12
    double d13    = 1.0 + blinkArg * 0.016;

    double d11 = isDrag ? p.dx : p.x;
    double d10 = isDrag ? p.dy : p.fy;
    double lean    = p.lean;
    double faceVis = p.faceVis;

    // shake / shiver
    if ([face[@"shake"] boolValue]) {
        d11 += sin(t * 60.0) * 1.4;
    } else if ([self.pulse[@"kind"] isEqual:@"shiver"]) {
        double amp      = sin(t * 75.0) * 1.1;
        double progress = (t - [self.pulse[@"t0"] doubleValue]) / [self.pulse[@"dur"] doubleValue];
        // smoothstep 双段（0.08 / 0.15 两档），公式 s(x)=x²(3-2x)
        double a = fmax(fmin(progress / 0.08, 1.0), 0.0);
        double b = fmax(fmin((progress - 0.85) / 0.15, 1.0), 0.0);
        double sa = a * a * (3.0 - 2.0 * a);
        double sb = b * b * (3.0 - 2.0 * b);
        d11 += amp * (1.0 - sb) * sa;
    }

    vScale *= d9;
    hScale *= d13;
    d13     = lean * faceVis;

    double rot;
    if (self.groupTilt) {
        // 注：头文件声明 void(^)(void)，二进制实为 double(^)(NSString*,double,double)
        rot = self.groupTilt(self.mode, p.tilt, d13);
    } else {
        rot = d13 + p.tilt;
    }

    NSDictionary *xf = @{
        @"AX":  @(d11),
        @"AY":  @(d10),
        @"ax":  @128.0,                      // 常量 NSConstantIntegerNumber @0x110960
        @"ay":  @(isDrag ? 36.0 : 256.0),
        @"kx":  @(self->scale * faceVis * vScale),
        @"ky":  @(hScale * self->scale),
        @"rot": @(rot),
    };
    [self setTransform:xf];

    // faceConfig = face 的可变副本 + eyes/gap/blush
    double blink;
    double blinkAge = p.blinkAge;
    double thresh   = p.drowse * 0.3 + 0.16;
    if (blinkAge < thresh) {
        blink = sin(blinkAge * M_PI / thresh);
    } else {
        blink = 0;
    }

    NSArray *eyes = self.eyeCur;
    if (!eyes) eyes = face[@"eyes"];
    double eyeClose = 0.0;
    double g = p.swapAge;
    if (g < 0.07 && self.eyePrev) {
        eyes = self.eyePrev;
        eyeClose = g / 0.07;
    } else if (g < 0.16) {
        eyeClose = 1.0 - (g - 0.07) / 0.09;
    }

    NSMutableDictionary *faceConfig = [face mutableCopy];
    faceConfig[@"eyes"] = eyes;
    faceConfig[@"gap"]  = @[ @(fmin(p.gap[0] + p.talkK * 12.0, 64.0)),
                             @(fmin(p.gap[1] + p.talkK * 12.0, 64.0)) ];
    faceConfig[@"blush"] = @(p.blushK);

    id gesture = [NSNull null];
    if (self.pulse) {
        double k = fmax(fmin((t - [self.pulse[@"t0"] doubleValue]) / [self.pulse[@"dur"] doubleValue], 1.0), 0.0);
        gesture = @{ @"kind": self.pulse[@"kind"], @"k": @(k) };
    }

    NSArray *leg0 = @[ @104.0, @(p.low + 212.0), @(p.feet[0][0]), @(p.feet[0][1]) ];
    NSArray *leg1 = @[ @150.0, @(p.low + 212.0), @(p.feet[1][0]), @(p.feet[1][1]) ];

    NSDictionary *frame = @{
        @"faceConfig": faceConfig,
        @"look":       @[ @(p.look[0]), @(p.look[1]) ],
        @"legs":       @[ leg0, leg1 ],
        @"low":        @(p.low),
        @"t":          @(t),
        @"blink":      @(blink),
        @"eyeClose":   @(eyeClose),
        @"swing":      @(p.swing),
        @"face":       self.faceName,
        @"mode":       self.mode,
        @"modeT":      @(p.modeT),
        @"talk":       @(p.talkK),
        @"drowse":     @(p.drowse),
        @"sit":        @(p.sitK),
        @"facing":     @(faceVis),
        @"tilt":       @(p.tilt),
        @"lean":       @(d13),
        @"groupRot":   @(rot),
        @"gesture":    gesture,
    };
    [self setFrame:frame];
}
#endif

/// ⚠️ 11388 B（0x46bcc..0x49848）。主帧循环：roam 决策 → 走路物理 → 脉冲/表情/思考 →
/// 眼睛弹簧 → 粒子 → 模式迁移。相位 A（0x46bcc–0x4731c）已解出框架，内层物理与相位 B–F 待逐段深挖。
#if 0  // 已被分类里的同名方法覆盖（真正生效的是 WNMotion+Step.m），改写请去那边
- (void)step:(double)dt {
    // —— 相位 A（0x46bcc–0x4731c）：roam 决策 + 眨眼 + 看向指针 + 走路 ——
    if (!isfinite(dt)) return;                  // 0x46c00–0x46c68 NaN/Inf 守卫，跳 0x486d8

    self.time += dt;                            // 0x46c70 +0x1d8
    p.modeT  += dt;                             // 0x46c7c +0x48

    NSString *mode = self.mode;                 // 0x46c88
    double modeT = p.modeT;                     // 0x46c94

    // roam 是否到期
    BOOL roamOn = NO;                           // 0x46c98–0x46cd4
    if (![self.roamMode isEqual:@"off"]) {
        roamOn = self.time > self.roamHoldUntil;
    }

    // 眨眼计时：blinkT 倒计时，blinkAge 累加；到期重置并随机下次间隔
    p.blinkT  -= dt;                            // 0x46cd8 +0x118
    p.blinkAge += dt;                           // 0x46ce0 +0x120
    if (p.blinkT <= 0) {                        // 0x46ce8 b.hi
        p.blinkAge = 0;                         // 0x46cf4 +0x120
        p.blinkT = ([self random] < 0.2) ? 0.28 : [self rnd:2.2 to:5.2];  // 0x46cfc–0x46d30
    }

    // 指针 → 舞台锚点 (146.05, 128.13) 的距离（0x46d34–0x46d70）
    CGPoint anchor = [self toStage:CGPointMake(146.05, 128.13)];
    double px = self->pointerX - anchor.x;      // d10
    double py = self->pointerY - anchor.y;      // d11
    double dist = hypot(px, py);                // d12，0 时取 1.0

    // 看向指针（仅 idle/sit 模式，0x10f620；0x46d74–0x46e84）
    double lookX = 0, lookY = 0;                // d14/d15
    if ([@[ @"idle", @"sit" ] containsObject:mode]) {
        if (!([mode isEqual:@"wake"] && p.modeT <= 1.2)) {   // 0x46d8c–0x46db4
            if (self->pointerInside) {          // +0x241
                double k = fmin(dist / 120.0, 1.0);          // 0x405e=120
                lookX = (px * p.facing / dist) * 5.0 * k;    // 0x46dc0–0x46de8
                lookY = (py / dist) * 4.0 * k;               // 0x46dec–0x46df8
            } else if (self.time > p.glanceAt) {             // 0x46e00–0x46e0c
                if ([self random] < 0.45) {                  // 0x46e10–0x46e20
                    p.glance[0] = 0;
                } else {
                    p.glance[0] = [self rnd:-3.0 to:5.0];    // 0x46e38–0x46e48
                }
                p.glance[1] = [self rnd:-3.0 to:3.0];        // 0x46e4c–0x46e5c
                p.glanceAt = self.time + [self rnd:1.2 to:3.0];  // 0x46e60–0x46e7c
            }
        }
        lookX = p.glance[0]; lookY = p.glance[1];            // 0x46e80 ldp [0x178]
    }

    // idle：roam 到期 → decideAutonomousAction（0x46e84–0x46f40）
    if ([mode isEqual:@"idle"]) {
        // 0x46ea8–0x46ed8：pointerInside && !pressing && facing 朝反且 dist<600 → 转身（跳 0x48944）
        p.turnAcc = 0;                          // 0x46edc +0x140
        // [待补 0x46ee4–0x46f40] walk 目标初始化 + decideAutonomousAction
    }
    else if ([mode isEqual:@"walk"] || [mode isEqual:@"run"]) {
        // —— 走路物理（0x46f44–0x4731c，逐值还原）——
        BOOL isRun = [mode isEqual:@"run"];

        double cx = p.x;                        // 0x8
        double tx = p.target, ty = p.targetY;   // 0x58
        double cy = p.gy;                       // 0x18
        double dx = tx - cx;                    // d12
        double dy = ty - cy;                    // d11
        double dist = hypot(dx, dy);            // d10

        // 朝向：横向距离为 0 时沿用旧 facing，否则取 ±1
        double facing = (dx == 0) ? p.facing : (dx > 0 ? 1.0 : -1.0);  // 0x46fac–0x46fe4
        if (fabs(dx) <= 2.0 && !self->freeGround) p.facing = facing;   // 0x46fec–0x47004

        double speed = isRun ? 250.0 : 78.0;    // d13, 0xc6210/0xc5d10

        // 目标速度随距离衰减（越近越慢）
        double targetSpeed = fmin(speed, (isRun ? 20.0 : 14.0) + dist * (isRun ? 4.0 : 3.0));  // 0x47020–0x4703c

        double strideAmp = isRun ? 15.0 : 8.0;  // 0x4704c–0x47058
        double bobAmp    = isRun ? 17.0 : 10.0;
        double easeDiv, easeRate;
        int    walkK;                           // 相位 B 消费的参数（scvtf 存入栈）
        if (isRun) {
            easeDiv = 0.35; easeRate = 6.0; walkK = 11;
            if (dist < 50.0 && p.speed > 120.0) walkK = -6;   // 0x47084–0x470a0
        } else {
            easeDiv = 0.25; easeRate = 9.0; walkK = 4;
        }

        // 缓动 smoothstep(modeT/easeDiv) → 目标速度，再指数平滑逼近 p.speed
        double e = fmin(p.modeT / easeDiv, 1.0);            // 0x470b4–0x470bc
        double smooth = e * e * (3.0 - 2.0 * e);            // 0x470c4–0x470d0
        double target = targetSpeed * smooth;               // d9
        p.speed += (target - p.speed) * (1.0 - exp(-easeRate * dt));  // 0x470d8–0x470ec

        if (dist > 0) {                                     // 0x470f0
            double step = fmin(dist, p.speed * dt);         // 0x470f8–0x470fc
            p.fy = p.gy = cy + (dy / dist) * step;          // 0x47100–0x47110
            p.x = cx + (dx / dist) * step;                  // 0x47114–0x4711c
        }

        // 步频/相位：步进音效在 floor(phase/π) 变化时触发
        double speedRatio = fmax(fmin(p.speed / speed, 1.0), 0.0);  // 0x47120–0x4712c
        double bobK = 0.4 + speedRatio * 0.6;               // d9, 0xc5f08/0xc60d0
        double oldStep = floor(p.phase / M_PI);             // 0x47144–0x47150
        double stride = (isRun ? 27.646 : 13.1947) * dt;    // 0xc6220/0xc6218
        p.phase += stride * fmax(speedRatio, 0.35);         // 0x47170–0x47180

        if (floor(p.phase / M_PI) != oldStep) {             // 0x47184–0x4719c
            int parity = ((int)floor(p.phase / M_PI)) & 1;  // 0x471c4–0x471c8
            [self sound:@"step" kind:@"move" arguments:@[ @(isRun), @(parity) ]];  // 0x471fc
        }

        // run 高速扬尘（speed>120）
        if (isRun && p.speed > 120.0) {                     // 0x47220–0x47248
            [self dust:(dist < 50.0 ? 4 : 3) spread:20.0];
        }
        // run 高速急刹 skid（dist<50 && speed>120 && !skidded）
        if (isRun && dist < 50.0 && p.speed > 120.0 && !p.skidded) {  // 0x47258–0x47288
            [self sound:@"skid" kind:@"move" arguments:@[]];
            p.skidded = YES;                                // 0x472b0 +0x1d4
        }

        // bob/lean 振幅（存入栈，相位 B 弹簧系统消费）
        (void)bobAmp; (void)strideAmp; (void)walkK;         // 值已上算，消费点见相位 B

        // 到达判定
        if (dist < 1.5) {                                   // 0x472e0
            p.speed = 0;                                    // 0x472ec
            if (self.walkIdentifier) {
                [self event:@"arrived"
                     detail:@{ @"walkId": self.walkIdentifier, @"x": @(p.x) }];  // 0x472f4–0x47378
                [self setWalkIdentifier:nil];
            }
            [self setModeTo:@"idle"];                       // 0x473a0
            p.nextAt = self.time + [self rnd:1.2 to:3.2];   // 0x473bc
        }
    }
    // —— 相位 B（0x473dc–0x47510）：pulse 解析（flap/shiver/spin）——
    double lookAdj  = 0;                          // d11 累积 flap 看向偏移，相位 D 消费
    double flapTilt = 0;                          // d13 累积 flap 倾斜，相位 D 消费

    NSDictionary *pulse = self.pulse;
    if (pulse) {
        double u = (self.time - [pulse[@"t0"] doubleValue]) / [pulse[@"dur"] doubleValue];  // 0x473f8–0x4750
        NSString *kind = pulse[@"kind"];          // 0x4764
        if (u < 1.0) {                            // 0x748c–0x7494
            if ([kind isEqual:@"shiver"]) {
                // shiver 已在 render 处理，此处跳过
            } else if ([kind isEqual:@"flap"]) {
                double s = sin(u * M_PI * 8.0);   // 0x74c0–0x74d0
                lookAdj  += s * 7.0 * (1.0 - u);          // 0x74d4–0x74e4
                flapTilt += fabs(s) * -0.06 * (1.0 - u);  // 0x74e8–0x74f8, 0xc6228=-0.06
            } else {
                // spin 等其它 pulse → 0x48818（flipped/first，见相位 E/F 区域）
            }
        } else {
            [self setPulse:nil];                  // 0x47500 pulse 到期
        }
    }

    // —— 相位 C（0x47510–0x47598）：face + 思考气泡 ——
    NSString *faceName = [self currentFaceName];      // 0x47514
    NSDictionary *faceCfg = [self faceAt:faceName];   // 0x47528
    if (self.thinking && self.thoughtShown && [faceName isEqual:@"thinking"]) {  // 0x47538–0x4755c
        NSMutableDictionary *fc = [faceCfg mutableCopy];
        fc[@"think"] = @NO;                            // 0xf8b88 = ___kCFBooleanFalse, key 0x4757c "think"
        faceCfg = fc;
    }
    // —— 相位 D（0x47598–0x477f4）：eyeSig 拼接 + 眼睛弹簧 ——
    BOOL lookLock = [faceCfg[@"lookLock"] boolValue];        // 0x475a4
    if (lookLock || [self is:@"sleep"]) {                    // 0x475b8 tbnz lookLock；0x475cc tbz sleep→0x48720
        NSArray *eyes = faceCfg[@"eyes"];                    // 0x475e8
        NSString *sig = [NSString stringWithFormat:@"%@,%@",
                         eyes[0][@"shape"], eyes[1][@"shape"]];   // 0x47600–0x47658
        if (![sig isEqual:self.eyeSig]) {                    // 0x47678–0x476a4
            if (self.eyeCur) [self setEyePrev:self.eyeCur];  // 0x476a8–0x476d8
            p.swapAge = 0;                                   // 0x476e0 +0x170
            [self setEyeSig:sig];                            // 0x476ec
        }
        // 眼睛弹簧：把每个眼睛的 rx/ry/dx/dy 打包进 eyeDims[i]（fcn 0x49848）
        for (int i = 0; i < 2; i++) {                        // 0x476f0–0x47824（w8 控制的 2 趟循环）
            NSDictionary *eye = eyes[i];
            double rx = WNReadNum(eye, @"rx", 16.0);         // 0x47714–0x47720
            double ry = WNReadNum(eye, @"ry", 16.0);         // 0x4773c–0x4774c
            double dx = WNReadNum(eye, @"dx", 0.0);          // 0x47768–0x47778
            double dy = WNReadNum(eye, @"dy", 0.0);          // 0x47798–0x477a8
            [self.eyeDims setObject:@[ @(rx), @(ry), @(dx), @(dy) ] atIndexedSubscript:i];  // 0x477f4
        }

        // 连续眼睛弹簧（0x47828–0x47a40，每帧）：ring/lid 形状按指数平滑插值 dims
        p.swapAge += dt;                                     // 0x47834 +0x170
        double spring = 1.0 - exp(-16.0 * dt);               // 0x47850–0x47864
        NSMutableArray *newEyes = [NSMutableArray new];      // 0x47844–0x4784c
        for (int i = 0; i < 2; i++) {                        // 0x47890–0x47a30（w28 控制的 2 趟循环）
            NSMutableDictionary *eye = [eyes[i] mutableCopy];
            if ([@[ @"ring", @"lid" ] containsObject:eye[@"shape"]]) {  // 0x10f638
                NSMutableArray *dims = [self.eyeDims[i] mutableCopy];
                for (int k = 0; k < 4; k++) {                // 0x4791c–0x479e0
                    double cur    = [dims[k] doubleValue];
                    double target = WNReadNum(eye, kEyeKeys[k], (k < 2 ? 16.0 : 0.0));
                    double val    = cur + (target - cur) * spring;
                    dims[k]            = @(val);
                    eye[kEyeKeys[k]]   = @(val);
                }
                [self.eyeDims setObject:dims atIndexedSubscript:i];
            }
            [newEyes addObject:eye];
        }
        [self setEyeCur:newEyes];                            // 0x47a40
    }
    // —— 相位 E（0x482b4–0x48690）：抚摸冷却衰减 + 粒子更新 + 落地/寿命剔除 ——
    p.strokeAcc *= exp(-1.5 * dt);                       // 0x482b4–0x482c8 +0x200
    p.petCool   -= dt;                                   // 0x482cc–0x482d4 +0x208

    NSArray *pcopy = [self.particles copy];              // 0x482e8–0x482f8
    double dustDamp = exp(-4.0 * dt);                    // 0x4832c–0x48338
    for (NSMutableDictionary *pt in pcopy) {             // 0x48314 枚举
        double age = [pt[@"age"] doubleValue] + dt;      // 0x4839c–0x483ac
        double x   = [pt[@"x"] doubleValue] + [pt[@"vx"] doubleValue] * dt;   // 0x483bc–0x483ec
        double y   = [pt[@"y"] doubleValue] + [pt[@"vy"] doubleValue] * dt;   // 0x48400–0x4842c
        pt[@"age"] = @(age);
        pt[@"x"]   = @(x);
        pt[@"y"]   = @(y);

        if ([pt[@"type"] isEqual:@"drop"]) {             // 0x484b4–0x484dc
            double vy = [pt[@"vy"] doubleValue] + 900.0 * dt;   // 0x484ec–0x484fc
            pt[@"vy"] = @(vy);
            double floor = self->freeGround ? p.gy : self->floorY;  // 0x48528–0x48540
            if (y > floor) age = [pt[@"life"] doubleValue];        // 落地 → 立刻过期
        }
        if ([pt[@"type"] isEqual:@"dust"]) {             // 0x48570–0x48598
            pt[@"vx"] = @([pt[@"vx"] doubleValue] * dustDamp);    // vx 阻尼
        }
        double life = [pt[@"life"] doubleValue];         // 0x485f0–0x48610
        if (age >= life) {                               // 0x48614
            [self.particles removeObject:pt];            // 0x48630
        }
    }

    p.talkK *= exp(-12.0 * dt);                          // 0x4866c–0x48684 +0x1b8
    [self setFace:faceCfg];                              // 0x48690

    // —— 相位 F（0x48c20–0x49848）：模式迁移 / 落地 / 戳 / 音效 ——
    // 注：此段为逐模式分派的物理/音效状态机，锚点齐全；dense 浮点（空中弹跳/晕眩 spin/play_ball 弹性）按段标注。
    if ([mode isEqual:@"crouch"]) {                          // 0x48c94
        // 下蹲蓄力：modeT>0.16 时起跳
        if (p.modeT > 0.16) {                                // 0x48cd0
            p.vx = p.jumpVx;  p.vy = -p.jumpV;               // 0x48cd8–0x48ce0
            [self setAirKind:@"jump"];                       // 0x48cf4
            p.sqv += -2.6;                                   // 0x48cf8–0x48d08, 0xc61f0=-2.6
            [self sound:@"jump" kind:@"move" arguments:@[]]; // 0x48d24
            [self setModeTo:@"air"];                         // 0x48d34
        }
    }
    else if ([mode isEqual:@"air"]) {                        // 0x48d50
        // —— 空中物理（0x48d64–0x494e4）——
        //   vy += (2300 或 jump 分支 0x40a9)·dt（重力/推力）→ 水平阻尼 exp(-0.4dt)
        //   freeGround 时 gvy 衰减 exp(-1.2dt)，gy/fy 随动
        //   地板（minY）反弹 vy=|vy|·0.55、sqv+=0.6；天花板（floorY）反弹 vy=-|vy|·0.55
        //   左右墙（minX/maxX）反弹 vx=±|vx|·0.55、sqv+=0.6
        //   落地判定：fy 穿过 scale·(-250) 且 vy<0 → land（0x494d4）
        //   [待补 0x48d64–0x494e4] 逐值还原重力/反弹常量
    }
    else if ([mode isEqual:@"land"]) {                       // 0x48fe4
        // 落地挤压：u=clamp(modeT/0.35,0,1)，挤压 = (1-smoothstep(u))·0.35
        // modeT>0.4 → setModeTo:idle（0x49064）
        // [待补 0x48fe4–0x49068] 挤压值入栈消费点
    }
    else if ([mode isEqual:@"dizzy"]) {                      // 0x49080
        // 晕眩：modeT<2.4 且 time>noteAt(0x1c0) → 播 chirps，noteAt=time+0.9
        //       modeT>=2.4 且 noteAt==0 → 播 shake，noteAt=MAX
        //       modeT<2.4 → d11 = min(2·modeT,1)·sin(time·4.5)·8（旋转摇摆）
        // [待补 0x49080–0x4917c]
    }
    else if ([mode isEqual:@"dance"]) {                      // 0x49180
        // 舞蹈：phase += 6.9115·dt；floor(phase/π) 变化 → 播 step 音（@[NO, parity]）
        //       time>noteAt(0x1c8) → emit:@"note" 于 toStage(low+40, 196) 上方
        //       modeT>dur(0x50) → setModeTo:idle
        // [待补 0x49180–0x49540]
    }
    else if ([mode isEqual:@"play_ball"]) {                  // 0x49554
        // 拍球：两段 smoothstep 弹跳（d0/d1 归一化进度 × 权重），落地反转
        // [待补 0x49554–0x496d4]
    }
    else if ([mode isEqual:@"drag"]) {                       // 0x496d4
        // 拖拽：responsiveInteraction → syncDragPointer（0x49700）
        //       squeak 音（0x497fc，随机间隔）
        // [待补 0x496d4–0x49848]
    }
    // [待补 0x48720] 非 lookLock/sleep 眼睛路径；[待补 0x48818] spin pulse flipped/first
}
#endif
@end
