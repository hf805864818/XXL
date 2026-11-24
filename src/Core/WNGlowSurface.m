//
//  SmallClasses.m — 逆向还原：6 个小类
//
//  PDVoice              (5 方法 / 12 指令)   语音节点包装
//  WNGlowSurface        (9 方法 / 41 指令)   辉光表面
//  PDWindow             (3 方法 / 53 指令)   覆盖窗口（hitTest 穿透）
//  WNUploadSurface      (12 方法 / 71 指令)  上传表面
//  PDHostRootView       (2 方法 / 130 指令)  宿主根视图（点穿透）
//  PDChatPassthroughView(2 方法 / 130 指令)  聊天透传视图
//

#import "PDVoice.h"
#import "WNGlowSurface.h"
#import "PDWindow.h"
#import "WNUploadSurface.h"
#import "PDHostRootView.h"
#import "PDChatPassthroughView.h"
#import <AVFoundation/AVFoundation.h>
#import <MetalKit/MetalKit.h>
#import <UIKit/UIKit.h>

#pragma mark - WNGlowSurface

@implementation WNGlowSurface

@synthesize silhouette = _silhouette;
@synthesize blurred = _blurred;
@synthesize positions = _positions;

- (CGRect)stageRect { return _stageRect; }
- (void)setStageRect:(CGRect)v { _stageRect = v; }

@end

