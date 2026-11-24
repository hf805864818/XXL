//
//  PDTextureResolver.m
//  PetDFY 可编辑源码 · 素材/服装贴图定位层
//

#import "PDTextureResolver.h"

static NSString *PDTrimSlashes(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return @"";
    NSString *t = s;
    while ([t hasSuffix:@"/"] && t.length > 1) t = [t substringToIndex:t.length - 1];
    return t;
}

@implementation PDTextureResolver

+ (NSArray<NSString *> *)defaultUserPackRoots {
    // 与二进制一致的一级目录 + 两个用户可写目录
    NSString *base = @"/var/mobile/Library/Application Support/PetDFY";
    return @[
        [base stringByAppendingPathComponent:@"UserPacks"],
        [base stringByAppendingPathComponent:@"AssetImports"],
    ];
}

+ (instancetype)resolverWithRoot:(NSString *)root scheme:(NSString *)scheme outfit:(NSString *)outfit {
    PDTextureResolver *r = [PDTextureResolver new];
    r.resourceRoot = root;
    r.scheme = scheme.length ? scheme : @"deepseek";
    r.outfit = outfit.length ? outfit : @"maid";
    r.userPackRoots = [PDTextureResolver defaultUserPackRoots];
    return r;
}

- (id)init {
    self = [super init];
    if (self) {
        _scheme = @"deepseek";
        _outfit = @"maid";
        _userPackRoots = [[PDTextureResolver defaultUserPackRoots] copy];
    }
    return self;
}

- (NSString *)schemeRoot {
    if ([_scheme isEqualToString:@"deepseek"] || _scheme.length == 0) return @"originals/";
    return [NSString stringWithFormat:@"schemes/%@/", _scheme];
}

- (NSString *)absolutePathForRelative:(NSString *)rel {
    if (![rel isKindOfClass:[NSString class]] || rel.length == 0) return nil;
    if ([rel hasPrefix:@"/"]) {
        return [[NSFileManager defaultManager] fileExistsAtPath:rel] ? rel : nil;
    }
    if (_resourceRoot.length == 0) return nil;
    NSString *p = [_resourceRoot stringByAppendingPathComponent:rel];
    return [[NSFileManager defaultManager] fileExistsAtPath:p] ? p : nil;
}

- (BOOL)existsRelative:(NSString *)rel {
    return [self absolutePathForRelative:rel] != nil;
}

- (NSString *)firstExisting:(NSArray<NSString *> *)candidates fallback:(NSString *)fallback {
    if (_resourceRoot.length == 0) return candidates.firstObject ?: fallback;
    for (NSString *c in candidates) {
        if (c.length && [self existsRelative:c]) return c;
    }
    return fallback ?: candidates.firstObject;
}

- (NSString *)texturePathForPart:(NSString *)part tex:(NSString *)tex src:(NSString *)src {
    NSString *name = nil;
    if ([tex isKindOfClass:[NSString class]] && tex.length) name = tex;
    else if ([part isKindOfClass:[NSString class]] && part.length) name = part;
    else return nil;

    // 两级根：当前主题根，其次 originals/（主题包只放 tex/ 与 feat/，
    // 服装贴图与个别共享图常常只在 originals/ 里有，必须回退过去）。
    NSArray<NSString *> *roots = @[ [self schemeRoot], @"originals/" ];

    NSMutableArray<NSString *> *cands = [NSMutableArray array];

    if ([src isKindOfClass:[NSString class]] && src.length) {
        for (NSString *root in roots) {
            [cands addObject:[root stringByAppendingString:src]];
            if (![src hasPrefix:@"tex/"] && ![src hasPrefix:@"feat/"]) {
                [cands addObject:[root stringByAppendingFormat:@"%@", src]];
            }
        }
        [cands addObject:src];
    }

    for (NSString *root in roots) {
        [cands addObject:[root stringByAppendingFormat:@"tex/%@.png", name]];
        [cands addObject:[root stringByAppendingFormat:@"outfits/%@/%@.png", _outfit, name]];
        [cands addObject:[root stringByAppendingFormat:@"outfits/%@/tex/%@.png", _outfit, name]];
        [cands addObject:[root stringByAppendingFormat:@"feat/%@.png", name]];
    }

    // 用户素材包：<root>/<tex>.png、<root>/tex/<tex>.png
    for (NSString *u in _userPackRoots) {
        if (![u isKindOfClass:[NSString class]] || u.length == 0) continue;
        [cands addObject:[u stringByAppendingPathComponent:name]];
        [cands addObject:[u stringByAppendingPathComponent:[NSString stringWithFormat:@"tex/%@", name]]];
        [cands addObject:[u stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"outfits/%@/%@", self.outfit, name]]];
    }

    NSString *fallback = [@"originals/" stringByAppendingFormat:@"tex/%@.png", name];
    return [self firstExisting:cands fallback:fallback];
}

- (NSString *)featurePathForName:(NSString *)name {
    if (![name isKindOfClass:[NSString class]] || name.length == 0) return nil;
    NSArray<NSString *> *roots = @[ [self schemeRoot], @"originals/" ];
    NSMutableArray<NSString *> *cands = [NSMutableArray array];
    for (NSString *root in roots) {
        [cands addObject:[root stringByAppendingFormat:@"feat/%@.png", name]];
        [cands addObject:[root stringByAppendingFormat:@"tex/%@.png", name]];
    }
    for (NSString *u in _userPackRoots) {
        if (![u isKindOfClass:[NSString class]] || u.length == 0) continue;
        [cands addObject:[u stringByAppendingPathComponent:[NSString stringWithFormat:@"feat/%@", name]]];
        [cands addObject:[u stringByAppendingPathComponent:name]];
    }
    return [self firstExisting:cands fallback:cands.firstObject];
}

- (NSString *)propPathForName:(NSString *)name {
    if (![name isKindOfClass:[NSString class]] || name.length == 0) return nil;
    NSArray<NSString *> *roots = @[ [self schemeRoot], @"originals/" ];
    NSMutableArray<NSString *> *cands = [NSMutableArray array];
    for (NSString *root in roots) {
        [cands addObject:[root stringByAppendingFormat:@"props/%@.png", name]];
    }
    for (NSString *u in _userPackRoots) {
        if (![u isKindOfClass:[NSString class]] || u.length == 0) continue;
        [cands addObject:[u stringByAppendingPathComponent:[NSString stringWithFormat:@"props/%@", name]]];
    }
    return [self firstExisting:cands fallback:cands.firstObject];
}

#pragma mark - 目录枚举

- (NSArray<NSString *> *)availableOutfits {
    NSMutableOrderedSet<NSString *> *set = [NSMutableOrderedSet orderedSet];
    NSFileManager *fm = [NSFileManager defaultManager];

    // 1) model.json 里的 models 键（官方定义）
    for (NSString *cand in @[ @"originals/model.json", @"live/model.json", @"model.json" ]) {
        NSString *abs = [self absolutePathForRelative:cand];
        if (!abs) continue;
        NSData *d = [NSData dataWithContentsOfFile:abs];
        if (!d.length) continue;
        id json = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
        if ([json isKindOfClass:[NSDictionary class]]) {
            id models = ((NSDictionary *)json)[@"models"];
            if ([models isKindOfClass:[NSDictionary class]]) {
                [set addObjectsFromArray:[(NSDictionary *)models allKeys]];
            }
        }
    }

    // 2) 磁盘上的 outfits/ 目录
    for (NSString *rel in @[ @"originals/outfits", @"outfits" ]) {
        NSString *abs = _resourceRoot.length ? [_resourceRoot stringByAppendingPathComponent:rel] : nil;
        if (!abs) continue;
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:abs isDirectory:&isDir] || !isDir) continue;
        NSArray *items = [fm contentsOfDirectoryAtPath:abs error:NULL];
        for (NSString *it in items) {
            BOOL d2 = NO;
            NSString *p = [abs stringByAppendingPathComponent:it];
            if ([fm fileExistsAtPath:p isDirectory:&d2] && d2) [set addObject:it];
        }
    }

    // 3) 用户素材包
    for (NSString *u in _userPackRoots) {
        NSString *abs = [u stringByAppendingPathComponent:@"outfits"];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:abs isDirectory:&isDir] || !isDir) continue;
        NSArray *items = [fm contentsOfDirectoryAtPath:abs error:NULL];
        for (NSString *it in items) {
            BOOL d2 = NO;
            NSString *p = [abs stringByAppendingPathComponent:it];
            if ([fm fileExistsAtPath:p isDirectory:&d2] && d2) [set addObject:it];
        }
    }

    if (set.count == 0) [set addObjectsFromArray:@[ @"maid", @"cape", @"crew", @"sailor" ]];
    return [set array];
}

- (NSArray<NSString *> *)availableSchemes {
    NSMutableOrderedSet<NSString *> *set = [NSMutableOrderedSet orderedSet];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *abs = _resourceRoot.length ? [_resourceRoot stringByAppendingPathComponent:@"schemes"] : nil;
    if (abs) {
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:abs isDirectory:&isDir] && isDir) {
            for (NSString *it in [fm contentsOfDirectoryAtPath:abs error:NULL]) {
                BOOL d2 = NO;
                if ([fm fileExistsAtPath:[abs stringByAppendingPathComponent:it] isDirectory:&d2] && d2) {
                    [set addObject:it];
                }
            }
        }
    }
    [set insertObject:@"deepseek" atIndex:0];
    return [set array];
}

@end
