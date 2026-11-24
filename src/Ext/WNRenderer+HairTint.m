//
//  WNRenderer+HairTint.m
//  PetDFY 可编辑源码 · 渲染器发色挂接
//
//  三条约束决定了必须走「贴图注入」而不是改着色器：
//   1) Whale.metal 是资产包里的字符串（source 化编译），改它要动资源与管线描述；
//   2) 官方管线只有 normal / multiply / silhouette 三种，没有 per-mesh 色调 uniform；
//   3) 命中蒙版 WNHitMask 由 alpha 派生，换色不能影响 alpha —— HSV 重映射天然满足。
//

#import "WNRenderer+HairTint.h"
#import "PDHairTint.h"

@implementation WNRenderer (PDHairTint)

- (NSString *)pd_absoluteTexturePathForName:(NSString *)name {
    if (![name isKindOfClass:[NSString class]] || name.length == 0) return nil;
    if ([name hasPrefix:@"/"]) return name;
    NSString *root = [[self resourceURL] path];
    if (root.length == 0) return nil;
    return [root stringByAppendingPathComponent:name];
}

- (NSString *)pd_partIDForTextureName:(NSString *)name {
    NSString *base = [[name lastPathComponent] stringByDeletingPathExtension];
    return base.length ? base : name;
}

- (void)pdApplyHairTintForParts:(NSArray *)parts {
    PDHairTint *engine = [PDHairTint shared];
    if (![parts isKindOfClass:[NSArray class]]) return;

    if (!engine.enabled) {
        [self pdClearHairTint];
        return;
    }

    for (NSDictionary *part in parts) {
        if (![part isKindOfClass:[NSDictionary class]]) continue;

        NSString *texName = part[@"texture"];
        if (![texName isKindOfClass:[NSString class]] || texName.length == 0) continue;

        NSString *pid = part[@"id"];
        if (![pid isKindOfClass:[NSString class]] || pid.length == 0) {
            pid = [self pd_partIDForTextureName:texName];
        }
        if (![engine isHairPart:pid]) continue;

        NSString *abs = [self pd_absoluteTexturePathForName:texName];
        if (!abs.length) continue;

        id<MTLTexture> tex = [engine newTextureForPart:pid
                                         absolutePath:abs
                                               device:[self device]
                                               loader:[self loader]];
        if (tex) {
            NSMutableDictionary *live = [self liveTextures];
            if (![live isKindOfClass:[NSMutableDictionary class]]) {
                live = [NSMutableDictionary dictionary];
                [self setLiveTextures:live];
            }
            live[texName] = tex;
        }
    }
}

- (void)pdRefreshHairTintAtTime:(NSNumber *)time {
    PDHairTint *engine = [PDHairTint shared];
    if (!engine.enabled) return;

    double t = [time isKindOfClass:[NSNumber class]] ? [time doubleValue] : 0.0;
    if (![engine needsRefreshAtTime:t]) return;

    NSMutableDictionary *live = [self liveTextures];
    if (![live isKindOfClass:[NSMutableDictionary class]]) return;

    NSArray *keys = [live allKeys];
    for (NSString *key in keys) {
        NSString *pid = [self pd_partIDForTextureName:key];
        if (![engine isHairPart:pid]) continue;

        NSString *abs = [self pd_absoluteTexturePathForName:key];
        if (!abs.length) continue;

        id<MTLTexture> tex = [engine newTextureForPart:pid
                                         absolutePath:abs
                                               device:[self device]
                                               loader:[self loader]];
        if (tex) live[key] = tex;
    }
}

- (void)pdClearHairTint {
    NSMutableDictionary *live = [self liveTextures];
    if (![live isKindOfClass:[NSMutableDictionary class]]) return;
    PDHairTint *engine = [PDHairTint shared];
    for (NSString *key in [live allKeys]) {
        NSString *pid = [self pd_partIDForTextureName:key];
        if ([engine isHairPart:pid]) [live removeObjectForKey:key];
    }
}

@end
