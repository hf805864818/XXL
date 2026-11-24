//
//  PDNative_ScreenManager : NSObject
//  逆向还原：ivar/方法/属性来自二进制元数据
//
//  实例大小 8 字节（无 ivar），是无状态工具类 + 单例。
//  依赖的 C 函数见 PDNative_ScreenGeometry.h。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"
#import "PDNative_ScreenGeometry.h"

@interface PDNative_ScreenManager : NSObject {
}

/// 屏幕几何 + 设备交互状态（锁屏/亮屏），共 12 个键。
- (id)screenInfo;

/// 只返回设备交互状态字典（永不返回 nil）。
- (id)deviceInteractionState;

/// 同上，但必须已在主线程调用。
- (id)deviceInteractionStateOnMainThread;

/// 截图 payload：私有 API 四路回退，全失败再退回窗口捕获。
- (id)takeScreenshotPayload;

/// 私有 API 四路回退：getScreenDataWithQuantity / render server / _UICreateScreenUIImage / IOSurface。
- (id)privateScreenshotPayload;

- (id)payloadByEncodingImageData:(id)arg1 source:(id)arg2;
- (id)payloadByEncodingImage:(id)arg1 source:(id)arg2;

/// 私有 API 图像回退链（不含窗口捕获）。
- (id)privateScreenshotImage;

/// 等价于 captureScreenImageWithGeometry:NULL。
- (id)captureScreenImage;

/// 抓屏并把屏幕几何写进 *geometry（可为 NULL）。
- (id)captureScreenImageWithGeometry:(PDMCPScreenGeometry *)geometry;

- (id)screenshotImageFromRenderServerCapture;
- (id)screenshotImageFromUICreateScreenUIImage;
- (id)screenshotImageFromIOSurface;

/// CGImage → UIImage，强制 32 位 RGBA 位图（避免延迟解码 / 色彩空间问题）。
- (id)bitmapImageFromCGImage:(struct CGImage *)arg1 scale:(double)arg2;

/// 最后的兜底：找 keyWindow 用 drawViewHierarchyInRect 画一张。
- (id)fallbackScreenshotImage;

- (id)encodedPayloadForImage:(id)arg1;
- (id)payloadWithData:(id)arg1 mimeType:(id)arg2 image:(id)arg3;
- (CGSize)pixelSizeForImage:(id)arg1;

/// 把 Retina 像素图缩到「点尺寸」，保证截图坐标 == 屏幕坐标。
- (id)pointSizedImageFromImage:(id)arg1;

/// JPEG 编码并二分压缩到 maxBytes 以内（下限 0.3，上限 0.82）。
- (id)JPEGDataForImage:(id)arg1 maxBytes:(unsigned long long)arg2;

+ (id)sharedInstance;

/// 老式私有 API：UIWindow createScreenIOSurface → UIImageJPEGRepresentation。
+ (id)getScreenDataWithQuantity:(long long)arg1;

@end
