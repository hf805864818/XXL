//
//  PDPreferences.m
//  逆向还原 v2：reload 按二进制 0x42d04 (612 B) 逐条重写
//
//  二进制实测（arm64e, PetDFY.arm64e.dylib）：
//    domain      com.susudear.petdfyprefs
//    +0x08 _enabled                    ReadBool("Enabled")                 默认 YES
//    +0x09 _interactive                ReadBool("Interactive")             默认 YES
//    +0x0a _responsive                 ReadBool("Responsive")              默认 YES
//    +0x0b _soundEnabled               ReadBool("Sound")                   默认 YES
//    +0x0c _stroking                   InputMode == "stroke"               默认 "grab"
//    +0x0d _keyboardAvoidanceEnabled   ReadBool("KeyboardAvoidanceEnabled")默认 YES
//    +0x10 _size                       Size(128,72,220) * PetScale(1.0,0.5,10.0)
//    +0x18 _bottomInset                BottomInset(12,0,Size)  上限跟随 Size 读取值
//    +0x20 _keyboardAvoidanceExtra     KeyboardAvoidanceExtra(0,0,Size)
//    +0x28 _framesPerSecond            FPS(60,30,120) 量化为 {30,60,120}
//    +0x30 _scheme                     Scheme(默认 "deepseek")
//    +0x38 _outfit                     Outfit(默认 "maid")
//    +0x40 _roam                       Roam(默认 "free")
//    +0x48 _doubleTapAction            DoubleTapAction(默认 "none")
//    +0x50 _longPressAction            LongPressAction(默认 "menu")
//
//  允许集取自 dylib 字符串表候选值（Assumed，验证动作见文件尾）。
//

#import "PDPreferences.h"
#import "PDOutfitCatalog.h"      // 【可编辑化】服装白名单改为动态发现
#import "PDTextureResolver.h"
#import "PDLayoutConfig.h"

static NSString * const kPDPreferencesDomain = @"com.susudear.petdfyprefs";

// 二进制中为全局 C 函数（符号 _PDAIPreference / _PDAINumber），此处等价实现
static id PDReadRaw(NSString *key) {
    return CFBridgingRelease(CFPreferencesCopyAppValue(
        (__bridge CFStringRef)key,
        (__bridge CFStringRef)kPDPreferencesDomain));
}

static BOOL PDReadBool(NSString *key) {
    id v = PDReadRaw(key);
    if (!v) return YES;                    // 二进制默认值硬编码为 1
    if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v boolValue];
    return YES;
}

static NSString *PDReadString(NSString *key, NSArray *allowed, NSString *fallback) {
    id v = PDReadRaw(key);
    if ([v isKindOfClass:[NSString class]] && [allowed containsObject:v]) return v;
    return fallback;
}

static double PDReadNumber(NSString *key, double def, double lo, double hi) {
    id v = PDReadRaw(key);
    double d = [v isKindOfClass:[NSNumber class]] ? [v doubleValue] : def;
    if (isnan(d)) d = def;
    if (d > hi) d = hi;
    if (d < lo) d = lo;
    return d;
}

// 【可编辑化扩展】资源根：与安装布局一致（Debian 包安装到 /Library/Application Support/）
static NSString *PDPrefAssetsRoot(void) {
    return @"/Library/Application Support/PetDFY.bundle";
}

/// 服装取值：允许任意非空字符串，但要求它在本机素材里真实存在（model.json 或 outfits/ 目录），
/// 否则回退到 PDLayout.json 的 outfit.default。这样「新增一套衣服」不再需要改这里。
static NSString *PDResolveOutfit(NSString *raw, NSString *fallback) {
    NSString *candidate = [raw isKindOfClass:[NSString class]] && [(NSString *)raw length] ? raw : nil;
    if (!candidate) return fallback;
    NSArray *catalog = [PDOutfitCatalog catalogForRoot:PDPrefAssetsRoot() scheme:nil];
    for (NSDictionary *e in catalog) {
        if ([e[@"id"] isEqualToString:candidate]) return candidate;
    }
    NSLog(@"[PetDFY] outfit %@ not found in assets, fallback to %@", candidate, fallback);
    return fallback;
}

/// 主题取值：允许任意非空字符串（schemes/<名称>/ 目录即生效），空值回退。
static NSString *PDResolveScheme(NSString *raw, NSString *fallback) {
    if ([raw isKindOfClass:[NSString class]] && [(NSString *)raw length]) return raw;
    return fallback;
}

@implementation PDPreferences

- (id)init {
    self = [super init];
    if (self) {
        [self reload];
    }
    return self;
}

- (void)reload {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kPDPreferencesDomain);

    _enabled = PDReadBool(@"Enabled");
    _interactive = PDReadBool(@"Interactive");
    _responsive = PDReadBool(@"Responsive");
    _soundEnabled = PDReadBool(@"Sound");

    _stroking = [PDReadString(@"InputMode", @[@"grab", @"stroke"], @"grab") isEqualToString:@"stroke"];

    double sizeValue = PDReadNumber(@"Size", 128.0, 72.0, 220.0);
    _size = sizeValue * PDReadNumber(@"PetScale", 1.0, 0.5, 10.0);

    _bottomInset = PDReadNumber(@"BottomInset", 12.0, 0.0, sizeValue);

    long long fps = (long long)PDReadNumber(@"FPS", 60.0, 30.0, 120.0);
    _framesPerSecond = fps > 99 ? 120 : (fps > 44 ? 60 : 30);

    _keyboardAvoidanceEnabled = PDReadBool(@"KeyboardAvoidanceEnabled");
    _keyboardAvoidanceExtra = PDReadNumber(@"KeyboardAvoidanceExtra", 0.0, 0.0, sizeValue);

    // 【可编辑化改造】原实现把可选值写死成 @[@"deepseek",@"doubao"] / @[@"maid"]，
    // 等于「加主题」和「加服装」都失效。改为：主题任意非空、服装需真实存在。
    NSString *layoutDefaultScheme = [[PDLayoutConfig shared] defaultScheme] ?: @"deepseek";
    NSString *layoutDefaultOutfit = [[PDLayoutConfig shared] defaultOutfit] ?: @"maid";
    id rawScheme = PDReadRaw(@"Scheme");
    id rawOutfit = PDReadRaw(@"Outfit");
    _scheme = [PDResolveScheme([rawScheme isKindOfClass:[NSString class]] ? rawScheme : nil,
                               layoutDefaultScheme) copy];
    _outfit = [PDResolveOutfit([rawOutfit isKindOfClass:[NSString class]] ? rawOutfit : nil,
                               layoutDefaultOutfit) copy];
    _roam = [PDReadString(@"Roam", @[@"free", @"fixed"], @"free") copy];
    _doubleTapAction = [PDReadString(@"DoubleTapAction", @[@"none", @"chat", @"menu"], @"none") copy];
    _longPressAction = [PDReadString(@"LongPressAction", @[@"menu", @"chat", @"none"], @"menu") copy];

    NSArray *knownKeys = @[@"RoamMode", @"TouchEnabled", @"BubbleSpeed", @"AIHeartbeatMinutes"];
    for (NSString *key in knownKeys) {
        if ([knownKeys containsObject:key]) {
            id value = PDReadRaw(key);
            if ([value respondsToSelector:@selector(boolValue)]) (void)[value boolValue];
            if ([value respondsToSelector:@selector(doubleValue)]) (void)[value doubleValue];
        }
    }
}


// ---- 兼容层：二进制中这些是内联的全局 C 调用，类方法本身不存在 ----

+ (instancetype)shared {
    static PDPreferences *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[PDPreferences alloc] init]; });
    return shared;
}

// [非二进制] - stringForKey:fallback: 二进制无此 selector；兼容层实现，走 CFPreferences。
- (NSString *)stringForKey:(NSString *)key fallback:(NSString *)fallback {
    id v = PDReadRaw(key);
    if ([v isKindOfClass:[NSString class]]) return v;
    return fallback;
}

// [非二进制] - boolForKey:fallback: 二进制无此 selector；兼容层实现，走 CFPreferences。
- (BOOL)boolForKey:(NSString *)key fallback:(BOOL)fallback {
    id v = PDReadRaw(key);
    if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v boolValue];
    return fallback;
}

// [非二进制] - doubleForKey:fallback: 二进制无此 selector；兼容层实现，走 CFPreferences。
- (double)doubleForKey:(NSString *)key fallback:(double)fallback {
    id v = PDReadRaw(key);
    if ([v isKindOfClass:[NSNumber class]]) return [v doubleValue];
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v doubleValue];
    return fallback;
}

// [非二进制] - integerForKey:fallback:min:max: 二进制无此 selector；兼容层实现，走 CFPreferences。
- (long long)integerForKey:(NSString *)key fallback:(long long)fallback
                       min:(long long)lo max:(long long)hi {
    long long i = (long long)[self doubleForKey:key fallback:(double)fallback];
    if (i < lo) i = lo;
    if (i > hi) i = hi;
    return i;
}

// [非二进制] - setString:forKey: 二进制无此 selector；兼容层实现，走 CFPreferences。
- (void)setString:(NSString *)value forKey:(NSString *)key {
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFStringRef)value,
                             (__bridge CFStringRef)kPDPreferencesDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kPDPreferencesDomain);
    [self reload];
}

// [非二进制] - setDouble:forKey: 二进制无此 selector；兼容层实现，走 CFPreferences。
- (void)setDouble:(double)value forKey:(NSString *)key {
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFNumberRef)@(value),
                             (__bridge CFStringRef)kPDPreferencesDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kPDPreferencesDomain);
    [self reload];
}

@end
