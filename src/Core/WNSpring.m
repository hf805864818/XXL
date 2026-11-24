//
//  WNSpring.m — 逆向还原实现（可运行）
//
//  还原依据：PetDFY.dylib arm64e 切片，method.WNSpring.step:dt: 共 33 条指令
//  类：WNSpring（阻尼弹簧积分器，48 字节）
//
//  ivar 布局（来自 ivar_list）：
//    x     double  当前值
//    v     double  速度
//    k     double  劲度 / 速度基线
//    c     double  阻尼
//    limit double  位移上限
//
//  反汇编关键序列（逐条核对）：
//    fmov d2, d0                    ; d2 = target
//    fabs d3, d0 ; ldr d0, [x0,8]   ; d3=|target|, d0=s->x
//    fmov d4, 0x7ff0000000000000    ; +inf
//    fcmp d3, d4 ; b.eq / b.vs      ; 非有限则返回
//    fabs d3, d1 ; fcmp d3, d4      ; dt 同样检查
//    fsub d3, d2, d0                ; d3 = target - x
//    ldp d5, d4, [x0,0x10]          ; d5=k, d4=c
//    ldp d6, d2, [x0,0x20]          ; d6=limit
//    fnmul d6, d5, d6               ; d6 = -(k*limit)
//    fmadd d3, d3, d4, d6           ; d3 = (target-x)*c - k*limit
//    fmadd d3, d3, d1, d5           ; d3 = d3*dt + k
//    fmadd d0, d3, d1, d0           ; x  = d3*dt + x
//    stp d0, d3, [x0,8]             ; 写回 x, v
//    fabs d1, d0 ; fcmp d1, d2      ; |x| vs limit
//    b.le → 返回
//    str d0, [x0,8] ; str xzr,[x0,0x10]  ; x = ±limit, v = 0
//

#import "WNSpring.h"
#import <math.h>

@implementation WNSpring

/// 单步积分。返回值是新的 x（也写回 x）。
- (double)step:(double)target dt:(double)dt {
    // 1) NaN / Inf 双重保护（原版用 b.eq + b.vs 两条分支）
    if (!isfinite(target) || !isfinite(dt)) return x;

    // 2) 驱动力：(target - x) * c - k * limit
    double a = (target - x) * c - k * limit;

    // 3) 速度积分：v = a * dt + k
    double nv = a * dt + k;

    // 4) 位置积分：x = v * dt + x
    double nx = nv * dt + x;

    v = nv;
    x = nx;

    // 5) 超限硬钳位（速度清零，不反弹）
    if (fabs(x) > limit) {
        x = (x > 0) ? limit : -limit;
        v = 0;
    }
    return x;
}

@end
