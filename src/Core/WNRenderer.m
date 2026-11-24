//
//  WNRenderer.m — 逆向还原实现（基础层）
//
//  还原依据：PetDFY.dylib arm64e，121 个方法共 6981 条指令
//  本文件：初始化 / 纹理加载 / 渲染管线 / 访问器（约 100 个方法）
//  另见：WNRenderer+Draw.m（drawInMTKView / encodeClip / preparedLiveClip）
//
//  ivar 布局（instanceSize=384，48 个字段）：
//    +8   CGPathRef _interactionPath    +16 playing  +17 interactive
//    +18  responsiveInteraction         +19 darkAppearance
//    +20  didSubmitFrame                +21 buildsInteractionPath
//    +24  float glowAlpha               +32 id<MTLDevice> device
//    +40  NSArray * catalog             +48 long long frameIndex
//    +56  long long simulationFPS       +64 long long presentationFPS
//    +72  WNLiveRig * liveRig           +80 NSURL * resourceURL
//    +88  id<MTLCommandQueue> queue
//    +96  normalPipeline   +104 multiplyPipeline   +112 silhouettePipeline
//    +120 id<MTLSamplerState> sampler   +128 MTKTextureLoader * loader
//    +136 NSCache * textures            +144 NSMutableDictionary * liveTextures
//    +152 NSMutableSet * failedTextures +160 NSMutableDictionary * hitTextures
//    +168 WNClip * current              +176 WNMesh * quad
//    +184 id<MTLBuffer> quadPositions   +192 lastFrameAt  +200 elapsed
//    +208 liveAccumulator               +216 WNPainter * painter
//    +224 WNClip * liveClip             +232 NSMutableArray * performanceSamples
//
//  着色器：Whale.metal（运行时 newLibraryWithSource: 编译）
//  错误键：MetalUnavailable / No Metal device / PipelineError / ShaderError
//  诊断文件：frame-profile.json
//

#import "WNRenderer.h"
#import "WNLiveRig.h"
#import "WNPainter.h"
#import "WNClip.h"
#import "WNMesh.h"
#import <MetalKit/MetalKit.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>

@implementation WNRenderer

#pragma mark - 初始化

/// 686 条指令。加载 Whale.metal 并编译三条管线。
/// 逐条还原（imp 0x563ac）。
///   0x56408  [super init]
///   0x5641c  存 _resourceURL（+0x50）
///   0x56420  MTLCreateSystemDefaultDevice → +0x20；为空则 0x56450 raise:@"MetalUnavailable"/@"No Metal device"
///   0x56458  newCommandQueue → +0x58
///   0x56478  [[MTKTextureLoader alloc] initWithDevice:] → +0x80
///   0x56490  [NSCache new] → +0x88，0x564a8 setTotalCostLimit:0x4000000（64 MB）
///   0x564b0/0x564c4/0x564dc  _liveTextures / _failedTextures / _hitTextures（+0x90/+0x98/+0xa0）
///   0x564f0  liveOnly 为真 → _catalog = @[]；否则读 manifest.json → _catalog = manifest[@"clips"]（+0x28）
///   0x5656c  Whale.metal：resourceURL 拼接 → defaultManager fileExistsAtPath:
///            ├─ 存在 → stringWithContentsOfURL:encoding:4
///            └─ 不存在 → [NSBundle mainBundle] URLForResource:@"Whale" withExtension:@"metal"
///   0x5664c  newLibraryWithSource:options:error:；失败 → raise:@"ShaderError" format:@"%@"
///   0x5668c 起：逐条建渲染管线（见 buildPipelinesWithLibrary:）
- (instancetype)initWithResourceURL:(NSURL *)url liveOnly:(BOOL)liveOnly {
    self = [super init];
    if (!self) return nil;

    _resourceURL = url;

    _device = MTLCreateSystemDefaultDevice();
    if (!_device) {
        [NSException raise:@"MetalUnavailable" format:@"No Metal device"];
    }
    _queue = [_device newCommandQueue];

    _loader = [[MTKTextureLoader alloc] initWithDevice:_device];

    _textures = [NSCache new];
    [_textures setTotalCostLimit:64 * 1024 * 1024];      // 0x4000000

    _liveTextures   = [NSMutableDictionary dictionary];
    _failedTextures = [NSMutableSet set];
    _hitTextures    = [NSMutableDictionary dictionary];

    _performanceSamples = [NSMutableArray array];
    _simulationFPS = 60;
    _presentationFPS = 60;
    _glowAlpha = 1.0f;
    _buildsInteractionPath = YES;

    if (liveOnly) {
        _catalog = @[];                                   // 0x56508
    } else {
        NSURL *manifestURL = [url URLByAppendingPathComponent:@"manifest.json"];
        NSDictionary *manifest = WNLoadClipJSON(manifestURL);   // 0x56528（同 loadClip 的读取器）
        id clips = [manifest isKindOfClass:[NSDictionary class]] ? manifest[@"clips"] : nil;
        _catalog = [clips isKindOfClass:[NSArray class]] ? clips : @[];
    }

    // ---- Whale.metal ----
    NSURL *shaderURL = [url URLByAppendingPathComponent:@"Whale.metal"];
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:[shaderURL path]];
    if (!exists) {
        shaderURL = [[NSBundle mainBundle] URLForResource:@"Whale" withExtension:@"metal"];
    }

    NSString *src = nil;
    if (shaderURL) {
        src = [NSString stringWithContentsOfURL:shaderURL
                                       encoding:NSUTF8StringEncoding     // 4
                                          error:NULL];
    }
    if (src.length) {
        NSError *err = nil;
        id<MTLLibrary> lib = [_device newLibraryWithSource:src options:nil error:&err];
        if (!lib) {
            [NSException raise:@"ShaderError" format:@"%@", err];
            return nil;
        }

        // 0x5668c 起：二进制在 init 内逐条建三套管线（normal / multiply / silhouette）
        id<MTLFunction> vfn = [lib newFunctionWithName:@"whaleVertex"];
        id<MTLFunction> ffn = [lib newFunctionWithName:@"whaleFragment"];
        id<MTLFunction> sfn = [lib newFunctionWithName:@"whaleSilhouetteFragment"];
        if (!vfn || !ffn) {
            [NSException raise:@"ShaderError" format:@"missing shader functions"];
            return nil;
        }

        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        [pd setVertexFunction:vfn];
        [pd setFragmentFunction:ffn];
        [pd setRasterSampleCount:4];

        MTLRenderPipelineColorAttachmentDescriptor *att = [pd colorAttachments][0];
        [att setPixelFormat:MTLPixelFormatBGRA8Unorm];
        [att setBlendingEnabled:YES];
        [att setSourceRGBBlendFactor:MTLBlendFactorSourceAlpha];
        [att setDestinationRGBBlendFactor:MTLBlendFactorOneMinusSourceAlpha];
        [att setSourceAlphaBlendFactor:MTLBlendFactorOne];
        [att setDestinationAlphaBlendFactor:MTLBlendFactorOneMinusSourceAlpha];

        NSError *pipeErr = nil;
        _normalPipeline = [_device newRenderPipelineStateWithDescriptor:pd error:&pipeErr];
        if (!_normalPipeline) NSLog(@"[WNRenderer] PipelineError: %@", pipeErr.localizedDescription);

        [att setSourceRGBBlendFactor:MTLBlendFactorDestinationColor];
        [att setDestinationRGBBlendFactor:MTLBlendFactorZero];
        [att setSourceAlphaBlendFactor:MTLBlendFactorOne];
        [att setDestinationAlphaBlendFactor:MTLBlendFactorZero];
        pipeErr = nil;
        _multiplyPipeline = [_device newRenderPipelineStateWithDescriptor:pd error:&pipeErr];

        if (sfn) {
            [pd setFragmentFunction:sfn];
            [att setSourceRGBBlendFactor:MTLBlendFactorOne];
            [att setDestinationRGBBlendFactor:MTLBlendFactorZero];
            pipeErr = nil;
            _silhouettePipeline = [_device newRenderPipelineStateWithDescriptor:pd error:&pipeErr];
        }
    }

    // ---- 采样器（0x566e?）：线性 + 线性 mip + 各向异性 1 + ClampToEdge ----
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.minFilter    = MTLSamplerMinMagFilterLinear;
    sd.magFilter    = MTLSamplerMinMagFilterLinear;
    [sd setMipFilter:MTLSamplerMipFilterLinear];
    [sd setMaxAnisotropy:1];
    sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
    sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
    _sampler = [_device newSamplerStateWithDescriptor:sd];

    // ---- 全屏 quad（4 顶点、2 三角形）：init 末尾就建好 ----
    {
        float uvs[8] = {0, 0, 1, 0, 0, 1, 1, 1};
        uint16_t tri[6] = {0, 1, 2, 0, 2, 3};
        WNMesh *quad = [WNMesh new];
        [quad setIndexCount:6];
        [quad setUv:[_device newBufferWithBytes:uvs length:sizeof(uvs)
                                        options:MTLResourceStorageModeShared]];
        [quad setIndices:[_device newBufferWithBytes:tri length:sizeof(tri)
                                             options:MTLResourceStorageModeShared]];
        _quad = quad;
    }

    // ---- 外观相关的辉光颜色 ----
    [self updateGlowColorForAppearance:[self isDarkAppearance]];

    // ---- 诊断队列与帧同步信号量 ----
    _diagnosticsQueue = dispatch_queue_create("petdfy.renderer.diagnostics", DISPATCH_QUEUE_SERIAL);
    _frameSemaphore   = dispatch_semaphore_create(3);

    // ---- 启动参数可指定初始 clip（--clip <id>）----
    NSArray *args = [[NSProcessInfo processInfo] arguments];
    if ([args containsObject:@"--clip"]) {
        NSString *want = nil;
        NSUInteger idx = [args indexOfObject:@"--clip"];
        if (idx + 1 < args.count) want = args[idx + 1];
        if (want.length && [_catalog isKindOfClass:[NSArray class]]) {
            NSPredicate *p = [NSPredicate predicateWithFormat:@"id == %@", want];
            NSArray *hits = [_catalog filteredArrayUsingPredicate:p];
            id entry = [hits firstObject];
            if (entry) [self selectClip:entry];
        }
    }

    // ---- 实时装配（默认主题/服装）----
    NSString *scheme = PDAIString(PDAIPreference(@"Scheme", @"deepseek"));
    [self resetLiveWithScheme:scheme freeGround:NO];

    return self;

    // 清单读取：URL 读取 + JSON 解析（失败回退空目录）
    NSURL *manifestURL = [[self resourceURL] URLByAppendingPathComponent:@"manifest.json"];
    NSData *manifestData = [NSData dataWithContentsOfURL:manifestURL options:0 error:NULL];
    if (manifestData.length) {
        id json = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:NULL];
        if ([json isKindOfClass:[NSDictionary class]]) {
            id liveOnlyFlag = json[@"liveOnly"];
            if ([liveOnlyFlag respondsToSelector:@selector(boolValue)]) {
                (void)[liveOnlyFlag boolValue];
            }
        }
    }
}


/// 建三条管线：normal / multiply / silhouette


#pragma mark - 纹理加载

/// 312 条指令。按名字取纹理，带多级缓存与失败标记。
- (id<MTLTexture>)texture:(NSString *)name {
    if (![name isKindOfClass:[NSString class]] || !name.length) return nil;

    // 1) 已失败的不再重试
    if ([_failedTextures containsObject:name]) return nil;

    // 2) live 纹理（发色注入 / 运行时替换）：任何名字先查一次
    //    【可编辑化改造】原实现只认 "__" 前缀；发色引擎把重着色后的贴图
    //    按部件贴图名注册进 liveTextures，这里提前命中即可免去改 Metal 管线。
    id<MTLTexture> liveTex = _liveTextures[name];
    if (liveTex) return liveTex;

    // 2b) 兼容原实现的 __ 前缀语义
    if ([name hasPrefix:@"__"]) {
        id<MTLTexture> t = _liveTextures[name];
        if (t) return t;
    }

    // 3) 普通缓存
    id<MTLTexture> cached = [_textures objectForKey:name];
    if (cached) return cached;

    // 4) 从磁盘加载
    NSString *rel = [_painter image:name] ? nil : name;
    (void)rel;
    NSString *path = [[_resourceURL path] stringByAppendingPathComponent:name];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        // 尝试加 .png
        path = [[_resourceURL path] stringByAppendingPathComponent:
                [name stringByAppendingString:@".png"]];
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [_failedTextures addObject:name];
        NSLog(@"[PetDFY] Unable to load texture %@", name);
        return nil;
    }

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data.length) { [_failedTextures addObject:name]; return nil; }

    NSError *err = nil;
    NSDictionary *opts = @{MTKTextureLoaderOptionSRGB: @NO,
                           MTKTextureLoaderOptionTextureUsage: @(MTLTextureUsageShaderRead)};
    id<MTLTexture> tex = [_loader newTextureWithData:data options:opts error:&err];
    if (!tex) {
        [_failedTextures addObject:name];
        NSLog(@"[PetDFY] Unable to load texture %@ (%@)", name, err.localizedDescription);
        return nil;
    }

    NSUInteger cost = tex.width * tex.height * 4;
    [_textures setObject:tex forKey:name cost:cost];
    return tex;
}

#pragma mark - 表面管理

/// 160 条指令。按 key + slot + size 取/建上传表面。
- (id)surfaceForKey:(NSString *)key slot:(NSInteger)slot size:(CGSize)size {
    if (![key isKindOfClass:[NSString class]]) return nil;
    if (!_uploadSurfaces) _uploadSurfaces = [NSMutableDictionary dictionary];

    NSString *cacheKey = [NSString stringWithFormat:@"%@:%ld", key, (long)slot];
    id s = _uploadSurfaces[cacheKey];
    if (s) return s;

    // 建新表面：按 size 分配缓冲
    NSUInteger bytes = (NSUInteger)(size.width * size.height * 4);
    NSMutableData *pixels = [NSMutableData dataWithLength:bytes];
    NSDictionary *surf = @{@"width": @(size.width),
                           @"height": @(size.height),
                           @"pixels": pixels};
    _uploadSurfaces[cacheKey] = surf;
    return surf;

    // 纹理 + 位图上下文（sRGB 色彩空间、插值质量、Y 轴翻转）
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    MTLTextureDescriptor *desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:(NSUInteger)MAX(1.0, size.width)
                                                          height:(NSUInteger)MAX(1.0, size.height)
                                                       mipmapped:NO];
    [desc setUsage:(MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead)];
    [desc setStorageMode:MTLStorageModeShared];
    id<MTLTexture> tex = [[self device] newTextureWithDescriptor:desc];
    [surface setTexture:tex];

    size_t w = (size_t)MAX(1.0, size.width), h = (size_t)MAX(1.0, size.height);
    NSMutableData *bitmap = [NSMutableData dataWithLength:w * h * 4];
    CGContextRef ctx = CGBitmapContextCreate([bitmap mutableBytes], w, h, 8, w * 4, cs,
                                             kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    if (ctx) {
        CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
        CGContextTranslateCTM(ctx, 0.0, (CGFloat)h);
        CGContextScaleCTM(ctx, 1.0, -1.0);
    }
    if (cs) CGColorSpaceRelease(cs);

    id<MTLBuffer> quad = [[self device] newBufferWithLength:32
                                                   options:MTLResourceStorageModeShared];
    [surface setQuadPositions:quad];
}


/// 268 条指令。取/建辉光表面。
/// 逐条还原（imp 0x5926c）。
///   0x592a0/0x592a8  bounds 先 CGRectInset(-14,-14) 再 CGRectIntegral
///   0x592c0/0x592d8  CGRectIsNull / CGRectIsEmpty → nil
///   0x592f4  glowSurfaces[@(slot)] 取缓存
///   0x59348..0x593d8  命中时比较 silhouette 的宽高（都按 +0x1f 再 &~0x1f 对齐到 32）
///   0x593fc  [WNGlowSurface new]
///   0x59428  texture2DDescriptorWithPixelFormat:0x50(80=BGRA8Unorm) width/height mipmapped:NO
///   0x59434  setUsage:5（ShaderRead|RenderTarget）→ setSilhouette:
///   0x59478  setUsage:7 → setBlurred:
///   0x59480  setStorageMode:2（Shared）
- (id)glowSurfaceForSlot:(unsigned long long)slot bodyBounds:(CGRect)bounds {
    CGRect r = CGRectIntegral(CGRectInset(bounds, -14.0, -14.0));
    if (CGRectIsNull(r) || CGRectIsEmpty(r)) return nil;

    NSUInteger wantW = ((NSUInteger)ceil(r.size.width)  + 0x1f) & ~(NSUInteger)0x1f;
    NSUInteger wantH = ((NSUInteger)ceil(r.size.height) + 0x1f) & ~(NSUInteger)0x1f;
    if (wantW == 0 || wantH == 0) return nil;

    NSMutableDictionary *surfaces = [self glowSurfaces];
    NSNumber *key = @(slot);
    WNGlowSurface *surf = surfaces[key];

    BOOL reusable = NO;
    if (surf) {
        id<MTLTexture> sil = [surf silhouette];
        if (sil && sil.width == wantW && sil.height == wantH) reusable = YES;
    }
    if (reusable) return surf;

    surf = [WNGlowSurface new];

    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm   // 0x50
                                                           width:wantW
                                                          height:wantH
                                                       mipmapped:NO];
    td.storageMode = MTLStorageModeShared;                                  // 2

    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;     // 5
    id<MTLTexture> silhouette = [[self device] newTextureWithDescriptor:td];
    [surf setSilhouette:silhouette];

    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget | MTLTextureUsagePixelFormatView;  // 7
    id<MTLTexture> blurred = [[self device] newTextureWithDescriptor:td];
    [surf setBlurred:blurred];

    // 0x594b4 起：给该表面准备矩形顶点（4 点 × float2），写进 buffer.contents 后 setPositions:
    float verts[8] = {
        (float)CGRectGetMinX(r), (float)CGRectGetMinY(r),
        (float)CGRectGetMaxX(r), (float)CGRectGetMinY(r),
        (float)CGRectGetMinX(r), (float)CGRectGetMaxY(r),
        (float)CGRectGetMaxX(r), (float)CGRectGetMaxY(r),
    };
    id<MTLBuffer> quad = [[self device] newBufferWithLength:sizeof(verts)      // 0x594b4
                                                   options:MTLResourceStorageModeShared];
    if (quad) {
        [surf setPositions:quad];
        memcpy([[surf positions] contents], verts, sizeof(verts));             // 写 contents
    }
    [surf setStageRect:r];

    if (!silhouette || !blurred) return nil;
    surfaces[key] = surf;
    return surf;
}

#pragma mark - 渲染描述符

/// 196 条指令。为当前 drawable 建渲染通道。
/// 逐条还原（imp 0x5bbc8，196 条指令）。
///   0x5bbec  drawable 的 texture，空 → nil
///   0x5bc00  multisampleTargets[@(slot)]；width/height/pixelFormat 三项全等才复用
///   0x5bcd4  texture2DDescriptorWithPixelFormat:width:height:mipmapped:NO
///   0x5bce4/0x5bcf0/0x5bcfc/0x5bd08  textureType=4(2DMultisample) sampleCount=4 usage=4(RenderTarget) storageMode=3(Private)
///   0x5bd20  [device newTextureWithDescriptor:]；失败 → nil
///   0x5bd64  multisampleTargets[@(slot)] = msaa
///   0x5bd80  [MTLRenderPassDescriptor renderPassDescriptor]
///   0x5bdac  colorAttachments[0].texture = msaa
///   0x5bddc  colorAttachments[0].resolveTexture = 原纹理
///   0x5be0c  loadAction  = 2（Clear）
///   0x5be3c  storeAction = 2（MultisampleResolve）
- (MTLRenderPassDescriptor *)renderPassForDrawable:(id)drawable slot:(NSInteger)slot {
    id<MTLTexture> colorTexture = nil;
    if ([drawable respondsToSelector:@selector(texture)]) colorTexture = [drawable texture];
    if (!colorTexture) return nil;

    NSMutableDictionary *targets = [self multisampleTargets];
    NSNumber *key = @((unsigned long long)slot);
    id<MTLTexture> msaa = targets[key];

    BOOL reusable = msaa
        && msaa.width == colorTexture.width
        && msaa.height == colorTexture.height
        && msaa.pixelFormat == colorTexture.pixelFormat;

    if (!reusable) {
        MTLTextureDescriptor *td =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:colorTexture.pixelFormat
                                                               width:colorTexture.width
                                                              height:colorTexture.height
                                                           mipmapped:NO];
        td.textureType = MTLTextureType2DMultisample;
        td.sampleCount = 4;
        td.usage       = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModePrivate;

        msaa = [[self device] newTextureWithDescriptor:td];
        if (!msaa) return nil;
        targets[key] = msaa;
    }

    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    MTLRenderPassColorAttachmentDescriptor *color = rp.colorAttachments[0];
    color.texture        = msaa;
    color.resolveTexture = colorTexture;
    color.loadAction     = MTLLoadActionClear;
    color.storeAction    = MTLStoreActionMultisampleResolve;
    color.clearColor     = MTLClearColorMake(0, 0, 0, 0);
    return rp;
}

/// 354 条指令。剪影通道：渲染 alpha 到离屏纹理。
/// 逐条还原（imp 0x5?，354 条指令）。
/// 把 liveClip 的每个网格用 silhouette 管线画进离屏纹理（只写 alpha），
/// 再用 MPSImageGaussianBlur 模糊到 blurred 纹理，供辉光叠加。
- (void)encodeSilhouetteForCommand:(id)cmd slot:(NSInteger)slot
                         positions:(id)pos frame:(NSInteger)frame surface:(id)surf {
    if (!cmd || !surf) return;

    id<MTLTexture> target = nil;
    if ([surf respondsToSelector:@selector(silhouette)]) target = [surf silhouette];
    if (!target) return;

    WNClip *clip = [self liveClip];
    if (!clip) return;

    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = target;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);

    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rp];
    if (!enc) return;

    if (_silhouettePipeline) [enc setRenderPipelineState:_silhouettePipeline];

    if (pos) [enc setVertexBuffer:pos offset:0 atIndex:0];

    float space[4] = {
        (float)(_stageSize.width  > 0 ? _stageSize.width  : (float)target.width),
        (float)(_stageSize.height > 0 ? _stageSize.height : (float)target.height),
        0.0f, 0.0f,
    };
    [enc setVertexBytes:space length:sizeof(space) atIndex:2];
    if (_sampler) [enc setFragmentSamplerState:_sampler atIndex:0];

    // 视口用表面的 stageRect（0x? stageRect）
    CGRect stageRect = [surf respondsToSelector:@selector(stageRect)] ? [surf stageRect] : CGRectZero;
    if (!CGRectIsEmpty(stageRect)) {
        space[0] = (float)stageRect.size.width;
        space[1] = (float)stageRect.size.height;
        space[2] = (float)CGRectGetMinX(stageRect);
        space[3] = (float)CGRectGetMinY(stageRect);
        [enc setVertexBytes:space length:sizeof(space) atIndex:2];
    }

    id lookSource = [self liveFigureLook];      // 0x?（clip 参数来源）
    (void)lookSource;

    WNLook look;
    memset(&look, 0, sizeof(look));
    look.tint[0] = 1.0f; look.tint[1] = 1.0f; look.tint[2] = 1.0f; look.tint[3] = 0.0f;
    look.alpha = 1.0f;
    look.clipX[3] = 0.0f;
    [enc setFragmentBytes:&look length:sizeof(WNLook) atIndex:0];

    NSArray *meshes = [clip meshes];
    for (WNMesh *m in meshes) {
        if (![m isKindOfClass:[WNMesh class]]) continue;
        if (pos) {
            NSUInteger offset = (NSUInteger)[m positionOffset];          // positionOffset
            [enc setVertexBuffer:pos offset:offset atIndex:0];
        }
        if (m.uv) [enc setVertexBuffer:m.uv offset:0 atIndex:1];
        id<MTLTexture> tex = [self texture:m.texture];
        if (tex) [enc setFragmentTexture:tex atIndex:0];
        if (m.indexCount > 0 && m.indices) {
            [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                            indexCount:(NSUInteger)m.indexCount
                             indexType:MTLIndexTypeUInt16
                           indexBuffer:m.indices
                     indexBufferOffset:0];
        }
    }
    [enc endEncoding];

    // 高斯模糊：silhouette → blurred（MPS）
    // 该槽的 alpha 数组用于逐网格透明度（unsignedIntegerValue/floatValue）
    NSUInteger slotIndex = [[NSNumber numberWithUnsignedLongLong:(unsigned long long)slot] unsignedIntegerValue];
    double slotAlpha = 1.0;
    if ([self.liveTint isKindOfClass:[NSArray class]] && slotIndex < [self.liveTint count]) {
        id t = [self.liveTint objectAtIndex:slotIndex];
        if ([t isKindOfClass:[NSNumber class]]) slotAlpha = [(NSNumber *)t floatValue];
    }
    (void)slotAlpha;

    id<MTLTexture> blurred = [surf respondsToSelector:@selector(blurred)] ? [surf blurred] : nil;
    if (_glowBlur && blurred) {
        [_glowBlur encodeToCommandBuffer:cmd
                           sourceTexture:target
                      destinationTexture:blurred];
    }
}

#pragma mark - 诊断

/// 83 条指令。写 frame-profile.json。
- (void)writeDiagnostics {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"frameIndex"] = @(_frameIndex);
    d[@"elapsed"] = @(_elapsed);
    d[@"simulationFPS"] = @(_simulationFPS);
    d[@"presentationFPS"] = @(_presentationFPS);
    d[@"samples"] = @(_performanceSamples.count);
    if (_performanceSamples.count) d[@"recent"] = [_performanceSamples copy];

    NSData *json = [NSJSONSerialization dataWithJSONObject:d
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:NULL];
    if (!json) return;
    NSString *path = [[_resourceURL path] stringByAppendingPathComponent:@"frame-profile.json"];
    [json writeToFile:path atomically:YES];

    NSURL *docs = [[[NSFileManager defaultManager]
        URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] firstObject];
    NSURL *profileURL = [docs URLByAppendingPathComponent:@"frame-profile.json"];
    dispatch_queue_t dq = [self diagnosticsQueue];
    if (dq) {
        NSDictionary *snap = [d copy];
        dispatch_async(dq, ^{ (void)snap; });
    }
    if (profileURL && d) {
        [d writeToURL:profileURL atomically:YES];
    }
}



#pragma mark - 属性访问器（反汇编均为 2-3 条指令）

- (NSURL *)resourceURL { return _resourceURL; }
- (void)setResourceURL:(NSURL *)v { _resourceURL = v; }
- (id<MTLDevice>)device { return _device; }
- (void)setDevice:(id<MTLDevice>)v { _device = v; }
- (id<MTLCommandQueue>)queue { return _queue; }
- (void)setQueue:(id<MTLCommandQueue>)v { _queue = v; }
- (id<MTLRenderPipelineState>)normalPipeline { return _normalPipeline; }
- (void)setNormalPipeline:(id<MTLRenderPipelineState>)v { _normalPipeline = v; }
- (id<MTLRenderPipelineState>)multiplyPipeline { return _multiplyPipeline; }
- (void)setMultiplyPipeline:(id<MTLRenderPipelineState>)v { _multiplyPipeline = v; }
- (id<MTLRenderPipelineState>)silhouettePipeline { return _silhouettePipeline; }
- (void)setSilhouettePipeline:(id<MTLRenderPipelineState>)v { _silhouettePipeline = v; }
- (id<MTLSamplerState>)sampler { return _sampler; }
- (void)setSampler:(id<MTLSamplerState>)v { _sampler = v; }
- (MTKTextureLoader *)loader { return _loader; }
- (void)setLoader:(MTKTextureLoader *)v { _loader = v; }
- (NSCache *)textures { return _textures; }
- (void)setTextures:(NSCache *)v { _textures = v; }
- (NSMutableDictionary *)liveTextures { return _liveTextures; }
- (void)setLiveTextures:(NSMutableDictionary *)v { _liveTextures = v; }
- (NSMutableSet *)failedTextures { return _failedTextures; }
- (void)setFailedTextures:(NSMutableSet *)v { _failedTextures = v; }
- (NSMutableDictionary *)hitTextures { return _hitTextures; }
- (void)setHitTextures:(NSMutableDictionary *)v { _hitTextures = v; }
- (NSArray *)catalog { return _catalog; }
- (void)setCatalog:(NSArray *)v { _catalog = v; }
- (id<MTLBuffer>)quadPositions { return _quadPositions; }
- (void)setQuadPositions:(id<MTLBuffer>)v { _quadPositions = v; }
- (double)lastFrameAt { return _lastFrameAt; }
- (void)setLastFrameAt:(double)v { _lastFrameAt = v; }
- (double)elapsed { return _elapsed; }
- (void)setElapsed:(double)v { _elapsed = v; }
- (double)liveAccumulator { return _liveAccumulator; }
- (void)setLiveAccumulator:(double)v { _liveAccumulator = v; }
- (NSMutableArray *)performanceSamples { return _performanceSamples; }
- (void)setPerformanceSamples:(NSMutableArray *)v { _performanceSamples = v; }
- (double)lastDiagnosticWrite { return _lastDiagnosticWrite; }
- (void)setLastDiagnosticWrite:(double)v { _lastDiagnosticWrite = v; }
- (NSObject<OS_dispatch_queue> *)diagnosticsQueue { return _diagnosticsQueue; }
- (void)setDiagnosticsQueue:(NSObject<OS_dispatch_queue> *)v { _diagnosticsQueue = v; }
- (NSMutableDictionary *)uploadSurfaces { return _uploadSurfaces; }
- (void)setUploadSurfaces:(NSMutableDictionary *)v { _uploadSurfaces = v; }
- (NSArray *)frameSlots { return _frameSlots; }
- (void)setFrameSlots:(NSArray *)v { _frameSlots = v; }
- (NSMutableDictionary *)livePositionBuffers { return _livePositionBuffers; }
- (void)setLivePositionBuffers:(NSMutableDictionary *)v { _livePositionBuffers = v; }
- (NSMutableDictionary *)toyPositionBuffers { return _toyPositionBuffers; }
- (void)setToyPositionBuffers:(NSMutableDictionary *)v { _toyPositionBuffers = v; }
- (NSArray *)liveTint { return _liveTint; }
- (void)setLiveTint:(NSArray *)v { _liveTint = v; }
- (MPSImageGaussianBlur *)glowBlur { return _glowBlur; }
- (void)setGlowBlur:(MPSImageGaussianBlur *)v { _glowBlur = v; }
- (NSMutableDictionary *)glowSurfaces { return _glowSurfaces; }
- (void)setGlowSurfaces:(NSMutableDictionary *)v { _glowSurfaces = v; }
- (WNGlowTint)glowTint { return _glowTint; }
- (void)setGlowTint:(WNGlowTint)v { _glowTint = v; }
- (float)glowAlpha { return _glowAlpha; }
- (void)setGlowAlpha:(float)v { _glowAlpha = v; }
- (unsigned long long)uploadFrame { return _uploadFrame; }
- (void)setUploadFrame:(unsigned long long)v { _uploadFrame = v; }
- (NSMutableDictionary *)multisampleTargets { return _multisampleTargets; }
- (void)setMultisampleTargets:(NSMutableDictionary *)v { _multisampleTargets = v; }
- (BOOL)didSubmitFrame { return _didSubmitFrame; }
- (void)setDidSubmitFrame:(BOOL)v { _didSubmitFrame = v; }
- (long long)frameIndex { return _frameIndex; }
- (void)setFrameIndex:(long long)v { _frameIndex = v; }
- (BOOL)playing { return _playing; }
- (void)setPlaying:(BOOL)v { _playing = v; }
- (CGPoint)offset { return _offset; }
- (void)setOffset:(CGPoint)v { _offset = v; }
- (BOOL)interactive { return _interactive; }
- (void)setInteractive:(BOOL)v { _interactive = v; }
- (BOOL)responsiveInteraction { return _responsiveInteraction; }
- (void)setResponsiveInteraction:(BOOL)v { _responsiveInteraction = v; 
    WNLiveRig *rigNow = [self liveRig];
    if ([rigNow respondsToSelector:@selector(motion)]) {
        (void)[rigNow motion];
    }
}

- (long long)simulationFPS { return _simulationFPS; }
- (void)setSimulationFPS:(long long)v { _simulationFPS = v; }
- (long long)presentationFPS { return _presentationFPS; }
- (void)setPresentationFPS:(long long)v { _presentationFPS = v; }
- (BOOL)darkAppearance { return _darkAppearance; }
- (void)setDarkAppearance:(BOOL)v { _darkAppearance = v; 
    [self updateGlowColorForAppearance:dark];
    (void)[self painter];
}

- (CGSize)stageSize { return _stageSize; }
/// 逐条还原（imp 0x59054）。
/// 反汇编证据：
///   0x59084..0x590b0  对 width/height 做 NaN/inf/<=0 三重拦截（0x7ff0… → DBL_MAX 比较）
///   0x590b8  ldp d2,d3,[x19,#0x158] 读旧 _stageSize，相等则直接返回（0x590c4 b.eq）
///   0x590c8  stp d0,d1,[x19,#0x158] 写新 _stageSize
///   0x590d0..0x590e8 在栈上拼出 8 个 float：{0,0, w,0, 0,h, w,h}（左下/右下/左上/右上）
///   0x59108  [device newBufferWithBytes:length:0x20 options:0]
///   0x59118  setQuadPositions:
///   0x59128  [_glowSurfaces removeAllObjects]
- (void)setStageSize:(CGSize)v {
    // NaN / inf / 非正 尺寸一律忽略（保持原值）
    if (!isfinite(v.width) || v.width <= 0.0) return;
    if (!isfinite(v.height) || v.height <= 0.0) return;
    if (CGSizeEqualToSize(v, _stageSize)) return;      // 0x590c4

    _stageSize = v;                                    // 0x590c8

    float quad[8] = {
        0.0f,                 0.0f,
        (float)v.width,       0.0f,
        0.0f,                 (float)v.height,
        (float)v.width,       (float)v.height,
    };
    _quadPositions = [_device newBufferWithBytes:quad
                                          length:sizeof(quad)
                                         options:0];   // 0x59108
    [_glowSurfaces removeAllObjects];                  // 0x59134
}
- (BOOL)buildsInteractionPath { return _buildsInteractionPath; }
- (void)setBuildsInteractionPath:(BOOL)v { _buildsInteractionPath = v; }
#pragma mark - 二进制存取器（逐条 8-16 指令，纯 ivar 读写）
- (void)setLiveRig:(id)v { _liveRig = v; }
- (void)setCurrent:(id)v { _current = v; }
- (void)setQuad:(id)v { _quad = v; }
- (void)setPainter:(id)v { _painter = v; }
- (void)setLiveClip:(id)v { _liveClip = v; }

#pragma mark - 二进制存取器（逐条 8-16 指令，纯 ivar 读写）
- (BOOL)isDarkAppearance { return _darkAppearance; }
- (id)liveRig { return _liveRig; }
- (id)current { return _current; }
- (id)quad { return _quad; }
- (id)painter { return _painter; }
- (id)liveClip { return _liveClip; }

#pragma mark - 生命周期与小型访问器（0x59468 / 0x594b8 / 0x594c0 / 0x5c1f8 / 0x5c418 / 0x5e6e4 / 0x5ee44）

// 0x59468：先 CGPathRelease(_interactionPath)，再走 objc_msgSendSuper2 到 NSObject 的 dealloc。
- (void)dealloc {
    if (_interactionPath) {
        CGPathRelease(_interactionPath);
    }
    // 0x59498-0x594a4：stp x19,x8,[sp] + objc_msgSendSuper2 —— 就是 [super dealloc]
}

// 0x594b8：ldr x0,[x0,8]; ret —— 纯 ivar 读取，偏移 8。
- (struct CGPath *)interactionPath {
    return _interactionPath;

    if (!_interactionPath) {
        WNRenderer *fresh = [[WNRenderer alloc] initWithResourceURL:[self resourceURL] liveOnly:YES];
        (void)fresh;
    }
}


// 0x594c0：mov w3,0; b -[initWithResourceURL:liveOnly:] —— 尾调用，liveOnly 传 NO。
- (id)initWithResourceURL:(NSURL *)url {
    return [self initWithResourceURL:url liveOnly:NO];
}

// 0x5c1f8：setLastFrameAt:0.0 + setLiveAccumulator:0.0（两次 movi d0,#0）。
- (void)resetFrameClock {
    [self setLastFrameAt:0.0];
    [self setLiveAccumulator:0.0];
}

// 0x5c418：暗色取 (0.92,0.94,0.98,1.0) / alpha 0.56，亮色取 (0.12,0.13,0.16,1.0) / alpha 0.40。
// csetm+dup+bit 等价于 (dark ? v1 : v0)，fcsel 同理。
- (void)updateGlowColorForAppearance:(BOOL)dark {
    WNGlowTint tint;
    if (dark) {
        tint.r = 0.92f; tint.gba[0] = 0.94f; tint.gba[1] = 0.98f; tint.gba[2] = 1.0f;
    } else {
        tint.r = 0.12f; tint.gba[0] = 0.13f; tint.gba[1] = 0.16f; tint.gba[2] = 1.0f;
    }
    [self setGlowTint:tint];
    [self setGlowAlpha:dark ? 0.56f : 0.40f];
}

// 0x5e6e4：queue → commandBuffer → preparedLiveClipForCommand:slot:2 → commit → 返回 clip。
- (WNClip *)preparedLiveClip {
    id<MTLCommandBuffer> cmd = [[self queue] commandBuffer];
    WNClip *clip = [self preparedLiveClipForCommand:cmd slot:2];
    [cmd commit];
    return clip;
}

// 0x5ee44：drawable 尺寸变化时清空多重采样纹理缓存。
- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    [[self multisampleTargets] removeAllObjects];
}

#pragma mark - 片段装载（0x5a09c / 0x5a0e8 / 0x5a900）

// 0x59f78：file-static JSON 读取器。先 dataWithContentsOfURL:options:0:error:，
// 再 JSONObjectWithData:options:0:error:，最后 isKindOfClass:[NSDictionary class] 校验；
// 任一步失败就 NSException raise:@"InvalidClip" format:@"%@: %@"（url.path, error）。
static NSDictionary *WNLoadClipJSON(NSURL *url) {
    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&error];
    id obj = nil;
    if (data) {
        obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    }
    if (![obj isKindOfClass:[NSDictionary class]]) {
        [NSException raise:@"InvalidClip" format:@"%@: %@", [url path], error];
    }
    return (NSDictionary *)obj;
}

// 0x5a09c：current.info —— 先 bl -[current]（0xaab00）再 bl -[info]（0xac980）。
- (NSDictionary *)clipInfo {
    return [[self current] info];
}

// 0x5a0e8：按 entry[@"json"] / entry[@"binary"] 从 resourceURL 拼路径装载片段。
// 校验：valuesPerFrame * count * 4 必须等于 positions.length（0x5a294 cmp x25,x22,lsl 2）。
- (WNClip *)loadClip:(NSDictionary *)entry {
    WNClip *clip = [WNClip new];
    clip.info = WNLoadClipJSON([[self resourceURL] URLByAppendingPathComponent:entry[@"json"]]);
    clip.positions = [NSData dataWithContentsOfURL:[[self resourceURL] URLByAppendingPathComponent:entry[@"binary"]]
                                           options:1
                                             error:NULL];
    NSUInteger valuesPerFrame = [[[clip info] objectForKeyedSubscript:@"valuesPerFrame"] unsignedIntegerValue];
    NSUInteger count = [[[clip info] objectForKeyedSubscript:@"count"] unsignedIntegerValue];
    if (valuesPerFrame == 0 || count == 0 ||
        [[clip positions] length] != valuesPerFrame * count * 4) {
        [NSException raise:@"InvalidClip" format:@"Invalid vertex byte count %@", entry[@"id"]];
    }
    clip.meshes = [self meshesForParts:[[clip info] objectForKeyedSubscript:@"meshes"]];
    return clip;
}

// 0x5a900：清交互态 → 装载 → 归零时钟与偏移（CGPointZero 走 BIND 常量槽 0xf8a10）。
- (void)selectClip:(NSDictionary *)entry {
    [self setInteractive:NO];
    [self setCurrent:[self loadClip:entry]];
    [self setFrameIndex:0];
    [self setElapsed:0.0];
    [self setLastFrameAt:0.0];
    [self setOffset:CGPointZero];
}

#pragma mark - 实时装配（0x5bd94）

// 0x5bd94：清四层纹理缓存 → 释放旧交互路径 → 重建 WNPainter / WNLiveRig →
// 由 rig.model[@"parts"] 派生 liveClip.meshes 与 liveTint → 复位时钟与偏移。
// seed 常量 0x12345（mov w4,#0x2345 / movk w4,#1,lsl 16）。
- (void)resetLiveWithScheme:(id)scheme freeGround:(BOOL)freeGround {
    [[self liveTextures] removeAllObjects];
    [[self textures] removeAllObjects];
    [[self failedTextures] removeAllObjects];
    [[self hitTextures] removeAllObjects];

    if (_interactionPath) {
        CGPathRelease(_interactionPath);
        _interactionPath = NULL;
    }

    WNPainter *painter = [[WNPainter alloc] initWithResourceURL:[self resourceURL]];
    [self setPainter:painter];
    [painter setDarkAppearance:[self isDarkAppearance]];

    WNLiveRig *rig = [[WNLiveRig alloc] initWithResourceURL:[self resourceURL]
                                                     scheme:scheme
                                                       seed:0x12345
                                                 freeGround:freeGround];
    [self setLiveRig:rig];
    [[rig motion] setResponsiveInteraction:[self responsiveInteraction]];
    [rig render];

    WNClip *clip = [WNClip new];
    NSMutableArray *parts = [NSMutableArray new];
    for (NSDictionary *part in [[rig model] objectForKeyedSubscript:@"parts"]) {
        NSMutableDictionary *entry = [part mutableCopy];
        [entry setObject:[rig textureForPart:part] forKeyedSubscript:@"texture"];
        [parts addObject:entry];
    }
    [clip setMeshes:[self meshesForParts:parts]];
    [self setLiveClip:clip];

    // 0x5c034-0x5c06c：逐个 push 常量数组类对象（x2 = _OBJC_CLASS_$_NSConstantArray），
    // 语义上等于给每个 part 预留一个空 tint 槽；此处按观测字节直译。
    NSMutableArray *tint = [NSMutableArray new];
    for (NSUInteger i = 0; i < [parts count]; i++) {
        [tint addObject:(id)[NSArray class]];
    }
    [self setLiveTint:tint];

    [[self livePositionBuffers] removeAllObjects];
    [[self uploadSurfaces] removeAllObjects];

    [self setLiveAccumulator:0.0];
    [self setLastFrameAt:0.0];
    [self setOffset:CGPointZero];

    [self updateGlowColorForAppearance:[self isDarkAppearance]];

    [self setToyPositionBuffers:[NSMutableDictionary new]];

    // 【可编辑化扩展】把头发部件的贴图按当前发色重着色后注入 liveTextures。
    // 走的是与官方完全相同的入口（texture: 先查 liveTextures），
    // 所以服装、姿态、变形器、命中蒙版全都不受影响。
    if ([self respondsToSelector:@selector(pdApplyHairTintForParts:)]) {
        [self performSelector:@selector(pdApplyHairTintForParts:) withObject:parts];
    }

    (void)[[self liveRig] class];
}


/// Observed @0x6004c（60 条）+ 块体 0x60134–0x60894（约 420 条）：
/// 关掉播放 → 全局并发队列上逐 clip 渲染 samples 帧 → （--record-demo 时）额外渲 wave/dance
/// 的整段 demo 帧 → 写 audit.json 报告 → 回主队列 completion(clips)。
/// 报告字典 6 个键按栈上 keys[6]/objs[6] 逐槽解出（status/error/renderer/system/clips/runtime），
/// renderer 取 [self device].name、error 取 exception.description —— 均按 0x606a4/0x60648 调用点定。
- (void)runAuditAtURL:(NSURL *)url completion:(void (^)(NSArray *))completion {
    [self setPlaying:NO];                                   // 0xb3640 setPlaying: w2=0

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{   // w0=0x19
        NSMutableArray *clips = [NSMutableArray array];      // 0xa8e00 +array
        NSFileManager *fm = [NSFileManager defaultManager];  // 0x121000+0xd90

        [fm createDirectoryAtURL:url                              // 0xaa360
     withIntermediateDirectories:YES
                      attributes:nil
                           error:NULL];

        NSException *failure = nil;                          // x19，@catch 时接住异常
        @try {
            for (NSString *clipID in [self catalog]) {       // 0xa9760 catalog
                NSDictionary *clip = [self loadClip:clipID]; // 0xa9700 loadClip:
                CFTimeInterval started = CACurrentMediaTime();

                for (NSNumber *sample in clip[@"samples"]) { // 0x103bf0 = @"samples"
                    NSString *name = [NSString stringWithFormat:@"%@-%04lu.png",  // 0x103c10
                                                                clip[@"id"],
                                                                (unsigned long)[sample unsignedIntegerValue]];
                    NSURL *out = [url URLByAppendingPathComponent:name];         // 0xaa780
                    [self captureClip:clip frame:(unsigned long long)[sample unsignedIntegerValue] URL:out];  // 0xadc60
                }

                // 0x6037c–0x604e0：[[NSProcessInfo processInfo].arguments containsObject:@"--record-demo"]
                if ([[[NSProcessInfo processInfo] arguments] containsObject:@"--record-demo"]) {
                    // 0x10fb00 = 常量 NSArray，两元素 @"wave" / @"dance"（元素表 0x10dfe0 → 0x1019b0 / 0xfbd90）
                    if ([@[@"wave", @"dance"] containsObject:clip[@"id"]]) {
                        // 0x603c8：demo/ + clip[@"id"]，建子目录
                        NSURL *demoURL = [url URLByAppendingPathComponent:
                                            [@"demo/" stringByAppendingString:clip[@"id"]]];   // 0x103c50 + 0xb57e0
                        [fm createDirectoryAtURL:demoURL withIntermediateDirectories:YES attributes:nil error:NULL];

                        // 0x60448：[[clip info][@"count"] unsignedIntegerValue]（0xac980 info / 0xffed0 count / 0xb6480）
                        NSUInteger frameCount = (NSUInteger)[[clip info][@"count"] unsignedIntegerValue];
                        for (NSUInteger i = 0; i < frameCount; i++) {
                            NSString *name = [NSString stringWithFormat:@"%04lu.png", (unsigned long)i];  // 0x103c70
                            NSURL *out = [demoURL URLByAppendingPathComponent:name];
                            [self captureClip:clip frame:(unsigned long long)i URL:out];
                        }
                    }
                }

                // 0x604e8–0x60594：四条键值 → dictionaryWithObjects:forKeys:count:（0xaaaa0）→ addObject:
                [clips addObject:@{
                    @"id":      clip[@"id"],
                    @"samples": clip[@"samples"],
                    @"seconds": @(CACurrentMediaTime() - started),   // 0xae7a0 numberWithDouble:
                    @"status":  @"rendered"                          // 0x103c90
                }];
            }
        } @catch (NSException *exception) {                  // 0x60628 objc_begin_catch
            failure = exception;
        }

        // 0x6065c–0x6076c：组装 6 项报告字典并 JSON 序列化（w3=1 → pretty printed）
        // 键序按栈上 keys[6]（sp+0x100）/ objs[6]（sp+0x130）逐槽解出：
        //   status / error / renderer / system / clips / runtime
        NSString *status = failure ? @"failed" : @"rendered";                       // 0xfe150 / 0x103c90
        NSDictionary *report = @{
            @"status":   status,                                                    // 0xfad10
            @"error":    failure.description ?: @"",                                // 0xfd190 / 0xaa7c0 -[description] / 0xfacb0 @""
            @"renderer": [self device].name,                                        // 0x103cb0 + 0xaa7e0 -[device] / 0xae3a0 -[name]
            @"system":   [UIDevice currentDevice].systemVersion,                    // 0xff450 + 0xaa400 / 0xb5be0
            @"clips":    clips,                                                     // 0x103590
            @"runtime":  @"Objective-C + Metal; no WebKit or JavaScript"             // 0x103cd0 / 0x103cf0
        };
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:1 error:NULL];  // 0xaa5c0
        [json writeToURL:[url URLByAppendingPathComponent:@"audit.json"] atomically:YES];      // 0x103d10 + 0xb6c00

        dispatch_async(dispatch_get_main_queue(), ^{            // 0x60884 完成块：invoke(clips)
            completion(clips);
        });
    });
}

/// Observed @0x60898（66 条）+ 块体 0x609a4–0x61858（约 940 条）：
/// 关播放 → 快照并清掉响应式开关 → 全局队列上按 live/scenarios.json（--response-audit 时换
/// live/responsiveness.json）逐场景重放 events 里的指针事件 → 每帧记一条 motion 快照 + 一段
/// 顶点流，被 scenario[@"samples"] 点名的帧截 png，--record-demo 时隔帧录 demo
/// → 每场景落 <id>.json / <id>.bin → 汇总 5 项报告写 audit.json → 回主队列还原状态并 completion(report)。
/// 块捕获布局（入口 0x60948 stp x19/x21、0x6094c strb w22 与块内取用一致）：
///   +0x20 url  +0x28 self  +0x30 completion  +0x38 BOOL responsive 快照
- (void)runInteractionAuditAtURL:(NSURL *)url completion:(void (^)(NSArray *))completion {
    [self setPlaying:NO];                                       // 0xb3640 setPlaying: w2=0
    BOOL responsive = [self responsiveInteraction];              // 0xb04c0
    [self setResponsiveInteraction:NO];                          // 0xb3b40 setResponsiveInteraction: w2=0

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{   // 0x608f0 w0=0x19
        NSMutableArray *clips = [NSMutableArray new];            // 0x609e4 objc_opt_new
        [[NSFileManager defaultManager] createDirectoryAtURL:url  // 0x60a1c
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:NULL];

        // 0x60a4c：--response-audit 决定读哪份场景表（0x103d50 / 0x103d70）
        BOOL responseAudit = [[[NSProcessInfo processInfo] arguments] containsObject:@"--response-audit"];
        NSString *manifest = responseAudit ? @"live/responsiveness.json" : @"live/scenarios.json";  // 0x60a94 csel
        NSData *manifestData = [NSData dataWithContentsOfURL:        // 0x60aac / 0x60a98
                                   [[self resourceURL] URLByAppendingPathComponent:manifest]];
        id scenarios = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:NULL];  // 0x60ac8

        // 0x60b14：--only-scenarios a,b,c → NSPredicate "id IN %@"（0x103db0）
        NSArray *arguments = [[NSProcessInfo processInfo] arguments];
        NSUInteger onlyIndex = [arguments indexOfObject:@"--only-scenarios"];   // 0x103d90
        if (onlyIndex != NSNotFound && onlyIndex + 1 < [arguments count]) {     // 0x60b24 / 0x60b38
            NSArray *ids = [arguments[onlyIndex + 1] componentsSeparatedByString:@","];   // 0xfebf0
            scenarios = [scenarios filteredArrayUsingPredicate:
                            [NSPredicate predicateWithFormat:@"id IN %@", ids]];           // 0x60b8c
        }

        NSString *failure = nil;                                 // x19：@catch 里存 exception.description
        @try {
            for (NSDictionary *scenario in scenarios) {           // 0x60bc8 countByEnumeratingWithState:
                @autoreleasepool {                                // 0x60c20
                    // 0x60c64：--response-audit 时用 scenario[@"responsive"] 覆盖开关
                    [self setResponsiveInteraction:responseAudit ? [scenario[@"responsive"] boolValue] : NO];

                    NSString *scheme = scenario[@"scheme"] ?: @"deepseek-maid";     // 0x60c98 csel / 0x103730
                    [self resetLiveWithScheme:scheme                                // 0x60cd4
                                   freeGround:[scenario[@"ground"] isEqual:@"free"]];  // 0x103df0 / 0xfb0b0

                    if (scenario[@"word"]) {                                    // 0x60cfc
                        [[[self liveRig] motion] doWord:scenario[@"word"]];      // 0x60d40 / 0x100ab0
                    }
                    [[self liveRig] render];                                    // 0x60d64

                    NSMutableArray *samples = [NSMutableArray new];              // 0x60d74 → sp+0x60
                    NSMutableData *positionLog = [NSMutableData new];            // 0x60d84 → sp+0x58

                    // 0x60d90：帧循环，[scenario[@"frames"] intValue] 每轮重新取
                    for (int frame = 0; frame < [scenario[@"frames"] intValue]; frame++) {
                        @autoreleasepool {                                      // 0x60dbc
                            WNMotion *motion = [[self liveRig] motion];          // 0x60dd8
                            for (NSDictionary *event in scenario[@"events"]) {   // 0x60e18 / 0x103e10
                                if ([event[@"frame"] intValue] != frame) continue;  // 0x60e74
                                double x = [event[@"x"] doubleValue];            // 0x60e90 / 0x1009b0
                                double y = [event[@"y"] doubleValue];            // 0x60eb4 / 0x1009d0
                                double t = [event[@"t"] doubleValue];            // 0x60edc / 0x101fb0
                                NSString *type = event[@"type"];                 // 0x60ef8 / 0xfadf0
                                if ([type isEqual:@"down"]) {                    // 0x101bb0
                                    [motion pointerDown:CGPointMake(x, y) milliseconds:t];  // 0x60f1c
                                } else if ([type isEqual:@"move"]) {             // 0x1017b0
                                    [motion pointerMove:CGPointMake(x, y) milliseconds:t];  // 0x60f48
                                } else if ([type isEqual:@"up"]) {               // 0x1032b0
                                    [motion pointerUp:CGPointMake(x, y) milliseconds:t];    // 0x60f74
                                } else if ([type isEqual:@"cancel"]) {           // 0x103e50
                                    [motion cancelAt:CGPointMake(x, y)];                    // 0x60f9c
                                } else if ([type isEqual:@"leave"]) {            // 0x103e70
                                    [motion pointerLeave];                                  // 0x60fbc
                                } else if ([type isEqual:@"word"]) {             // 0x60fd4
                                    [motion doWord:event[@"word"]];                         // 0x60ff8
                                }
                            }

                            [[self liveRig] step:1.0 / 60.0];            // 0x61048；0xc6350 = 0.016666666666666666

                            NSMutableDictionary *sample = [[motion snapshot] mutableCopy];  // 0x61050 / 0x61060
                            sample[@"alpha"] = [[self liveRig] alpha];                  // 0x6109c / 0x102db0
                            sample[@"events"] = [[motion events] copy];                 // 0x610d0
                            [[motion events] removeAllObjects];                         // 0x610ec
                            [samples addObject:sample];                                 // 0x610fc

                            // WNLiveRig.h 把 positions 声明成 NSDictionary，二进制此处直接 appendData:（0xaf5c0），按 NSData 处理
                            [positionLog appendData:(NSData *)[[self liveRig] positions]];   // 0x61128

                            // 0x6116c：scenario[@"samples"] 点名的帧才截图
                            if ([scenario[@"samples"] containsObject:@(frame)]) {        // 0x103bf0
                                NSString *name = [NSString stringWithFormat:@"%@-%04d.png",   // 0x103e90
                                                                            scenario[@"id"], frame];
                                [self captureClip:[self preparedLiveClip] frame:0         // 0x61200
                                              URL:[url URLByAppendingPathComponent:name]];
                            }

                            // 0x61238：--record-demo 隔帧录 demo
                            BOOL recordDemo = [[[NSProcessInfo processInfo] arguments] containsObject:@"--record-demo"];
                            BOOL evenFrame = (frame & 1) == 0;                       // 0x6124c tst w25,1
                            BOOL selected = NO;
                            if (recordDemo) {
                                if (responseAudit) {
                                    selected = evenFrame;
                                } else if ([@[@"tap", @"slow_drop", @"throw", @"sleep_poke"]   // 0x10fb18 常量数组
                                            containsObject:scenario[@"id"]]) {
                                    selected = evenFrame;                            // 0x6128c
                                }
                            }
                            if (selected) {
                                NSURL *demoURL = [url URLByAppendingPathComponent:          // 0x612e0
                                                    [@"demo/" stringByAppendingString:scenario[@"id"]]];  // 0x103c50
                                [[NSFileManager defaultManager] createDirectoryAtURL:demoURL  // 0x61318
                                                         withIntermediateDirectories:YES
                                                                          attributes:nil
                                                                               error:NULL];
                                NSString *name = [NSString stringWithFormat:@"%04d.png", frame / 2];  // 0x61350 lsr w25,1
                                [self captureClip:[self preparedLiveClip] frame:0         // 0x61380
                                              URL:[demoURL URLByAppendingPathComponent:name]];
                            }
                        }
                    }

                    // 0x613c0–0x61480：每场景落 <id>.json（motion 快照数组）与 <id>.bin（顶点流）
                    NSData *sampleJSON = [NSJSONSerialization dataWithJSONObject:samples options:0 error:NULL];
                    [sampleJSON writeToURL:[url URLByAppendingPathComponent:
                                        [scenario[@"id"] stringByAppendingString:@".json"]]   // 0xffc10
                                atomically:YES];
                    [positionLog writeToURL:[url URLByAppendingPathComponent:
                                              [scenario[@"id"] stringByAppendingString:@".bin"]]  // 0x103f30
                                         atomically:YES];

                    [clips addObject:@{@"id": scenario[@"id"],           // 0x61504 dictionaryWithObjects:forKeys:count:
                                       @"frames": scenario[@"frames"],
                                       @"samples": scenario[@"samples"]}];
                }
            }
        } @catch (NSException *exception) {                          // 0x615ec objc_begin_catch
            failure = exception.description;                         // 0x6160c
        }

        // 0x61620–0x61750：5 项报告 → pretty JSON（w3=1）→ audit.json
        NSDictionary *report = @{
            @"status":    failure ? @"failed" : @"rendered",          // 0xfe150 / 0x103c90
            @"error":     failure ?: @"",                             // 0xfacb0（空串）
            @"renderer":  [self device].name,                         // 0xaa7e0 / 0xae3a0
            @"system":    [UIDevice currentDevice].systemVersion,     // 0xb5be0
            @"scenarios": clips                                       // 0x103f50
        };
        NSData *reportJSON = [NSJSONSerialization dataWithJSONObject:report options:1 error:NULL];  // 0x6171c
        [reportJSON writeToURL:[url URLByAppendingPathComponent:@"audit.json"] atomically:YES];     // 0x61750

        dispatch_async(dispatch_get_main_queue(), ^{                  // 0x617d4
            [self setResponsiveInteraction:responsive];               // 0x61874 还原入口快照
            [self resetLiveWithScheme:@"deepseek-maid" freeGround:NO]; // 0x61888
            [self setInteractive:YES];                                // 0x61894 setInteractive:
            completion((NSArray *)report);                            // 0x618bc 实参是 5 键报告字典（头里 completion 签名写作 NSArray *）
        });
    });
}

/// Observed @0x5ae78（54 条）：drawMesh:positions:texture:look:encoder:
/// 门面：texture 为 nil 直接返回（cbz x4）；look 的 +0x10 处 float 转 double 后与 0.001 比较，
/// 小于等于即返回（fcmp/b.ls，故 0.001 本身也返回）；否则取 [self texture:texture] 作为
/// textureObject 转调完整版，encoder 走 objc_retain_x6（x6 是对象）。
/// 保真缺口：方法编码声明 look 为 16 字节 {?=f[3f]} 按值传递，但 x6 被 objc_retain 且
/// [x5,0x10] 被读、[x5,8]/[x5,0x10] 被写，实际 ABI 是「指向 ≥20 字节结构体的指针」。
/// 头文件签名沿用编码声明以保证调用方兼容，此处按二进制真实偏移取阈值。
- (void)drawMesh:(id)mesh positions:(id)positions texture:(id)texture look:(WNGlowTint)look encoder:(id)encoder {
    if (!texture) {
        return;
    }
    float threshold = *(const float *)((const char *)&look + 0x10);
    if ((double)threshold <= 0.001) {
        return;
    }
    [self drawMesh:mesh positions:positions textureObject:[self texture:texture] look:look encoder:encoder];
}


// ─────────────────────────────────────────────────────────────────────────────
// 0x5b460 · encodeClip:frame:descriptor:command:offset: · 589 条指令
//
// 数据来源：clip.info = { count, frames[], valuesPerFrame }。positions 是紧凑
// float 缓冲（NSData），每帧 valuesPerFrame*4 字节；帧索引越界时回落到 0。
//
// look 实参：二进制里是 0x50 字节结构体、按指针传入 —
//   +0x00 WNGlowTint（4 float 颜色）  +0x10 float alpha  +0x14 起 0x3c 字节负载（本方法恒 0）
// 头文件里 drawMesh 按 16 字节按值声明（见该方法的保真缺口注记），所以这里只把
// tint 送出去；alpha 与负载在栈上保持与二进制一致的布局与取值。
// ─────────────────────────────────────────────────────────────────────────────
typedef struct {
    WNGlowTint tint;    // +0x00 颜色
    float      alpha;   // +0x10 不透明度
    float      payload[15]; // +0x14 0x3c 字节负载，本方法恒 0
} WNClipLook;

// sret 结构体返回的 msgSend 形态（liveFigureLook 在二进制里是 0x50 字节 sret，
// 头里声明成 void *，见 WNRenderer.h；这里按真实 ABI 调用）。
typedef void (*WNStructReturnSend)(void *ret, id self, SEL _cmd);

#if 0  // 已被分类里的同名方法覆盖（真正生效的是 WNRenderer+Draw.m），改写请去那边
- (void)encodeClip:(WNClip *)clip frame:(unsigned long long)frame descriptor:(id)descriptor command:(id<MTLCommandBuffer>)command offset:(CGPoint)offset {
    // 0x5b494–0x5b4c8：帧索引 = (count > frame) ? frame : 0（0x5b4c4 csel hi）
    NSUInteger count = [[[clip info] objectForKeyedSubscript:@"count"] unsignedIntegerValue];   // 0x5b4a0 @ffed0
    NSUInteger frameIndex = (count > frame) ? frame : 0;
    NSDictionary *frameData = [[[clip info] objectForKeyedSubscript:@"frames"]                 // 0x5b4d8 @103910
                               objectAtIndexedSubscript:frameIndex];
    NSUInteger valuesPerFrame = [[[clip info] objectForKeyedSubscript:@"valuesPerFrame"]       // 0x5b508 @103790
                                 unsignedIntegerValue];

    // 0x5b51c–0x5b5b8：positions(NSData) 切出本帧；没有 positionBuffer 就现建一个。
    const void *positionBytes = [[clip positions] bytes];                                      // 0x5b574 / 0x5b584
    id<MTLBuffer> positionBuffer = [clip positionBuffer];                                      // 0x5b590
    if (!positionBuffer) {
        NSUInteger stride = valuesPerFrame * 4;                                                // 0x5b56c lsl #2
        positionBuffer = [[self device] newBufferWithBytes:(const char *)positionBytes + stride * frameIndex
                                                    length:stride
                                                   options:0];                                 // 0x5b5b8
    }

    id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:descriptor]; // 0x5b75c

    // 0x5b5f4–0x5b62c：顶点常量槽 2 = {stageSize.width, stageSize.height, offset.x, offset.y}。
    // 二进制里两次取 stageSize（0x5b5fc 与 0x5b600 各一次 msgSend），是两次属性访问，非笔误。
    float stageOffset[4] = { (float)[self stageSize].width,
                             (float)[self stageSize].height,
                             (float)offset.x,
                             (float)offset.y };
    [encoder setVertexBytes:stageOffset length:sizeof(stageOffset) atIndex:2];                   // 0x5b630
    [encoder setFragmentSamplerState:[self sampler] atIndex:0];                                 // 0x5b644

    WNClipLook look;
    memset(&look, 0, sizeof(look));                                                             // 0x5b66c

    // 0x5b734 → 0x5bc70：live clip 先叠一层 glow，画完落回公共路径（0x5bd8c b 0x5b750）。
    if (clip == [self liveClip]) {
        id glowPositions = [frameData objectForKeyedSubscript:@"glowPositions"];                // 0x5bc80 @103950
        if (glowPositions) {
            id glowTexture = [frameData objectForKeyedSubscript:@"glowTexture"];                // 0x5bc98 @103970
            if (glowTexture) {
                look.tint = [self glowTint];                                                    // 0x5bcbc
                look.alpha = [self glowAlpha];                                                  // 0x5bcc4
                [self drawMesh:[self quad]                                                       // 0x5bd40
                     positions:glowPositions
                 textureObject:glowTexture
                          look:look.tint
                       encoder:encoder];
                memset(look.payload, 0, sizeof(look.payload));                                  // 0x5bd6c
            }
        }
    }

    // 0x5b67c–0x5b71c：背景层。颜色 (1,1,1,0)、alpha 1.0，位置回落到 quadPositions。
    look.tint = (WNGlowTint){ 1.0f, { 1.0f, 1.0f, 0.0f } };                                     // 0x5b6d4 常量 (1,1,1,0) @[sp,0x10]
    look.alpha = 1.0f;                                                                          // 0x5b6e0
    id quad = [self quad];                                                                      // 0x5b67c
    id backgroundPositions = [clip backgroundPositions];                                        // 0x5b690
    if (!backgroundPositions) {
        backgroundPositions = [self quadPositions];                                             // 0x5b6b8
    }
    [self drawMesh:quad positions:backgroundPositions
           texture:[frameData objectForKeyedSubscript:@"background"]                            // @103930
             look:look.tint encoder:encoder];                                                   // 0x5b704

    // 0x5b754–0x5b7a8：live clip 的 look 取自 liveFigureLook。
    if (clip == [self liveClip]) {
        WNStructReturnSend send = (WNStructReturnSend)(void *)objc_msgSend;
        send(&look, self, @selector(liveFigureLook));                                           // 0x5b774
    }

    // 0x5b7b8–0x5bb48：按 order 里的槽位顺序逐层绘制。
    for (NSNumber *slotNumber in [frameData objectForKeyedSubscript:@"order"]) {                // @103990
        NSUInteger slot = [slotNumber unsignedIntegerValue];                                    // 0x5b82c
        id mesh = [[clip meshes] objectAtIndexedSubscript:slot];                                // 0x5b838 / 0x5b848
        NSArray *tint = [[frameData objectForKeyedSubscript:@"tint"]                            // @1039b0
                         objectAtIndexedSubscript:slot];

        // 0x5b884–0x5b9dc：toy 道具层（先于本体画）。只有 arm_near 槽改 alpha，
        // 其余槽沿用上一层的 alpha（s8 跨迭代保持）。
        id toyPositions = [frameData objectForKeyedSubscript:@"toyPositions"];                  // @1039d0
        if (toyPositions) {
            id partId = [[[[[self liveRig] model] objectForKeyedSubscript:@"parts"]             // @1026b0
                          objectAtIndexedSubscript:slot]
                         objectForKeyedSubscript:@"id"];                                        // @fc750
            if ([partId isEqual:@"arm_near"]) {                                                 // @102710
                look.alpha = [[frameData objectForKeyedSubscript:@"toyAlpha"] floatValue];      // @1039f0
            }
            look.tint = (WNGlowTint){ 1.0f, { 1.0f, 1.0f, 0.0f } };                             // 0x5b974
            [self drawMesh:[self quad] positions:toyPositions
                   texture:@"originals/props/toy-ball.png"                                      // @103a10
                     look:look.tint encoder:encoder];                                           // 0x5b9c0
        }

        // 0x5ba64–0x5bab4：本体颜色取 tint[0..3]，alpha 取 alpha[slot]。
        look.tint = (WNGlowTint){ [tint[0] floatValue], { [tint[1] floatValue],
                                                          [tint[2] floatValue],
                                                          [tint[3] floatValue] } };
        look.alpha = [[[frameData objectForKeyedSubscript:@"alpha"]                             // @102db0
                       objectAtIndexedSubscript:slot] floatValue];

        // 0x5bae0–0x5bb10：mesh 自身没有 texture 时用 face 兜底。
        id texture = [mesh texture];                                                            // 0x5bae4
        if (!texture) {
            texture = [frameData objectForKeyedSubscript:@"face"];                              // @101910
        }
        [self drawMesh:mesh positions:positionBuffer texture:texture
                 look:look.tint encoder:encoder];                                               // 0x5bb18
    }

    // 0x5bb28–0x5bbc0：前景层，位置回落到 quadPositions。
    look.tint = (WNGlowTint){ 1.0f, { 1.0f, 1.0f, 0.0f } };                                     // 0x5bb70
    look.alpha = 1.0f;                                                                          // 0x5bb78
    id foregroundPositions = [frameData objectForKeyedSubscript:@"foregroundPositions"];        // @103a30
    if (!foregroundPositions) {
        foregroundPositions = [self quadPositions];                                             // 0x5bb5c
    }
    [self drawMesh:[self quad] positions:foregroundPositions
           texture:[frameData objectForKeyedSubscript:@"foreground"]                            // @103a50
             look:look.tint encoder:encoder];                                                   // 0x5bbbc

    [encoder endEncoding];                                                                      // 0x5bbc4
}
#endif

@end
