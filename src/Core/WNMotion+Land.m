//
//  WNMotion+Land.m
//  PetDFY
//
//  还原自 PetDFY.arm64e.dylib
//  -[WNMotion land]  IMP 0x46970 .. 0x46bcc（151 条指令，下一个 IMP 0x46bcc）
//
//  证据等级：逐条对地址还原，全部 Observed（除注明 Assumed 处）。
//  p 位于 self+8，故反汇编里的 [x20,#N] 对应 p+(N-8)。
//

#import "WNMotion.h"

@implementation WNMotion (Land)

- (void)land {
    double vy = p.vy;                               // [0x469a4]  ldr d9, [x20,0x30]  → p.vy
    NSString *air = self.airKind;                   // [0x469a8]  airKind

    p.fy = p.gy;                                    // [0x469b4]  ldr d0,[x20,0x18] → str [x20,0x10]

    // 冲击量：0.0024 * vy，夹在 [0.8, 4.5]
    double impact = vy * 0.0024;                    // [0x469c0]  0x0024
    impact = fmin(impact, 4.5);                     // [0x469c8]
    impact = fmax(impact, 0.8);                     // [0x469d4]  0.8
    p.vx = 0.0;                                     // [0x469dc]  stp xzr,xzr,[x20,0x28]
    p.vy = 0.0;
    p.gvy = 0.0;                                    // [0x469e0]  str xzr,[x20,0x20]
    p.sqv += impact;                                // [0x469e4]  ldr d1,[x20,0xb0]; fadd; str

    // 落地尘土：重落 7 股、轻落 3 股，扩散 70
    [self dust:(vy > 900.0 ? 7 : 3) spread:70.0];   // [0x469f0]  900.0 / csel(7,3) / 70.0

    // 音效参数：重落且不是跳跃落地时传 YES
    BOOL heavy = (vy > 1000.0) && !([air isEqual:@"jump"]);
    [self sound:@"land"                             // [0x46a20]  @"land"
           kind:@"move"                             // [0x46a7c]  @"move"
      arguments:@[ @(heavy) ]];                      // [0x46a40]  bic w2,w8,w0

    // 抛掷且冲击 > 1000：弹一下 + 报 crash，不走 land 姿态
    if ([air isEqual:@"throw"] && vy > 1000.0) {    // [0x46a98]  @"throw" / 1000.0
        [self setModeTo:@"jump"];                   // [0x46ab4]  @"jump"
        [self event:@"values" detail:@{ @"kind": @"crash" }]; // [0x46ac4] @"values" + @{kind:crash}
        return;                                     // [0x46adc]  b 0x46b90
    }

    [self setModeTo:@"land"];                       // [0x46ae0]  @"land"

    if ([air isEqual:@"throw"]) {                   // [0x46af0]
        [self setExpression:@"surprised"];          // [0x46b04]  @"surprised"
        p.nextAt = self.time + 0.9;                 // [0x46b14]  0.9
        p.emitAt = self.time + 2.0;                 // [0x46b24]  2.0
    } else if ([air isEqual:@"drop"]) {             // [0x46b2c]  @"drop"
        [self setExpression:@"happy"];              // [0x46b40]  @"happy"
        p.nextAt = self.time + 1.6;                 // [0x46b50]  1.6
        p.emitAt = self.time + 2.6;                 // [0x46b60]  2.6
    } else {
        p.emitAt = self.time + [self rnd:0.8 to:2.0]; // [0x46b74]  rnd:0.8 to:2.0
    }
}

@end
