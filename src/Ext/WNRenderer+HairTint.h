//
//  WNRenderer+HairTint.h
//  PetDFY 可编辑源码 · 渲染器发色挂接（分类，不污染原还原文件）
//

#import "WNRenderer.h"

@interface WNRenderer (PDHairTint)

/// 实时装配完成后调用：把头发部件的贴图按当前发色重着色，注入 liveTextures。
- (void)pdApplyHairTintForParts:(NSArray *)parts;

/// 每帧调用：彩虹模式下按 1/8 秒节流重建受影响头发的贴图。
- (void)pdRefreshHairTintAtTime:(NSNumber *)time;

/// 移除所有发色注入（关闭发色时调用）。
- (void)pdClearHairTint;

@end
