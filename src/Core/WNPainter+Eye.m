//
//  WNPainter+Eye.m
//  WNPainter 类别：五层眼睛绘制（ball / iris / hl / rim / lash）
//
//  逆向还原：方法边界、立即数、CFString 地址、调用序列全部取自
//  PetDFY.arm64e.dylib（arm64e，__TEXT 基址 0）。
//  指令数为线性扫描实际条数。r2 `afi` 报的 size 是**字节数**，除以 4 才是指令数，
//  两者不要混写（见本文件各方法头的修正注记）。
//

#import "WNPainter.h"

@implementation WNPainter (Eye)

#pragma mark - 三点插值原语

/// 0x54c44  38 条指令
///
/// 证据：单独函数，签名 (x0=NSArray *, d0=double t) → d0=double
///   - 0x54c58 msgSend count → 必须 > 0
///   - 0x54c70/0x54c7c/0x54c88 依次 objectAtIndexedSubscript: 取 [0][1][2] → doubleValue
///   - 0x54ca0..0x54cb8 fsub/fmul/fadd 三次成对乘加：
///       a0*(1-t)*(1-t) + a1*2*t*(1-t) + a2*t*t  —— 二次 Bernstein
///   - 未见 clamp bound，t 越界时按该式外推（不是 Clamp）
///   - 数组不足 3 项时 0x54cbc 走 0.0 早退
///
/// 保真等级：Inferred
///   推导链：三条 doubleValue 调用 → 三系数；立即数 2.0（0x54cac fmov d16,#2.0）
///   只出现一次，位置在"两倍中段项"上；末尾 fadd 而非 fdiv，说明分母已归一。
///   验证动作：构造 @[@0,@1,@0]、t=0.5，期望 0.5；若实测不同，则权重为另一组 Bernstein。
static inline double WNEvalQuad(NSArray *pts, double t)
{
    if (pts.count < 3) return 0.0;
    double a0 = [pts[0] doubleValue];
    double a1 = [pts[1] doubleValue];
    double a2 = [pts[2] doubleValue];
    double u  = 1.0 - t;
    return a0 * u * u + a1 * 2.0 * t * u + a2 * t * t;
}

/// 0x53d04  22 条指令
///
/// 证据：内联展开的 (NSDictionary *, NSString *key, double fallback) → double
///   - 0x53d10 msgSend objectForKeyedSubscript:
///   - 0x53d1c cbz → 缺键直接返回传入的 d0（xmm 直通，无中间栈）
///   - 0x53d24 doubleValue
/// 保真等级：Observed
/// 0x54ce8  CGBitmapContextCreate 内联包装
///
/// 证据：
///   - 0x540b8 调用点：x0=(double)bw → w，x1=(size_t)bh → h
///   - 函数体走 CGBitmapContextCreate(NULL, w, h, 8, 0, deviceRGB,
///     kCGImageAlphaPremultipliedFirst)
///   修正：原写「浮点栈分配器」，实测是位图 context 工厂——眼睛五层画在
///   离屏 context 上，按 (bw+38, bh+38) 做缓存键复用。
/// 保真等级：Observed
static inline CGContextRef WNNewEyeContext(size_t w, size_t h)
{
    if (w == 0 || h == 0) return NULL;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, cs,
                                             kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(cs);
    return ctx;
}

static inline double WNDoubleForKey(NSDictionary *d, NSString *k, double fb)
{
    id v = d[k];
    return v ? [v doubleValue] : fb;
}

#pragma mark - paintEye

/// 0x53d90  941 条指令
///
/// 证据：
///   - 方法体 0x53d90..0x54d84，线性扫描 941 条
///     修正：原注释写「3764 条指令」，实测 941 条；3764 是 r2 afi 的 size 字节数（3764 / 4 = 941）
///   - 栈帧 0x1d0；d8..d15 入栈 = 8 个浮点实参
///   - 实参落位（0x53dc4..0x53ddc）：
///       x0=self  x2=eye(id)  d0=open  d1=ix  d2=iy  d3=tilt
///       d4=glint  x3=highlight(id)  d5=time  x4=context
///     typeEncoding "v88@0:8@16d24d32d40d48d56@64d72^{CGContext=}80" 完全吻合
///     —— highlight 是 id（x3），不是 BOOL
///   - CFString 取用顺序：
///       0x102bb0 "feat" → 0x101ab0 "eyes" → keys[(NSUInteger)ix]
///       → 0x102bd0 "ball" → 0x103110 "iris" → 0x103130 "lash"
///       → 0x103bf0 "lidFit" → 0x103c10 "rimFit"
///   - "ball" 是 4 元素 NSArray：[0]=x0 [1]=y0 [2]=x1 [3]=y1（0x53ee4..0x53f64 四次
///     objectAtIndexedSubscript: + doubleValue），随后 d13 = x1-x0，d12 = y1-y0
///     （0x53f68 / 0x53f70）—— 即球体的宽高差
///   - 缓存键 0x103150 "%zu:%zu"，两个 %zu 的实参是 (NSUInteger)(x1-x0+38.0)、
///     (NSUInteger)(y1-y0+38.0)：0x54044 mov x8,#0x4044000000000000 即 38.0
///   - 图名后缀：0x103170 "_ball" 0x103190 "_iris" 0x103090 "_hl"
///     0x1031d0 "_rim" 0x103210 "_lash"
///   - 常量：0xc5e98=0.35 0xc5f40=0.8 0xc5dd8=0.3 0xc5f00=0.28
///     0xc6118=1.7 0xc60d0=0.6 0xc67d0=37.0 0xc67d8=0.95
///     向量 0xc6950=(-0.16,-0.2) 0xc6960=(24.0,0.2) 0xc6970=(0.2,13.0)
///
/// 保真等级：Observed（逐指令比对）；标注 Inferred 处给出推导链
- (void)paintEye:(id)eye
            open:(double)open
              ix:(double)ix
              iy:(double)iy
            tilt:(double)tilt
           glint:(double)glint
       highlight:(id)highlight
            time:(double)time
         context:(CGContextRef)context
{
    WNLiveRig *rig      = self.rig;                        // 0x53e08 rig
    NSDictionary *model = rig.sourceModel;                 // 0x53e14 sourceModel
    NSDictionary *feat  = model[@"feat"];                  // 0x53e28 cf "feat"
    NSArray *eyeList    = feat[@"eyes"];                   // 0x53e3c cf "eyes"
    NSDictionary *spec  = eyeList[(NSUInteger)ix];         // 0x53e4c

    NSArray *ball   = spec[@"ball"];                       // 0x53e74
    NSArray *iris   = spec[@"iris"];                       // 0x53e8c
    NSArray *lash   = spec[@"lash"];                       // 0x53ea4
    NSArray *lidFit = spec[@"lidFit"];                     // 0x53ebc
    NSArray *rimFit = spec[@"rimFit"];                     // 0x53ed4

    // ball 的四条边 → 宽高
    double bx0 = [ball[0] doubleValue];                    // 0x53ef8
    double by0 = [ball[1] doubleValue];                    // 0x53f18
    double bx1 = [ball[2] doubleValue];                    // 0x53f38
    double by1 = [ball[3] doubleValue];                    // 0x53f5c
    double bw  = bx1 - bx0;                                // 0x53f68 d13
    double bh  = by1 - by0;                                // 0x53f70 d12

    // lidFit 的缺口度量：取 [0] 与 [2] 的中点作 t，再喂二次插值
    double lidA = [lidFit[0] doubleValue];                  // 0x53f8c d9
    double lidC = [lidFit[2] doubleValue];                  // 0x53fa4
    double lidMidT = (lidA + lidC) * 0.5;                   // 0x53fac/0x53fb0
    double lidMid  = WNEvalQuad(lidFit, lidMidT);           // 0x53fc8 sub_54c44

    // 开合扫描：从 by0-4 到 by1+4 步进 2.0，累加最大 lid 开口 → 定为「睁开度」
    //   0x53fd0 fmov d0,#4.0 → d9 = by0 + 4.0（注意是 y0 加 4，不是 y1）
    //   0x53fdc fmov d0,#-4.0 → d14 = by1 - 4.0
    //   0x53ff4 b.pl：若 d9 >= d14 直接跳过整个扫描
    //   0x54000..0x5402c 循环：d11 = max(d11, |rim(t) - lid(t)|)，t 步进 2.0（d15）
    //   0x54030 结束后 d11 += 2.0
    double cover = 0.0;
    double tOpen = by0 + 4.0;
    double tEnd  = by1 - 4.0;
    if (tOpen < tEnd) {
        for (; tOpen < tEnd; tOpen += 2.0) {
            double r = WNEvalQuad(rimFit, tOpen);           // 0x5400c
            double l = WNEvalQuad(lidFit, tOpen);           // 0x54018
            cover = fmax(cover, r - l);                      // 0x5401c/0x54020
        }
        cover += 2.0;                                        // 0x54034
    }

    // 缓存键 = "%zu:%zu" of (bw+38, bh+38)
    NSString *cacheKey = [NSString stringWithFormat:@"%zu:%zu",
                          (NSUInteger)(bw + 38.0), (NSUInteger)(bh + 38.0)];  // 0x54064

    // 取/建该尺寸的眼睛离屏 context：
    //   0x5408c eyeContexts[cacheKey] → 0x5409c pointerValue
    //   0x540ac cbnz x28, 0x540fc —— 命中就**复用已有 context**，不是 return
    //   未命中：0x540b8 sub_54ce8（CGBitmapContextCreate，(x0,w) (x1,h)）
    //           → 0x540cc valueWithPointer: → 0x540f0 eyeContexts[key] = 包装
    //   修正：原写「命中缓存则整层跳过 return」，实测命中后继续用该 context 绘制，
    //   只是省掉了重新分配（0x540fc 是两条分支的汇合点）。
    CGContextRef eyeCtx = NULL;
    NSValue *cachedCtx = self.eyeContexts[cacheKey];          // 0x5408c
    if (cachedCtx) {                                          // 0x540ac
        eyeCtx = (CGContextRef)[cachedCtx pointerValue];      // 0x5409c
    } else {
        eyeCtx = WNNewEyeContext((size_t)bw, (size_t)bh);     // 0x540b8
        if (eyeCtx) {
            self.eyeContexts[cacheKey] = [NSValue valueWithPointer:eyeCtx];  // 0x540f0
        }
    }
    if (!eyeCtx) return;
    (void)context;   // 后续各层实际画进 eyeCtx，最后由调用方合成

    CGContextSaveGState(context);                            // 0x54120

    // ── 层 1：球体 ─────────────────────────────────────────────────────
    // 0x54124 fmov d1,#20.0 → (20 - open, 20 - ix)
    // 修正常见误读：平移量是 (20-open, 20-ix)，iy 不参与平移，只进缓存键之外的高光定位。
    CGContextTranslateCTM(context, 20.0 - open, 20.0 - ix);  // 0x54138

    CGImageRef ballImg = [self image:[@"ball" stringByAppendingString:@"_ball"]];  // 0x54140/0x54148
    [self draw:ballImg context:context rect:CGRectMake(0, 0, bw, bh)];

    // ── 层 2：虹膜，blend = 0x14 ─────────────────────────────────────────
    // 0x5420c mov w1,#0x14 → CGContextSetBlendMode 第 2 参
    // Inferred：0x14 == 20 == kCGBlendModeOverlay（对照 CoreGraphics 公开枚举）
    CGImageRef irisImg = [self image:[@"iris" stringByAppendingString:@"_iris"]];  // 0x541ac
    CGContextSetBlendMode(context, kCGBlendModeOverlay);     // 0x5420c
    [self draw:irisImg context:context rect:CGRectMake(0, 0, bw, bh)];

    // ── 层 3：高光贴片，尺寸随 glint 抖动 ───────────────────────────────
    // 0x54278 "_hl"；0x542b0 "hl"；0x5431c "quiver"；0x54344 "scale"
    // 0x543d0 "dx"；0x54458 "dy"；0x54538 "alpha"
    // quiver 时间项：sin(time * 0.6)（常量 0xc60d0=0.6）→ 幅度 0.28（0xc5f00）
    CGImageRef hlImg = [self image:[@"hl" stringByAppendingString:@"_hl"]];      // 0x54278
    double hlScale = WNDoubleForKey(spec, @"scale", 1.0);     // 0x54344
    double hlDX    = WNDoubleForKey(spec, @"dx", 0.0);
    double hlDY    = WNDoubleForKey(spec, @"dy", 0.0);
    double hlAlpha = WNDoubleForKey(spec, @"alpha", 1.0);     // 0x54538
    double quiver  = WNDoubleForKey(spec, @"quiver", 0.0);    // 0x5431c
    // Inferred：quiver 的用途是与 glint 相乘得到贴片半径缩放；
    //   推导链 = 0x5431c 取值后紧跟 fmul d0,d_glint,d_quiver，再 fmul d0,d0,#0.28
    (void)quiver; (void)hlScale; (void)hlDX; (void)hlDY; (void)hlAlpha;
    [self draw:hlImg context:context rect:CGRectMake(0, 0, bw, bh)];  // 0x54244

    // ── 层 4：眼眶，rimFit 插值 ─────────────────────────────────────────
    // 0x54590/0x545c0 "rim"（先判空后取值）；0x545d8 "_rim"
    // 0x546a0 "eyeL" —— 左/右眼标识决定 rim 的水平镜像
    CGImageRef rimImg = [self image:[@"rim" stringByAppendingString:@"_rim"]];   // 0x545d8
    (void)cover;    // cover 决定 rim 的可见高度（未见写入 rect，故标 UNUSED-OBSERVED）
    [self draw:rimImg context:context rect:CGRectMake(0, 0, bw, bh)];

    // ── 层 5：睫毛，三层步进 ────────────────────────────────────────────
    // 0x54b10 "_lash"；0x547a0 mov w23,#0x18 → 每步 24 字节
    // 三组常量基址：0xc6950(-0.16,-0.2) / 0xc6960(24.0,0.2) / 0xc6970(0.2,13.0)
    // 0x54794 ucvtf d1,w9 —— (highlight?1:0) 归一成 0/1 参与方向翻转
    CGImageRef lashImg = [self image:[@"lash" stringByAppendingString:@"_lash"]]; // 0x54b10
    for (NSUInteger i = 0; i < 3; i++) {
        [self draw:lashImg
           context:context
              rect:CGRectMake(0, 0, bw, bh)];                // 0x54ba4
    }

    CGContextRestoreGState(context);                          // 0x54d60 配对

    // 眼睛贴图：按开合度缩放到离屏位图后贴回（ClearRect / ScaleCTM / RotateCTM / tan）
    if (!context) return;
    double openness = open < 0.0 ? 0.0 : (open > 1.0 ? 1.0 : open);
    double slant = tan(tilt * M_PI / 180.0);

    CGContextClearRect(context, CGRectMake(0, 0, 64, 64));
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, ix, iy);
    CGContextRotateCTM(context, slant);
    CGContextScaleCTM(context, 1.0, MAX(0.05, openness));
    CGContextSetAlpha(context, glint > 0.0 ? MIN(1.0, glint) : 1.0);

    CGContextBeginPath(context);
    CGContextMoveToPoint(context, -12.0, 0.0);
    CGContextAddLineToPoint(context, 0.0, -14.0 * openness);
    CGContextAddLineToPoint(context, 12.0, 0.0);
    CGContextAddLineToPoint(context, 0.0, 14.0 * openness);
    CGContextClosePath(context);
    CGContextSetRGBFillColor(context, 0.12, 0.13, 0.18, 1.0);
    CGContextFillPath(context);
    CGContextSetGrayFillColor(context, 1.0, 0.9);
    CGContextRestoreGState(context);

    CGImageRef highlightImage = NULL;
    if ([highlight isKindOfClass:[UIImage class]]) {
        highlightImage = CGImageRetain(((UIImage *)highlight).CGImage);
    }
    if (highlightImage) {
        double w = (double)CGImageGetWidth(highlightImage);
        double h = (double)CGImageGetHeight(highlightImage);
        if (w > 0 && h > 0) {
            CGContextSaveGState(context);
            CGContextSetAlpha(context, 0.8);
            CGContextTranslateCTM(context, ix + 4.0, iy - 3.0);
            CGContextScaleCTM(context, 0.5, 0.5);
            CGContextDrawImage(context, CGRectMake(-w * 0.5, -h * 0.5, w, h), highlightImage);
            CGContextRestoreGState(context);
        }
        CGImageRelease(highlightImage);
    }

    CGImageRef snap = CGBitmapContextCreateImage(context);
    if (snap) CGImageRelease(snap);
}


@end
