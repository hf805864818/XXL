//
//  PDLayoutConfig.m
//  PetDFY 可编辑源码 · 布局与操作配置
//

#import "PDLayoutConfig.h"
#import <math.h>

NSString * const PDLayoutConfigDidChangeNotification = @"PDLayoutConfigDidChangeNotification";

static NSString * const kPDLayoutUserPath =
    @"/var/mobile/Library/Application Support/PetDFY/PDLayout.json";

@implementation PDLayoutConfig {
    NSDictionary *_raw;
    NSString *_loadedPath;
}

+ (instancetype)shared {
    static PDLayoutConfig *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[PDLayoutConfig alloc] init]; });
    return s;
}

- (id)init {
    self = [super init];
    if (self) {
        [self reload];
    }
    return self;
}

+ (NSDictionary *)defaultLayout {
    return @{
        @"pet": @{
            @"scale": @1.0,
            @"offsetX": @0.0,
            @"offsetY": @0.0,
            @"anchorBottom": @12.0,
        },
        @"stage": @{
            @"padding": @0.0,
        },
        @"interaction": @{
            @"padding": @6.0,
            @"alphaThreshold": @0.12,
            @"longPress": @0.45,
            @"drag": @6.0,
        },
        @"gesture": @{
            @"single": @"stroke",
            @"double": @"chat",
            @"long": @"menu",
            @"dragStart": @"grab",
            @"dragEnd": @"drop",
        },
        @"motion": @{
            @"gravity": @1.0,
            @"speed": @1.0,
            @"jump": @1.0,
            @"roam": @"free",
        },
        @"hud": @{
            @"glow": @YES,
            @"glowAlpha": @0.55,
        },
        @"bubble": @{
            @"fontSize": @15.0,
            @"maxWidth": @260.0,
            @"typing": @1.0,
        },
        @"outfit": @{
            @"default": @"maid",
        },
        @"scheme": @{
            @"default": @"deepseek",
        },
    };
}

+ (NSDictionary *)deepMerge:(NSDictionary *)base with:(NSDictionary *)over {
    if (![over isKindOfClass:[NSDictionary class]] || over.count == 0) return base;
    NSMutableDictionary *out = [base mutableCopy] ?: [NSMutableDictionary dictionary];
    [over enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
        id b = out[k];
        if ([v isKindOfClass:[NSDictionary class]] && [b isKindOfClass:[NSDictionary class]]) {
            out[k] = [PDLayoutConfig deepMerge:b with:v];
        } else {
            out[k] = v;
        }
    }];
    return out;
}

- (void)reload {
    NSDictionary *merged = [PDLayoutConfig defaultLayout];
    NSString *found = nil;

    NSArray *cands = @[
        kPDLayoutUserPath,
        @"/var/jb/var/mobile/Library/Application Support/PetDFY/PDLayout.json",
    ];
    for (NSString *p in cands) {
        NSData *d = [NSData dataWithContentsOfFile:p];
        if (!d.length) continue;
        id json = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
        if ([json isKindOfClass:[NSDictionary class]]) {
            merged = [PDLayoutConfig deepMerge:merged with:json];
            found = p;
            break;
        }
    }

    BOOL changed = (_raw == nil) || ![merged isEqual:_raw];
    _raw = [merged copy];
    _loadedPath = found;
    if (changed) {
        [[NSNotificationCenter defaultCenter] postNotificationName:PDLayoutConfigDidChangeNotification
                                                            object:self];
    }
}

- (NSDictionary *)raw { return _raw ?: [PDLayoutConfig defaultLayout]; }
- (NSString *)loadedPath { return _loadedPath; }

#pragma mark - 取值

- (id)valueForPath:(NSString *)path {
    if (![path isKindOfClass:[NSString class]] || path.length == 0) return nil;
    id cur = self.raw;
    for (NSString *seg in [path componentsSeparatedByString:@"."]) {
        if (![cur isKindOfClass:[NSDictionary class]]) return nil;
        cur = ((NSDictionary *)cur)[seg];
        if (!cur) return nil;
    }
    return cur;
}

- (double)doubleForPath:(NSString *)path fallback:(double)fb lo:(double)lo hi:(double)hi {
    id v = [self valueForPath:path];
    double d = fb;
    if ([v isKindOfClass:[NSNumber class]]) d = [v doubleValue];
    else if ([v isKindOfClass:[NSString class]]) d = [(NSString *)v doubleValue];
    if (isnan(d)) d = fb;
    if (d < lo) d = lo;
    if (d > hi) d = hi;
    return d;
}

- (BOOL)boolForPath:(NSString *)path fallback:(BOOL)fb {
    id v = [self valueForPath:path];
    if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v boolValue];
    return fb;
}

- (NSString *)stringForPath:(NSString *)path fallback:(NSString *)fb {
    id v = [self valueForPath:path];
    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) return v;
    return fb;
}

- (NSInteger)integerForPath:(NSString *)path fallback:(NSInteger)fb lo:(NSInteger)lo hi:(NSInteger)hi {
    double d = [self doubleForPath:path fallback:(double)fb lo:(double)lo hi:(double)hi];
    return (NSInteger)llround(d);
}

#pragma mark - 语义化

- (CGFloat)petScale { return (CGFloat)[self doubleForPath:@"pet.scale" fallback:1.0 lo:0.2 hi:6.0]; }
- (CGPoint)petOffset {
    return CGPointMake((CGFloat)[self doubleForPath:@"pet.offsetX" fallback:0 lo:-400 hi:400],
                       (CGFloat)[self doubleForPath:@"pet.offsetY" fallback:0 lo:-400 hi:400]);
}
- (CGFloat)anchorBottom { return (CGFloat)[self doubleForPath:@"pet.anchorBottom" fallback:12 lo:0 hi:600]; }
- (CGFloat)stagePadding { return (CGFloat)[self doubleForPath:@"stage.padding" fallback:0 lo:0 hi:200]; }
- (CGFloat)interactPadding { return (CGFloat)[self doubleForPath:@"interaction.padding" fallback:6 lo:0 hi:64]; }
- (CGFloat)alphaThreshold { return (CGFloat)[self doubleForPath:@"interaction.alphaThreshold" fallback:0.12 lo:0 hi:1]; }
- (double)longPressSeconds { return [self doubleForPath:@"interaction.longPress" fallback:0.45 lo:0.2 hi:3.0]; }
- (double)dragThreshold { return [self doubleForPath:@"interaction.drag" fallback:6 lo:0 hi:60]; }
- (double)gravityScale { return [self doubleForPath:@"motion.gravity" fallback:1.0 lo:0 hi:5]; }
- (double)speedScale { return [self doubleForPath:@"motion.speed" fallback:1.0 lo:0 hi:5]; }
- (double)jumpScale { return [self doubleForPath:@"motion.jump" fallback:1.0 lo:0 hi:5]; }
- (double)glowAlpha { return [self doubleForPath:@"hud.glowAlpha" fallback:0.55 lo:0 hi:1]; }
- (BOOL)glowEnabled { return [self boolForPath:@"hud.glow" fallback:YES]; }
- (CGFloat)bubbleFontSize { return (CGFloat)[self doubleForPath:@"bubble.fontSize" fallback:15 lo:8 hi:40]; }
- (CGFloat)bubbleMaxWidth { return (CGFloat)[self doubleForPath:@"bubble.maxWidth" fallback:260 lo:80 hi:600]; }
- (CGFloat)bubbleTypingSpeed { return (CGFloat)[self doubleForPath:@"bubble.typing" fallback:1.0 lo:0 hi:4]; }
- (NSString *)defaultOutfit { return [self stringForPath:@"outfit.default" fallback:@"maid"]; }
- (NSString *)defaultScheme { return [self stringForPath:@"scheme.default" fallback:@"deepseek"]; }

- (NSString *)actionForGesture:(NSString *)gesture {
    if (![gesture isKindOfClass:[NSString class]]) return @"none";
    NSString *path = [@"gesture." stringByAppendingString:gesture];
    return [self stringForPath:path fallback:@"none"];
}

+ (BOOL)writeDefaultLayoutTo:(NSString *)targetPath {
    if (![targetPath isKindOfClass:[NSString class]] || targetPath.length == 0) return NO;
    NSData *d = [NSJSONSerialization dataWithJSONObject:[PDLayoutConfig defaultLayout]
                                                options:NSJSONWritingPrettyPrinted
                                                  error:NULL];
    if (!d) return NO;
    NSString *dir = [targetPath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    return [d writeToFile:targetPath atomically:YES];
}

@end
