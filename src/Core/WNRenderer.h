//
//  WNRenderer : NSObject
//  逆向还原：ivar/方法/属性来自二进制元数据
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

// glowTint 的 method_t types 在二进制里是 {?=f[3f]}（类型串表里有 "{?=f[3f]}16@0:8"）：
// 匿名结构体，+0 一个 float、+4 三个 float，共 16 字节；读写用 ldr/str q0,[x0,0x170]
//（getter 0x61bc8 / setter 0x61bd0）。用匿名 struct typedef 才能复现同样的 {?=...} 编码。
// 字段语义按 updateGlowColorForAppearance: 的两个常量取值：
//   dark  = (0.12, 0.13, 0.16, 1.0)
//   light = (0.92, 0.94, 0.98, 1.0)
// 即 r / (g, b, a) 顺序。
typedef struct {
    float r;
    float gba[3];
} WNGlowTint;

// Appearance uniform：Whale.metal 里 80 字节的结构体
//   struct Appearance { float4 tint; float alpha; float pad0..2;
//                       float4 clipX; float4 clipY; float4 clipRect; };
// 反汇编证据（-[WNRenderer drawMesh:positions:textureObject:look:encoder:] imp 0x57db0）：
//   0x57dd0  x22 = positions 参数         0x57e54 mesh.positionOffset → setVertexBuffer:offset:atIndex:0
//   0x57e90  setVertexBuffer:mesh.uv offset:0 atIndex:1
//   0x57ea8  setFragmentBytes:look length:0x50 atIndex:0     ← Appearance（80 字节，按指针传）
//   0x57eb8  setFragmentTexture:atIndex:0
//   0x57ef8  drawIndexedPrimitives:3(三角形) indexCount mesh.indexCount
//            indexType 0(UInt16) indexBuffer mesh.indices indexBufferOffset 0
//   0x57df8  look->alpha <= 常量(≈1/512) 时直接返回，不提交绘制
typedef struct WNLook {
    float tint[4];
    float alpha;
    float pad0;
    float pad1;
    float pad2;
    float clipX[4];
    float clipY[4];
    float clipRect[4];
} WNLook;

@interface WNRenderer : NSObject {
    struct CGPath * _interactionPath;
    BOOL _playing;
    BOOL _interactive;
    BOOL _responsiveInteraction;
    BOOL _darkAppearance;
    BOOL _didSubmitFrame;
    BOOL _buildsInteractionPath;
    float _glowAlpha;
    id<MTLDevice> _device;
    NSArray * _catalog;
    long long _frameIndex;
    long long _simulationFPS;
    long long _presentationFPS;
    WNLiveRig * _liveRig;
    NSURL * _resourceURL;
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _normalPipeline;
    id<MTLRenderPipelineState> _multiplyPipeline;
    id<MTLRenderPipelineState> _silhouettePipeline;
    id<MTLSamplerState> _sampler;
    MTKTextureLoader * _loader;
    NSCache * _textures;
    NSMutableDictionary * _liveTextures;
    NSMutableSet * _failedTextures;
    NSMutableDictionary * _hitTextures;
    WNClip * _current;
    WNMesh * _quad;
    id<MTLBuffer> _quadPositions;
    double _lastFrameAt;
    double _elapsed;
    double _liveAccumulator;
    WNPainter * _painter;
    WNClip * _liveClip;
    NSMutableArray * _performanceSamples;
    double _lastDiagnosticWrite;
    NSObject<OS_dispatch_queue> * _diagnosticsQueue;
    NSMutableDictionary * _uploadSurfaces;
    NSArray * _frameSlots;
    NSMutableDictionary * _livePositionBuffers;
    NSMutableDictionary * _toyPositionBuffers;
    NSArray * _liveTint;
    MPSImageGaussianBlur * _glowBlur;
    NSMutableDictionary * _glowSurfaces;
    unsigned long long _uploadFrame;
    NSMutableDictionary * _multisampleTargets;
    CGPoint _offset;
    CGSize _stageSize;
    WNGlowTint _glowTint;
    dispatch_semaphore_t _frameSemaphore;   // 帧同步（二进制 init 里 dispatch_semaphore_create）
}

@property (nonatomic, strong) NSURL * resourceURL;
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> queue;
@property (nonatomic, strong) id<MTLRenderPipelineState> normalPipeline;
@property (nonatomic, strong) id<MTLRenderPipelineState> multiplyPipeline;
@property (nonatomic, strong) id<MTLRenderPipelineState> silhouettePipeline;
@property (nonatomic, strong) id<MTLSamplerState> sampler;
@property (nonatomic, strong) MTKTextureLoader * loader;
@property (nonatomic, strong) NSCache * textures;
@property (nonatomic, strong) NSMutableDictionary * liveTextures;
@property (nonatomic, strong) NSMutableSet * failedTextures;
@property (nonatomic, strong) NSMutableDictionary * hitTextures;
@property (nonatomic, strong) NSArray * catalog;
@property (nonatomic, strong) WNClip * current;
@property (nonatomic, strong) WNMesh * quad;
@property (nonatomic, strong) id<MTLBuffer> quadPositions;
@property (nonatomic) double lastFrameAt;
@property (nonatomic) double elapsed;
@property (nonatomic) double liveAccumulator;
@property (nonatomic, strong) WNLiveRig * liveRig;
@property (nonatomic, strong) WNPainter * painter;
@property (nonatomic, strong) WNClip * liveClip;
@property (nonatomic, strong) NSMutableArray * performanceSamples;
@property (nonatomic) double lastDiagnosticWrite;
@property (nonatomic, strong) NSObject<OS_dispatch_queue> * diagnosticsQueue;
@property (nonatomic, strong) NSMutableDictionary * uploadSurfaces;
@property (nonatomic, strong) NSArray * frameSlots;
@property (nonatomic, strong) NSMutableDictionary * livePositionBuffers;
@property (nonatomic, strong) NSMutableDictionary * toyPositionBuffers;
@property (nonatomic, strong) NSArray * liveTint;
@property (nonatomic, strong) MPSImageGaussianBlur * glowBlur;
@property (nonatomic, strong) NSMutableDictionary * glowSurfaces;
@property (nonatomic) WNGlowTint glowTint;
@property (nonatomic) float glowAlpha;
@property (nonatomic) unsigned long long uploadFrame;
@property (nonatomic, strong) NSMutableDictionary * multisampleTargets;
@property (nonatomic) BOOL didSubmitFrame;
@property (nonatomic, readonly) NSDictionary * clipInfo;
@property (nonatomic) long long frameIndex;
@property (nonatomic) BOOL playing;
@property (nonatomic) CGPoint offset;
@property (nonatomic) BOOL interactive;
@property (nonatomic) BOOL responsiveInteraction;
@property (nonatomic) long long simulationFPS;
@property (nonatomic) long long presentationFPS;
@property (nonatomic) BOOL darkAppearance;
@property (nonatomic) CGSize stageSize;
@property (nonatomic) BOOL buildsInteractionPath;
@property (nonatomic, readonly) struct CGPath * interactionPath;
@property (nonatomic, readonly) unsigned long long hash;
@property (nonatomic, readonly) Class superclass;
@property (nonatomic, readonly, copy) NSString * description;
@property (nonatomic, readonly, copy) NSString * debugDescription;

- (void)dealloc;
- (struct CGPath *)interactionPath;
- (id)initWithResourceURL:(id)arg1;
- (id)initWithResourceURL:(id)arg1 liveOnly:(BOOL)arg2;
- (id)loadClip:(id)arg1;
- (id)meshesForParts:(id)arg1;
- (void)selectClip:(id)arg1;
- (id)texture:(id)arg1;
- (void)drawMesh:(id)arg1 positions:(id)arg2 texture:(id)arg3 look:(WNGlowTint)arg4 encoder:(id)arg5;
- (void)drawMesh:(id)arg1 positions:(id)arg2 textureObject:(id)arg3 look:(WNGlowTint)arg4 encoder:(id)arg5;
- (void)pd_drawMesh:(id)mesh positions:(id)positions textureObject:(id)tex lookPtr:(const WNLook *)look encoder:(id)encoder;
- (void *)liveFigureLook;
- (void)encodeClip:(id)arg1 frame:(unsigned long long)arg2 descriptor:(id)arg3 command:(id)arg4 offset:(CGPoint)arg5;
- (void)resetLiveWithScheme:(id)arg1 freeGround:(BOOL)arg2;
- (void)resetFrameClock;
- (void)setStageSize:(CGSize)arg1;
- (void)setResponsiveInteraction:(BOOL)arg1;
- (void)setDarkAppearance:(BOOL)arg1;
- (void)updateGlowColorForAppearance:(BOOL)arg1;
- (id)glowSurfaceForSlot:(unsigned long long)arg1 bodyBounds:(CGRect)arg2;
- (CGRect)liveFigureBounds;
- (void)encodeSilhouetteForCommand:(id)arg1 slot:(unsigned long long)arg2 positions:(id)arg3 frame:(id)arg4 surface:(id)arg5;
- (id)surfaceForKey:(id)arg1 slot:(unsigned long long)arg2 size:(CGSize)arg3;
- (id)paintSurface:(id)arg1 slot:(unsigned long long)arg2 rect:(CGRect)arg3 blit:(id)arg4;
- (id)preparedLiveClipForCommand:(id)arg1 slot:(unsigned long long)arg2;
- (id)preparedLiveClip;
- (void)updateInteractionPath;
- (void)mtkView:(id)arg1 drawableSizeWillChange:(CGSize)arg2;
- (id)renderPassForDrawable:(id)arg1 slot:(unsigned long long)arg2;
- (void)writeDiagnostics;
- (void)drawInMTKView:(id)arg1;
- (void)captureClip:(id)arg1 frame:(unsigned long long)arg2 URL:(id)arg3;
- (void)runAuditAtURL:(NSURL *)arg1 completion:(void (^)(NSArray *))arg2;
- (void)runInteractionAuditAtURL:(NSURL *)arg1 completion:(void (^)(NSArray *))arg2;
- (long long)frameIndex;
- (void)setFrameIndex:(long long)arg1;
- (BOOL)playing;
- (void)setPlaying:(BOOL)arg1;
- (CGPoint)offset;
- (void)setOffset:(CGPoint)arg1;
- (BOOL)interactive;
- (void)setInteractive:(BOOL)arg1;
- (BOOL)responsiveInteraction;
- (long long)simulationFPS;
- (void)setSimulationFPS:(long long)arg1;
- (long long)presentationFPS;
- (void)setPresentationFPS:(long long)arg1;
- (BOOL)isDarkAppearance;
- (CGSize)stageSize;
- (BOOL)didSubmitFrame;
- (void)setDidSubmitFrame:(BOOL)arg1;
- (BOOL)buildsInteractionPath;
- (void)setBuildsInteractionPath:(BOOL)arg1;
- (double)lastFrameAt;
- (void)setLastFrameAt:(double)arg1;
- (double)elapsed;
- (void)setElapsed:(double)arg1;
- (double)liveAccumulator;
- (void)setLiveAccumulator:(double)arg1;
- (double)lastDiagnosticWrite;
- (void)setLastDiagnosticWrite:(double)arg1;
- (float)glowAlpha;
- (void)setGlowAlpha:(float)arg1;
- (unsigned long long)uploadFrame;
- (void)setUploadFrame:(unsigned long long)arg1;
@end


#pragma mark - 编译补齐（PDStubs.m 提供实现）

@interface WNRenderer (PDStub)
/// 原版：把变形结果写回顶点缓冲
- (void)updateMesh;
/// view 坐标 → stage 坐标。原版实现缺失，当前恒等返回。
- (CGPoint)toStage:(CGPoint)viewportPoint;
@end
