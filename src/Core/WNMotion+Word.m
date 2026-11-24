//
//  WNMotion+Word.m — 逆向还原：指令词入口
//
//  还原依据：PetDFY.dylib arm64e，-[WNMotion doWord:] @0x44efc
//  真实边界 0x44efc–0x4556c（412 条指令）；r2 的 1648 条为函数边界误并。
//
//  语义：把一句自然语言指令词映射成模式切换 / 表情 / 音效 / 一次脉冲。
//        返回 YES 表示词被消费，NO 表示未识别或当前忙。

#import "WNMotion.h"

// 模式时长与下一拍间隔
static const double kPlayBallDur   = 6.5;    // 0x401a000000000000
static const double kNextPad       = 2.0;    // 0x4000000000000000
static const double kStandPad      = 3.0;    // 0x4008000000000000
static const double kDanceDur      = 3.2;    // 0x400999999999999a
static const double kDurForever    = 1e9;    // 0x41cdcd6500000000

// 脉冲时长
static const double kPulseFlap   = 1.4;
static const double kPulseDance  = 3.4;
static const double kPulseSet    = 0.7;
static const double kPulseSpin   = 0.6;
static const double kPulseShiver = 0.7;
static const double kPulseOther  = 1.8;

// 起跳初速（+Y，单位 pt/s）
static const double kJumpV  = 720.0;   // 0xc40... 
static const double kHopV   = 540.0;
static const double kFlapV  = 480.0;
// 起跳水平初速 = kJumpVx * facing
static const double kJumpVx = 40.0;    // 0x4044000000000000

// ── 字面量集合（Assumed）────────────────────────────────────────────
// 0x10f5c0 / 0x10f5d8 / 0x10f5f0 是三个 __objc_* 容器字面量；其元素未能从
// 链式修复表解出（元素槽落在 __objc_const 的指针岛上，非独立 arrayobj）。
// 成员按「可达性反推」确定：命中 containsObject: 之后代码立即比对的词必然是
// 成员，否则那些分支不可达。
//   验证动作：lldb 在 0x45150 / 0x45394 / 0x45464 下断，打印 x0 的
//   -[NSArray count] 与 description，或对 0x10f5c0 做 dyld chained-fixup 全解码。
static NSSet *WNWordGestures(void) {          // @0x10f5c0
    static NSSet *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithObjects:@"stand", @"turn", @"jump", @"hop",
                                   @"flap", @"dance", @"spin", @"bow", nil];
    });
    return s;
}

static NSSet *WNWordModes(void) {             // @0x10f5d8
    static NSSet *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithObjects:@"dance", @"sit", @"sleep", @"crouch",
                                   @"drag", @"flap", nil];
    });
    return s;
}

static NSSet *WNWordShortPulse(void) {        // @0x10f5f0
    static NSSet *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithObjects:@"nod", @"shake", @"look", @"bounce", nil];
    });
    return s;
}


// [0x1104b0] 词 → 音效名映射字典。
// NOT RUN：该 __objc_dict 的键值未能从链式修复表解出（见 HANDOFF 第六轮）。
// 兜底为空表：未命中的词不发声，行为安全降级，不臆造条目。
// @0x1104b0 __objc_dictobj：count=5，keys @0x10d920 / values @0x10d948
// 逐条解出：bow→tick, nod→nod, shake→shake, shiver→shiver, spin→spin
static NSDictionary *WNWordSoundMap(void) {
    static NSDictionary *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        m = @{ @"bow":    @"tick",
               @"nod":    @"nod",
               @"shake":  @"shake",
               @"shiver": @"shiver",
               @"spin":   @"spin" };
    });
    return m;
}

@implementation WNMotion (Word)

- (BOOL)doWord:(NSString *)word {
    if ([word isEqual:@"neutral"]) {
        if ([self is:@"play_ball"]) [self setModeTo:@"idle"];
        [self setExpr:word seconds:0.1];
        return YES;
    }
    if ([self busy]) return NO;

    if ([word isEqual:@"play_ball"]) {                 // [0x44f84]
        [self setPulse:nil];
        [self setExpression:nil];
        [self setModeTo:@"play_ball"];
        p.dur    = kPlayBallDur;
        p.nextAt = self.time + kPlayBallDur + kNextPad;
        return YES;
    }

    BOOL sitting = ([self is:@"sit"] || [self is:@"sleep"]);   // w21

    if ([word isEqual:@"walk"] || [word isEqual:@"run"]) {     // [0x45098]
        double halfW = self->width * 0.5;              // 0x1f0
        double r     = [self random];
        // 靠左半区选 0.55~0.90，右半区选 0.10~0.45
        double k     = (p.x < halfW) ? (0.55 + r * 0.35) : (0.10 + r * 0.35);

        double gy = self->freeGround ? [self rnd:[self minY] to:self->floorY] : p.gy;

        if (sitting) {                                 // 睡着被叫去走 → 先惊醒
            [self setModeTo:@"wake"];
            p.startle = YES;
        }
        [self setExpression:nil];

        p.target  = fmax(fmin([self maxX], halfW * k), [self minX]);
        p.targetY = gy;
        return YES;
    }

    // ── 表情名直通：faces 字典里有这个键就当表情处理 ──────────────
    if (![WNWordGestures() containsObject:word]) {      // [0x45150]
        if ([self faces][word] == nil) return NO;       // 未识别的词
        if ([self is:@"play_ball"]) [self setModeTo:@"idle"];
        [self setExpression:nil];
        [self setExpr:word seconds:0.0];
        return YES;
    }

    if ([self is:@"play_ball"]) [self setModeTo:@"idle"];
    [self setExpression:nil];

    if ([word isEqual:@"stand"]) {                      // [0x45188]
        [self setModeTo:(sitting ? @"wake" : @"idle")];
        p.nextAt = self.time + kStandPad + kNextPad;
        return YES;
    }

    if ([word isEqual:@"turn"]) {                       // [0x4522c]
        if (!sitting) [self setModeTo:@"idle"];
        p.facing = -p.facing;
        [self sound:@"tick" kind:@"move" arguments:nil];
        return YES;
    }

    // ── 起跳族 ───────────────────────────────────────────────────
    if ([word isEqual:@"jump"]) {
        p.jumpV = kJumpV;
    } else if ([word isEqual:@"hop"]) {
        p.jumpV = kHopV;
    } else if ([word isEqual:@"flap"]) {
        p.jumpV = kFlapV;
    }
    if ([word isEqual:@"jump"] || [word isEqual:@"hop"] || [word isEqual:@"flap"]) {
        p.jumpVx = [word isEqual:@"jump"] ? (p.facing * kJumpVx) : 0.0;   // [0x45304]
    }

    if ([word isEqual:@"flap"]) {                       // [0x45330]
        [self pulse:word duration:kPulseFlap];
        [self holdFace:@"happy" seconds:kPulseSet];
        [self sound:@"chirps" kind:@"move" arguments:nil];
    }

    // ── 模式词：直接切模式并定长驻留 ─────────────────────────────
    if ([WNWordModes() containsObject:word]) {          // [0x45394]
        [self setModeTo:word];
        p.dur       = [word isEqual:@"dance"] ? kDanceDur : kDurForever;
        p.willSleep = NO;
        if ([word isEqual:@"dance"]) {
            [self holdFace:@"happy" seconds:kPulseDance];
            [self sound:@"dance" kind:@"move" arguments:nil];
        }
    }

    // ── spin / bow 需要坐姿，没坐就先回 idle ─────────────────────
    if (([word isEqual:@"spin"] || [word isEqual:@"bow"]) && !sitting) {   // [0x4541c]
        [self setModeTo:@"idle"];
    }

    double dur;
    if ([WNWordShortPulse() containsObject:word]) {     // [0x45464]
        dur = kPulseSet;
    } else if ([word isEqual:@"spin"]) {
        dur = kPulseSpin;
    } else if ([word isEqual:@"shiver"]) {
        dur = kPulseShiver;
    } else {
        dur = kPulseOther;
    }
    [self pulse:word duration:dur];

    NSString *sfx = WNWordSoundMap()[word];            // @0x1104b0
    if (sfx) [self sound:sfx kind:@"move" arguments:@[]];   // [0x45500] x4 = __NSArray0__struct

    if ([word isEqual:@"wave"]) [self holdFace:@"happy"  seconds:1.8];   // [0x45510]
    if ([word isEqual:@"bow"])  [self holdFace:@"bowing" seconds:1.5];   // [0x4553c]

    return YES;

    [self setWalkWord:word];
}


@end
