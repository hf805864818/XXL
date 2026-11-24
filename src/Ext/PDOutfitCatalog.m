//
//  PDOutfitCatalog.m
//  PetDFY 可编辑源码 · 服装目录
//

#import "PDOutfitCatalog.h"
#import "PDTextureResolver.h"

NSString * const PDOutfitCatalogDidChangeNotification = @"PDOutfitCatalogDidChangeNotification";

static NSDictionary *PDOutfitLoadModelJSON(NSString *root) {
    if (![root isKindOfClass:[NSString class]] || root.length == 0) return nil;
    NSArray *cands = @[ @"live/model.json", @"originals/model.json", @"model.json" ];
    for (NSString *rel in cands) {
        NSString *p = [root stringByAppendingPathComponent:rel];
        NSData *d = [NSData dataWithContentsOfFile:p];
        if (!d.length) continue;
        id json = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
        if ([json isKindOfClass:[NSDictionary class]]) {
            NSDictionary *dict = json;
            if ([dict[@"models"] isKindOfClass:[NSDictionary class]]) return dict;
        }
    }
    return nil;
}

static NSDictionary<NSString *, NSString *> *PDOutfitTitles(void) {
    return @{
        @"maid":      @"女仆装",
        @"cape":      @"斗篷冬装",
        @"crew":      @"店员装",
        @"sailor":    @"JK 水手服",
        @"jk-sailor": @"JK 水手服",
        @"default":   @"默认",
    };
}

@implementation PDOutfitCatalog

+ (NSDictionary<NSString *, NSString *> *)titlesFromDataForRoot:(NSString *)root {
    if (![root isKindOfClass:[NSString class]] || root.length == 0) return @{};
    for (NSString *rel in @[ @"PDOutfitTitles.json",
                             @"originals/PDOutfitTitles.json" ]) {
        NSData *d = [NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:rel]];
        if (!d.length) continue;
        id json = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
        if ([json isKindOfClass:[NSDictionary class]]) {
            NSMutableDictionary *out = [NSMutableDictionary dictionary];
            [(NSDictionary *)json enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
                if ([k isKindOfClass:[NSString class]] && [v isKindOfClass:[NSString class]]) out[k] = v;
            }];
            return out;
        }
    }
    return @{};
}

+ (NSString *)titleForOutfit:(NSString *)outfitID {
    return [self titleForOutfit:outfitID root:nil];
}

+ (NSString *)titleForOutfit:(NSString *)outfitID root:(NSString *)root {
    if (![outfitID isKindOfClass:[NSString class]]) return @"";
    NSString *fromData = [self titlesFromDataForRoot:root][outfitID];
    if (fromData.length) return fromData;
    NSString *t = PDOutfitTitles()[outfitID];
    return t.length ? t : outfitID;
}

+ (NSString *)thumbPathForOutfit:(NSString *)outfitID {
    if (![outfitID isKindOfClass:[NSString class]] || outfitID.length == 0) return nil;
    return [NSString stringWithFormat:@"originals/thumbs/%@.png", outfitID];
}

+ (NSArray<NSDictionary *> *)partsForOutfit:(NSString *)outfitID root:(NSString *)root {
    NSDictionary *model = PDOutfitLoadModelJSON(root);
    NSDictionary *models = model[@"models"];
    if (![models isKindOfClass:[NSDictionary class]]) return @[];
    NSDictionary *one = models[outfitID];
    if (![one isKindOfClass:[NSDictionary class]]) return @[];
    NSArray *parts = one[@"parts"];
    return [parts isKindOfClass:[NSArray class]] ? parts : @[];
}

+ (NSArray<NSString *> *)missingTexturesForOutfit:(NSString *)outfitID
                                             root:(NSString *)root
                                           scheme:(NSString *)scheme {
    NSMutableArray *missing = [NSMutableArray array];
    PDTextureResolver *r = [PDTextureResolver resolverWithRoot:root scheme:scheme outfit:outfitID];
    for (NSDictionary *part in [self partsForOutfit:outfitID root:root]) {
        if (![part isKindOfClass:[NSDictionary class]]) continue;
        NSString *pid = part[@"id"];
        NSString *tex = part[@"tex"];
        NSString *src = part[@"src"];
        NSString *rel = [r texturePathForPart:pid tex:tex src:src];
        if (!rel.length) continue;
        if (![r existsRelative:rel]) {
            [missing addObject:[NSString stringWithFormat:@"%@ -> %@", pid ?: @"?", rel]];
        }
    }
    return missing;
}

+ (NSArray<NSDictionary *> *)catalogForRoot:(NSString *)root scheme:(NSString *)scheme {
    NSMutableOrderedSet<NSString *> *ids = [NSMutableOrderedSet orderedSet];

    // 1) model.json 的 models 键：这是「服装 = 模型」的官方定义
    NSDictionary *model = PDOutfitLoadModelJSON(root);
    NSDictionary *models = model[@"models"];
    if ([models isKindOfClass:[NSDictionary class]]) {
        NSArray *keys = [[models allKeys] sortedArrayUsingSelector:@selector(compare:)];
        [ids addObjectsFromArray:keys];
    }

    // 2) 磁盘目录（允许只放贴图的轻量新服装）
    PDTextureResolver *probe = [PDTextureResolver resolverWithRoot:root scheme:scheme outfit:@"maid"];
    for (NSString *o in [probe availableOutfits]) [ids addObject:o];

    NSMutableArray *out = [NSMutableArray array];
    for (NSString *oid in ids) {
        if (![oid isKindOfClass:[NSString class]] || oid.length == 0) continue;
        NSArray *missing = [self missingTexturesForOutfit:oid root:root scheme:scheme];
        BOOL hasModel = [self partsForOutfit:oid root:root].count > 0;
        [out addObject:@{
            @"id": oid,
            @"title": [self titleForOutfit:oid root:root],
            @"thumb": [self thumbPathForOutfit:oid] ?: @"",
            @"complete": @(missing.count == 0),
            @"missing": missing,
            @"hasModel": @(hasModel),
        }];
    }
    if (out.count == 0) {
        for (NSString *fallback in @[ @"maid", @"cape", @"crew", @"sailor" ]) {
            [out addObject:@{ @"id": fallback,
                              @"title": [self titleForOutfit:fallback],
                              @"thumb": [self thumbPathForOutfit:fallback] ?: @"",
                              @"complete": @YES,
                              @"missing": @[],
                              @"hasModel": @YES }];
        }
    }
    return out;
}

+ (NSString *)outfitAfter:(NSString *)current inCatalog:(NSArray<NSDictionary *> *)catalog {
    if (catalog.count == 0) return current;
    NSMutableArray *ids = [NSMutableArray array];
    for (NSDictionary *e in catalog) {
        if ([e isKindOfClass:[NSDictionary class]] && e[@"id"]) [ids addObject:e[@"id"]];
    }
    NSUInteger idx = [ids indexOfObject:current ?: @""];
    if (idx == NSNotFound) return ids.firstObject;
    return ids[(idx + 1) % ids.count];
}

+ (NSString *)outfitBefore:(NSString *)current inCatalog:(NSArray<NSDictionary *> *)catalog {
    if (catalog.count == 0) return current;
    NSMutableArray *ids = [NSMutableArray array];
    for (NSDictionary *e in catalog) {
        if ([e isKindOfClass:[NSDictionary class]] && e[@"id"]) [ids addObject:e[@"id"]];
    }
    NSUInteger idx = [ids indexOfObject:current ?: @""];
    if (idx == NSNotFound) return ids.firstObject;
    return ids[(idx + ids.count - 1) % ids.count];
}

@end
