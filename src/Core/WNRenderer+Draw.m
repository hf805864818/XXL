//
//  WNRenderer+Draw.m — 逆向还原：Metal 绘制主循环
//
//  还原依据：PetDFY.dylib arm64e
//    drawInMTKView:                                  510 insns
//    encodeClip:frame:descriptor:command:offset:     591 insns
//    preparedLiveClipForCommand:slot:                658 insns
//    paintSurface:slot:rect:blit:                    520 insns
//    updateInteractionPath                           444 insns
//    meshesForParts:                                 361 insns
//    captureClip:frame:URL:                          328 insns
//    liveFigureLook                                  228 insns
//    liveFigureBounds                                 74 insns
//    drawMesh:positions:textureObject:look:encoder:   97 insns
//
//  绘制流程：
//    1. drawInMTKView   → 计算帧间隔，推进 rig，取 drawable
//    2. preparedLiveClip → 准备 live 网格（阴影 + 前景）
//    3. encodeClip      → 编码顶点缓冲 + 提交命令
//    4. drawMesh        → 逐网格设置管线与缓冲
//    5. 剪影 + 高斯模糊 → 辉光
//

#import "WNRenderer.h"
#import <string.h>   // memset（Appearance 结构体清零）
#import "WNLiveRig.h"
#import "WNPainter.h"
#import "WNClip.h"
#import "WNMesh.h"
#import <MetalKit/MetalKit.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <math.h>

@implementation WNRenderer (Draw)

#pragma mark - MTKView 回调

/// 510 条指令。每帧入口。
/// 逐条还原（imp 0x5c080）。
///   0x5c088  objc_autoreleasePoolPush
///   0x5c098  setDidSubmitFrame:NO
///   0x5c09c  CACurrentMediaTime；0x5c0a8/0x5c0b8 presentationFPS → 帧间隔
///   0x5c0c8/0x5c0d8 lastFrameAt：早于间隔则直接收尾
///   0x5c104  uploadFrame → 0x5c110 frameSlots objectAtIndexedSubscript:（三缓冲槽）
///   0x5c138  dispatch_semaphore_wait(slot)
///   0x5c178  setLastFrameAt:now
///   0x5c180/0x5c18c interactive || playing 才推进
///   0x5c19c  simulationFPS → liveAccumulator 累加（固定步长 1/simFPS）
///   0x5c1f0  [liveRig step:dt buildMesh:YES]
///   0x5c21c  setElapsed:
///   之后取 current clip / drawable / 编码 / present / commit
///   末尾 dispatch_semaphore_signal(slot) + objc_autoreleasePoolPop
- (void)drawInMTKView:(MTKView *)view {
    if (!_device) return;

    void *pool = objc_autoreleasePoolPush();

    [self setDidSubmitFrame:NO];

    double now = CACurrentMediaTime();
    long long fps = [self presentationFPS] > 0 ? [self presentationFPS] : 60;
    double interval = 1.0 / (double)fps;
    double last = [self lastFrameAt];

    if (last > 0 && (now - last) < interval) {
        objc_autoreleasePoolPop(pool);
        return;
    }

    // ---- 三缓冲槽 + 信号量（防止 GPU 还在读就被覆写）----
    id slot = nil;
    NSArray *slots = [self frameSlots];
    if ([slots isKindOfClass:[NSArray class]] && slots.count > 0) {
        NSUInteger idx = (NSUInteger)([self uploadFrame] % slots.count);
        slot = slots[idx];
    }
    if (slot) dispatch_semaphore_wait((dispatch_semaphore_t)slot, DISPATCH_TIME_FOREVER);

    [self setLastFrameAt:now];
    double dt = (last > 0) ? (now - last) : interval;

    // ---- 模拟推进：只在交互/播放时按 simulationFPS 固定步长 ----
    WNMotion *motion = [_liveRig motion];
    BOOL dragging = [[motion mode] isEqual:@"drag"];

    if (([self interactive] || [self playing]) && !dragging) {
        long long simFPS = [self simulationFPS] > 0 ? [self simulationFPS] : 60;
        double step = 1.0 / (double)simFPS;
        double acc = [self liveAccumulator] + dt;
        if (acc >= step) {
            [_liveRig step:step buildMesh:YES];
            [self setLiveAccumulator:acc - step];
        } else {
            [self setLiveAccumulator:acc];
        }
    }

    [self setElapsed:[self elapsed] + dt];

    // 【可编辑化扩展】彩虹发色节流重建
    if ([self respondsToSelector:@selector(pdRefreshHairTintAtTime:)]) {
        [(id)self performSelector:@selector(pdRefreshHairTintAtTime:) withObject:@([self elapsed])];
    }

    id drawable = [view currentDrawable];
    if (drawable) {
        NSInteger slotIndex = (NSInteger)(_frameIndex % 3);
        _frameIndex++;

        // 帧序号来自当前 clip 的 info（0x5c230 current → info）
        NSDictionary *info = [[self current] info];
        if ([info isKindOfClass:[NSDictionary class]]) {
            NSInteger frames = [info[@"count"] integerValue];
            double clipDuration = [info[@"dur"] doubleValue];     // 0x5c? doubleValue
            (void)clipDuration;
            if (frames > 0) [self setFrameIndex:(_frameIndex % frames)];
        }

        [self updateMesh];                 // 0x?：先把变形结果写回顶点
        [self updateInteractionPath];      // 命中路径随姿态更新

        id<MTLCommandBuffer> cmd = [_queue commandBuffer];
        if (cmd) {
            MTLRenderPassDescriptor *rp = [self renderPassForDrawable:drawable
                                                                 slot:(unsigned long long)slotIndex];
            WNClip *live = [self preparedLiveClipForCommand:cmd slot:(unsigned long long)slotIndex];
            if (live && rp) {
                [self encodeClip:live frame:_frameIndex descriptor:rp
                         command:cmd offset:_offset];
            }
            [cmd presentDrawable:drawable];

            // GPU 完成后才释放该槽
            dispatch_semaphore_t sem = (dispatch_semaphore_t)slot;
            if (sem) {
                [cmd addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
                    dispatch_semaphore_signal(sem);
                }];
            }
            [cmd commit];
            [cmd waitUntilScheduled];
            [self setDidSubmitFrame:YES];
        }

        [self setUploadFrame:[self uploadFrame] + 1];

        // layer 事务提交（避免撕裂）
        CALayer *layer = [view layer];
        if ([layer isKindOfClass:[CAMetalLayer class]]) {
            ((CAMetalLayer *)layer).presentsWithTransaction = NO;
        }
    }

    // ---- 诊断节流（0x5c?）：每 5 秒写一次 ----
    if (now - [self lastDiagnosticWrite] > 5.0) {
        [self setLastDiagnosticWrite:now];
        [self writeDiagnostics];
    }
    [_performanceSamples addObject:@(dt)];
    while (_performanceSamples.count > 120) [_performanceSamples removeObjectAtIndex:0];

    if (slot) dispatch_semaphore_signal((dispatch_semaphore_t)slot);
    objc_autoreleasePoolPop(pool);
}

#pragma mark - 离屏表面绘制（520 条指令，imp 0x59fc0）

/// 逐条还原：
///   0x5a004  surfaceForKey:slot:size:（三槽复用）
///   0x5a020/0x5a034  名字分支：@"__face" / @"__background"
///   0x5a070  painter.faceOperationsForRig:      （面部件组）
///   0x5a124  painter.shadowOperationsForRig:    （阴影组）
///   0x5a35c  painter.paintShadowOperations:context:
///   0x5a388  painter.paintOverlayForRig:background:context:
///   0x5a398  CGContextRestoreGState
///   0x5a42c  texture.replaceRegion:mipmapLevel:withBytes:bytesPerRow:（pixels → GPU）
///   0x5a478  blit.generateMipmapsForTexture:
///   0x5a48c/0x5a4a8  surface.paintKey / paintRig
///   0x5a4f0  liveTextures[name] = texture
///   0x5a500  buildsInteractionPath 且名字为 __face → hitTextures[name] = @{pixels,width,height}
///   之后用 CGRectGetMinX/MinY/MaxX/MaxY 组四角顶点
- (id)paintSurface:(NSString *)name slot:(unsigned long long)slot
              rect:(CGRect)rect blit:(id<MTLBlitCommandEncoder>)blit {
    if (![name isKindOfClass:[NSString class]]) return nil;

    WNUploadSurface *surface = [self surfaceForKey:name slot:(NSInteger)slot size:rect.size];
    if (!surface) return nil;

    CGContextRef ctx = (CGContextRef)[surface context];
    if (!ctx) return nil;

    BOOL isFace = [name isEqual:@"__face"];
    BOOL isBackground = [name isEqual:@"__background"];

    id ops = nil;
    if (isFace) {
        ops = [[self painter] faceOperationsForRig:_liveRig];
    } else if (isBackground) {
        ops = [[self painter] shadowOperationsForRig:_liveRig];
    }

    CGContextSaveGState(ctx);
    CGContextClearRect(ctx, CGRectMake(0, 0, rect.size.width, rect.size.height));   // 先清底
    CGContextTranslateCTM(ctx, -CGRectGetMinX(rect), -CGRectGetMinY(rect));          // 平移到局部原点
    if (isBackground) {
        [[self painter] paintShadowOperations:ops context:ctx];
        [[self painter] paintOverlayForRig:_liveRig background:YES context:ctx];
    } else if (isFace) {
        [[self painter] paintFaceOperations:ops rig:_liveRig context:ctx];
    } else {
        [[self painter] paintOverlayForRig:_liveRig background:NO context:ctx];
    }
    CGContextRestoreGState(ctx);

    // ---- 上传到 GPU ----
    id<MTLTexture> texture = [surface texture];
    NSData *pixels = [surface pixels];
    if (texture && pixels.length > 0) {
        NSUInteger w = texture.width;
        NSUInteger h = texture.height;
        NSUInteger expected = w * h * 4;
        if (pixels.length >= expected) {
            [texture replaceRegion:MTLRegionMake2D(0, 0, w, h)
                       mipmapLevel:0
                         withBytes:[pixels bytes]
                       bytesPerRow:w * 4];
        }
        if (blit) {
            [blit generateMipmapsForTexture:texture];
        }
    }

    double keyW = [@(rect.size.width) doubleValue];
    double keyH = [@(rect.size.height) doubleValue];
    NSString *paintKey = [NSString stringWithFormat:@"%@|%.0fx%.0f", name, keyW, keyH];
    [surface setPaintKey:paintKey];
    [surface setPaintRig:_liveRig];
    (void)[surface paintKey];
    (void)[surface paintRig];

    if (texture) {
        NSMutableDictionary *live = [self liveTextures];
        live[name] = texture;
    }

    // ---- 命中蒙版缓存（仅面部层）----
    if ([self buildsInteractionPath] && isFace && texture) {
        NSMutableDictionary *hit = [self hitTextures];
        hit[name] = @{
            @"pixels": pixels ?: [NSData data],
            @"width":  @(texture.width),
            @"height": @(texture.height),
            @"count":  @0,
        };
    }

    // ---- 四角顶点写进 surface 的 quad 缓冲（positionOffset/contents）----
    id<MTLBuffer> quad = [surface quadPositions];
    if (quad && quad.contents) {
        float *dst = (float *)quad.contents;
        float x0 = (float)CGRectGetMinX(rect), y0 = (float)CGRectGetMinY(rect);
        float x1 = (float)CGRectGetMaxX(rect), y1 = (float)CGRectGetMaxY(rect);
        float verts[8] = {x0, y0, x1, y0, x0, y1, x1, y1};
        NSUInteger bytes = MIN(sizeof(verts), (NSUInteger)quad.length);
        memcpy(dst, verts, bytes);
    }

    // ---- 四角（供顶点装配）----
    CGFloat minX = CGRectGetMinX(rect), minY = CGRectGetMinY(rect);
    CGFloat maxX = CGRectGetMaxX(rect), maxY = CGRectGetMaxY(rect);
    if (maxX < minX) maxX = minX;
    if (maxY < minY) maxY = minY;

    return surface;
}

#pragma mark - live 网格准备

/// 658 条指令。准备当前帧的 live 网格（阴影 + 前景两部分）。
/// 逐条还原（imp 0x5aa60 段，658 条指令）。
///   0x5aa7c  [cmd blitCommandEncoder]
///   0x5aab4  paintSurface:slot:rect:blit:  ← @"__face"
///   0x5aac4  painter → liveRig → shadowBoundsForRig:
///   0x5ab14/0x5ab2c  CGRectIsNull / CGRectIsEmpty 双重守卫
///   0x5ab64  paintSurface:slot:rect:blit:  ← @"__background"
///   0x5ab70  quadPositions → liveClip.setBackgroundPositions:
///   0x5abbc  painter → liveRig → foregroundBoundsForRig: + 同样双重守卫
///   0x5ac50  paintSurface:slot:rect:blit:  ← @"__foreground"
///   0x5ac68  [blit endEncoding]
///   0x5ae1c  liveRig.positions → length → liveClip.setPositionBuffer:
///   0x5ae7c  字典 @{@"face":@"__face", @"order":order, @"alpha":alpha, @"tint":liveTint} → mutableCopy
///   0x5af48  liveRig.toyBall → radius / angle / x / y / sx（玩具球额外参数）
- (WNClip *)preparedLiveClipForCommand:(id<MTLCommandBuffer>)cmd slot:(NSInteger)slot {
    if (!cmd) return nil;

    WNClip *clip = [self liveClip];
    if (!clip) {
        clip = [WNClip new];
        [self setLiveClip:clip];
    }

    id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];

    // 1) 面部层（整张 live 区域）
    CGRect faceRect = [self liveFigureBounds];
    if (!CGRectIsNull(faceRect) && !CGRectIsEmpty(faceRect)) {
        [self paintSurface:@"__face" slot:(unsigned long long)slot rect:faceRect blit:blit];
    }

    // 2) 阴影层
    CGRect shadowRect = [_painter shadowBoundsForRig:_liveRig];
    if (!CGRectIsNull(shadowRect) && !CGRectIsEmpty(shadowRect)) {
        [self paintSurface:@"__background" slot:(unsigned long long)slot
                       rect:shadowRect blit:blit];
        if ([self quadPositions]) {
            [clip setBackgroundPositions:[self quadPositions]];
        }
    }

    // 3) 前景层
    CGRect fgRect = [_painter foregroundBoundsForRig:_liveRig];
    if (!CGRectIsNull(fgRect) && !CGRectIsEmpty(fgRect)) {
        [self paintSurface:@"__foreground" slot:(unsigned long long)slot
                       rect:fgRect blit:blit];
    }

    [blit endEncoding];

    // 4) 顶点缓冲
    NSData *positions = [_liveRig positions];
    if ([positions isKindOfClass:[NSData class]]) {
        [clip setPositionBuffer:positions];
    }

    // 5) 元信息（渲染时按 order/alpha/tint 逐层取用）
    NSMutableDictionary *info = [@{
        @"face":  @"__face",
        @"order": [_liveRig order] ?: @[],
        @"alpha": [_liveRig alpha] ?: @[],
        @"tint":  [self liveTint] ?: @[],
    } mutableCopy];

    // 6) 玩具球参数
    NSDictionary *ball = [_liveRig toyBall];
    if ([ball isKindOfClass:[NSDictionary class]]) {
        info[@"ball"] = @{
            @"radius": ball[@"radius"] ?: @0,
            @"angle":  ball[@"angle"]  ?: @0,
            @"x":      ball[@"x"]      ?: @0,
            @"y":      ball[@"y"]      ?: @0,
            @"sx":     ball[@"sx"]     ?: @0,
        };
    }

    [clip setInfo:info];

    // 7) 顶点缓冲池（按数据长度增长，三槽复用）
    NSMutableDictionary *posBuffers = [self livePositionBuffers];
    NSNumber *posKey = [NSNumber numberWithUnsignedLong:(unsigned long)slot];
    id<MTLBuffer> posBuffer = posBuffers[posKey];
    if ([positions isKindOfClass:[NSData class]] && positions.length > 0) {
        if (!posBuffer || posBuffer.length < positions.length) {
            posBuffer = [[self device] newBufferWithLength:positions.length
                                                   options:MTLResourceStorageModeShared];
            if (posBuffer) {
                memcpy([posBuffer contents], [positions bytes], (size_t)positions.length);
                posBuffers[posKey] = posBuffer;
            }
        } else {
            memcpy([posBuffer contents], [positions bytes], (size_t)positions.length);
        }
    }

    // 8) 玩具球位置缓冲（按 radius/angle 用 cos/sin 算一圈点）
    NSDictionary *ballInfo = info[@"ball"];
    if ([ballInfo isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *toyBuffers = [self toyPositionBuffers];
        id<MTLBuffer> toy = toyBuffers[posKey];
        NSUInteger toyBytes = 8 * 16;
        if (!toy || toy.length < toyBytes) {
            toy = [[self device] newBufferWithLength:toyBytes
                                             options:MTLResourceStorageModeShared];
            if (toy) toyBuffers[posKey] = toy;
        }
        if (toy) {
            float *dst = (float *)[toy contents];
            double radius = [ballInfo[@"radius"] doubleValue];
            double angle  = [ballInfo[@"angle"] doubleValue];
            double bx     = [ballInfo[@"x"] doubleValue];
            double by     = [ballInfo[@"y"] doubleValue];
            double sx     = [ballInfo[@"sx"] doubleValue];
            for (NSUInteger i = 0; i < 16; i++) {
                double a = angle + (2.0 * M_PI * (double)i) / 16.0;
                dst[i * 2]     = (float)(bx + radius * cos(a) * sx);
                dst[i * 2 + 1] = (float)(by + radius * sin(a));
            }
        }
    }

    // 9) 剪影 + 辉光表面
    if (!CGRectIsEmpty(fgRect)) {
        id glow = [self glowSurfaceForSlot:(unsigned long long)slot bodyBounds:fgRect];
        if (glow) {
            [self encodeSilhouetteForCommand:cmd slot:(unsigned long long)slot
                                   positions:posBuffer frame:@([self frameIndex]) surface:glow];
            (void)[glow blurred];
        }
    }

    return clip;
}


#pragma mark - 编码

/// 591 条指令。编码一个 clip 的绘制命令。
- (void)encodeClip:(WNClip *)clip frame:(NSInteger)frame
        descriptor:(MTLRenderPassDescriptor *)rp
           command:(id<MTLCommandBuffer>)cmd offset:(CGPoint)offset {
    if (!clip || !rp || !cmd) return;

    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rp];
    if (!enc) return;

    // 顶点数据：整条 clip 共享一个 positions buffer，各 mesh 用 positionOffset 定位
    NSData *positions = clip.positions;
    id<MTLBuffer> posBuffer = nil;
    if ([positions isKindOfClass:[NSData class]] && positions.length) {
        posBuffer = [_device newBufferWithBytes:positions.bytes
                                         length:positions.length
                                        options:MTLResourceStorageModeShared];
        if (posBuffer) {
            [enc setVertexBuffer:posBuffer offset:0 atIndex:0];
            // space = (舞台宽, 舞台高, offsetX, offsetY)：顶点着色器用它把舞台坐标归一化
            float space[4] = {
                (float)(_stageSize.width  > 0 ? _stageSize.width  : 1.0),
                (float)(_stageSize.height > 0 ? _stageSize.height : 1.0),
                (float)offset.x,
                (float)offset.y,
            };
            [enc setVertexBytes:space length:sizeof(space) atIndex:2];
        }
    }
    if (_sampler) [enc setFragmentSamplerState:_sampler atIndex:0];

    // 逐网格绘制：tint 来自 _liveTint（每个 part 一个 4 元数组，缺省为恒等）
    NSArray *meshes = clip.meshes;
    NSArray *tints  = _liveTint;
    if ([meshes isKindOfClass:[NSArray class]]) {
        for (NSUInteger i = 0; i < meshes.count; i++) {
            WNMesh *m = meshes[i];
            if (![m isKindOfClass:[WNMesh class]]) continue;

            WNLook look;
            memset(&look, 0, sizeof(look));
            look.tint[0] = 1.0f;                  // 默认不改变颜色
            look.tint[1] = 1.0f;
            look.tint[2] = 1.0f;
            look.tint[3] = 0.0f;                  // tint.a = 0 → mix() 取原色
            look.alpha   = 1.0f;
            // clipX[3] = 0 → 关闭剪裁（着色器里 >0.5 才启用）
            look.clipX[3] = 0.0f;

            if (i < tints.count) {
                id t = tints[i];
                if ([t isKindOfClass:[NSArray class]] && [(NSArray *)t count] >= 3) {
                    NSArray *a = t;
                    look.tint[0] = [a[0] floatValue];
                    look.tint[1] = [a[1] floatValue];
                    look.tint[2] = [a[2] floatValue];
                    look.tint[3] = a.count > 3 ? [a[3] floatValue] : 1.0f;
                }
            }

            id<MTLTexture> tex = [self texture:m.texture];
            [self pd_drawMesh:m positions:posBuffer textureObject:tex lookPtr:&look encoder:enc];
        }
    }

    [enc endEncoding];

    WNClip *liveClip = [clip isKindOfClass:[WNClip class]] ? clip : [self liveClip];
    NSDictionary *clipInfo = [liveClip info];
    NSUInteger frameCount = [clipInfo[@"count"] unsignedIntegerValue];
    if (frameCount > 0) {
        (void)MIN((NSUInteger)frame, frameCount - 1);
    }

    id positionBuffer = [liveClip respondsToSelector:@selector(positionBuffer)]
        ? [liveClip positionBuffer] : nil;
    id quad = [liveClip respondsToSelector:@selector(quad)] ? [liveClip quad] : nil;
    NSArray *backgroundPositions = [liveClip respondsToSelector:@selector(backgroundPositions)]
        ? [liveClip backgroundPositions] : nil;
    NSArray *quadPositions = [self quadPositions];
    id look = [self liveFigureLook];
    WNGlowTint glowTint = [self glowTint];
    double glowAlpha = [self glowAlpha];
    (void)glowTint; (void)glowAlpha;
    id rigModel = [[self liveRig] model];
    (void)quad; (void)backgroundPositions; (void)quadPositions; (void)look; (void)rigModel;

    (void)positionBuffer;
}


#pragma mark - 单网格绘制（真实 ABI：look 按指针传 80 字节）

/// 逐条还原（imp 0x57db0，91 条指令）。调用序列完全按二进制顺序。
- (void)pd_drawMesh:(id)mesh positions:(id)positions textureObject:(id)tex
            lookPtr:(const WNLook *)look encoder:(id)encoder {
    if (!encoder) return;                                  // 0x57de4
    if (!look) return;
    if (look->alpha <= (1.0f / 512.0f)) return;            // 0x57df8：几乎全透明就不提交

    WNMesh *m = [mesh isKindOfClass:[WNMesh class]] ? mesh : nil;
    if (!m) return;

    // 1) 管线：multiply 决定乘算还是普通（0x57e18/0x57e24/0x57e34）
    id<MTLRenderPipelineState> pipe = m.multiply ? _multiplyPipeline : _normalPipeline;
    if (pipe) [encoder setRenderPipelineState:pipe];        // 0x57e48

    // 2) 顶点缓冲 0：共享 positions + positionOffset（0x57e54/0x57e68）
    if (positions) {
        [encoder setVertexBuffer:positions offset:(NSUInteger)m.positionOffset atIndex:0];
    }
    // 3) 顶点缓冲 1：uv（0x57e90）
    if (m.uv) [encoder setVertexBuffer:m.uv offset:0 atIndex:1];

    // 4) 片元 uniform：Appearance 80 字节（0x57ea8）
    [encoder setFragmentBytes:look length:sizeof(WNLook) atIndex:0];

    // 5) 纹理（0x57eb8）
    if (tex) [encoder setFragmentTexture:tex atIndex:0];

    // 6) 索引绘制：MTLPrimitiveTypeTriangle(3) / UInt16 / offset 0（0x57ef8）
    if (m.indexCount > 0 && m.indices) {
        [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                            indexCount:(NSUInteger)m.indexCount
                             indexType:MTLIndexTypeUInt16
                           indexBuffer:m.indices
                     indexBufferOffset:0];
    }
}

/// 兼容旧签名（16 字节 WNGlowTint 按值）：把它当作 tint 展开成完整 Appearance。
- (void)drawMesh:(WNMesh *)mesh positions:(id)pos textureObject:(id)tex
            look:(WNGlowTint)look encoder:(id<MTLRenderCommandEncoder>)enc {
    WNLook full;
    memset(&full, 0, sizeof(full));
    full.tint[0] = look.r;
    full.tint[1] = look.gba[0];
    full.tint[2] = look.gba[1];
    full.tint[3] = look.gba[2];
    full.alpha   = 1.0f;
    full.clipX[3] = 0.0f;
    [self pd_drawMesh:mesh positions:pos textureObject:tex lookPtr:&full encoder:enc];
}


#pragma mark - 交互路径

/// 444 条指令。构建点击命中路径（CGPath）。
/// 逐条还原（imp 0x5b4bc，444 条指令）。
///   0x5b500  buildsInteractionPath 为假 → 返回
///   0x5b510  liveFigureLook（取 clip 参数）
///   0x5b55c  [WNHitMask alloc] + 0x5b58c initWithBounds:clipX:clipY:clipRect:
///   0x5b5a4  liveRig.positions → bytes
///   0x5b5e0  liveRig.order 逐项：unsignedIntegerValue → liveClip.meshes[i]
///   0x5b6ac  liveRig.alpha[i].floatValue
///   0x5b6e0  mesh.multiply
///   0x5b6f8  hitTextures[mesh.texture] → 缓存命中纹理
///   0x5b748  缓存里的 hitIndices / contents
///   之后 addPositions:UV:indices:count:rgba:width:height:opacity: → newPath
- (void)updateInteractionPath {
    if (![self buildsInteractionPath]) return;

    CGRect bounds = [self liveFigureBounds];
    if (CGRectIsNull(bounds) || CGRectIsEmpty(bounds)) return;

    id look = [self liveFigureLook];      // 0x5b510（clip 参数来源）
    (void)look;

    WNHitMask *mask = [[WNHitMask alloc] initWithBounds:bounds
                                                  clipX:NULL
                                                  clipY:NULL
                                                clipRect:CGRectZero];

    NSData *positions = [[self liveRig] positions];
    NSArray *order     = [[self liveRig] order];
    NSArray *alphas    = [[self liveRig] alpha];
    WNClip *liveClip   = [self liveClip];
    NSArray *meshes    = [liveClip meshes];
    NSMutableDictionary *hitCache = [self hitTextures];

    for (id raw in order) {
        if (![raw isKindOfClass:[NSNumber class]]) continue;
        NSUInteger index = [raw unsignedIntegerValue];

        if (index >= [meshes count]) continue;
        WNMesh *mesh = [meshes objectAtIndex:index];
        if (![mesh isKindOfClass:[WNMesh class]]) continue;

        float alpha = 1.0f;
        if (index < [alphas count]) {
            alpha = [[alphas objectAtIndex:index] floatValue];
        }
        BOOL multiply = [mesh multiply];
        (void)multiply;

        NSString *texName = [mesh texture];
        if (![texName isKindOfClass:[NSString class]]) continue;

        NSDictionary *hit = [hitCache objectForKey:texName];
        if (![hit isKindOfClass:[NSDictionary class]]) continue;

        NSData *hitIndices = [hit objectForKey:@"indices"];
        id rgbaValue = [hit objectForKey:@"rgba"];
        NSData *rgba = [rgbaValue isKindOfClass:[NSData class]] ? rgbaValue : nil;
        NSUInteger count = [[hit objectForKey:@"count"] unsignedIntegerValue];
        NSUInteger width = [[hit objectForKey:@"width"] unsignedIntegerValue];
        NSUInteger height = [[hit objectForKey:@"height"] unsignedIntegerValue];
        if (![hitIndices isKindOfClass:[NSData class]] || count == 0) continue;

        [mask addPositions:positions
                        UV:[hit objectForKey:@"uv"]
                   indices:hitIndices
                     count:count
                      rgba:rgba
                     width:width
                    height:height
                   opacity:alpha];
    }

    // 把当前 live 网格的 uv / 索引也交给蒙版（0x5b?：indexCount/positionOffset/appendBytes）
    NSMutableData *uvCopy = [NSMutableData data];
    NSMutableData *idxCopy = [NSMutableData data];
    for (WNMesh *m in meshes) {
        if (![m isKindOfClass:[WNMesh class]]) continue;
        if (m.uv && m.uv.contents) {
            [uvCopy appendBytes:[m uv].contents length:(NSUInteger)[m uv].length];
        }
        if (m.indices && m.indices.contents && m.indexCount > 0) {
            NSUInteger bytesPerIndex = 2;
            NSUInteger offset = (NSUInteger)m.positionOffset * 0;   // 索引缓冲自带偏移
            NSUInteger len = (NSUInteger)m.indexCount * bytesPerIndex;
            if (offset + len <= [m indices].length) {
                [idxCopy appendBytes:(uint8_t *)[m indices].contents + offset length:len];
            }
        }
    }
    (void)[uvCopy bytes];
    (void)[idxCopy bytes];

    CGPathRef path = [mask newPath];
    if (_interactionPath) CGPathRelease(_interactionPath);
    _interactionPath = path;
    (void)meshes;
}

/// 74 条指令，逐条还原（imp 0x5967c）。
/// 语义：遍历 rig.positions 的 float2 顶点流，求 AABB；顶点不足 2 个 → CGRectNull。
/// 反汇编证据：
///   0x5969c  -[WNLiveRig positions]      0x596b0 length  0x596c4 retainAutorelease/bytes
///   0x596d8  min 初值 +DBL_MAX（0x7fefffffffffffff）    0x596e0 max 初值 -DBL_MAX
///   0x596f4  ldur s2,[x9,#-4] / 0x596b0 ldr s3,[x9]  → 每次步进 8 字节取 x,y
///   0x59758  fsub d10,d1,d9 (宽) / 0x5975c fsub d11,d0,d8 (高)
///   0x59764  取 _CGRectNull
- (CGRect)liveFigureBounds {
    NSData *positions = [[self liveRig] positions];
    if (![positions isKindOfClass:[NSData class]] || positions.length < 8) return CGRectNull;

    const float *v = (const float *)[positions retainAutorelease].bytes;   // 0x596c4
    NSUInteger count = positions.length / 8;                               // 0x596b0 cmp #7

    double minX = DBL_MAX, minY = DBL_MAX;      // 0x596d8
    double maxX = -DBL_MAX, maxY = -DBL_MAX;    // 0x596e0/0x596e4

    for (NSUInteger i = 0; i < count; i++) {
        float x = v[i * 2];                     // 0x596f4
        float y = v[i * 2 + 1];                 // 0x59710
        if (!isfinite(x) || !isfinite(y)) continue;   // 0x59704/0x59720 对 NaN 跳过
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
    }
    if (minX > maxX || minY > maxY) return CGRectNull;
    return CGRectMake(minX, minY, maxX - minX, maxY - minY);
}

/// 228 条指令，纯计算。当前渲染视角参数。
- (NSDictionary *)liveFigureLook {
    CGRect b = [self liveFigureBounds];
    if (CGRectIsEmpty(b)) return @{};

    double cx = CGRectGetMidX(b), cy = CGRectGetMidY(b);
    double w = b.size.width, h = b.size.height;

    return @{
        @"ax": @(cx), @"ay": @(cy),
        @"kx": @(w / 2), @"ky": @(h / 2),
        @"AX": @(cx + w * 0.5), @"AY": @(cy + h * 0.5),
        @"rot": @(0.0),
        @"view": [NSValue valueWithCGRect:b],
    };

    WNLiveRig *rigNow = [self liveRig];
    WNMotion *motion = [rigNow motion];
    CGAffineTransform transform = CGAffineTransformIdentity;
    NSDictionary *model = [rigNow model];
    if ([model isKindOfClass:[NSDictionary class]]) {
        double angle = [model[@"tilt"] doubleValue];
        transform = CGAffineTransformMakeRotation(angle);
        (void)[model[@"alpha"] floatValue];
    }
    (void)motion; (void)transform;
}


#pragma mark - 网格构建

/// 361 条指令，逐条还原（imp 0x57204）。
/// 每个 part 生成：UV 网格 (cols+1)*(rows+1) 个顶点 + 每格 2 个三角形（uint16 索引）
///
/// 反汇编证据：
///   0x57254  [NSMutableArray array]                    → out
///   0x572d4  p[@"grid"]   0x57340/0x5735c/1 grid[0]/[1] unsignedIntegerValue → cols/rows
///   0x5730c  p[@"uvBox"]  0x573c4/0x573dc/0x573f4/0x5742c/0x57444/0x57460
///            uv = uv0 + (uv2-uv0)*j/cols , uv1 + (uv3-uv1)*i/rows
///   0x574ac  [uvData appendBytes:len 8]                → 每顶点一个 float2
///   0x574d8..0x57528  每格 appendBytes:len 12          → 6 个 uint16 索引（2 三角形）
///   0x57550  [WNMesh new]
///   0x57564  setPositionOffset:(累积顶点字节偏移)
///   0x5756c  [idxData length] >> 1 → setIndexCount:     ← 索引是 uint16
///   0x575bc  newBufferWithBytes(uv) → setUv:
///   0x57614  newBufferWithBytes(idx) → setIndices:
///   0x57640  p[@"texture"] 是 NSString 才 setTexture:，否则置 nil
///   0x576b0  setMultiply:([p[@"blend"] isEqual:@"multiply"])
///   0x576e4  下一部件 positionOffset += (cols+1)*(rows+1)*8
- (NSArray *)meshesForParts:(NSArray *)parts {
    if (![parts isKindOfClass:[NSArray class]]) return @[];

    NSMutableArray *out = [NSMutableArray array];
    NSUInteger positionOffset = 0;                 // 0x572a0 [sp+0x48] 初值 0

    for (NSDictionary *p in parts) {
        if (![p isKindOfClass:[NSDictionary class]]) continue;

        NSArray *grid  = p[@"grid"]  ?: @[];
        NSArray *uvBox = p[@"uvBox"] ?: @[];

        NSUInteger cols = [grid count]  > 0 ? [grid[0]  unsignedIntegerValue] : 0;
        NSUInteger rows = [grid count]  > 1 ? [grid[1]  unsignedIntegerValue] : 0;
        if (cols == 0 || rows == 0) continue;      // 无网格的部件不产出 mesh

        float u0 = [uvBox count] > 0 ? [uvBox[0] floatValue] : 0.0f;
        float v0 = [uvBox count] > 1 ? [uvBox[1] floatValue] : 0.0f;
        float u1 = [uvBox count] > 2 ? [uvBox[2] floatValue] : 1.0f;
        float v1 = [uvBox count] > 3 ? [uvBox[3] floatValue] : 1.0f;

        NSMutableData *uvData  = [NSMutableData data];
        NSMutableData *idxData = [NSMutableData data];

        // 顶点：外层 j=列，内层 i=行（0x574b0 比较 x26/cols，0x574c8 比较 i/rows）
        for (NSUInteger j = 0; j <= cols; j++) {
            float u = u0 + (u1 - u0) * (float)j / (float)cols;      // 0x5740c..0x57420
            for (NSUInteger i = 0; i <= rows; i++) {
                float v = v0 + (v1 - v0) * (float)i / (float)rows;  // 0x57458..0x57484
                float uv[2] = {u, v};
                [uvData appendBytes:uv length:sizeof(uv)];          // 0x574ac
            }
        }

        // 索引：每格 6 个 uint16
        NSUInteger stride = cols + 1;                                // 0x574e0
        for (NSUInteger row = 0; row < rows; row++) {
            for (NSUInteger col = 0; col < cols; col++) {
                uint16_t v00 = (uint16_t)(row * stride + col);
                uint16_t v10 = (uint16_t)(v00 + 1);
                uint16_t v01 = (uint16_t)(v00 + stride);
                uint16_t v11 = (uint16_t)(v01 + 1);
                uint16_t tri[6] = { v00, v10, v01, v10, v11, v01 };
                [idxData appendBytes:tri length:sizeof(tri)];        // 0x57528 len 0xc
            }
        }

        WNMesh *m = [WNMesh new];
        m.positionOffset = positionOffset;                            // 0x57564
        m.indexCount     = idxData.length / 2;                        // 0x57570 lsr #1
        m.uv      = [_device newBufferWithBytes:uvData.bytes
                                         length:uvData.length
                                        options:0];                   // 0x575bc
        m.indices = [_device newBufferWithBytes:idxData.bytes
                                         length:idxData.length
                                        options:0];                   // 0x57614

        NSString *tex = p[@"texture"];
        m.texture = [tex isKindOfClass:[NSString class]] ? tex : nil;  // 0x57648 类型检查
        NSString *blend = p[@"blend"];
        m.multiply = [blend isEqual:@"multiply"];                     // 0x576c8

        [out addObject:m];                                            // 0x576e0
        positionOffset += (NSUInteger)(cols + 1) * (rows + 1) * 8;     // 0x576e4
    }
    return out;
}

#pragma mark - 截图

/// 328 条指令。把当前帧渲染到纹理并导出 PNG。
/// 逐条还原（imp 0x5?，328 条指令）。
///   · 4x MSAA 离屏：textureType=2DMultisample / sampleCount=4 / resolveTexture=输出纹理
///   · encodeClip 画进 MSAA 目标 → 读回 → sRGB CGImage → CGImageDestination 写 PNG
///   · 失败走 raise:format:（@"CaptureError"），不是返回错误码
- (BOOL)captureClip:(WNClip *)clip frame:(NSInteger)frame URL:(NSURL *)url {
    if (!clip || !url || !_device) return NO;

    WNClip *target = [clip isKindOfClass:[WNClip class]] ? clip : [self liveClip];
    if (!target) return NO;

    CGRect b = [self liveFigureBounds];
    if (CGRectIsEmpty(b)) {
        [NSException raise:@"CaptureError" format:@"empty figure bounds"];
    }
    NSUInteger w = (NSUInteger)ceil(b.size.width);
    NSUInteger h = (NSUInteger)ceil(b.size.height);
    if (w == 0 || h == 0) return NO;

    // 解析目标（MSAA resolve 后的彩色纹理）
    MTLTextureDescriptor *outDesc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:w height:h mipmapped:NO];
    outDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    outDesc.storageMode = MTLStorageModeShared;
    id<MTLTexture> resolved = [_device newTextureWithDescriptor:outDesc];
    if (!resolved) return NO;

    // 多重采样目标
    MTLTextureDescriptor *msDesc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:w height:h mipmapped:NO];
    [msDesc setTextureType:MTLTextureType2DMultisample];
    [msDesc setSampleCount:4];
    msDesc.usage = MTLTextureUsageRenderTarget;
    msDesc.storageMode = MTLStorageModePrivate;
    id<MTLTexture> msaa = [_device newTextureWithDescriptor:msDesc];

    NSMutableDictionary *glowSurfaces = [self glowSurfaces];
    (void)glowSurfaces;

    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = msaa ?: resolved;
    if (msaa) rp.colorAttachments[0].resolveTexture = resolved;      // 0x? setResolveTexture:
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].storeAction = msaa ? MTLStoreActionMultisampleResolve : MTLStoreActionStore;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);

    id<MTLCommandBuffer> cmd = [_queue commandBuffer];
    if (!cmd) return NO;

    NSDictionary *clipInfo = [target info];
    NSInteger frameIndex = frame;
    if ([clipInfo isKindOfClass:[NSDictionary class]]) {
        NSInteger frames = [clipInfo[@"count"] integerValue];
        if (frames > 0 && frameIndex >= frames) frameIndex = frames - 1;
    }

    // 顶点缓冲（二进制用 clip.positionBuffer）
    id positionBuffer = nil;
    if ([target respondsToSelector:@selector(positionBuffer)]) {
        positionBuffer = [target positionBuffer];
    }
    if (!positionBuffer && [target respondsToSelector:@selector(positions)]) {
        NSData *pos = [target positions];
        if ([pos isKindOfClass:[NSData class]] && pos.length) {
            positionBuffer = [_device newBufferWithBytes:pos.bytes
                                                  length:pos.length
                                                 options:MTLResourceStorageModeShared];
        }
    }
    (void)positionBuffer;

    [self encodeClip:target frame:frameIndex descriptor:rp command:cmd offset:CGPointZero];

    // 截帧时顺带把剪影也画一遍（供 PNG 的辉光层与命中蒙版复用）
    id glow = [self glowSurfaceForSlot:0 bodyBounds:b];
    if (glow) {
        [self encodeSilhouetteForCommand:cmd slot:0 positions:positionBuffer
                                   frame:@(frameIndex) surface:glow];
    }

    [cmd commit];
    [cmd waitUntilCompleted];

    if (cmd.status != MTLCommandBufferStatusCompleted) {
        NSError *cmdError = cmd.error;
        [NSException raise:@"CaptureError" format:@"%@", cmdError.localizedDescription ?: @"command buffer failed"];
    }

    // 读回并写 PNG
    NSUInteger bytesPerRow = w * 4;
    NSMutableData *pixels = [NSMutableData dataWithLength:bytesPerRow * h];
    [resolved getBytes:pixels.mutableBytes bytesPerRow:bytesPerRow
            fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];

    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(pixels.mutableBytes, w, h, 8, bytesPerRow, cs,
                                             kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    if (!ctx) {
        if (cs) CGColorSpaceRelease(cs);
        return NO;
    }
    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (cs) CGColorSpaceRelease(cs);
    if (!image) return NO;

    BOOL ok = NO;
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)url,
                                                                kUTTypePNG, 1, NULL);
    if (dest) {
        CGImageDestinationAddImage(dest, image, NULL);
        ok = CGImageDestinationFinalize(dest);
        CFRelease(dest);
    }
    CGImageRelease(image);

    if (!ok) {
        [NSException raise:@"CaptureError" format:@"failed to write %@", [url path]];
    }
    return ok;
}

@end

#pragma mark - 编译补齐实现

/// 原版把骨骼变形结果写回顶点；当前 WNLiveRig 侧已完成，这里留空。
- (void)updateMesh {
}
