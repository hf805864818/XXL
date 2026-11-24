//
//  PDOutfitCatalog.h
//  PetDFY 可编辑源码 · 服装目录（换衣服 / 加新衣服）
//
//  原实现把服装写死成 @[@"maid",@"cape",@"crew",@"sailor"]，
//  预制里也把白名单限定成 @[@"maid"]，所以「加一套新衣服」必须先改代码。
//  这里改成「以 model.json 的 models 键 + 磁盘 outfits/ 目录」为唯一事实源：
//  只要模型里有一段 JSON、磁盘上有一组 PNG，它就会出现在可切换列表里。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

extern NSString * const PDOutfitCatalogDidChangeNotification;

@interface PDOutfitCatalog : NSObject

/// 枚举所有服装。root 为资源根（PetDFY.bundle）。
/// 返回 @[ @{@"id":@"maid", @"title":@"女仆装", @"thumb":@"thumbs/maid.png",
///            @"complete":@YES, @"missing":@[] }, ... ]
+ (NSArray<NSDictionary *> *)catalogForRoot:(NSString *)root scheme:(NSString *)scheme;

/// 服装 id -> 中文显示名。未知 id 原样返回。
/// 显示名可被数据覆盖：<资源根>/PDOutfitTitles.json（{"school":"校服"}），
/// 这样「加一套衣服」连编译都不用碰。
+ (NSString *)titleForOutfit:(NSString *)outfitID;
+ (NSString *)titleForOutfit:(NSString *)outfitID root:(NSString *)root;

/// 服装 id -> 缩略图相对路径（可能不存在，调用方需自行判空）。
+ (NSString *)thumbPathForOutfit:(NSString *)outfitID;

/// 循环取下一套（用于「单击换装」手势）。
+ (NSString *)outfitAfter:(NSString *)current inCatalog:(NSArray<NSDictionary *> *)catalog;

/// 循环取上一套。
+ (NSString *)outfitBefore:(NSString *)current inCatalog:(NSArray<NSDictionary *> *)catalog;

/// 校验一套服装的素材完整度：返回缺失的部件贴图列表（空数组 = 完整）。
+ (NSArray<NSString *> *)missingTexturesForOutfit:(NSString *)outfitID
                                             root:(NSString *)root
                                           scheme:(NSString *)scheme;

/// 把 model.json 里某个 model 的部件列表读出来（调试/工具用）。
+ (NSArray<NSDictionary *> *)partsForOutfit:(NSString *)outfitID root:(NSString *)root;

@end
