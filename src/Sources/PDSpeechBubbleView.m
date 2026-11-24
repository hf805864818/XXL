//
//  PDSpeechBubbleView.m
//  逆向还原：PDSpeechBubbleView（470 指令 / 13 方法）
//
//  角色：桌宠气泡的绘制层。CALayer 只负责承载，真正的轮廓由 updateOutline
//        生成一条 CGMutablePathRef：圆角矩形 + 可选的小尾巴；尺寸/缩放/
//        尾巴位置任一变化才重算，否则直接命中缓存返回。
//
//  保真分级
//    Observed  init 的图层装配（clearColor / lineJoin / lineCap / addSublayer）
//              updateOutline 的缓存四连比、全部几何常量与 CG 调用顺序
//              pointInside 的 CGPathContainsPoint 判定
//              layoutSubviews 的 super 调用 + updateOutline
//              8 个存取器的 ivar 偏移（0x420/0x424/0x428/0x42c/0x430/0x434/0x438/0x43c）
//    Inferred  kCALineJoinRound / kCALineCapRound 的具体归属（二进制取的是
//              __DATA_CONST GOT 里的 CFString，两槽内容同族，round 语义可定）
//    Assumed   无
//

#import "PDSpeechBubbleView.h"

@implementation PDSpeechBubbleView

#pragma mark - 生命周期

- (id)init
{
    self = [super init];
    if (!self) {
        return nil;
    }

    self.backgroundColor = [UIColor clearColor];

    CAShapeLayer *shape = [CAShapeLayer layer];
    _outline = shape;
    _outline.lineJoin = kCALineJoinRound;
    _outline.lineCap = kCALineCapRound;
    [self.layer addSublayer:_outline];

    return self;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    [self updateOutline];
}

#pragma mark - 轮廓

// 几何：外框 [r, w-r] × [r, h-r-tailH]，圆角半径 s，尾巴挂在底边 tailX 处。
// 只有 unit / bounds / tailX / tail 四项全都没变时才跳过重算。
- (void)updateOutline
{
    CGFloat unit = self.unit;
    if (unit <= 0.0) {
        return;
    }

    CGSize size = self.bounds.size;
    if (size.width <= 0.0 || size.height <= 0.0) {
        return;
    }

    BOOL needsLayout = (self.outline.path == NULL);
    if (!needsLayout) {
        CGSize drawn = self.drawnSize;
        needsLayout = (drawn.width != size.width)
                   || (drawn.height != size.height)
                   || (self.drawnUnit != unit)
                   || (self.drawnTailX != self.tailX)
                   || (self.drawnTail != self.tail);
        if (!needsLayout) {
            return;
        }
    }

    self.drawnSize = size;
    self.drawnUnit = unit;
    self.drawnTailX = self.tailX;
    self.drawnTail = self.tail;

    const CGFloat w = size.width;
    const CGFloat h = size.height;
    const BOOL hasTail = self.tail;
    const CGFloat tailX = self.tailX;

    const CGFloat inset = unit * 1.25;                      // r
    const CGFloat tailHeight = hasTail ? unit * 10.0 : 0.0; // tailH

    // 竖直方向：先算「半高减 r」，再与 18*unit 取小，兜底非负
    CGFloat vertical = fmin(unit * 18.0, (h - tailHeight) * 0.5 - inset);
    vertical = fmax(vertical, 0.0);

    // 水平方向：((w - r) / 2 - 20*unit) / 2，兜底非负
    CGFloat horizontal = ((w - inset) * 0.5 - unit * 20.0) * 0.5;
    horizontal = fmax(horizontal, 0.0);

    const CGFloat radius = hasTail ? fmin(vertical, horizontal) : vertical; // s

    CGMutablePathRef path = CGPathCreateMutable();

    const CGFloat left = inset + radius;             // r + s
    const CGFloat right = w - inset - radius;        // w - r - s
    const CGFloat top = inset;                       // r
    const CGFloat bottom = h - inset - tailHeight;   // h - r - tailH

    CGPathMoveToPoint(path, NULL, left, top);
    CGPathAddLineToPoint(path, NULL, right, top);
    CGPathAddArcToPoint(path, NULL, w - inset, top, w - inset, top + radius, radius);
    CGPathAddLineToPoint(path, NULL, w - inset, bottom - radius);
    CGPathAddArcToPoint(path, NULL, w - inset, bottom, right, bottom, radius);

    if (hasTail) {
        CGFloat tip = fmax(left + unit * 10.0,
                           fmin(right - unit * 10.0, tailX));

        CGPathAddLineToPoint(path, NULL, tip, bottom);
        CGPathAddLineToPoint(path, NULL, tip + unit, bottom + unit * 9.0);
        CGPathAddQuadCurveToPoint(path, NULL,
                                  tip, bottom + unit * 9.0,
                                  tip - unit, bottom + unit * 9.0);
        CGPathAddLineToPoint(path, NULL, tip - unit * 10.0, bottom);
    }

    CGPathAddLineToPoint(path, NULL, left, bottom);
    CGPathAddArcToPoint(path, NULL, inset, bottom, inset, bottom - radius, radius);
    CGPathAddLineToPoint(path, NULL, inset, left);
    CGPathAddArcToPoint(path, NULL, inset, inset, left, inset, radius);
    CGPathCloseSubpath(path);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    self.outline.frame = self.bounds;
    self.outline.path = path;
    self.outline.lineWidth = hasTail ? unit * 2.5 : 0.0;

    [CATransaction commit];

    CGPathRelease(path);
}

#pragma mark - 命中

- (BOOL)pointInside:(CGPoint)point withEvent:(id)event
{
    CGPathRef path = self.outline.path;
    if (path == NULL) {
        return NO;
    }
    return CGPathContainsPoint(path, NULL, point, NO);
}

#pragma mark - 存取器

- (CAShapeLayer *)outline
{
    return _outline;
}

- (void)setOutline:(CAShapeLayer *)outline
{
    _outline = outline;
}

- (double)unit
{
    return _unit;
}

- (void)setUnit:(double)unit
{
    _unit = unit;
}

- (double)tailX
{
    return _tailX;
}

- (void)setTailX:(double)tailX
{
    _tailX = tailX;
}

- (BOOL)tail
{
    return _tail;
}

- (void)setTail:(BOOL)tail
{
    _tail = tail;
}

- (CGSize)drawnSize
{
    return _drawnSize;
}

- (void)setDrawnSize:(CGSize)drawnSize
{
    _drawnSize = drawnSize;
}

- (double)drawnUnit
{
    return _drawnUnit;
}

- (void)setDrawnUnit:(double)drawnUnit
{
    _drawnUnit = drawnUnit;
}

- (double)drawnTailX
{
    return _drawnTailX;
}

- (void)setDrawnTailX:(double)drawnTailX
{
    _drawnTailX = drawnTailX;
}

- (BOOL)drawnTail
{
    return _drawnTail;
}

- (void)setDrawnTail:(BOOL)drawnTail
{
    _drawnTail = drawnTail;
}

@end
