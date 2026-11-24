//
//  WNClip.m — 逆向还原实现
//
//  还原依据：PetDFY.dylib arm64e，11 个方法共 51 条指令
//  性质：纯数据容器（一个动画片段的元数据与顶点数据）
//
//  ivar 布局（ivar_list，instanceSize=48）：
//    +0  isa
//    +8  NSDictionary * info               片段元信息（帧率/循环/名称等）
//    +16 NSData *       positions          每帧顶点位置（原始字节）
//    +24 NSArray *      meshes             网格部件数组（WNMesh）
//    +32 id<MTLBuffer>  positionBuffer     顶点缓冲（GPU）
//    +40 id<MTLBuffer>  backgroundPositions 背景层位置缓冲
//
//  反汇编特征：与 WNMesh 同构 —— getter 2 条指令、setter 3 条指令、
//  .cxx_destruct 逆序释放 +40 → +32 → +24 → +16 → +8。
//

#import "WNClip.h"

@implementation WNClip

@synthesize info = _info;
@synthesize positions = _positions;
@synthesize meshes = _meshes;
@synthesize positionBuffer = _positionBuffer;
@synthesize backgroundPositions = _backgroundPositions;


- (id)quad {
    return nil;
}
@end
