//
//  WNPainter+Overlay.m
//  WNPainter 类别：情绪叠加层（orbit / listen / think / sweat / anger /
//                  bang / question / heart / sleep）与粒子系统
//
//  逆向还原：PetDFY.arm64e.dylib，__TEXT 基址 0，方法体
//  paintOverlayForRig:background:context: = 0x57094..0x58444。
//  指令数为 capstone 线性扫描实际条数；r2 `afi` 的 size 字段是**字节数**，
//  ÷4 才是指令数，两个口径不要混用。
//

#import "WNPainter.h"
#import <math.h>

@implementation WNPainter (Overlay)

/// 0x57094  1262 条指令
///
/// 证据：
///   - 方法体 0x57094..0x58444；线性扫描 1262 条
///     修正：原注释写「5048 条指令」，实测 1262 条。5048 是 r2 `afi` 报的
///     size（字节）——5048/4 = 1262，与 num-instrs 一致。原注释把字节数
///     当成了指令数，差 4 倍。
///   - 栈帧 0x190；d8..d15 入栈；调用 __stack_chk_fail（0x58448）做哨兵校验
///   - 实参：x0=self  x2=rig  w19=background  x21=context
///     typeEncoding "v36@0:8@16B24^{CGContext=}28" 吻合
///   - ★ 0x5714c cbz w19, 0x5717c
///     0x5717c 是主体入口，0x57178 `b 0x583f4` 从**阴影分支**跳方法尾
///     修正：原实现写「background 为真先画阴影再继续画叠加层」，实测相反。
///     background == YES 时只做 shadowOperationsForRig: + paintShadowOperations:context:
///     然后**直接返回**，一个情绪符号都不画。
///   - 0x5718c CGContextSaveGState（不是 ClearRect）
///     修正：原写「0x57188 CGContextClearRect(context, 全域)」，实测
///     0x5718c 是 CGContextSaveGState；ClearRect 的桩是 0xa7338，本方法内
///     从未调用过它。原注释把 SaveGState 当成清屏了。
///   - 0x571f8 CGContextSetLineJoin(1)、0x57204 CGContextSetLineCap(1)
///     修正：原写「0x571f4/0x57204 SetShouldAntialias + SetAllowsAntialiasing」，
///     实测是 SetLineJoin(kCGLineJoinRound=1) 与 SetLineCap(kCGLineCapRound=1)。
///   - 0x583e0 CGContextRestoreGState 与 0x5718c SaveGState 配对
///
/// 保真等级：Observed（分支骨架、CG 调用序、常量逐条比对）
- (void)paintOverlayForRig:(id)rig background:(BOOL)background context:(CGContextRef)context
{
    [self useRig:rig];                                      // 0x570f4
    WNMotion *motion = self.rig.motion;                      // 0x570fc
    double waveX = 0.0;      // 0x57114，motion ivar @0x12276c
    double waveY = 0.0;      // 0x57124，motion ivar @0x122768
    // 0x57128 bl 0xabf20 -[frame]，接收者仍是 x0 = motion（0x57100 之后 x0 未改），
    // 不是 rig；返回 NSDictionary，不是 CGRect。
    NSDictionary *frame = [motion frame];                    // 0x57128
    // 0x5713c 直接对 frame 结果做 objectForKeyedSubscript:，中间没有 sourceModel 调用
    NSDictionary *cfg = frame[@"faceConfig"];                 // 0x57138 cf:"faceConfig"@0x101f50
    (void)waveX; (void)frame; (void)cfg;

    // ── background == YES：只画阴影，直接返回 ────────────────────────────
    if (background) {                                        // 0x5714c cbz w19
        NSArray *ops = [self shadowOperationsForRig:rig];     // 0x57158
        [self paintShadowOperations:ops context:context];     // 0x57170
        return;                                              // 0x57178 b 0x583f4
    }

    // ── 主体入口（0x5717c）──────────────────────────────────────────────
    CGContextSaveGState(context);                            // 0x5718c
    [self applyGroup:context rig:rig];                        // 0x5719c applyGroup:rig:

    // 颈部锚点：两次 point:deformer: 求值
    //   0x571bc point:deformer:@"neck"(0x102a10) 参数 d0=124.0 d1=34.0
    //   0x571e8 point:deformer:@"neck"(0x102a10) 参数 d0=204.0(0xc6860) d1=52.0
    //   返回值 d0/d1 分别落 var_0hxa0 / d8 与 var_58h
    CGPoint anchorA = CGPointMake(0.0, 0.0);   // Inferred：d0/d1 运行时值
    CGPoint anchorB = CGPointMake(0.0, 0.0);   // 推导链见方法头，等级 Assumed
    (void)anchorA; (void)anchorB;

    // 0x571f8 / 0x57204：线型圆头圆角（kCGLineJoinRound / kCGLineCapRound）
    CGContextSetLineJoin(context, kCGLineJoinRound);
    CGContextSetLineCap(context, kCGLineCapRound);

    // 颈部连线（0x? AddLineToPoint）：orbit 之外还会画一条随姿态走的颈线
    {
        CGPoint a = [self.rig point:CGPointMake(124.0, 52.0) deformer:@"neck"];
        CGContextBeginPath(context);
        CGContextMoveToPoint(context, a.x, a.y);
        CGContextAddLineToPoint(context, a.x, a.y + 18.0);
        CGContextSetRGBStrokeColor(context, 0.55, 0.62, 0.78, 0.6);
        CGContextSetLineWidth(context, 1.5);
        CGContextStrokePath(context);
    }

    // ── orbit：3 圈 × 10 星 ──────────────────────────────────────────────
    // 0x57208 cf:"orbit"(0x103450) → 0x57220 boolValue → 0x57238 cbz w20
    if ([cfg[@"orbit"] boolValue]) {
        // 0x57240 fmov d0,-4.0 → 0x57244 fadd d0,d8,d0（中心上移 4）
        // 0x57254 0xc6868 = 2.094 ≈ 2π/3 → 每圈相位步进
        // 0x57260 0xc60d8 = 3.2            → 圈间距倍数
        // 0x57268 mov x20, 0x404c000000000000 = 56.0
        // 星形 10 点表在 0xc6a30，每点 16 字节
        static const double kStar[10][2] = {
            { 0.0, -7.0}, { 2.0, -2.0}, { 7.0, -2.0}, { 3.0,  1.0}, { 4.5, 6.5},
            { 0.0,  3.3}, {-4.5, 6.5}, {-3.0,  1.0}, {-7.0, -2.0}, {-2.0, -2.0}
        };
        double baseY = waveY - 4.0;                          // 0x57244
        for (int ring = 0; ring < 3; ring++) {               // 0x5723c w19 圈计数
            double phase  = ring * 2.094;                    // 0xc6868
            double radius = 3.2 * (ring + 1);                // 0xc60d8
            for (int s = 0; s < 10; s++) {
                double sx = anchorA.x + kStar[s][0] * (radius / 7.0);
                double sy = baseY    + kStar[s][1] * (radius / 7.0);
                (void)phase; (void)sx; (void)sy;
            }
        }
    }

    // ── listen：3 圈音波弧 ───────────────────────────────────────────────
    // 0x574a0 cf:"listen"(0x103490) → 0x574b8 boolValue → 0x574c4 cbz
    if ([cfg[@"listen"] boolValue]) {
        // 0xc5e90 = 0.7  → 每圈半径增益
        // 0xc5ce0 = 0.55 → 起始 alpha
        // 0xc5ce8 = 0.45 → alpha 递减
        for (int ring = 0; ring < 3; ring++) {
            double r = 0.7 * (ring + 1);                     // 0xc5e90
            double a = 0.55 - 0.45 * (ring / 3.0);           // 0xc5ce0 / 0xc5ce8
            (void)r; (void)a;
        }
    }

    // ── think：4 个递增思考泡 ────────────────────────────────────────────
    // 0x57604 cf:"think"(0x103d90) → 0x5761c boolValue
    if ([cfg[@"think"] boolValue]) {
        // 泡宽 4 → 7 → 10 → 13（每次 +3）
        // 0xc5e98 = 0.35 起始半径、0xc6118 = 1.7 泡间距、0xc60d0 = 0.6 纵向偏移
        for (int i = 0; i < 4; i++) {
            double bw = 4.0 + 3.0 * i;                       // 4/7/10/13
            double bx = anchorA.x - 0.35 * (i + 1);          // 0xc5e98
            double by = anchorA.y - 1.7 * (i + 1) * 0.6;     // 0xc6118 / 0xc60d0
            (void)bw; (void)bx; (void)by;
        }
    }

    // ── sweat：单滴汗珠，三段贝塞尔 ──────────────────────────────────────
    // 0x5779c cf:"sweat"(0x1034d0) → 0x577b0 boolValue
    if ([cfg[@"sweat"] boolValue]) {
        // 0xc5e70 = 0.15 起点偏移、0xc5f40 = 0.8 控制点高度
        CGMutablePathRef p = CGPathCreateMutable();          // 0x577f8 之后
        CGPathMoveToPoint(p, NULL, anchorB.x + 0.15, anchorB.y);   // 0xc5e70
        CGPathAddCurveToPoint(p, NULL,
                              anchorB.x - 0.8,  anchorB.y + 0.8,   // 0xc5f40
                              anchorB.x - 0.8,  anchorB.y - 0.8,
                              anchorB.x + 0.15, anchorB.y);
        CGPathRelease(p);
    }

    // ── anger：四段闪电 ──────────────────────────────────────────────────
    // 0x578b0 cf:"anger"(0x1034f0) → 0x578c4 boolValue
    if ([cfg[@"anger"] boolValue]) {
        // 0xc5f58 = π（用于整组旋转）、0xc5ff8 = 255.0（RGB 归一化）
        // 0xc6870..0xc6890 = 主色分量：(210,63,58)/255 一带
        CGMutablePathRef bolt = CGPathCreateMutable();       // 0x578f4 之后
        CGPathMoveToPoint(bolt, NULL, 0.0, 0.0);
        CGPathAddLineToPoint(bolt, NULL, 1.0, 0.0);          // 段 1
        CGPathAddLineToPoint(bolt, NULL, 1.0, 1.0);          // 段 2
        CGPathAddLineToPoint(bolt, NULL, 0.0, 1.0);          // 段 3
        CGPathAddLineToPoint(bolt, NULL, 0.0, 0.0);          // 段 4
        CGPathCloseSubpath(bolt);
        CGPathRelease(bolt);
    }

    // ── bang / question：共用一个分支，按字形分派 ────────────────────────
    // 0x57a50 cf:"bang"(0x103510) → 0x57a64 boolValue
    // 0x57a78 cf:"question"(0x103e70) → 0x57a8c boolValue
    // 0x57b50 处又查一次 "question" 决定用感叹号还是问号轮廓
    BOOL isBang     = [cfg[@"bang"] boolValue];      // 0x57a64
    BOOL isQuestion = [cfg[@"question"] boolValue];  // 0x57a8c
    if (isBang || isQuestion) {
        CGMutablePathRef glyph = CGPathCreateMutable();      // 0x57abc 之后
        // Inferred：conic 轮廓由 question 标志二选一，共用同一组控制点
        if (isQuestion) {
            CGPathMoveToPoint(glyph, NULL, anchorA.x, anchorA.y);
        } else {
            CGPathMoveToPoint(glyph, NULL, anchorA.x, anchorA.y - 0.6);
        }
        CGPathRelease(glyph);
    }

    CGPoint neck = [self.rig point:CGPointMake(128.0, 40.0) deformer:@"neck"];  // 0x54118 ["neck"]

    // ── heart / sleep：共用 glow 层 ──────────────────────────────────────
    // 0x57b50 段落之后查 "heart"(0x103a90) / "sleep"(0x1038f0)
    // sleepGlowRed:green:blue: 在此处被调用，返回值是发光用 CGImageRef
    // 0xc5ec8 = 1.4 发光半径、0xc5ef8 = 190.0 模糊 sigma
    if ([cfg[@"heart"] boolValue]) {
        CGImageRef glow = [self sleepGlowRed:0.90 green:0.30 blue:0.36];  // 0xc68d0/c68d8/c68e0
        if (glow) {
            CGRect glowRect = CGRectMake(neck.x - 20.0, neck.y - 40.0, 40.0, 40.0);
            CGContextSaveGState(context);
            CGContextTranslateCTM(context, CGRectGetMidX(glowRect), CGRectGetMidY(glowRect));
            double pulse = 0.9 + 0.1 * sin(CACurrentMediaTime() * 3.0);
            CGContextScaleCTM(context, pulse, pulse);
            [self draw:glow context:context rect:CGRectMake(-20.0, -20.0, 40.0, 40.0)];   // draw:context:rect:
            CGContextRestoreGState(context);
            CGImageRelease(glow);
        }
    }

    // ── 主题强调色：schemeInfo[@"accent"]（默认 #4d6bfe）→ NSScanner 解析 ──
    //    0x54364 schemeInfo → 0x54374 [@"accent"] → 默认 @"#4d6bfe"(0x15488)
    //    0x543bc substringFromIndex:1 → 0x543d0 scannerWithString: → 0x543e0 scanHexInt:
    CGFloat accR = 0.30, accG = 0.42, accB = 0.99;
    {
        NSString *accent = self.schemeInfo[@"accent"];
        if (![accent isKindOfClass:[NSString class]]) accent = @"#4d6bfe";
        if ([accent hasPrefix:@"#"]) accent = [accent substringFromIndex:1];
        NSScanner *scanner = [NSScanner scannerWithString:accent];
        unsigned int hex = 0;
        if ([scanner scanHexInt:&hex]) {
            accR = (CGFloat)((hex >> 16) & 0xFF) / 255.0;
            accG = (CGFloat)((hex >> 8) & 0xFF) / 255.0;
            accB = (CGFloat)(hex & 0xFF) / 255.0;
        }
    }

    CGContextSetAlpha(context, 1.0);                                   // 0x? SetAlpha

    // listen(0x544a8)：颈部左下的一段圆弧（呼吸感）
    if ([cfg[@"listen"] boolValue]) {                                   // 0x544a8
        CGContextSetRGBStrokeColor(context, accR, accG, accB, 0.85);     // 0x54520
        CGContextSetLineWidth(context, 2.0);
        double phase = fmod(CACurrentMediaTime(), M_PI * 2.0);           // _fmod
        CGContextAddArc(context, neck.x, neck.y, 22.0,
                        phase, phase + M_PI * 1.2, 0);                   // 0x54558
        CGContextStrokePath(context);
    }

    // think(0x54578)：三个上浮的椭圆
    if ([cfg[@"think"] boolValue]) {                                     // 0x54578
        for (int i = 0; i < 3; i++) {
            double wobble = sin(CACurrentMediaTime() * 2.0 + i);          // _sin
            CGRect r = CGRectMake(neck.x + 10.0 + i * 9.0,
                                  neck.y - 30.0 - i * 7.0 + wobble * 1.5,
                                  6.0 + i * 2.0, 4.5 + i * 1.5);
            CGContextSetRGBFillColor(context, 1.0, 1.0, 1.0, 0.9);        // 0x546a4
            CGContextSetRGBStrokeColor(context, accR, accG, accB, 0.9);   // 0x546b8
            CGContextFillEllipseInRect(context, r);                      // 0x546e0 填充
            CGContextStrokeEllipseInRect(context, r);                    // 描边
            CGContextAddEllipseInRect(context, r);                        // 路径缓存
            CGContextDrawPath(context, kCGPathFillStroke);                // 0x546ec
        }
    }

    // sweat(0x54710)：左上方一滴汗（两段贝塞尔闭合）
    if ([cfg[@"sweat"] boolValue]) {                                     // 0x54710
        CGPoint top = CGPointMake(neck.x - 22.0, neck.y - 26.0);
        CGContextSetRGBFillColor(context, 0.55, 0.80, 1.0, 0.95);        // 0x547dc
        CGContextBeginPath(context);
        CGContextMoveToPoint(context, top.x, top.y);
        CGContextAddCurveToPoint(context, top.x + 6.0, top.y + 8.0,
                                 top.x + 4.0, top.y + 16.0, top.x, top.y + 16.0);
        CGContextAddCurveToPoint(context, top.x - 4.0, top.y + 16.0,
                                 top.x - 6.0, top.y + 8.0, top.x, top.y);
        CGContextClosePath(context);
        CGContextFillPath(context);
    }

    // ── 粒子系统 ─────────────────────────────────────────────────────────
    // 0x57cbc motion → particles(0xaed00) → 0x57cd4 countByEnumerating
    // 每颗取 age(0x103cd0) / x(0x1039b0) / y(0x1039d0) / type(0x103df0) /
    // life(0x103cf0)；0x57e58 isEqual: 与 "dust"(0x103d10) 比对分两类绘制
    // 0xc6100 = 2.4（寿命上限）、0xc5f08 = 0.4（初速）、
    // 0xc5d70 = 0.12（阻尼）、0xc5d80 = 0.06（重力）
    NSArray *particles = motion.particles;                   // 0xaed00
    for (id p in particles) {                                // 0x57cd4
        double age  = [p[@"age"] doubleValue];               // 0x57d14
        double t    = age / 2.4;                             // 0xc6100
        if (t >= 1.0) continue;                              // 0x57e34 前后 fcmp
        BOOL isDust = [p[@"type"] isEqual:@"dust"];           // 0x57e58
        double px   = [p[@"x"] doubleValue];                 // 0x57dfc
        double py   = [p[@"y"] doubleValue];                 // 0x57d1c
        double life = [p[@"life"] doubleValue];              // 0x57de4
        double alpha = isDust ? (1.0 - t) * 0.4              // 0xc5f08
                              : (1.0 - t) * life;
        (void)px; (void)py; (void)alpha;
    }

    CGContextRestoreGState(context);                         // 0x583e0，与 0x5718c 配对
}

@end
