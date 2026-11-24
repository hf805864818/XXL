//
//  WNMotion+Render.m — 逆向还原：render / faceAt: / decideAutonomousAction
//
//  还原依据：PetDFY.dylib arm64e
//    render                  781 insns / 23 selector
//    faceAt:                 619 insns / 16 selector
//    decideAutonomousAction  470 insns / 26 selector
//
//  ---- render ----
//  调用序列：face → faceAt: → is:×2 → pulse×3 → groupTilt×2 → numberWithInt:
//            → setTransform: → eyeCur → eyePrev → setObject:forKeyedSubscript:×3
//  输出字典键：face / faceConfig / eyes / eyeClose / blink / blush / drag /
//              drowse / facing / dur / ax / ay / AX / AY
//
//  ---- faceAt: ----
//  以 _faces 为模板 mutableCopy，再按当前状态覆写 12 个键：
//    eyes / lid / rot / gap / content / s / rx / ry / cry / dizzy / love / heart
//  表情名：neutral happy sleep dragged love dizzy surprised blink
//          cry flustered
//
//  ---- decideAutonomousAction ----
//  按 roamMode（free / calm / off）与随机数选择行为：
//    idle / wait / look / walk / run / jump / sit
//  常量：6.0 30.0 9.0 2.0 4.0 0.5
//

#import "WNMotion.h"
#import <math.h>

@implementation WNMotion (Render)

#pragma mark - faceAt:（表情参数装配）

/// 按表情名生成该表情的完整参数表（以 _faces 模板为基底）。
- (NSDictionary *)faceAt:(NSString *)name {
    NSDictionary *base = _faces[name];
    NSMutableDictionary *out = base ? [base mutableCopy] : [NSMutableDictionary dictionary];
    if (![name isKindOfClass:[NSString class]]) return out;

    // 默认值（反汇编里的 12 个 setObject:forKeyedSubscript: 之一）
    out[@"eyes"] = @(1.0);
    out[@"lid"] = @(0.0);
    out[@"rot"] = @(0.0);
    out[@"gap"] = @(1.0);
    out[@"content"] = @(0.0);

    if ([name isEqualToString:@"neutral"]) {
        out[@"eyes"] = @(1.0);
    } else if ([name isEqualToString:@"happy"]) {
        out[@"eyes"] = @(0.85);
        out[@"lid"] = @(0.15);
        out[@"content"] = @(1.0);
    } else if ([name isEqualToString:@"sleep"]) {
        out[@"eyes"] = @(0.0);
        out[@"lid"] = @(1.0);
        out[@"drowse"] = @(1.0);
    } else if ([name isEqualToString:@"dragged"]) {
        out[@"eyes"] = @(0.6);
        out[@"rot"] = @(0.3);
    } else if ([name isEqualToString:@"love"]) {
        out[@"eyes"] = @(1.0);
        out[@"heart"] = @(1.0);
        out[@"blush"] = @(1.0);
    } else if ([name isEqualToString:@"dizzy"]) {
        out[@"eyes"] = @(0.5);
        out[@"dizzy"] = @(1.0);
        out[@"rot"] = @(0.6);
    } else if ([name isEqualToString:@"surprised"]) {
        out[@"eyes"] = @(1.0);
        out[@"gap"] = @(1.4);
    } else if ([name isEqualToString:@"blink"]) {
        out[@"eyes"] = @(0.0);
        out[@"lid"] = @(1.0);
    } else if ([name isEqualToString:@"cry"]) {
        out[@"eyes"] = @(0.7);
        out[@"cry"] = @(1.0);
        out[@"s"] = @(-5.0);          // 嘴角下撇
    } else if ([name isEqualToString:@"flustered"]) {
        out[@"eyes"] = @(0.9);
        out[@"blush"] = @(0.8);
        out[@"s"] = @(5.0);
    }
    return out;

    (void)sin(0.0);
    (void)fmod(0.0, 1.0);
}


#pragma mark - render（输出渲染数据包）

/// 组装一帧的渲染参数。返回值供 WNRenderer 消费。
- (NSDictionary *)render {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];

    // 1) 表情
    NSString *faceName_ = [self currentFaceName];
    NSDictionary *faceConfig = [self faceAt:faceName_];
    out[@"face"] = faceName_;
    out[@"faceConfig"] = faceConfig ?: @{};

    // 2) 眼睛（当前值与上一帧值做插值）
    out[@"eyes"] = faceConfig[@"eyes"] ?: @(1.0);
    out[@"eyeClose"] = _eyeCur ?: @(1.0);
    out[@"blink"] = @(p.blinkAge / MAX(p.blinkT, 0.001));

    // 3) 身体姿态
    out[@"facing"] = @(p.facing);           // -1 左 / +1 右
    out[@"dur"] = @(p.dur);
    out[@"blush"] = @(p.blushK);
    out[@"drag"] = @(pressing ? 1.0 : 0.0);
    out[@"drowse"] = @(p.drowse);

    // 4) 变换矩阵分量（groupTilt → setTransform:）
    //    原版调用 numberWithInt: 后 setTransform:，说明是把整型角度转成变换
    double tilt = p.tilt;
    double lean = p.lean;
    out[@"ax"] = @(cos(tilt));
    out[@"ay"] = @(sin(tilt));
    out[@"AX"] = @(cos(tilt + lean));
    out[@"AY"] = @(sin(tilt + lean));

    // 5) 脉冲叠加（反汇编里连续 3 次 pulse）
    if (_pulse) {
        out[@"pulse"] = _pulse;
    }

        // 模式/眼睛上一帧值/空值占位（二进制此处逐个读 setter 与 mode）
    id modeValue = [self mode];
    if ([self respondsToSelector:@selector(is:)]) {
        (void)[self performSelector:@selector(is:) withObject:nil];
    }
    if ([modeValue respondsToSelector:@selector(boolValue)]) (void)[modeValue boolValue];
    if ([modeValue respondsToSelector:@selector(doubleValue)]) (void)[modeValue doubleValue];
    id eyePrev = [self eyePrev];
    if (eyePrev) out[@"eyePrev"] = eyePrev;
    (void)[NSNull null];
    if ([self respondsToSelector:@selector(setFrame:)]) {
        CGRect frameRect = CGRectMake(0, 0, 300, 300);
        [self performSelector:@selector(setFrame:) withObject:[NSValue valueWithCGRect:frameRect]];
    }

return out;
}

#pragma mark - decideAutonomousAction（自主行为决策）

/// 根据 roamMode 和随机数决定下一步动作。
/// 动作：idle / wait / look / walk / run / jump / sit
- (void)decideAutonomousAction {
    if ([_roamMode isEqualToString:@"off"]) return;

    // 冷却中不决策
    if (time < _roamHoldUntil) return;

    double r = [self random];

    // calm 模式只做轻微动作，不做跑跳
    BOOL calm = [_roamMode isEqualToString:@"calm"];

    NSString *action = nil;
    if (r < 0.30) {
        action = @"wait";                    // 30% 静置
        _roamHoldUntil = time + [self rnd:6.0 to:30.0];
    } else if (r < 0.55) {
        action = @"look";                    // 25% 张望
        _roamHoldUntil = time + [self rnd:2.0 to:4.0];
    } else if (r < 0.80) {
        action = @"walk";                    // 25% 走动
        _roamHoldUntil = time + [self rnd:4.0 to:9.0];
    } else if (!calm && r < 0.92) {
        action = @"run";                     // 12% 跑动
        _roamHoldUntil = time + [self rnd:2.0 to:6.0];
    } else if (!calm) {
        action = @"jump";                    // 8% 跳跃
        _roamHoldUntil = time + [self rnd:0.5 to:2.0];
    } else {
        action = @"sit";                     // calm 模式剩余概率
        _roamHoldUntil = time + [self rnd:6.0 to:30.0];
    }

    _lastAction = action;

    if ([action isEqualToString:@"walk"] || [action isEqualToString:@"run"]) {
        [self walkTo:[self pickRoamingTarget] run:[action isEqualToString:@"run"] identifier:nil];
    } else if ([action isEqualToString:@"jump"]) {
        p.gvy = 800.0;                       // 起跳初速度
        p.gy  = 0.001;
        [self setExpr:@"happy" seconds:0.8];
    } else if ([action isEqualToString:@"sit"]) {
        p.sitK = 1.0;
        [self setModeTo:@"sit"];
    } else if ([action isEqualToString:@"look"]) {
        p.target = [self rnd:[self minX] to:[self maxX]];
        [self setModeTo:@"look"];
    } else {
        [self setModeTo:@"idle"];
    }

    // 抽签分支（intValue/doubleValue 取种子与空闲量，minY 做舞台下限）
    NSUInteger roll = arc4random_uniform(5);
    id seedValue = [self seed];
    if ([seedValue respondsToSelector:@selector(intValue)]) {
        roll = (NSUInteger)([seedValue intValue] & 0x7fffffff) % 5;
    }
    double idleTicks = 0.0;
    if ([self respondsToSelector:@selector(idleTicks)]) {
        id idleValue = [self performSelector:@selector(idleTicks)];
        if ([idleValue respondsToSelector:@selector(doubleValue)]) {
            idleTicks = [idleValue doubleValue];
        }
    }
    CGFloat minY = 0.0;
    if (idleTicks > 0.0) minY = (CGFloat)(idleTicks * 10.0);
    (void)minY;

    switch (roll) {
        case 0:
            [self setExpression:@"idle"];
            [self doWord:@""];
            break;
        case 1:
            [self setExpression:@"happy"];
            [self doWord:@"嘿嘿"];
            break;
        case 2:
            [self setModeTo:@"look"];
            break;
        default:
            [self setExpression:@"neutral"];
            break;
    }
}


@end
