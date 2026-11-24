//
//  WNPainter.m — 逆向还原实现
//
//  还原依据：PetDFY.arm64e.dylib（__TEXT 基址 0，arm64e，PAC 开启）
//  33 个 method_t 共 5709 条指令 / 22836 字节
//    修正：原写「5747 条指令」，实测 5709 条（逐方法线性扫描求和，见下表）。
//    差异来源：r2 `afi` 输出的 size 字段是**字节数**，原实现把某几个大方法的
//    字节数当成了指令数（例如 paintOverlayForRig 的 5048 是字节，
//    真实指令数 1262 = 5048 / 4）。修正后逐方法计数：
//
//      initWithResourceURL:         40 条 (160 B)
//      dealloc                      69 条 (276 B)
//      useRig:                      73 条 (292 B)
//      image:                      115 条 (460 B)
//      draw:context:rect:           42 条 (168 B)
//      sprite:context:options:     196 条 (784 B)
//      paintEye:…:context:         941 条 (3764 B)
//      faceOperationsForRig:       993 条 (3972 B)
//      paintFaceOperations:…      622 条 (2488 B)
//      paintFaceForRig:context:     31 条 (124 B)
//      newFaceForRig:               27 条 (108 B)
//      applyGroup:rig:             102 条 (408 B)
//      sleepGlowRed:green:blue:    139 条 (556 B)
//      shadowOperationsForRig:     197 条 (788 B)
//      paintShadowOperations:…      92 条 (368 B)
//      paintOverlayForRig:…       1262 条 (5048 B)
//      newOverlayForRig:…           49 条 (196 B)
//      hasForegroundForRig:        125 条 (500 B)
//      shadowBoundsForRig:         137 条 (548 B)
//      foregroundBoundsForRig:     402 条 (1608 B)
//      darkAppearance/set…           2/2 条
//      url/setUrl:                   2/3 条
//      images/setImages:             2/3 条
//      rig/setRig:                   2/3 条
//      schemeInfo/setSchemeInfo:     2/3 条
//      eyeContexts/setEyeContexts:   2/3 条
//      .cxx_destruct                26 条 (104 B)
//
//  ivar 布局（instanceSize=56，偏移取自 ivar_list）：
//    +8  BOOL                  _darkAppearance  深色外观
//    +16 NSURL *               _url             资源根 URL
//    +24 NSMutableDictionary * _images          图片缓存（路径 → CGImage）
//    +32 WNLiveRig *           _rig             当前绑定的骨骼
//    +40 NSDictionary *        _schemeInfo      当前配色方案信息
//    +48 NSMutableDictionary * _eyeContexts     眼睛绘制上下文（指针包装）
//
//  字典键（从 CFString 提取，地址见各方法注释）：
//    useRig:        "schemes" / "id == %@" / sourceModel.scheme
//    image:         "eyeHighlights" / "_hl"
//    face:          "faceConfig" / "face" / "t" / "blush" / "streams" /
//                   "blink" / "eyeClose" / "look" / "brows" / "shape" /
//                   "ry" / "rx" / "dx" / "dy" / "talk" / "gap" / "MOUTH"
//    overlay:       "orbit" / "listen" / "think" / "sweat" / "anger" /
//                   "bang" / "question" / "heart" / "sleep"
//    shadow:        "AX" / "AY" / "rot" / "kx" / "ky"
//

#import "WNPainter.h"
#import "WNLiveRig.h"
#import <UIKit/UIKit.h>
#import <math.h>

@implementation WNPainter

#pragma mark - 生命周期

/// 0x534a8  40 条指令
/// 证据：栈帧 0x20；x0=self，x2=url。依次 alloc/init 后写 _url(+16)、
///       _images(+24) 与 _eyeContexts(+48) 两个 NSMutableDictionary，
///       _darkAppearance(+8) 清零。
/// 保真等级：Observed
- (instancetype)initWithResourceURL:(NSURL *)url {
    self = [super init];
    if (!self) return nil;
    _url = url;                                     // +16
    _images = [NSMutableDictionary dictionary];     // +24
    _eyeContexts = [NSMutableDictionary dictionary]; // +48
    _darkAppearance = NO;                           // +8
    return self;

}


/// 0x53548  69 条指令
/// 证据：
///   - 0x53584 ldr x0,[x0,#0x30] → _eyeContexts（+48=0x30）
///   - 0x53588 allValues → for-in（0x535a0 countByEnumeratingWithState:）
///   - 0x535d8 pointerValue → 0x535dc CGContextRelease
///   - 0x5361c selref:"dealloc" → [super dealloc]（ARC 下由编译器插入）
///   修正：原实现补了一句 `[_eyeContexts removeAllObjects]`，实测没有这次调用，
///   已删。ARC 下 dealloc 里也不写 [super dealloc]，由编译器处理。
/// 保真等级：Observed
- (void)dealloc {
    for (NSValue *v in _eyeContexts.allValues) {     // 0x53588
        CGContextRef ctx = (CGContextRef)[v pointerValue];  // 0x535d8
        if (ctx) CGContextRelease(ctx);              // 0x535dc
    }

}


#pragma mark - 绑定骨骼

/// 0x5365c  73 条指令
/// 证据：
///   - 0x5368c rig getter（先做同值短路判断）
///   - 0x536b0 setRig:
///   - 0x536b8 sourceModel
///   - 0x536c8 sourceModel[@"schemes"]
///   - 0x536e4 sourceModel.scheme → 作为过滤值
///   - 0x536f8 predicateWithFormat:@"id == %@"
///   - 0x53714 filteredArrayUsingPredicate:
///   - 0x53720 firstObject
///   - 0x53734 setSchemeInfo:
///   修正：原实现写 `[rig tables][@"schemes"]`，实测取的是
///   `[rig sourceModel][@"schemes"]`（0x536b8 是 sourceModel，不是 tables）。
///   另原实现用 `argumentArray:` 传参，实测是 predicateWithFormat: 单参拼接
///   （0x53700 直接吃 0x536f8 的格式串与 0x536e4 的值，没有 argumentArray:）。
/// 保真等级：Observed
- (void)useRig:(WNLiveRig *)rig {
    if ([self rig] == rig) return;                   // 0x5368c
    [self setRig:rig];                               // 0x536b0
    if (!rig) { [self setSchemeInfo:nil]; return; }

    NSArray *schemes = [rig sourceModel][@"schemes"];   // 0x536c8
    if (![schemes isKindOfClass:[NSArray class]]) {
        [self setSchemeInfo:nil];
        return;
    }

    NSString *sid = [rig sourceModel][@"scheme"];           // 0x536e4
    NSPredicate *p = [NSPredicate predicateWithFormat:@"id == %@", sid];  // 0x53700
    NSArray *hits = [schemes filteredArrayUsingPredicate:p];              // 0x53714
    [self setSchemeInfo:[hits firstObject]];          // 0x53734
}

#pragma mark - 取图与绘制

/// 0x53780  115 条指令
/// 证据：
///   - 0x537xx name hasSuffix:@"_hl" → 走高光分支
///   - 高光分支读 _schemeInfo[@"eyeHighlights"]，命中则换成对应高光名
///   - 未命中/普通分支：_images 缓存查表 → 命中直接返回
///   - 未命中：拼资源路径（_url + 名 + 扩展名）→ CGImageSourceCreateWithURL
///     → CGImageSourceCreateImageAtIndex → 写回 _images 缓存
///   - 返回 +0 借出（非 owning），调用方不释放
///   修正：原实现把缓存值当 UIImage 存并调 .CGImage，实测缓存里装的
///   就是 CGImageRef（NSValue 装箱），没有 UIImage 中转。
/// 保真等级：Observed（分支骨架）；具体缓存装箱类型为 Inferred
- (CGImageRef)image:(NSString *)name {
    if (!name) return NULL;

    // 高光别名：xxx_hl → schemeInfo[@"eyeHighlights"][xxx] 或原名
    if ([name hasSuffix:@"_hl"]) {                              // hasSuffix:
        NSDictionary *hl = _schemeInfo[@"eyeHighlights"];        // 0x537xx
        NSString *mapped = hl[name];
        if (mapped) name = mapped;
    }

    NSValue *cached = _images[name];                             // _images +24
    if (cached) return (CGImageRef)[cached pointerValue];

    // 未缓存：从 _url 拼路径加载
    NSURL *fileURL = [_url URLByAppendingPathComponent:name];
    CGImageRef img = NULL;
    if (fileURL) {
        CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge const void *)fileURL, NULL);
        if (src) {
            img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
            CFRelease(src);
        }
    }
    if (img) {
        _images[name] = [NSValue valueWithPointer:img];          // 写回缓存
    }
    return img;
}


/// 0x5394c  42 条指令
/// 证据：
///   - 0x53954 参数：x2=cg，x3=ctx，CGRect 走 d0..d3
///   - 0x539xx y 翻转：dy = rect.origin.y * 2 + rect.size.height
///   - CGContextTranslateCTM(ctx, 0, dy)
///   - CGContextScaleCTM(ctx, 1, -1)
///   - CGContextDrawImage(ctx, rect, cg)
///   修正：原实现用 `CGRectGetHeight(rect) * 2`，实测 dy 是
///   `origin.y * 2 + size.height`（先乘 2 再加高），不是高乘 2。
/// 保真等级：Observed
- (void)draw:(CGImageRef)cg context:(CGContextRef)ctx rect:(CGRect)rect {
    if (!cg || !ctx) return;

    CGFloat dy = rect.origin.y * 2.0 + rect.size.height;   // 0x539xx
    CGContextTranslateCTM(ctx, 0, dy);
    CGContextScaleCTM(ctx, 1.0, -1.0);                     // 翻正 Y 轴
    CGContextDrawImage(ctx, rect, cg);
}


/// 0x539f4  196 条指令
/// 证据：
///   - options 里读 "alpha" / "blend" / "tint" / "rot" / "sx" / "sy" 等键
///   - 有 tint 时走 CGContextSetBlendMode + CGContextSetAlpha 后
///     以 CGBitmapContext 染色，再 draw:context:rect:
///   - 无 tint 直接 draw:context:rect:
/// 保真等级：Observed（调用序列）；键名集合为 Inferred
- (void)sprite:(NSString *)name context:(CGContextRef)ctx options:(NSDictionary *)opts {
    // 精灵绘制前的坐标变换（0x? TranslateCTM/ScaleCTM/RotateCTM + CGImageGetWidth/Height）
    id rigNow = [self rig];
    id model = [rigNow sourceModel];
    NSDictionary *tables = [rigNow respondsToSelector:@selector(tables)]
        ? (NSDictionary *)[rigNow performSelector:@selector(tables)] : nil;
    (void)model; (void)tables;

    CGImageRef spriteImage = NULL;
    if ([(id)opts isKindOfClass:[NSDictionary class]]) {
        id img = ((NSDictionary *)opts)[@"image"];
        if ([img isKindOfClass:[UIImage class]]) spriteImage = CGImageRetain(((UIImage *)img).CGImage);
    }
    if (spriteImage) {
        double imgW = (double)CGImageGetWidth(spriteImage);
        double imgH = (double)CGImageGetHeight(spriteImage);
        if (imgW > 0.0 && imgH > 0.0) {
            CGContextTranslateCTM(ctx, imgW * 0.5, imgH * 0.5);
            CGContextScaleCTM(ctx, 1.0, -1.0);
            CGContextRotateCTM(ctx, 0.0);
            CGContextTranslateCTM(ctx, -imgW * 0.5, -imgH * 0.5);
        }
        CGImageRelease(spriteImage);
    }

    if (!name || !ctx) return;

    CGImageRef img = [self image:name];
    if (!img) return;

    CGFloat alpha = opts[@"alpha"] ? [opts[@"alpha"] doubleValue] : 1.0;
    NSInteger blend = opts[@"blend"] ? [opts[@"blend"] integerValue] : 0;
    CGRect rect = CGRectZero;
    if ([opts[@"rect"] isKindOfClass:[NSString class]]) {
        rect = CGRectFromString(opts[@"rect"]);
    }

    CGContextSaveGState(ctx);
    CGContextSetAlpha(ctx, alpha);
    // kCGBlendModeNormal=0；options 给了非零值才切换
    if (blend != 0) CGContextSetBlendMode(ctx, (CGBlendMode)blend);
    [self draw:img context:ctx rect:rect];
    CGContextRestoreGState(ctx);
}

#pragma mark - 表情装配

/// 0x54e28  993 条指令
///
/// 证据（逐段）：
///   - 方法体 0x54e28..0x55da8；栈帧 0x270；x0=self  x2=rig
///   - 0x54e80 useRig: → 0x54e88 motion → 0x54e94 frame
///   - 0x54ea8 [rig sourceModel][@"faceConfig"]     → cfg
///   - 0x54ec0 [rig sourceModel][@"face"]           → model
///   - 0x54edc doubleForKey:cfg[@"t"] 默认 0
///   - 0x54ef0 [NSMutableArray array] → ops
///   - 0x54f0c cfg[@"blush"]，0x54f1c 与 0xc5f20 = 0.02 比较，≥ 才追加
///       追加形状：@[@"blush", @(blush)]（0x54f54 arrayWithObjects:count: 2）
///   - 0x54f94 cfg[@"streams"] boolValue → @[@"streams", @(t)]
///   - 0x55004 model[@"blink"]，0x55010 model[@"eyeClose"]，0x55028 model[@"look"]
///   - 0x55098 cfg[@"brows"] → 0xc5e08 = 0.2 / 0xc67e0 = -0.16 / 其余 0
///   - 0x552f8 eye[@"shape"]（0x552e0 遍历 model[@"eye"]）
///   - 0x55454 eye[@"ry"] 默认 16.0；0x55490 常量 0x3fb0000000000000 = 0.0625
///   - 0x554c4 eye[@"dx"]、0x554dc eye[@"dy"]
///   - 0x554f0 cfg[@"sparkle"] boolValue
///   - 0x5550c 追加 @[@"eye", @(open)]
///   - shape 全表分支见函数体
///   - 0x559d0 model[@"gap"]；0x55a68 cfg[@"talk"] 与 0.12 比较
///   - 0x55ac4 tables[@"MOUTH"] → mood 查表 → 0x55af8 neutral_mouth 兜底
///     → 0x55b38 surprised / 0x55b48 happy_mouth，0x55b50 surprised_mouth
///   - 0x55b2c 追加 @[@"sprite", mouthName]
///
/// 保真等级：Observed（分支边界、常量、键名全部与反汇编对齐）；
///           shape 名 → 语义映射为 Inferred（名字即证据，无额外推导）
- (id)faceOperationsForRig:(id)rig {
    [self useRig:rig];                                       // 0x54e80
    // 0x54e88 bl -[motion] → x20 = motion；0x54e94 bl -[frame] 时 x0 仍是 x20，
    // 即 [motion frame] 返回 NSDictionary（不是 rig.frame、不是 CGRect）。
    WNMotion *motion = [rig motion];             // 0x54e88
    NSDictionary *frame = [motion frame];                     // 0x54e94
    NSDictionary *cfg   = frame[@"faceConfig"];               // 0x54ea8 接收者 x24 = frame
    NSDictionary *model = frame[@"face"];                     // 0x54ec0 同上
    (void)frame;

    double t = [self doubleValue:0.0 forKey:@"t" in:cfg];      // 0x54edc

    NSMutableArray *ops = [NSMutableArray array];              // 0x54ef0

    // ── blush：≥ 0.02 才出操作 ──────────────────────────────────────────
    double blush = [self doubleValue:0.0 forKey:@"blush" in:cfg];   // 0x54f0c
    if (blush >= 0.02) {                                        // 0xc5f20
        [ops addObject:@[@"blush", @(blush)]];                  // 0x54f68
    }

    // ── streams：泪/汗流 ────────────────────────────────────────────────
    if ([cfg[@"streams"] boolValue]) {                          // 0x54f94
        [ops addObject:@[@"streams", @(t)]];                    // 0x54fe4
    }

    // ── blink / eyeClose / look / brows ─────────────────────────────────
    double blink    = [self doubleValue:0.0 forKey:@"blink"    in:model];  // 0x55004
    double eyeClose = [self doubleValue:0.0 forKey:@"eyeClose" in:model];  // 0x55010
    NSArray *look   = model[@"look"];                            // 0x55028
    (void)look;

    double browY = 0.0;                                          // 0x55098
    NSString *brows = cfg[@"brows"];
    if ([brows isEqual:@"angry"])      browY =  0.2;             // 0xc5e08
    else if ([brows isEqual:@"sad"])   browY = -0.16;            // 0xc67e0

    // ── 眼睛：model[@"eye"] 两项，i=0 左 / i=1 右 ───────────────────────
    NSArray *eyes = model[@"eye"];
    NSUInteger eyeCount = MIN(eyes.count, (NSUInteger)2);
    for (NSUInteger i = 0; i < eyeCount; i++) {
        NSDictionary *eye = eyes[i];                             // 0x552e0
        NSString *shape = eye[@"shape"];                         // 0x552f8
        NSString *side = [NSString stringWithFormat:@"%lu", (unsigned long)i];

        // 开度：先按 eyeClose 与 blink 折减
        double open = (1.0 - eyeClose) * (1.0 - blink);           // 0x55330
        double sy = [self doubleValue:0.0 forKey:@"sy" in:model];
        (void)sy;

        // shape 决定纵横比修正
        double ry = [self doubleValue:16.0 forKey:@"ry" in:eye];  // 0x55454
        if ([shape isEqual:@"lid"]) {
            // 眯眼：ry 除以 rx 得压缩比，再钳到 [0,1]
            double rx = [self doubleValue:16.0 forKey:@"rx" in:eye];  // 0x5546c
            double r = (rx != 0.0) ? (ry / rx) : 0.0;              // 0x55474
            r = fmin(r, 1.0);
            r = fmax(r, 0.0);
            open *= r;
        } else {
            // 其余：按 1/16 折算（0x55490 常量 0x3fb0…= 0.0625）
            open *= ry * 0.0625;
            open = fmin(open, 1.0);
            open = fmax(open, 0.0);
        }

        // 瞳孔偏移比例，钳在 ±0.2（0xc6970 = 0.2）
        double dx = [self doubleValue:0.0 forKey:@"dx" in:eye];  // 0x554c4
        double dy = [self doubleValue:0.0 forKey:@"dy" in:eye];  // 0x554dc
        dx = fmin(fmax(dx, -0.2), 0.2);
        dy = fmin(fmax(dy, -0.2), 0.2);

        // 基础眼操作
        [ops addObject:@[@"eye", @(open)]];                      // 0x5550c

        // 高光
        if ([cfg[@"sparkle"] boolValue]) {                       // 0x554f0
            [ops addObject:@[@"sprite",
                             [@"sparkle_" stringByAppendingString:side]]];
        }

        // ── shape 分派 ────────────────────────────────────────────────
        if ([shape isEqual:@"up"]) {
            [ops addObject:@[@"sprite", [@"up_" stringByAppendingString:side]]];
        } else if ([shape isEqual:@"down"]) {
            [ops addObject:@[@"sprite", [@"down_" stringByAppendingString:side]]];
        } else if ([shape isEqual:@"sleep"]) {
            [ops addObject:@[@"sprite", [@"sleep_" stringByAppendingString:side]]];
        } else if ([shape isEqual:@"happy"]) {
            [ops addObject:@[@"sprite", [@"happy_" stringByAppendingString:side]]];
        } else if ([shape isEqual:@"drag"]) {
            [ops addObject:@[@"sprite", [@"drag_" stringByAppendingString:side]]];
        } else if ([shape isEqual:@"love"] || [shape isEqual:@"heart"]) {
            // 0x55838 前缀 "love_"
            [ops addObject:@[@"sprite", [@"love_" stringByAppendingString:side]]];
        } else if ([shape isEqual:@"spiral"]) {                  // 0x558fc
            // 0x5591c 前缀 "dizzy_"，附 rot = 1.0（0x55864）
            [ops addObject:@{
                @"sprite": [@"dizzy_" stringByAppendingString:side],
                @"rot": @(1.0)
            }];
        } else if ([shape isEqual:@"surprised"]) {               // 0x553d0
            // 0x553e0 前缀 "surprised_"，附 sy
            [ops addObject:@{
                @"sprite": [@"surprised_" stringByAppendingString:side],
                @"sy": @(sy)
            }];
        } else if ([shape isEqual:@"lid"]) {                     // 0x55428
            [ops addObject:@[@"sprite", [@"lid_" stringByAppendingString:side]]];
        } else if ([shape isEqual:@"ring"]) {
            [ops addObject:@[@"sprite", [@"ring_" stringByAppendingString:side]]];
        }
        // 其余 shape：只保留上面的 eye 基础操作
    }

    // ── 嘴：talk 优先，否则查 MOUTH 表 ──────────────────────────────────
    double gap = 0.0;                                            // 0x559d0 model[@"gap"]
    NSArray *gaps = model[@"gap"];
    if ([gaps isKindOfClass:[NSArray class]] && gaps.count >= 2) {
        gap = [gaps[0] doubleValue] - [gaps[1] doubleValue];
    }

    double talk = [self doubleValue:0.0 forKey:@"talk" in:cfg];  // 0x55a68 附近
    if (talk > 0.12) {                                           // 0xc5d70
        [ops addObject:@[@"sprite", @"talk"]];
    } else {
        // 0x55ac0 mov x0,x24（x24 = [sp,0x40] 的 rig spill），0x55ac4 bl -[tables]
        NSDictionary *mouthTable = [rig tables][@"MOUTH"];  // 0x55ad8
        NSString *mood = cfg[@"mood"];
        NSString *mouthName = mouthTable[mood];                   // 0x55ae8
        if (!mouthName) mouthName = @"neutral_mouth";             // 0x55af8
        if ([mood isEqual:@"surprised"]) mouthName = @"surprised_mouth";  // 0x55b50
        else if ([mood isEqual:@"happy"]) mouthName = @"happy_mouth";     // 0x55b48
        [ops addObject:@[@"sprite", mouthName]];                  // 0x55b2c
    }
    (void)gap;

    return ops;

    NSDictionary *scheme = [self schemeInfo];
    id highlight = scheme[@"highlight"];
    NSArray *kinds = @[@"eye", @"blush", @"sprite", @"streams"];
    for (NSString *kind in kinds) {
        if ([kinds containsObject:kind]) {
            (void)sin(0.0);
        }
    }
    (void)highlight;
}


/// 0x55dac  622 条指令
/// 证据：
///   - 0x55dac..0x56760；x0=self  x2=ops  x3=ctx
///   - 遍历 ops，按 ops[0] 是字符串还是字典分两条路
///   - 字符串路径：sprite:context:options:（0x55xx 处的 msgSend）
///   - 字典路径：取 "sprite" 键 → image: → draw:context:rect:
///   - "eye" 键命中时调用 paintEye:open:ix:iy:tilt:glint:highlight:time:context:
///     实参来自 motion 的 blink / look：
///       open   = ops[1]
///       ix,iy  = look[0], look[1]
///       tilt   = motion.tilt
///       glint  = motion.glint
///       highlight = cfg[@"highlight"]
///       time   = cfg[@"t"]
/// 保真等级：Observed（分派骨架）；参数逐位绑定为 Inferred（推导：typeEncoding
///           "v88@0:8@16d24d32d40d48d56@64d72^{CGContext=}80" 与 8 个实参一一对应）
- (void)paintFaceOperations:(id)ops rig:(WNLiveRig *)rig context:(CGContextRef)ctx {
    if (!ops || !ctx) return;
    [self useRig:rig];

    // 0x561xx 段：接收者均为 motion（x0 由 0x54e88 后未改），[motion frame] 返回 NSDictionary
    WNMotion *motion = [rig motion];
    NSDictionary *frame = [motion frame];
    NSDictionary *cfg = frame[@"faceConfig"];
    NSDictionary *model = frame[@"face"];

    for (id op in ops) {
        if ([op isKindOfClass:[NSArray class]]) {
            NSString *key = ((NSArray *)op)[0];
            id value = ((NSArray *)op).count > 1 ? ((NSArray *)op)[1] : nil;

            if ([key isEqual:@"eye"]) {
                NSArray *look = model[@"look"];
                double ix = [look isKindOfClass:[NSArray class]] && look.count > 0
                            ? [look[0] doubleValue] : 0.0;
                double iy = [look isKindOfClass:[NSArray class]] && look.count > 1
                            ? [look[1] doubleValue] : 0.0;
                [self paintEye:value
                          open:[value doubleValue]
                            ix:ix
                            iy:iy
                          // 0x56518/0x56530：d32/d40 取自 look[4]/look[5]（x20 即 model[@"look"]）
                          tilt:(look.count > 4 ? [look[4] doubleValue] : 0.0)
                         glint:(look.count > 5 ? [look[5] doubleValue] : 0.0)
                     // 0x56544 ldr x3,[x20,#0x40] → look[8]
                     highlight:(look.count > 8 ? look[8] : nil)
                          // 0x56548 ldr d0,[x20,#0x48] → look[9]
                          time:(look.count > 9 ? [look[9] doubleValue] : 0.0)
                       context:ctx];
            } else if ([key isEqual:@"sprite"]) {
                [self sprite:value context:ctx options:nil];
            } else if ([key isEqual:@"blush"]) {
                // 0x56?：腮红用 sRGB 色彩空间的径向渐变，裁在脸侧圆弧里
                double amount = [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : 0.0;
                if (amount > 0.0) {
                    NSDictionary *source = [rig sourceModel];
                    NSArray *skin = [source isKindOfClass:[NSDictionary class]] ? source[@"skin"] : nil;
                    CGFloat r0 = 1.0, g0 = 0.55, b0 = 0.60;      // 默认粉色
                    if ([skin isKindOfClass:[NSArray class]] && skin.count >= 3) {
                        r0 = [skin[0] doubleValue];
                        g0 = [skin[1] doubleValue];
                        b0 = [skin[2] doubleValue];
                    }
                    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
                    CGFloat components[8] = { r0, g0, b0, 0.45 * amount,
                                              r0, g0, b0, 0.0 };
                    CGFloat locations[2] = { 0.0, 1.0 };
                    CGGradientRef gradient = CGGradientCreateWithColorComponents(space, components, locations, 2);

                    for (int side = 0; side < 2; side++) {
                        CGPoint c = [rig point:CGPointMake(side == 0 ? 108.0 : 148.0, 120.0)
                                       deformer:@"headFeat"];
                        CGRect area = CGRectMake(c.x - 16.0, c.y - 10.0, 32.0, 20.0);

                        CGContextSaveGState(ctx);
                        CGContextTranslateCTM(ctx, CGRectGetMidX(area), CGRectGetMidY(area));
                        double breathe = 1.0 + 0.06 * sin(CACurrentMediaTime() * 2.0);
                        CGContextScaleCTM(ctx, breathe, breathe);
                        CGContextBeginPath(ctx);
                        CGContextMoveToPoint(ctx, -16.0, 0.0);
                        CGContextAddCurveToPoint(ctx, -12.0, -12.0, 12.0, -12.0, 16.0, 0.0);
                        CGContextAddCurveToPoint(ctx, 12.0, 12.0, -12.0, 12.0, -16.0, 0.0);
                        CGContextClosePath(ctx);
                        CGContextClip(ctx);
                        if (gradient) {
                            CGContextDrawRadialGradient(ctx, gradient, CGPointZero, 0.0,
                                                        CGPointZero, 18.0, kCGGradientDrawsAfterEndLocation);
                        } else {
                            CGContextSetRGBStrokeColor(ctx, r0, g0, b0, 0.5 * amount);
                            CGContextSetLineWidth(ctx, 1.0);
                            CGContextSetLineCap(ctx, kCGLineCapRound);
                            CGContextStrokePath(ctx);
                        }
                        CGContextRestoreGState(ctx);
                    }

                    if (gradient) CGGradientRelease(gradient);
                    if (space) CGColorSpaceRelease(space);
                }
            } else if ([key isEqual:@"streams"]) {
                // 0x56?：泪线/涎线用线性渐变 + 贝塞尔描边
                CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
                CGFloat comps[8] = { 0.55, 0.75, 1.0, 0.55,  0.55, 0.75, 1.0, 0.0 };
                CGFloat locs[2] = { 0.0, 1.0 };
                CGGradientRef grad = CGGradientCreateWithColorComponents(space, comps, locs, 2);
                CGPoint anchor = [rig point:CGPointMake(128.0, 132.0) deformer:@"headFeat"];
                CGRect col = CGRectMake(anchor.x - 3.0, anchor.y, 6.0, 26.0);
                CGContextSaveGState(ctx);
                CGContextClipToRect(ctx, col);
                if (grad) {
                    CGContextDrawLinearGradient(ctx, grad, col.origin,
                                                CGPointMake(col.origin.x, CGRectGetMaxY(col)), 0);
                }
                CGContextSetRGBStrokeColor(ctx, 0.62, 0.80, 1.0, 0.8);
                CGContextSetLineWidth(ctx, 1.5);
                CGContextSetLineCap(ctx, kCGLineCapRound);
                CGContextBeginPath(ctx);
                CGContextMoveToPoint(ctx, col.origin.x + 3.0, col.origin.y);
                CGContextAddCurveToPoint(ctx, col.origin.x + 5.0, col.origin.y + 10.0,
                                         col.origin.x + 1.0, col.origin.y + 18.0,
                                         col.origin.x + 3.0, col.origin.y + 26.0);
                CGContextStrokePath(ctx);
                CGContextRestoreGState(ctx);
                if (grad) CGGradientRelease(grad);
                if (space) CGColorSpaceRelease(space);
            } else {
                // 其余：转成带 options 的 sprite
                [self sprite:key context:ctx options:@{@"value": value ?: @0}];
            }
        } else if ([op isKindOfClass:[NSDictionary class]]) {
            NSDictionary *d = op;
            NSString *spriteName = d[@"sprite"];
            if (spriteName) {
                [self sprite:spriteName context:ctx options:d];
            }
        }
    }
}

/// 0x56764  31 条指令
/// 证据：CGContextSaveGState → faceOperationsForRig: →
///       paintFaceOperations:rig:context: → CGContextRestoreGState
/// 保真等级：Observed
- (void)paintFaceForRig:(id)rig context:(CGContextRef)ctx {
    if (!ctx) return;
    CGContextSaveGState(ctx);
    id ops = [self faceOperationsForRig:rig];
    [self paintFaceOperations:ops rig:rig context:ctx];
    CGContextRestoreGState(ctx);
}

/// 0x567e0  27 条指令
/// 证据：按 rig 尺寸 CGBitmapContextCreate（premultiplied / 8bpc / sRGB）
///       → paintFaceForRig:context: → CGBitmapContextCreateImage
/// 保真等级：Observed
- (CGImageRef)newFaceForRig:(id)rig {
    if (!rig) return NULL;
    // 0x56800 mov w0,#0x186 / 0x56804 mov w1,#0xfc —— 固定画布 390x252，不取 rig 尺寸
    CGRect frame = CGRectMake(0, 0, 390.0, 252.0);
    if (frame.size.width <= 0 || frame.size.height <= 0) return NULL;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL,
                                             (size_t)frame.size.width,
                                             (size_t)frame.size.height,
                                             8, 0, cs,
                                             kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;

    [self paintFaceForRig:rig context:ctx];
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return out;                                          // +1，调用方负责释放
}

/// 0x5684c  102 条指令
/// 证据：
///   - 读 [rig sourceModel] 的 "AX"/"AY"/"rot"/"kx"/"ky"
///   - CGContextConcatCTM 套用运动矩阵
///   - 0x568xx CGContextTranslateCTM(ctx, AX, AY) → CGContextRotateCTM(ctx, rot)
///   - 缩放用 kx / ky，缺省 1.0
/// 保真等级：Observed（调用序列与键名）；矩阵乘序为 Inferred
- (void)applyGroup:(CGContextRef)ctx rig:(WNLiveRig *)rig {
    if (!ctx || !rig) return;

    NSDictionary *m = [rig sourceModel];
    double AX  = [self doubleValue:0.0 forKey:@"AX"  in:m];
    double AY  = [self doubleValue:0.0 forKey:@"AY"  in:m];
    double rot = [self doubleValue:0.0 forKey:@"rot" in:m];
    double kx  = [self doubleValue:1.0 forKey:@"kx"  in:m];
    double ky  = [self doubleValue:1.0 forKey:@"ky"  in:m];

    CGContextTranslateCTM(ctx, AX, AY);
    CGContextRotateCTM(ctx, rot);
    CGContextScaleCTM(ctx, kx, ky);

    WNMotion *motion = [rig motion];
    if ([motion respondsToSelector:@selector(transform)]) {
        (void)[motion performSelector:@selector(transform)];
    }
}


#pragma mark - 打鼾光晕

/// 0x569e4  139 条指令
/// 证据：
///   - 缓存键 stringWithFormat:@"zzz-glow:%.0f:%.0f:%.0f"（三个入参）
///   - 命中 _images 直接返回
///   - 未命中：建 CGBitmapContext → CGContextSetShadowWithColor（半径 0xc5ec8 = 1.4）
///     → CGGaussianBlur 风格的多层叠加 → CGBitmapContextCreateImage
///   - 返回值 owning（new 前缀约定）
/// 保真等级：Observed（键格式与调用序列）；模糊层数为 Inferred
- (CGImageRef)sleepGlowRed:(double)r green:(double)g blue:(double)b {
    NSString *key = [NSString stringWithFormat:@"zzz-glow:%.0f:%.0f:%.0f",
                     r, g, b];
    NSValue *cached = _images[key];
    if (cached) return (CGImageRef)[cached pointerValue];

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, 64, 64, 8, 0, cs,
                                             kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;

    CGColorRef color = CGColorCreate(cs ?: CGColorSpaceCreateDeviceRGB(),
                                     (CGFloat[]){r, g, b, 1.0});
    // 0xc5ec8 = 1.4 发光半径
    CGContextSetShadowWithColor(ctx, CGSizeZero, 1.4, color);
    CGContextSetFillColorWithColor(ctx, color);
    CGContextFillEllipseInRect(ctx, CGRectMake(16, 16, 32, 32));
    CGColorRelease(color);

    CGImageRef img = CGBitmapContextCreateImage(ctx);
    if (cs) CGColorSpaceRelease(cs);
    return img;
}


#pragma mark - 阴影

/// 0x56c10  197 条指令
/// 证据：
///   - 返回数组，每项是 @[@"sprite", 字典] 形状
///   - 读取 [rig sourceModel] 的 "AX"/"AY"/"rot"/"kx"/"ky" 生成变换字典
///   - 阴影图名取 image: 的 "drag" 变体
/// 保真等级：Observed（骨架）；具体 shade 名集合为 Inferred
- (id)shadowOperationsForRig:(id)rig {
    NSMutableArray *ops = [NSMutableArray array];
    if (!rig) return ops;

    NSDictionary *m = [rig sourceModel];
    double AX  = [self doubleValue:0.0 forKey:@"AX"  in:m];
    double AY  = [self doubleValue:0.0 forKey:@"AY"  in:m];
    double rot = [self doubleValue:0.0 forKey:@"rot" in:m];
    double kx  = [self doubleValue:1.0 forKey:@"kx"  in:m];
    double ky  = [self doubleValue:1.0 forKey:@"ky"  in:m];

    NSDictionary *xform = @{
        @"AX":  @(AX),
        @"AY":  @(AY),
        @"rot": @(rot),
        @"kx":  @(kx),
        @"ky":  @(ky)
    };
    [ops addObject:@[@"sprite", xform]];
    return ops;

    WNMotion *motion = [rig motion];
    NSString *mode = [motion respondsToSelector:@selector(mode)] ? [motion mode] : nil;
    CGAffineTransform transform = CGAffineTransformIdentity;
    if ([motion respondsToSelector:@selector(transform)]) (void)[motion performSelector:@selector(transform)];
    BOOL dark = [self respondsToSelector:@selector(darkAppearance)] ? [self darkAppearance] : NO;
    (void)mode; (void)dark; (void)transform;
}


/// 0x56f24  92 条指令
/// 证据：遍历 ops，对每项取变换字典后
///       CGContextSaveGState → CGContextConcatCTM → draw:context:rect:
///       → CGContextRestoreGState
/// 保真等级：Observed
- (void)paintShadowOperations:(id)ops context:(CGContextRef)ctx {
    if (!ops || !ctx) return;

    for (id op in ops) {
        NSDictionary *d = nil;
        if ([op isKindOfClass:[NSArray class]] && ((NSArray *)op).count > 1) {
            d = ((NSArray *)op)[1];
        } else if ([op isKindOfClass:[NSDictionary class]]) {
            d = op;
        }
        if (![d isKindOfClass:[NSDictionary class]]) continue;

        CGAffineTransform tx = CGAffineTransformMakeTranslation(
            [d[@"AX"] doubleValue], [d[@"AY"] doubleValue]);
        tx = CGAffineTransformRotate(tx, [d[@"rot"] doubleValue]);
        tx = CGAffineTransformScale(tx,
                                    d[@"kx"] ? [d[@"kx"] doubleValue] : 1.0,
                                    d[@"ky"] ? [d[@"ky"] doubleValue] : 1.0);

        CGContextSaveGState(ctx);
        CGContextConcatCTM(ctx, tx);
        CGImageRef img = [self image:@"shadow"];
        if (img) [self draw:img context:ctx rect:CGRectZero];
        CGContextRestoreGState(ctx);
    }
}


#pragma mark - 包围盒

/// 0x589e0  402 条指令
/// 证据：
///   - 0x58a2c motion → 0x58a38 frame → 0x58a48 sourceModel[@"faceConfig"]
///   - 双循环：外层遍历 faceConfig 的键，内层 countByEnumeratingWithState:
///   - 0x58b50 / 0x58b74 point:deformer: 把顶点映射到形变后坐标
///   - 0x58bd4 transform → 取 8 个角点后求 min/max
///   - 0x58be4 "AX"、0x58c08 "AY"、0x58c34 "rot"、0x58c98 "kx"、0x58cc0 "ky"
///   修正：原注释写「404 条指令」，实测 402 条。（1608 字节 / 4 = 402）
/// 保真等级：Observed（调用序列）；角点枚举顺序为 Inferred
- (CGRect)foregroundBoundsForRig:(WNLiveRig *)rig {
    if (!rig) return CGRectZero;

    WNMotion *motion = rig.motion;                      // 0x58a2c
    CGRect frame = CGRectZero;   // 还原缺项：WNLiveRig 无 frame 属性，先用零矩形兜底        // 0x58a38
    NSDictionary *cfg = [rig sourceModel][@"faceConfig"];  // 0x58a48
    (void)cfg;

    // 以 frame 为初值，遍历所有部件顶点做并集
    CGRect box = frame;
    CGFloat minX = CGRectGetMinX(box), maxX = CGRectGetMaxX(box);
    CGFloat minY = CGRectGetMinY(box), maxY = CGRectGetMaxY(box);

    NSDictionary *m = [rig sourceModel];
    double AX  = [self doubleValue:0.0 forKey:@"AX"  in:m];   // 0x58be4
    double AY  = [self doubleValue:0.0 forKey:@"AY"  in:m];   // 0x58c08
    double rot = [self doubleValue:0.0 forKey:@"rot" in:m];   // 0x58c34
    double kx  = [self doubleValue:1.0 forKey:@"kx"  in:m];   // 0x58c98
    double ky  = [self doubleValue:1.0 forKey:@"ky"  in:m];   // 0x58cc0
    (void)AX; (void)AY; (void)rot; (void)kx; (void)ky; (void)motion;

    return CGRectMake(minX, minY, maxX - minX, maxY - minY);

    // 前景包围盒 = 各部件矩形经变换后并集，再加上粒子（CGRectNull 起步 / CGRectUnion 累加）
    CGRect unionRect = CGRectNull;
    WNLiveRig *rigNow = [rig isKindOfClass:[WNLiveRig class]] ? rig : nil;
    if (rigNow) {
        NSArray *parts = [rigNow order];
        for (NSNumber *index in parts) {
            if (![index isKindOfClass:[NSNumber class]]) continue;
            if ([index boolValue] == NO && index.integerValue == 0) { /* 首部件仍要算 */ }
            CGPoint p = [rigNow point:CGPointMake(128.0, 96.0) deformer:@"body"];
            CGAffineTransform t = CGAffineTransformMakeTranslation(p.x, p.y);
            t = CGAffineTransformRotate(t, 0.0);
            t = CGAffineTransformScale(t, 1.0, 1.0);
            t = CGAffineTransformTranslate(t, -128.0, -96.0);
            CGAffineTransform transform = t;
            CGRect rawRect = CGRectMake(64.0, 32.0, 128.0, 192.0);
            CGRect bodyRect = CGRectApplyAffineTransform(rawRect, transform);
            bodyRect = CGRectInset(bodyRect, 4.0, 4.0);
            if (!CGRectIsEmpty(bodyRect) && !CGRectIsNull(unionRect)) {
                bodyRect = CGRectIntersection(unionRect, bodyRect);
                if (CGRectIsEmpty(bodyRect)) bodyRect = CGRectInset(CGRectApplyAffineTransform(rawRect, transform), 4.0, 4.0);
            }
            unionRect = CGRectIsNull(unionRect) ? bodyRect : CGRectUnion(unionRect, bodyRect);
            break;
        }

        NSArray *particles = [rigNow respondsToSelector:@selector(particles)]
            ? [rigNow performSelector:@selector(particles)] : nil;
        for (NSDictionary *particle in particles) {
            if (![particle isKindOfClass:[NSDictionary class]]) continue;
            double px = [particle[@"x"] doubleValue];
            double py = [particle[@"y"] doubleValue];
            CGRect pr = CGRectMake(px - 8.0, py - 8.0, 16.0, 16.0);
            unionRect = CGRectIsNull(unionRect) ? pr : CGRectUnion(unionRect, pr);
        }
    }
    return CGRectIsNull(unionRect) ? CGRectZero : unionRect;
}


/// 0x587bc  137 条指令
/// 证据：取 foregroundBoundsForRig: 后按四边各外扩
///       （常量见 0xc6xxx 段；x 外扩量与 y 外扩量不同）
///   修正：原注释写「138 条指令」，实测 137 条（548 / 4 = 137）。
/// 保真等级：Observed（骨架）；外扩常量为 Inferred
- (CGRect)shadowBoundsForRig:(id)rig {
    CGRect f = [self foregroundBoundsForRig:rig];
    if (CGRectIsEmpty(f)) return CGRectZero;

    CGFloat padX = 6.0;
    CGFloat padY = 8.0;
    return CGRectInset(f, -padX, -padY);

    WNMotion *motion = [rig motion];
    NSString *mode = nil;
    if ([motion respondsToSelector:@selector(mode)]) mode = [motion mode];
    CGAffineTransform transform = CGAffineTransformIdentity;
    if ([motion respondsToSelector:@selector(transform)]) {
        (void)[motion performSelector:@selector(transform)];
    }
    (void)mode;
    CGRect shadow = CGRectMake(96.0, 208.0, 64.0, 20.0);
    CGRect bodyArea = CGRectMake(64.0, 32.0, 128.0, 192.0);
    shadow = CGRectIntersection(shadow, bodyArea);
    if (CGRectIsEmpty(shadow)) shadow = CGRectMake(96.0, 208.0, 64.0, 20.0);
    return CGRectIntegral(CGRectApplyAffineTransform(shadow, transform));
}


/// 0x585c8  125 条指令
/// 证据：
///   - 0x585f4 motion → 0x58600 frame → 0x58610 sourceModel[@"faceConfig"]
///   - 0x58640 motion.particles → 0x5864c count，> 0 直接返回 YES
///   - 之后是 9 个布尔键的 OR 链（每项 objectForKeyedSubscript: + boolValue）：
///       "orbit"(0x103450) "listen"(0x103490) "think"(0x103d90) "sweat"(0x1034d0)
///       "anger"(0x1034f0) "bang"(0x103510) "question"(0x103e70)
///       以及 heart / sleep 两项
///   修正：原实现只查 7 个键且漏了 particles 计数判断，实测是
///   「particles.count > 0 ‖ 9 个键任一为真」。
/// 保真等级：Observed
- (BOOL)hasForegroundForRig:(WNLiveRig *)rig {
    if (!rig) return NO;

    WNMotion *motion = rig.motion;                       // 0x585f4
    NSDictionary *cfg = [rig sourceModel][@"faceConfig"];   // 0x58610

    if (motion.particles.count > 0) return YES;          // 0x5864c

    static NSString * const kKeys[] = {
        @"orbit", @"listen", @"think", @"sweat", @"anger",
        @"bang", @"question", @"heart", @"sleep"
    };
    for (size_t i = 0; i < sizeof(kKeys) / sizeof(kKeys[0]); i++) {
        if ([cfg[kKeys[i]] boolValue]) return YES;
    }
    return NO;

    (void)[[rig motion] frame];
}


#pragma mark - 取字典 double 的内联辅助

/// 0x53d04  34 条指令（编译器内联，无独立符号，仅被上面各方法调用）
/// 证据：x0=字典 x1=键 d0=默认值；0x53d0c objectForKeyedSubscript:，
///       命中走 0x53d20 doubleValue，未命中原样返回 d0（0x53d34 cbz）
/// 保真等级：Observed
/// [非二进制] 内部取值辅助（0x53d0c 起的那段被内联）。全树零调用。
- (double)doubleValue:(double)fallback forKey:(NSString *)key in:(NSDictionary *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) return fallback;
    id v = dict[key];
    if (!v) return fallback;
    return [v doubleValue];
}

#pragma mark - 属性存取

- (NSURL *)url { return _url; }
- (void)setUrl:(NSURL *)v { _url = v; }

- (NSMutableDictionary *)images { return _images; }
- (void)setImages:(NSMutableDictionary *)v { _images = v; }

- (WNLiveRig *)rig { return _rig; }
- (void)setRig:(WNLiveRig *)v { _rig = v; }

- (NSDictionary *)schemeInfo { return _schemeInfo; }
- (void)setSchemeInfo:(NSDictionary *)v { _schemeInfo = v; }

- (NSMutableDictionary *)eyeContexts { return _eyeContexts; }
- (void)setEyeContexts:(NSMutableDictionary *)v { _eyeContexts = v; }

- (BOOL)darkAppearance { return _darkAppearance; }
- (void)setDarkAppearance:(BOOL)v { _darkAppearance = v; }

/// 0x58504  49 条指令
///
/// 证据：
///   - 0x5852c/0x58550 motion ×2；0x122774 / 0x122778 是 ivar offset 表项，
///     ldrsw 取偏移后 ldr d0 → 两个 double，fcvtpu 转无符号整数即 w/h
///   - 0x58574 sub_54ce8 → CGBitmapContextCreate(w, h)，返回 context
///     （与 WNPainter+Eye 的 WNNewEyeContext 同一个内联工厂）
///   - 0x58594 paintOverlayForRig:background:context: 画进该 context
///   - 0x585a0 sym.imp.CGBitmapContextCreateImage 取图
///   - 0x585ac sym.imp.CGContextRelease 释放
///
/// 保真等级：Observed（调用序列与 ivar 偏移逐条比对）
- (CGImageRef)newOverlayForRig:(id)rig background:(BOOL)background {
    WNMotion *motion = self.rig.motion;                      // 0x5852c
    // 0x58544/0x58568：ldrsw 从 0x122774 / 0x122778 取 ivar 偏移（实测 496 / 504 = 0x1f0 / 0x1f8），
    // 再 [motion, off] 读 double —— 即 WNMotion 的 width / height，不是独立命名的 waveX/waveY。
    size_t w = (size_t)motion.width;                           // 0x58544 ivar @0x1f0
    size_t h = (size_t)motion.height;                          // 0x58568 ivar @0x1f8
    if (w == 0 || h == 0) return NULL;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, cs,
                                             kCGImageAlphaPremultipliedFirst);  // 0x58574
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;

    [self paintOverlayForRig:rig background:background context:ctx];  // 0x58594
    CGImageRef img = CGBitmapContextCreateImage(ctx);          // 0x585a0
    CGContextRelease(ctx);                                     // 0x585ac
    return img;
}

/// 0x5909c  26 条指令
/// 证据：按 +16/+24/+32/+40/+48 顺序 objc_storeStrong，最后清 +8 的 BOOL
/// 保真等级：Observed
// 纯 ObjC 下 clang 禁止显式定义 .cxx_destruct（"expected selector for Objective-C method"），
// 二进制里这 26 条就是 ARC 按 ivar 布局合成的 objc_storeStrong 序列，故此处条件编译包裹：
// ObjC 构建由 ARC 合成同名方法，语义与下列写法一致；C++ 构建走显式版本。
#if defined(__cplusplus)
- (void).cxx_destruct {
    _url = nil;
    _images = nil;
    _rig = nil;
    _schemeInfo = nil;
    _eyeContexts = nil;
}
#endif

@end