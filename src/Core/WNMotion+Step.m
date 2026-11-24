//
//  WNMotion+Step.m
//  PetDFY
//
//  -[WNMotion step:] 逐帧推进。
//  二进制：-step:  IMP 0x46bcc，方法体 11388 字节 = 2847 条指令（末条 0x49844）。
//  下方按反汇编地址分段还原，注释中的 [0xADDR] 为对应指令地址。
//
//  已还原：0x46bcc → 0x473dc（入口守卫、时钟、眨眼、注视、idle、walk/run）
//  NOT RUN：0x473dc → 0x49844（公共姿态应用段 + sit/sleep/crouch/air/spin/land/
//           drag/flap/wake 分支），续作从 0x473dc 接。
//

#import "WNMotion.h"

static const double kPi = 3.141592653589793;      // 一次落脚（半个步态周期）

// [0x10f620] __objc_arrayobj count=2，元素为模式名，用于跳过 wake 过渡计时。
// Assumed: 元素未能从 __objc_arrayobj 的链式修复表解出（见 GAPS.md #3），
// 按语义取 sit/sleep；验证动作：对 0x10f630 起的元素槽做 chained-fixup 解码，
// 或在下断点观察 -[WNMotion step:] 首帧的 x0 实参。
static BOOL WNModeSkipsWakeClock(NSString *mode) {
    return [mode isEqual:@"sit"] || [mode isEqual:@"sleep"];
}

@implementation WNMotion (Step)

- (void)step:(double)dt {
    // [0x46bf4] 入口守卫：dt 必须为正的有限值
    if (!(dt > 0.0) || !isfinite(dt)) {
        return;
    }

    // [0x46c88] time += dt；[0x46c94] p.modeT += dt
    time += dt;
    p.modeT += dt;

    NSString *mode = _mode;
    double modeT = p.modeT;                 // [0x46c90] d13

    // [0x46c9c] 自主行动开关：roamMode == "off" 时关闭，否则由 roamHoldUntil 决定
    NSString *roam = _roamMode;
    BOOL autonomous;
    if ([roam isEqual:@"off"]) {
        autonomous = NO;
    } else {
        autonomous = (time > _roamHoldUntil);   // [0x46cc8]
    }

    // ---- 眨眼计时 [0x46cd4] ----
    // blinkT 为倒计时，blinkAge 为已持续时长
    p.blinkT -= dt;
    p.blinkAge += dt;
    if (p.blinkT <= 0.0) {                  // [0x46cec] b.hi 跳过
        p.blinkAge = 0.0;                   // [0x46cf4]
        if ([self random] < 0.2) {          // [0x46cf8]
            p.blinkT = 0.28;                // 20% 概率连眨
        } else {
            p.blinkT = [self rnd:2.2 to:5.2];   // [0x46d1c]
        }
    }

    // ---- 指针相对锚点的偏移 [0x46d40] ----
    CGPoint anchor = [self toStage:CGPointMake(146.05, 128.13)];
    double px = pointerX - anchor.x;        // [0x46d60] d10
    double py = pointerY - anchor.y;        // [0x46d64] d11
    double dist = hypot(px, py);            // [0x46d68] d12
    if (dist == 0.0) {                      // [0x46d70]
        dist = 1.0;
    }

    // ---- 静止姿态集合判定 [0x46d74] ----
    // 该集合内的模式不参与 wake 过渡计时
    BOOL settled = WNModeSkipsWakeClock(mode);   // 静态集合字面量 @0x10f620
    if (!settled) {
        if ([mode isEqual:@"wake"]) {        // [0x46d88]
            if (modeT <= 1.2) {              // [0x46da4]
                goto motion_look_targets;
            }
            [self setMode:@"idle"];          // [0x46db4]
        }
    }

motion_look_targets:;
    // ---- 注视目标 lookX / lookY [0x46dbc] ----
    // 指针在身体范围内时跟随指针（受朝向与距离衰减），否则走随机瞟视
    double lookX, lookY;
    if (pointerInside) {                     // [0x241]
        double k = fmin(dist / 120.0, 1.0);  // [0x46dc8]
        lookX = k * ((px * p.facing) / dist) * 5.0;   // [0x46dd4] d14
        lookY = k * ((py / dist) * 4.0);              // [0x46df4] d15
    } else {
        if (time > p.glanceAt) {             // [0x46e04]
            if ([self random] < 0.25) {      // [0x46e18]
                p.glance[0] = 0.0;           // [0x46e24]
                p.glance[1] = 0.0;
            } else {
                p.glance[0] = [self rnd:-3.0 to:5.0];   // [0x46e34]
                p.glance[1] = [self rnd:-3.0 to:3.0];   // [0x46e50]
            }
            p.glanceAt = time + [self rnd:1.2 to:3.0];  // [0x46e6c]
        }
        lookX = p.glance[0];                 // [0x46e80] ldp
        lookY = p.glance[1];
    }

    // ---- 模式分派 ----
    // 目标姿态量，对应反汇编里 sp+0x20..0x90 的溢出槽
    double tStride = 0.0, tLift = 0.0, tBob = 0.0;
    double tLean = 0.0, tSitK = 0.0, tDrowse = 0.0, tPhase = 0.0;
    double tiltStiff = 0.0, tiltDamp = 0.0;
    double tRun = 0.0, tSoft = 0.0, tFast = 0.0;   // 公共应用段 [0x473dc] 的输入槽

    if ([mode isEqual:@"idle"]) {            // [0x46e84]
        // [0x46e88] 指针在身体外或未按下 → 走沉睡/待机维持分支
        if (pointerInside && !pressing) {          // [0x46e88 / 0x46eb0]
            BOOL behind = (dist < 600.0) && ((px * p.facing) < -50.0);  // [0x46eb8..0x46ed8]
            if (behind) {
                goto motion_behind_pointer;        // → 0x48944：转身
            }
        }
        // [0x46edc] 未转身：清转身累积，坐姿抬到 12，困倦归零
        p.turnAcc = 0.0;                           // [0x46ee0]
        tSitK   = 12.0;                            // [0x46ee4]
        tDrowse = 0.0;                             // [0x46ee8]

        // [0x46ef0] 自主行为门控：上一次自主备注未到期且表情仍在播放时抑制
        if (autonomous) {
            BOOL suppress = NO;
            if (p.noteAt > p.nextAt) {             // [0x46ef4 / 0x46efc]
                if ([self expression] == nil) {    // [0x46f08]
                    suppress = NO;
                } else if (p.noteAt < p.exprUntil) {  // [0x46f1c]
                    suppress = YES;
                }
            }
            if (!suppress) {
                [self decideAutonomousAction];     // [0x46f2c]
            }
        }
        tiltStiff = 128.0;                          // [0x46f34]
        tBob = 0.0;
    } else if ([mode isEqual:@"walk"] || [mode isEqual:@"run"]) {   // [0x46f44]
        // ---- 行走 / 奔跑：目标追踪 + 指数平滑 + 步态相位 [0x46f6c → 0x473d8] ----
        BOOL isRun = [mode isEqual:@"run"];                         // [0x46f6c] w19

        double baseX = p.x;                                         // [0x46f80]
        double baseY = p.gy;                                        // [0x46f90]
        double dx = p.target - p.x;                                 // [0x46f8c]
        double dy = p.targetY - p.gy;                               // [0x46f98]
        double wdist = hypot(dx, dy);                               // [0x46fa4]

        // 朝向：有横向位移时取符号，否则沿用当前朝向
        double dir = (dx != 0.0) ? copysign(1.0, dx) : p.facing;    // [0x46fac]
        // 自由悬浮（freeGround==0）时无条件转向；着地时要求 |dx| > 2 才转
        if (fabs(dx) > 2.0 || !freeGround) {                        // [0x46ff0]
            p.facing = dir;                                         // [0x47004]
        }

        // 目标速度：距离线性项 + 基值，封顶（跑 250 / 走 78）
        double cap  = isRun ? 250.0 : 78.0;                         // [0x47008]
        double want = isRun ? (wdist * 4.0 + 20.0)                  // [0x47014]
                           : (wdist * 3.0 + 14.0);                  // [0x47020]
        want = fmin(cap, want);                                     // [0x4703c]

        // 步态幅度基准：跑 bob 17 / lift 15，走 bob 10 / lift 8
        double gBob  = isRun ? 17.0 : 10.0;                         // [0x47040]
        double gLift = isRun ? 15.0 : 8.0;                          // [0x4704c]
        // [0x4705c] var_58 = 7（跑）/ 3（走），由公共应用段读取

        // 前倾：走 4；跑远端 11；跑近处已高速 -6（刹车后仰）
        int leanK;
        if (!isRun) {
            leanK = 4;                                              // [0x470a8]
        } else if (wdist >= 50.0) {
            leanK = 11;                                             // [0x4706c]
        } else if (p.speed > 120.0) {
            leanK = -6;                                             // [0x4709c]
        } else {
            leanK = 11;
        }

        double easeA = isRun ? 0.35 : 0.25;                         // [0x47078] / [0x470ac]
        double dampK = isRun ? 6.0  : 9.0;                          // [0x47070] / [0x470b0]

        // 模式内加速进度 + smoothstep t²(3−2t)
        double tAcc = p.modeT / easeA;                              // [0x470b4]
        tAcc = fmin(tAcc, 1.0);                                     // [0x470bc]
        double smooth = tAcc * tAcc * (3.0 - 2.0 * tAcc);           // [0x470c4..0x470d0]

        // 指数平滑逼近目标速度
        double cur  = p.speed;                                      // [0x470c0]
        double goal = want * smooth;                                // [0x470d4]
        double damp = 1.0 - exp(-dampK * dt);                       // [0x470d8..0x470e0]
        double next = cur + (goal - cur) * damp;                    // [0x470e8]
        p.speed = next;                                             // [0x470ec]

        // 沿直线推进，不越过目标
        if (wdist > 0.0) {                                          // [0x470f0]
            double move = fmin(wdist, next * dt);                   // [0x470f8]
            double ux   = dx / wdist;                               // [0x47100]
            double uy   = dy / wdist;                               // [0x47104]
            double ny   = baseY + uy * move;                        // [0x4710c]
            p.fy = ny;                                              // [0x47110] [x24+0x10]
            p.gy = ny;                                              // [0x47110] [x24+0x18]
            p.x  = baseX + ux * move;                               // [0x4711c]
        }

        // 速度比 → 步态幅度；相位每 π 一次落脚
        double ratio = fmax(fmin(next / cap, 1.0), 0.0);            // [0x47120..0x4712c]
        double gait  = 0.4 + 0.6 * ratio;                           // [0x47130..0x47140]
        double cyclePrev = floor(p.phase / kPi);                    // [0x47144..0x47150]
        double inc = (isRun ? 27.646015351590183 : 13.194689145077131) * dt;  // [0x4715c]
        p.phase += inc * fmax(ratio, 0.35);                         // [0x47174..0x47180]

        if (floor(p.phase / kPi) != cyclePrev) {                    // [0x47190..0x4719c]
            int foot = ((int)floor(p.phase / kPi)) & 1;             // [0x471c4..0x471c8]
            [self sound:@"step" kind:@"move"
            arguments:@[ @(isRun), @(foot) ]];                      // [0x471a0..0x47210]

            // 奔跑高速时扬尘：近处 3 团，远处 1 团
            if (isRun && p.speed > 120.0) {                         // [0x47220..0x47234]
                [self dust:(wdist < 50.0 ? 3 : 1) spread:20.0];     // [0x47238..0x47254]
            }
        }

        // 奔跑接近目标仍有余速 → 打滑音效，每次进入只触发一次
        if (isRun && wdist < 50.0 && p.speed > 120.0 && !p.skidded) { // [0x47258..0x47288]
            [self sound:@"skid" kind:@"move" arguments:@[]];        // [0x4728c]
            p.skidded = YES;                                        // [0x472ac]
        }

        // 姿态通道目标（公共应用段 [0x473dc] 读取）
        tBob  = gBob  * gait;                                       // [0x472b8]
        tLift = gLift * gait;                                       // [0x472c4]
        tLean = (double)leanK;                                      // [0x472b4]
        tRun  = isRun ? 1.0 : 0.0;                                  // [0x472d0]
        tSoft = 12.0;                                               // [0x472d4]
        tFast = 0.0;                                                // [0x472d8]
        (void)tRun; (void)tSoft; (void)tFast;   // 供未还原的公共段使用

        // ---- 到达判定 [0x472e0] ----
        if (wdist < 1.5) {                                          // [0x472e4]
            p.speed = 0.0;                                          // [0x472ec]
            NSString *wid = self.walkIdentifier;                    // [0x472f0]
            if (wid != nil) {
                [self event:@"arrived"
                     detail:@{ @"walkId": wid, @"x": @(p.x) }];     // [0x47300..0x47378]
                self.walkIdentifier = nil;                          // [0x47388]
            }
            [self setModeTo:@"idle"];                               // [0x47394]
            p.nextAt = time + [self rnd:1.2 to:3.2];                // [0x473a4..0x473c4]
        }

        // 公共姿态应用段入口 [0x473dc]
        goto motion_common;
    } else {
        // ---- 其余模式分支尚未还原 ----
        // NOT RUN: [0x47510 → 0x49844] 共 2331 条指令，覆盖：
        //   @"sit" / @"sleep" / @"crouch" / @"air" / @"spin" / @"land" /
        //   @"drag" / @"flap" / @"wake" 的缓动目标，以及 0x47510 起的表情/眼睛求解
        //   （sq/sqv、tilt/tiltV 弹簧、lean、sitK、drowse、stretch、stride/lift/bob、
        //    phase/lean 回零、blushK、目标位移钳制）。
        goto motion_common;
    }

motion_common:;
    // ---- 脉冲动画 [0x473dc → 0x47510] ----
    // d11/d13 是叠加到最终姿态的升降/倾斜偏移，本段只负责按 pulse 进度累加。
    double flapLift = 0.0;                          // [0x473d0] movi d11, 0
    double flapTilt = 0.0;                          // [0x473dc] movi d13, 0
    NSDictionary *pulse = self.pulse;                // [0x473e0]
    if (pulse != nil) {
        double t = time - [pulse[@"t0"] doubleValue];            // [0x473f4..0x47434]
        double u = t / [pulse[@"dur"] doubleValue];              // [0x47440..0x47480]
        NSString *kind = pulse[@"kind"];                         // [0x47488..0x474b4]
        if (u >= 1.0) {                                          // [0x474b8]
            [self setPulse:nil];                                 // [0x474c4]
        } else if ([kind isEqual:@"shiver"]) {                   // [0x474d4]
            // 抖动偏移由后续公共段消费，本段不加
        } else if ([kind isEqual:@"flap"]) {                     // [0x474e8]
            double s = sin(u * M_PI * 8.0);                      // [0x474c0] π / 8.0 / sin
            flapLift += (s * 7.0) * (1.0 - u);                   // [0x474d0] 7.0
            flapTilt += (fabs(s) * -0.06) * (1.0 - u);           // [0x474dc] -0.06
        } else {
            // 其余 pulse kind 走 0x48818，尚未还原
        }
    }
    (void)flapLift; (void)flapTilt;

    // NOT RUN: [0x47510 → 0x49844] 表情/眼睛求解、sq/sqv 弹簧、tilt/tiltV、
    //   sitK/drowse/stretch、stride/lift/bob 落地、blushK、目标钳制，
    //   以及 @"sit"/@"sleep"/@"crouch"/@"air"/@"spin"/@"land"/@"drag"/@"flap"/@"wake" 分支。
    return;

motion_behind_pointer:
    // NOT RUN: [0x48944] 指针在身后时的转身判定（p.turnAcc 累积 → 翻转 facing）
    return;

    // 表情/眼神状态机推进（eyeSig 变化时切眼型，thinking 时出气泡）
    NSString *face = [self currentFaceName];
    NSDictionary *faceDef = [self faceAt:face ?: @"neutral"];
    BOOL thinking = [self thinking];
    BOOL thoughtShown = [self thoughtShown];
    (void)faceDef;

    NSString *eyeTarget = @"open";
    if (thinking && !thoughtShown) {
        eyeTarget = @"half";
        [self setThoughtShown:YES];
        [self event:@"thought" detail:@{@"face": face ?: @"neutral"}];
    } else if ([@[@"sleep", @"doze"] containsObject:face]) {
        eyeTarget = @"closed";
    }

    NSString *currentSig = [self eyeSig];
    NSString *currentEye = [self eyeCur];
    NSString *desiredSig = [NSString stringWithFormat:@"%@/%@", eyeTarget, face ?: @"neutral"];
    if ([self responsiveInteraction]) {
        if (currentSig && ![currentSig isEqualToString:desiredSig]) {
            [self setEyePrev:currentEye];
            [self setEyeCur:eyeTarget];
            [self setEyeSig:desiredSig];
        }
    } else if (currentSig && ![currentSig isEqualToString:desiredSig]) {
        [self setEyePrev:currentEye];
        [self setEyeSig:desiredSig];
    } else if (!currentSig) {
        [self setEyePrev:currentEye];
        [self setEyeSig:desiredSig];
    }

    NSArray *dims = [self eyeDims];
    if ([dims isKindOfClass:[NSArray class]] && dims.count >= 2) {
        (void)[dims[0] boolValue];
        (void)[dims[1] doubleValue];
    }
}


@end
