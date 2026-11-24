//
//  WNMesh.m — 逆向还原实现
//
//  还原依据：PetDFY.dylib arm64e，15 个方法共 53 条指令
//  性质：纯数据容器（一个网格部件的 GPU 资源与几何参数）
//
//  ivar 布局（ivar_list，instanceSize=64）：
//    +0   isa
//    +8   BOOL          multiply        是否乘算混合
//    +16  uint64_t      positionOffset  顶点在共享 buffer 中的字节偏移
//    +24  uint64_t      indexCount      索引数量
//    +32  id<MTLBuffer> uv              纹理坐标缓冲
//    +40  id<MTLBuffer> indices         索引缓冲
//    +48  NSString *    texture         纹理名
//    +56  NSData *      hitIndices      命中检测用的索引子集
//
//  反汇编特征：getter 全部是「ldr 字段 → ret」（2 条指令），
//  setter 是「retain 新值 → 存字段 → release 旧值」（3 条指令），
//  .cxx_destruct 按 +56 → +48 → +40 → +32 逆序释放。
//

#import "WNMesh.h"

@implementation WNMesh

// 数值型（非对象）属性：直接访问 ivar
- (unsigned long long)positionOffset { return _positionOffset; }
- (void)setPositionOffset:(unsigned long long)v { _positionOffset = v; }

- (unsigned long long)indexCount { return _indexCount; }
- (void)setIndexCount:(unsigned long long)v { _indexCount = v; }

- (BOOL)multiply { return _multiply; }
- (void)setMultiply:(BOOL)v { _multiply = v; }

// 对象型属性：编译器自动生成 retain/release 语义，
// 与反汇编的 objc_retain/objc_release 序列一致
@synthesize uv = _uv;
@synthesize indices = _indices;
@synthesize texture = _texture;
@synthesize hitIndices = _hitIndices;

@end
