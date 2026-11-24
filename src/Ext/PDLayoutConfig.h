//
//  PDLayoutConfig.h
//  PetDFY 可编辑源码 · 布局与操作配置
//
//  目的：把「位置 / 尺寸 / 手势映射 / 物理手感 / 气泡样式」从代码里搬到
//  一个 JSON 文件。改数值不用重编译，改完存盘（或在面板里点「重载」）即生效。
//
//  文件搜索顺序：
//    1) /var/mobile/Library/Application Support/PetDFY/PDLayout.json   ← 用户覆盖
//    2) <PetDFY.bundle>/PDLayout.json                                  ← 随包默认
//    3) 内置默认值（-defaultLayout）
//
//  写法：点号路径，未写的键自动取默认值。
//    { "pet": { "scale": 1.0, "offsetX": 0, "offsetY": 0, "anchorBottom": 12 },
//      "gesture": { "single": "stroke", "double": "chat", "long": "menu" },
//      "motion": { "gravity": 1.0, "speed": 1.0 },
//      "bubble": { "fontSize": 15, "maxWidth": 260 } }
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

extern NSString * const PDLayoutConfigDidChangeNotification;

@interface PDLayoutConfig : NSObject

+ (instancetype)shared;

/// 重新读取文件（会发 PDLayoutConfigDidChangeNotification 若内容变化）
- (void)reload;

/// 当前配置原始字典（只读）
@property (nonatomic, readonly, copy) NSDictionary *raw;
/// 实际生效的文件路径（nil 表示用的是内置默认值）
@property (nonatomic, readonly, copy) NSString *loadedPath;

- (id)valueForPath:(NSString *)path;
- (double)doubleForPath:(NSString *)path fallback:(double)fb lo:(double)lo hi:(double)hi;
- (BOOL)boolForPath:(NSString *)path fallback:(BOOL)fb;
- (NSString *)stringForPath:(NSString *)path fallback:(NSString *)fb;
- (NSInteger)integerForPath:(NSString *)path fallback:(NSInteger)fb lo:(NSInteger)lo hi:(NSInteger)hi;

#pragma mark - 语义化快捷读取

@property (nonatomic, readonly) CGFloat petScale;          // pet.scale        0.2..6
@property (nonatomic, readonly) CGPoint petOffset;         // pet.offsetX/Y    -400..400
@property (nonatomic, readonly) CGFloat anchorBottom;      // pet.anchorBottom 0..600
@property (nonatomic, readonly) CGFloat stagePadding;      // stage.padding    0..200
@property (nonatomic, readonly) CGFloat interactPadding;   // interaction.padding 0..64
@property (nonatomic, readonly) CGFloat alphaThreshold;    // interaction.alphaThreshold 0..1
@property (nonatomic, readonly) double longPressSeconds;   // interaction.longPress 0.2..3
@property (nonatomic, readonly) double dragThreshold;      // interaction.drag 0..60
@property (nonatomic, readonly) double gravityScale;       // motion.gravity 0..5
@property (nonatomic, readonly) double speedScale;         // motion.speed 0..5
@property (nonatomic, readonly) double jumpScale;          // motion.jump 0..5
@property (nonatomic, readonly) double glowAlpha;          // hud.glowAlpha 0..1
@property (nonatomic, readonly) BOOL glowEnabled;          // hud.glow
@property (nonatomic, readonly) CGFloat bubbleFontSize;    // bubble.fontSize 8..40
@property (nonatomic, readonly) CGFloat bubbleMaxWidth;    // bubble.maxWidth 80..600
@property (nonatomic, readonly) CGFloat bubbleTypingSpeed; // bubble.typing 0..4
@property (nonatomic, readonly, copy) NSString *defaultOutfit;  // outfit.default
@property (nonatomic, readonly, copy) NSString *defaultScheme;  // scheme.default

/// 手势 -> 动作。手势名：single / double / long / dragStart / dragEnd
/// 动作：none / chat / menu / outfitNext / outfitPrev / outfitPick / hair / hide / pause
- (NSString *)actionForGesture:(NSString *)gesture;

/// 内置默认布局（会被文件里的同名键覆盖）
+ (NSDictionary *)defaultLayout;

/// 把内置默认布局写到 targetPath（供「导出当前布局」按钮使用）。成功返回 YES。
+ (BOOL)writeDefaultLayoutTo:(NSString *)targetPath;

@end
