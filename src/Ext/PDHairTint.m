//
//  PDHairTint.m
//  PetDFY 可编辑源码 · 发色自定义引擎
//

#import "PDHairTint.h"
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>

static NSString * const kPDHairDomain = @"com.susudear.petdfyprefs";

static id PDHairRaw(NSString *key) {
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                       (__bridge CFStringRef)kPDHairDomain));
}

static BOOL PDHairBool(NSString *key, BOOL def) {
    id v = PDHairRaw(key);
    if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v boolValue];
    return def;
}

static double PDHairNum(NSString *key, double def, double lo, double hi) {
    id v = PDHairRaw(key);
    double d = [v isKindOfClass:[NSNumber class]] ? [v doubleValue] : def;
    if (isnan(d)) d = def;
    if (d < lo) d = lo;
    if (d > hi) d = hi;
    return d;
}

static NSString *PDHairStr(NSString *key, NSString *def) {
    id v = PDHairRaw(key);
    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) return v;
    return def;
}

#pragma mark - HSV 工具

typedef struct { double h, s, v; } PDHSV;

static PDHSV PDRGB2HSV(double r, double g, double b) {
    double mx = fmax(r, fmax(g, b));
    double mn = fmin(r, fmin(g, b));
    double d = mx - mn;
    PDHSV out = {0, 0, mx};
    if (mx <= 0.0 || d <= 0.0) { out.h = 0; out.s = 0; return out; }
    out.s = d / mx;
    if (mx == r)      out.h = fmod(((g - b) / d), 6.0);
    else if (mx == g) out.h = ((b - r) / d) + 2.0;
    else              out.h = ((r - g) / d) + 4.0;
    out.h *= 60.0;
    if (out.h < 0) out.h += 360.0;
    return out;
}

static void PDHSV2RGB(PDHSV in, double *r, double *g, double *b) {
    double h = fmod(in.h, 360.0);
    if (h < 0) h += 360.0;
    double c = in.v * in.s;
    double x = c * (1.0 - fabs(fmod(h / 60.0, 2.0) - 1.0));
    double m = in.v - c;
    double rr = 0, gg = 0, bb = 0;
    if (h < 60)       { rr = c; gg = x; bb = 0; }
    else if (h < 120) { rr = x; gg = c; bb = 0; }
    else if (h < 180) { rr = 0; gg = c; bb = x; }
    else if (h < 240) { rr = 0; gg = x; bb = c; }
    else if (h < 300) { rr = x; gg = 0; bb = c; }
    else              { rr = c; gg = 0; bb = x; }
    *r = rr + m; *g = gg + m; *b = bb + m;
}

static double PDClamp(double v, double lo, double hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

@implementation PDHairTint {
    NSCache<NSString *, id> *_imageCache;
    NSMutableDictionary<NSString *, id> *_textureCache;
    NSMutableDictionary<NSString *, NSNumber *> *_textureStamp;
    double _lastRefreshAt;
    double _refreshInterval;
}

+ (instancetype)shared {
    static PDHairTint *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[PDHairTint alloc] init]; });
    return s;
}

- (id)init {
    self = [super init];
    if (self) {
        _imageCache = [NSCache new];
        _imageCache.countLimit = 64;
        _textureCache = [NSMutableDictionary dictionary];
        _textureStamp = [NSMutableDictionary dictionary];
        _refreshInterval = 1.0 / 8.0;
        _partOverrides = @{};
        [self reload];
    }
    return self;
}

#pragma mark - 配置

+ (NSArray<NSString *> *)defaultHairParts {
    // 官方四个模型里出现过的全部头发部件（maid/cape/crew/sailor 并集）
    return @[
        @"hair_back", @"hair_back_curl", @"hair_front_left", @"hair_front_right",
        @"sidelocks", @"bangs", @"ahoge", @"tail",
        @"ponytail", @"crew_hair_back", @"crew_ponytail", @"crew_sidelocks",
        @"brow", @"brow0", @"brow1", @"browOver0", @"browOver1",
    ];
}

- (void)reload {
    _enabled = PDHairBool(@"HairTint", NO);

    NSString *modeStr = PDHairStr(@"HairTintMode", @"preset");
    if ([modeStr isEqualToString:@"custom"])       _mode = PDHairTintModeCustom;
    else if ([modeStr isEqualToString:@"rainbow"]) _mode = PDHairTintModeRainbow;
    else                                           _mode = PDHairTintModePreset;
    if (!_enabled) _mode = PDHairTintModeOff;

    _presetName = [PDHairStr(@"HairTintPreset", @"sakura") copy];

    NSDictionary *presets = [PDHairTint presets];
    UIColor *presetColor = nil;
    NSString *hex = presets[_presetName];
    if (hex) presetColor = [PDHairTint colorFromHex:hex];

    CGFloat ph = 330.0, ps = 0.55, pv = 1.0;
    if (presetColor) {
        CGFloat r = 0, g = 0, b = 0, a = 1;
        if ([presetColor getRed:&r green:&g blue:&b alpha:&a]) {
            PDHSV hsv = PDRGB2HSV(r, g, b);
            ph = hsv.h; ps = hsv.s; pv = hsv.v > 0.05 ? hsv.v : 1.0;
        }
    }

    // custom/preset 都允许用滑杆微调：滑杆未设置时以预设为初值
    _hue        = (CGFloat)PDHairNum(@"HairHue", ph, 0.0, 360.0);
    _saturation = (CGFloat)(PDHairNum(@"HairSat", ps * 100.0, 0.0, 100.0) / 100.0);
    _value      = (CGFloat)(PDHairNum(@"HairValue", pv * 100.0, 40.0, 160.0) / 100.0);
    _strength   = (CGFloat)(PDHairNum(@"HairTintStrength", 100.0, 0.0, 100.0) / 100.0);
    _smooth     = PDHairBool(@"HairTintSmooth", YES);
    _rainbowSpeed = (CGFloat)(PDHairNum(@"HairTintSpeed", 40.0, 0.0, 100.0) / 100.0);

    id parts = PDHairRaw(@"HairTintParts");
    if ([parts isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *clean = [NSMutableDictionary dictionary];
        [(NSDictionary *)parts enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
            if ([k isKindOfClass:[NSString class]] && [v isKindOfClass:[NSString class]]) {
                clean[k] = v;
            }
        }];
        _partOverrides = [clean copy];
    } else {
        _partOverrides = @{};
    }

    [self invalidateCache];
}

- (BOOL)isHairPart:(NSString *)part {
    if (![part isKindOfClass:[NSString class]] || part.length == 0) return NO;
    if ([part isEqualToString:@"face"] || [part isEqualToString:@"faceFx"] ||
        [part isEqualToString:@"eye_creases"] || [part hasPrefix:@"brow"]) {
        if ([part hasPrefix:@"brow"]) return PDHairBool(@"HairTintIncludeBrows", NO);
        return NO;
    }
    static NSSet *set = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSSet setWithArray:[PDHairTint defaultHairParts]]; });
    if ([set containsObject:part]) return YES;
    // 兜底：名字里带 hair 的部件（新服装自定义头发命名也能吃到）
    return [part rangeOfString:@"hair" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

- (UIColor *)colorForPart:(NSString *)part atTime:(double)seconds {
    NSString *override = _partOverrides[part ?: @""];
    if (override.length) {
        UIColor *c = [PDHairTint colorFromHex:override];
        if (c) return c;
    }
    if (_mode == PDHairTintModeRainbow) {
        double h = fmod(_hue + seconds * (10.0 + _rainbowSpeed * 110.0), 360.0);
        double r, g, b;
        PDHSV hsv = { h, _saturation, _value };
        PDHSV2RGB(hsv, &r, &g, &b);
        return [UIColor colorWithRed:r green:g blue:b alpha:1.0];
    }
    double r, g, b;
    PDHSV hsv = { _hue, _saturation, _value };
    PDHSV2RGB(hsv, &r, &g, &b);
    return [UIColor colorWithRed:(CGFloat)PDClamp(r, 0, 1)
                           green:(CGFloat)PDClamp(g, 0, 1)
                            blue:(CGFloat)PDClamp(b, 0, 1)
                           alpha:1.0];
}

- (BOOL)needsRefreshAtTime:(double)seconds {
    if (!_enabled || _mode != PDHairTintModeRainbow) return NO;
    if (seconds - _lastRefreshAt < _refreshInterval) return NO;
    _lastRefreshAt = seconds;
    return YES;
}

#pragma mark - 像素重着色

- (CGImageRef)newTintedImage:(CGImageRef)src part:(NSString *)part color:(UIColor *)color {
    if (!src || !color) return NULL;
    size_t w = CGImageGetWidth(src);
    size_t h = CGImageGetHeight(src);
    if (w == 0 || h == 0 || w > 4096 || h > 4096) return CGImageRetain(src);

    size_t bytesPerRow = w * 4;
    NSMutableData *buf = [NSMutableData dataWithLength:bytesPerRow * h];
    if (!buf.length) return CGImageRetain(src);

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf.mutableBytes, w, h, 8, bytesPerRow, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) return CGImageRetain(src);

    CGContextSetBlendMode(ctx, kCGBlendModeCopy);
    CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h), src);
    CGContextRelease(ctx);

    CGFloat tr = 0, tg = 0, tb = 0, ta = 1;
    if (![color getRed:&tr green:&tg blue:&tb alpha:&ta]) {
        return CGImageRetain(src);
    }
    PDHSV tintHSV = PDRGB2HSV(tr, tg, tb);

    unsigned char *px = (unsigned char *)buf.mutableBytes;
    const size_t n = w * h;
    const double strength = (double)_strength;
    const double valueScale = (double)_value;
    const double satScale = (double)_saturation;
    const BOOL smooth = _smooth;

    for (size_t i = 0; i < n; i++) {
        unsigned char *p = px + i * 4;
        unsigned int a = p[3];
        if (a == 0) continue;

        // 反预乘
        double r = (double)p[0] / (double)a;
        double g = (double)p[1] / (double)a;
        double b = (double)p[2] / (double)a;
        r = PDClamp(r, 0, 1); g = PDClamp(g, 0, 1); b = PDClamp(b, 0, 1);

        PDHSV hsv = PDRGB2HSV(r, g, b);

        // 近黑线稿保护：明度很低且饱和度低 → 原样保留
        if (smooth && hsv.v < 0.10 && hsv.s < 0.35) continue;
        // 纯白高光保护：过曝区不给染（否则高光变灰）
        if (smooth && hsv.v > 0.985 && hsv.s < 0.04) continue;

        PDHSV out;
        // 色相：完全采用目标色相（纱状发丝仍由 V 保留明暗）
        out.h = tintHSV.h;
        // 饱和度：以原饱和度为系数做缩放，保留发丝的层次差
        out.s = PDClamp(satScale * (0.45 + 0.85 * hsv.s), 0.0, 1.0);
        // 明度：原明度 × 明度乘子，夹在合法区间
        out.v = PDClamp(hsv.v * valueScale, 0.0, 1.0);

        double nr, ng, nb;
        PDHSV2RGB(out, &nr, &ng, &nb);

        // 强度混合
        nr = r + (nr - r) * strength;
        ng = g + (ng - g) * strength;
        nb = b + (nb - b) * strength;

        // 重新预乘
        p[0] = (unsigned char)lrint(PDClamp(nr, 0, 1) * a);
        p[1] = (unsigned char)lrint(PDClamp(ng, 0, 1) * a);
        p[2] = (unsigned char)lrint(PDClamp(nb, 0, 1) * a);
        p[3] = (unsigned char)a;
    }

    CGColorSpaceRef cs2 = CGColorSpaceCreateDeviceRGB();
    CGContextRef octx = CGBitmapContextCreate(buf.mutableBytes, w, h, 8, bytesPerRow, cs2,
                                              kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs2);
    if (!octx) return CGImageRetain(src);
    CGImageRef out = CGBitmapContextCreateImage(octx);
    CGContextRelease(octx);
    return out ? out : CGImageRetain(src);
}

#pragma mark - 纹理

- (id<MTLTexture>)newTextureForPart:(NSString *)part
                       absolutePath:(NSString *)absPath
                             device:(id<MTLDevice>)device
                             loader:(MTKTextureLoader *)loader {
    if (!_enabled || _mode == PDHairTintModeOff) return nil;
    if (![self isHairPart:part]) return nil;
    if (!absPath.length || !device || !loader) return nil;

    UIColor *color = [self colorForPart:part atTime:CACurrentMediaTime()];
    NSString *hex = [PDHairTint hexFromColor:color];
    NSString *key = [NSString stringWithFormat:@"%@|%@|%.2f|%.2f", part, hex, _strength, _value];

    id<MTLTexture> cached = _textureCache[key];
    if (cached) return cached;

    NSData *data = [NSData dataWithContentsOfFile:absPath];
    if (!data.length) return nil;

    UIImage *img = [UIImage imageWithData:data];
    if (!img || !img.CGImage) return nil;

    CGImageRef tinted = [self newTintedImage:img.CGImage part:part color:color];
    if (!tinted) return nil;

    NSDictionary *opts = @{ MTKTextureLoaderOptionSRGB: @NO,
                            MTKTextureLoaderOptionTextureUsage: @(MTLTextureUsageShaderRead) };
    NSError *err = nil;
    id<MTLTexture> tex = [loader newTextureWithCGImage:tinted options:opts error:&err];
    CGImageRelease(tinted);
    if (!tex) return nil;

    // 缓存上限：按部件数保持有限条目，避免彩虹模式无限膨胀
    if (_textureCache.count > 96) [_textureCache removeAllObjects];
    _textureCache[key] = tex;
    _textureStamp[part] = @(_lastRefreshAt);
    return tex;
}

- (void)invalidateCache {
    [_imageCache removeAllObjects];
    [_textureCache removeAllObjects];
    [_textureStamp removeAllObjects];
    _lastRefreshAt = 0;
}

#pragma mark - 颜色工具

+ (NSDictionary<NSString *, NSString *> *)presets {
    return @{
        @"sakura":    @"#FFB3D1",   // 樱花粉
        @"mint":      @"#8FE3C4",   // 薄荷绿
        @"sky":       @"#8FC7FF",   // 天空蓝
        @"lavender":  @"#C4A7FF",   // 薰衣草
        @"amber":     @"#FFC661",   // 蜜糖金
        @"scarlet":   @"#FF6B6B",   // 烈焰红
        @"silver":    @"#D8DEE9",   // 银白
        @"ink":       @"#2E3440",   // 墨黑
        @"matcha":    @"#A8C97F",   // 抹茶
        @"peach":     @"#FFB38A",   // 蜜桃
    };
}

+ (UIColor *)colorFromHex:(NSString *)hex {
    if (![hex isKindOfClass:[NSString class]]) return nil;
    NSString *s = [[hex stringByReplacingOccurrencesOfString:@"#" withString:@""]
                   stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (s.length != 6 && s.length != 8) return nil;
    unsigned long long v = 0;
    NSScanner *sc = [NSScanner scannerWithString:s];
    if (![sc scanHexLongLong:&v]) return nil;
    CGFloat r, g, b, a = 1.0;
    if (s.length == 8) {
        r = ((v >> 24) & 0xFF) / 255.0;
        g = ((v >> 16) & 0xFF) / 255.0;
        b = ((v >> 8) & 0xFF) / 255.0;
        a = (v & 0xFF) / 255.0;
    } else {
        r = ((v >> 16) & 0xFF) / 255.0;
        g = ((v >> 8) & 0xFF) / 255.0;
        b = (v & 0xFF) / 255.0;
    }
    return [UIColor colorWithRed:r green:g blue:b alpha:a];
}

+ (NSString *)hexFromColor:(UIColor *)color {
    CGFloat r = 0, g = 0, b = 0, a = 1;
    if (!color || ![color getRed:&r green:&g blue:&b alpha:&a]) return @"#FFFFFF";
    return [NSString stringWithFormat:@"#%02X%02X%02X",
            (unsigned)lrint(PDClamp(r, 0, 1) * 255),
            (unsigned)lrint(PDClamp(g, 0, 1) * 255),
            (unsigned)lrint(PDClamp(b, 0, 1) * 255)];
}

@end
