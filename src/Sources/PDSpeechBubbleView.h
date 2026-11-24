//
//  PDSpeechBubbleView : UIView
//  逆向还原：ivar/方法/属性来自二进制元数据
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

@interface PDSpeechBubbleView : UIView {
    BOOL _tail;
    BOOL _drawnTail;
    CAShapeLayer * _outline;
    double _unit;
    double _tailX;
    double _drawnUnit;
    double _drawnTailX;
    CGSize _drawnSize;
}

@property (nonatomic, strong) CAShapeLayer * outline;
@property (nonatomic) double unit;
@property (nonatomic) double tailX;
@property (nonatomic) BOOL tail;
@property (nonatomic) CGSize drawnSize;
@property (nonatomic) double drawnUnit;
@property (nonatomic) double drawnTailX;
@property (nonatomic) BOOL drawnTail;

- (id)init;
- (void)updateOutline;
- (void)layoutSubviews;
- (BOOL)pointInside:(CGPoint)arg1 withEvent:(id)arg2;
- (CAShapeLayer *)outline;
- (void)setOutline:(CAShapeLayer *)arg1;
- (double)unit;
- (void)setUnit:(double)arg1;
- (double)tailX;
- (void)setTailX:(double)arg1;
- (BOOL)tail;
- (void)setTail:(BOOL)arg1;
- (CGSize)drawnSize;
- (void)setDrawnSize:(CGSize)arg1;
- (double)drawnUnit;
- (void)setDrawnUnit:(double)arg1;
- (double)drawnTailX;
- (void)setDrawnTailX:(double)arg1;
- (BOOL)drawnTail;
- (void)setDrawnTail:(BOOL)arg1;
@end
