//
//  PDNative_ScreenGeometry.h — 逆向还原
//
//  二进制中的两个 C 函数（在 __init_offsets 里，不是 ObjC 方法）：
//    void  _PDNative_MCPGetScreenGeometry(PDMCPScreenGeometry *out)    // 0x735fc
//    id    _PDNative_MCPInterfaceOrientationName(int64_t orientation)  // 0x738ac
//
//  被 PDNative_ScreenManager.screenInfo / captureScreenImageWithGeometry:
//  以及 AX 相关类（PDNative_MCPAXRemoteContextResolver 等）共用。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>

/// 屏幕几何快照，120 字节（0x78）。
///
/// 布局取自 `captureScreenImageWithGeometry:` 的运行时类型编码：
///   ^{?={CGRect={CGPoint=dd}{CGSize=dd}}{CGRect={CGPoint=dd}{CGSize=dd}}{CGAffineTransform=dddddd}q}
/// 偏移由 0x735fc 的收尾拷贝逐条核对（block byref 在 +0x20，方法拷到 out+0x00）：
///   out+0x00 ← byref+0x20  CGRect   fixed bounds
///   out+0x20 ← byref+0x40  CGRect   coord bounds
///   out+0x40 ← byref+0x60  (a=ax, b=ay, c=bx, d=by)
///   out+0x60 ← byref+0x80  (tx=p0.x, ty=p0.y)
///   out+0x70 ← byref+0x90  int64    orientation
typedef struct PDMCPScreenGeometry {
    CGRect            fixedBounds;    ///< 0x00 UIScreen.fixedCoordinateSpace.bounds（与方向无关）
    CGRect            screenBounds;   ///< 0x20 UIScreen.coordinateSpace.bounds（随方向旋转）
    CGAffineTransform fixedToScreen;  ///< 0x40 a=ax b=ay c=bx d=by tx=p0.x ty=p0.y
    int64_t           orientation;    ///< 0x70 1..4，其它为未知
} PDMCPScreenGeometry;

/// 取当前屏幕几何（内部收敛到主线程，非主线程调用安全）。
FOUNDATION_EXPORT void PDNative_MCPGetScreenGeometry(PDMCPScreenGeometry *out);

/// 1→portrait 2→portrait_upside_down 3→landscape_right 4→landscape_left，其它→"unknown"。
FOUNDATION_EXPORT NSString *PDNative_MCPInterfaceOrientationName(int64_t orientation);
