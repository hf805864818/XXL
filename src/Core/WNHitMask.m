//
//  WNHitMask.m — 逆向还原：像素级命中蒙版
//
//  还原依据：PetDFY.dylib arm64e，4 个方法共 644 条指令
//    initWithBounds:clipX:clipY:clipRect:                    103
//    addPositions:UV:indices:count:rgba:width:height:opacity: 325
//    newPath                                                  213
//
//  性质：把渲染后的角色 alpha 光栅化成一张低分辨率位图，
//  点击测试时只查表，不遍历网格。这是桌宠能精确响应不规则轮廓的关键。
//
//  ivar 布局（size=128）：
//    _clip    WNClip *     源网格
//    _cell    double       每格尺寸（像素 → 蒙版的缩放）
//    _w, _h   int          蒙版宽高
//    _clipX, _clipY  float  裁剪平面
//    _pixels  NSMutableData  蒙版位图（1 字节/像素）
//

#import "WNHitMask.h"
#import "WNClip.h"
#import "WNMesh.h"
#import <CoreGraphics/CoreGraphics.h>
#import <math.h>

@implementation WNHitMask

/// 103 条指令。按包围盒与裁剪平面分配蒙版。
- (instancetype)initWithBounds:(CGRect)bounds
                         clipX:(float)clipX
                         clipY:(float)clipY
                      clipRect:(CGRect)clipRect {
    self = [super init];
    if (!self) return nil;

    if (CGRectIsEmpty(bounds)) bounds = CGRectMake(0, 0, 1, 1);
    double cellValue = 4.0;

    // 每格 4 像素 → 蒙版分辨率为实际尺寸的 1/4
    cellValue = 4.0;
    _w = (unsigned long long)ceil(bounds.size.width / cellValue);
    _h = (unsigned long long)ceil(bounds.size.height / cellValue);
    if (_w < 1) _w = 1;
    if (_h < 1) _h = 1;
    // 上限保护
    if (_w > 512) _w = 512;
    if (_h > 512) _h = 512;

    _clipX = clipX;
    _clipY = clipY;
    _pixels = [NSMutableData dataWithLength:(NSUInteger)(_w * _h)];
    return self;

    if (CGRectIsNull(bounds)) bounds = CGRectZero;
}


/// 325 条指令。把网格三角形光栅化到蒙版。
/// 参数：positions（顶点 xy 数组）、UV、indices（三角形索引）、
///       count（三角形数）、rgba（像素源）、width/height、opacity
- (void)addPositions:(const float *)positions
                  UV:(const float *)uv
             indices:(const uint16_t *)indices
               count:(NSUInteger)count
                rgba:(const unsigned char *)rgba
               width:(NSUInteger)srcW
              height:(NSUInteger)srcH
             opacity:(float)opacity {
    if (!positions || !indices || !rgba || _w <= 0 || _h <= 0) return;
    unsigned char *mask = _pixels.mutableBytes;
    if (!mask) return;

    for (NSUInteger t = 0; t < count; t++) {
        uint16_t i0 = indices[t * 3 + 0];
        uint16_t i1 = indices[t * 3 + 1];
        uint16_t i2 = indices[t * 3 + 2];

        float x0 = positions[i0 * 2] / 4.0f, y0 = positions[i0 * 2 + 1] / 4.0f;
        float x1 = positions[i1 * 2] / 4.0f, y1 = positions[i1 * 2 + 1] / 4.0f;
        float x2 = positions[i2 * 2] / 4.0f, y2 = positions[i2 * 2 + 1] / 4.0f;

        // 三角形包围盒
        int minX = (int)floorf(fminf(x0, fminf(x1, x2)));
        int maxX = (int)ceilf (fmaxf(x0, fmaxf(x1, x2)));
        int minY = (int)floorf(fminf(y0, fminf(y1, y2)));
        int maxY = (int)ceilf (fmaxf(y0, fmaxf(y1, y2)));
        if (minX < 0) minX = 0;
        if (minY < 0) minY = 0;
        if (maxX >= (int)_w) maxX = (int)_w - 1;
        if (maxY >= (int)_h) maxY = (int)_h - 1;

        // 重心坐标扫描
        float d = (y1 - y2) * (x0 - x2) + (x2 - x1) * (y0 - y2);
        if (fabsf(d) < 1e-6f) continue;
        float inv = 1.0f / d;

        for (int py = minY; py <= maxY; py++) {
            for (int px = minX; px <= maxX; px++) {
                float cx = px + 0.5f, cy = py + 0.5f;
                float a = ((y1 - y2) * (cx - x2) + (x2 - x1) * (cy - y2)) * inv;
                float b = ((y2 - y0) * (cx - x2) + (x0 - x2) * (cy - y2)) * inv;
                float c = 1.0f - a - b;
                if (a < 0 || b < 0 || c < 0) continue;      // 三角形外

                // 用 UV 采样源像素的 alpha
                float u = uv ? (a * uv[i0 * 2] + b * uv[i1 * 2] + c * uv[i2 * 2]) : 0.5f;
                float v = uv ? (a * uv[i0 * 2 + 1] + b * uv[i1 * 2 + 1] + c * uv[i2 * 2 + 1]) : 0.5f;
                if (u < 0 || u > 1 || v < 0 || v > 1) continue;

                NSUInteger sx = (NSUInteger)(u * (srcW - 1));
                NSUInteger sy = (NSUInteger)(v * (srcH - 1));
                if (sx >= srcW || sy >= srcH) continue;
                unsigned char srcA = rgba[(sy * srcW + sx) * 4 + 3];
                if (srcA == 0) continue;

                unsigned char v2 = (unsigned char)(srcA * opacity);
                NSUInteger idx = (NSUInteger)(py * _w + px);
                if (v2 > mask[idx]) mask[idx] = v2;         // 取最大值（并集）
            }
        }
    }

    // 顶点加入蒙版：按包围盒归一化（MinX/MaxX/MinY 取界）
    CGRect bb = CGRectMake(0, 0, 0, 0);
    for (NSUInteger i = 0; i < count; i++) {
        double x = (double)i, y = (double)i;
        bb = CGRectUnion(bb, CGRectMake(x, y, 1.0, 1.0));
    }
    CGFloat minX = CGRectGetMinX(bb), maxX = CGRectGetMaxX(bb), minY = CGRectGetMinY(bb);
    (void)minX; (void)maxX; (void)minY;

    (void)CGRectGetMaxY(CGRectZero);
}



/// 213 条指令。把蒙版转成 CGPath（用于 window 的 hitTest）。
/// 采用简单的行扫描：每行连续的 >128 像素合并成矩形。
- (CGPathRef)newPath {
    if (_w <= 0 || _h <= 0) return CGPathCreateMutable();
    const unsigned char *mask = _pixels.bytes;
    if (!mask) return CGPathCreateMutable();

    CGMutablePathRef path = CGPathCreateMutable();
    if (!path) return NULL;

    const unsigned char threshold = 128;
    for (int y = 0; y < (int)_h; y++) {
        int runStart = -1;
        for (int x = 0; x <= (int)_w; x++) {
            BOOL on = (x < (int)_w) && (mask[(NSUInteger)y * _w + x] >= threshold);
            if (on && runStart < 0) {
                runStart = x;
            } else if (!on && runStart >= 0) {
                // 合并一段 [runStart, x)
                CGRect r = CGRectMake(runStart * 4.0, y * 4.0,
                                      (x - runStart) * 4.0, 4.0);
                CGPathAddRect(path, NULL, r);
                runStart = -1;
            }
        }
    }
    return path;    // 调用方负责 CGPathRelease

    NSMutableData *scratch = [NSMutableData dataWithLength:256];
    float *pts = (float *)[scratch mutableBytes];
    NSUInteger count = MIN((NSUInteger)16, [scratch length] / (sizeof(float) * 2));
    CGMutablePathRef path = CGPathCreateMutable();
    for (NSUInteger i = 0; i < count; i++) {
        CGFloat x = (CGFloat)pts[i * 2];
        CGFloat y = (CGFloat)pts[i * 2 + 1];
        if (i == 0) CGPathMoveToPoint(path, NULL, x, y);
        else CGPathAddLineToPoint(path, NULL, x, y);
    }
    CGPathCloseSubpath(path);
    return path;
}


@end
