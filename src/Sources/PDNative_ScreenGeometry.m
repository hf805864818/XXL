//
//  PDNative_ScreenGeometry.m — 逆向还原
//
//  对应二进制中的两个 C 函数（不是 ObjC 方法，位于 __init_offsets 段）：
//
//    _PDNative_MCPGetScreenGeometry       0x735fc  （实现块 0x73720，208 指令）
//    _PDNative_MCPInterfaceOrientationName 0x738ac  （16 指令，字符串表 @0xfa280）
//
//  ── 几何块反汇编要点（0x73720..0x738a8）────────────────────────────────
//    fixed = UIScreen.mainScreen.fixedCoordinateSpace
//    coord = UIScreen.mainScreen.coordinateSpace
//    p0 = [fixed convertPoint:CGPointZero fromCoordinateSpace:coord]
//    p1 = [fixed convertPoint:(1,0)      fromCoordinateSpace:coord]
//    p2 = [fixed convertPoint:(0,1)      fromCoordinateSpace:coord]
//    ax = p1.x-p0.x ; ay = p1.y-p0.y          // x 轴单位向量（fixed 空间）
//    bx = p2.x-p0.x ; by = p2.y-p0.y          // y 轴单位向量
//    方向判定（阈值 ±0.5）：
//        ay >  0.5 → 4   ay < -0.5 → 3
//        ax < -0.5 → 2   否则      → 1
//    out.fixedBounds  = [fixed bounds]
//    out.screenBounds = [coord bounds]
//    out.fixedToScreen = CGAffineTransformMake(ax, ay, bx, by, p0.x, p0.y)
//    out.orientation  = 上面的 1..4
//
//  方向名表（@0xfa280，index = orientation-1）：
//    1 portrait / 2 portrait_upside_down / 3 landscape_right / 4 landscape_left
//    其它 → "unknown"
//
//  调用方会先判 isMainThread，非主线程走 dispatch_sync(main)，
//  所以本函数内部同样做了主线程收敛（与原实现一致）。
//

#import "PDNative_ScreenGeometry.h"

static NSString *PDOrientationNameTable(int64_t orientation) {
    static NSString *names[4];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names[0] = @"portrait";
        names[1] = @"portrait_upside_down";
        names[2] = @"landscape_right";
        names[3] = @"landscape_left";
    });
    if (orientation >= 1 && orientation <= 4) {
        return names[orientation - 1];
    }
    return @"unknown";
}

NSString *PDNative_MCPInterfaceOrientationName(int64_t orientation) {
    return PDOrientationNameTable(orientation);
}

static void PDCollectScreenGeometry(PDMCPScreenGeometry *out) {
    if (!out) {
        return;
    }

    UIScreen *screen = [UIScreen mainScreen];
    id<UICoordinateSpace> coord = [screen coordinateSpace];
    id<UICoordinateSpace> fixed = [screen fixedCoordinateSpace];

    CGPoint p0 = CGPointZero;
    CGPoint p1 = CGPointMake(1.0, 0.0);
    CGPoint p2 = CGPointMake(0.0, 1.0);

    p0 = [fixed convertPoint:p0 fromCoordinateSpace:coord];
    p1 = [fixed convertPoint:p1 fromCoordinateSpace:coord];
    p2 = [fixed convertPoint:p2 fromCoordinateSpace:coord];

    double ax = p1.x - p0.x;
    double ay = p1.y - p0.y;
    double bx = p2.x - p0.x;
    double by = p2.y - p0.y;

    int64_t orientation;
    if (ay > 0.5) {
        orientation = 4;
    } else if (ay < -0.5) {
        orientation = 3;
    } else if (ax < -0.5) {
        orientation = 2;
    } else {
        orientation = 1;
    }

    out->fixedBounds = [fixed bounds];
    out->screenBounds = [coord bounds];
    out->fixedToScreen = CGAffineTransformMake(ax, ay, bx, by, p0.x, p0.y);
    out->orientation = orientation;
}

void PDNative_MCPGetScreenGeometry(PDMCPScreenGeometry *out) {
    if (!out) {
        return;
    }
    if ([NSThread isMainThread]) {
        PDCollectScreenGeometry(out);
        return;
    }
    dispatch_sync(dispatch_get_main_queue(), ^{
        PDCollectScreenGeometry(out);
    });
}
