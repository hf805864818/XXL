//
//  PDTextureResolver.h
//  PetDFY 可编辑源码 · 素材/服装贴图定位层
//
//  作用：把「部件名 + 主题名 + 当前服装名」解析成资源包内的相对路径。
//  原包只有一条模板（"originals/%@tex/%@.png" 与 "schemes/%@"），
//  对新加入的服装目录、用户素材包、同名覆盖都不友好。这里给出确定的
//  候选顺序，让「加一张 PNG 就能生效」成为硬保证。
//
//  解析顺序（命中即止）：
//    1) 部件自带 src 字段（model.json 里显式写了相对路径）
//    2) <root>tex/<tex>.png                    ← 主题包优先
//    3) <root>outfits/<outfit>/<tex>.png       ← 服装自有贴图
//    4) <root>outfits/<outfit>/tex/<tex>.png
//    5) originals/outfits/<outfit>/<tex>.png   ← 主题包里缺服装图时的兜底
//    6) <user>/<pack>/<tex>.png                ← 用户素材包（AssetImports/UserPacks）
//
//  root = "originals/"（deepseek 默认）或 "schemes/<scheme>/"
//

#import <Foundation/Foundation.h>

@interface PDTextureResolver : NSObject

/// 资源根目录（PetDFY.bundle）。nil 时不检测存在性，只返回候选路径。
@property (nonatomic, copy) NSString * resourceRoot;

/// 当前主题（deepseek / chatgpt / …）。deepseek 走 originals/，其余走 schemes/<scheme>/
@property (nonatomic, copy) NSString * scheme;

/// 当前服装（maid / cape / crew / sailor / 任意新目录名）
@property (nonatomic, copy) NSString * outfit;

/// 用户素材包根目录列表（按优先级）。每项是一个包含 tex/ feat/ outfits/ 的目录。
@property (nonatomic, copy) NSArray<NSString *> * userPackRoots;

+ (instancetype)resolverWithRoot:(NSString *)root scheme:(NSString *)scheme outfit:(NSString *)outfit;

/// 主题根前缀："originals/" 或 "schemes/<scheme>/"
- (NSString *)schemeRoot;

/// 部件贴图相对路径（不带资源根）。命中失败时返回第 2 条候选，保证有稳定回退。
- (NSString *)texturePathForPart:(NSString *)part
                             tex:(NSString *)tex
                             src:(NSString *)src;

/// 表情特征图相对路径（面部件/眼睛/嘴）。
- (NSString *)featurePathForName:(NSString *)name;

/// 道具（玩具球等）相对路径。
- (NSString *)propPathForName:(NSString *)name;

/// 给定相对路径，返回磁盘绝对路径；不存在返回 nil。
- (NSString *)absolutePathForRelative:(NSString *)rel;

/// 该相对路径是否真实存在。
- (BOOL)existsRelative:(NSString *)rel;

/// 列出所有可用服装（目录名）。
- (NSArray<NSString *> *)availableOutfits;

/// 列出所有可用主题。
- (NSArray<NSString *> *)availableSchemes;

+ (NSArray<NSString *> *)defaultUserPackRoots;

@end
