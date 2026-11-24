//
//  PDHairTint.h
//  PetDFY 可编辑源码 · 发色自定义引擎
//
//  原理：不动 Metal 着色器，也不动模型顶点，只在「贴图进入 GPU 之前」把
//  头发部件的像素做 HSV 重映射。这样：
//    · 服装、姿态、变形器、命中蒙版全部不受影响（它们只认 alpha 与位置）；
//    · 任何新加的头发贴图都能自动获得发色能力（无需在代码里登记）；
//    · 高光/阴影/线稿由「保留明度 V、保留近黑像素」两条规则保住。
//
//  配置来源：CFPreferences 域 com.susudear.petdfyprefs（与设置面板同域）
//    HairTint              BOOL    总开关
//    HairTintMode          str     "preset" | "custom" | "rainbow"
//    HairTintPreset        str     预设名（见 +presets）
//    HairHue               double  0..360
//    HairSat               double  0..100（百分比，50 = 原饱和度的一半）
//    HairValue             double  40..160（明度乘子，100 = 不变）
//    HairTintStrength      double  0..100（混合强度，100 = 完全替换色相）
//    HairTintSmooth        BOOL    保护近黑线稿（默认 YES）
//    HairTintSpeed         double  0..100（彩虹流动速度）
//    HairTintParts         dict    可选：{ "hair_back": "#FF88AA", ... } 单部件覆盖
//    HairTintIncludeBrows  BOOL    是否连眉毛一起染（默认 NO）
//
//  也可由「长发色面板」在运行时写入，写完调用 -reload 即可热生效。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>

typedef NS_ENUM(NSInteger, PDHairTintMode) {
    PDHairTintModeOff = 0,
    PDHairTintModePreset,
    PDHairTintModeCustom,
    PDHairTintModeRainbow,
};

@interface PDHairTint : NSObject

+ (instancetype)shared;

/// 从 CFPreferences 重新读取全部配置。
- (void)reload;

@property (nonatomic, readonly) BOOL enabled;
@property (nonatomic, readonly) PDHairTintMode mode;
@property (nonatomic, readonly, copy) NSString *presetName;
@property (nonatomic, readonly) CGFloat hue;        // 0..360
@property (nonatomic, readonly) CGFloat saturation; // 0..1
@property (nonatomic, readonly) CGFloat value;      // 0.4..1.6
@property (nonatomic, readonly) CGFloat strength;   // 0..1
@property (nonatomic, readonly) BOOL smooth;
@property (nonatomic, readonly) CGFloat rainbowSpeed; // 0..1
@property (nonatomic, readonly, copy) NSDictionary<NSString *, NSString *> *partOverrides;

/// 官方模型里所有头发部件 id（大小写敏感，和 model.json 一致）。
+ (NSArray<NSString *> *)defaultHairParts;

/// 该部件是否属于「头发」。
- (BOOL)isHairPart:(NSString *)part;

/// 当前生效颜色（彩虹模式下随时间推进）。part 为部件 id，可单独覆盖。
- (UIColor *)colorForPart:(NSString *)part atTime:(double)seconds;

/// 是否需要在 seconds 这个时刻重建贴图（只有彩虹模式需要）。
- (BOOL)needsRefreshAtTime:(double)seconds;

/// 像素级重着色：返回 +1 保留的 CGImage。src 为原图，alpha 完整保留。
- (CGImageRef)newTintedImage:(CGImageRef)src
                         part:(NSString *)part
                        color:(UIColor *)color CF_RETURNS_RETAINED;

/// 由磁盘 PNG 生成 GPU 贴图（内部带缓存，按 part+颜色 键）。
/// 非头发部件或未启用时返回 nil，调用方应回退到原贴图。
- (id<MTLTexture>)newTextureForPart:(NSString *)part
                       absolutePath:(NSString *)absPath
                             device:(id<MTLDevice>)device
                             loader:(MTKTextureLoader *)loader;

/// 清空纹理与图像缓存（切主题/换服装/改配置后调用）。
- (void)invalidateCache;

/// 预设表：name -> hex（不含 # 亦可）。
+ (NSDictionary<NSString *, NSString *> *)presets;

/// 十六进制 ⇄ UIColor（#RRGGBB / #RRGGBBAA）。
+ (UIColor *)colorFromHex:(NSString *)hex;
+ (NSString *)hexFromColor:(UIColor *)color;

@end
