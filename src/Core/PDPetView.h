//
//  PDPetView : MTKView
//  逆向还原：ivar/方法/属性来自二进制元数据
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

@interface PDPetView : MTKView {
    BOOL _interactionEnabled;
    BOOL _stroking;
    BOOL _layoutAnimating;
    BOOL _hasLastBubblePosition;
    BOOL _hasLastHoverPosition;
    BOOL _tapEligible;
    BOOL _menuPressActive;
    WNRenderer * _renderer;
    NSString * _doubleTapAction;
    NSString * _longPressAction;
    void (^_gestureActionHandler)(NSString *, CGPoint);
    long long _activeFPS;
    void (^_frameHandler)(void);
    void (^_beforeFrameHandler)(void);
    void (^_hoverHandler)(BOOL, CGPoint, double);
    void (^_bubblePositionHandler)(CGPoint);
    void (^_hoverPositionHandler)(CGPoint, CGSize);
    UIView * _interactionView;
    __weak UITouch * _activeTouch;
    CAShapeLayer * _interactionMask;
    double _lastHoverReach;
    UITapGestureRecognizer * _singleTapRecognizer;
    UITapGestureRecognizer * _doubleTapRecognizer;
    UILongPressGestureRecognizer * _longPressRecognizer;
    CGPoint _lastBubblePosition;
    CGPoint _lastHoverPosition;
    CGSize _lastHoverViewport;
}

@property (nonatomic, strong) WNRenderer * renderer;
@property (nonatomic, strong) UITouch * activeTouch;
@property (nonatomic, strong) UIView * interactionView;
@property (nonatomic, strong) CAShapeLayer * interactionMask;
@property (nonatomic) CGPoint lastBubblePosition;
@property (nonatomic) BOOL hasLastBubblePosition;
@property (nonatomic) CGPoint lastHoverPosition;
@property (nonatomic) double lastHoverReach;
@property (nonatomic) CGSize lastHoverViewport;
@property (nonatomic) BOOL hasLastHoverPosition;
@property (nonatomic, strong) UITapGestureRecognizer * singleTapRecognizer;
@property (nonatomic, strong) UITapGestureRecognizer * doubleTapRecognizer;
@property (nonatomic, strong) UILongPressGestureRecognizer * longPressRecognizer;
@property (nonatomic) BOOL tapEligible;
@property (nonatomic) BOOL menuPressActive;
@property (nonatomic) BOOL interactionEnabled;
@property (nonatomic) BOOL stroking;
@property (nonatomic, copy) NSString * doubleTapAction;
@property (nonatomic, copy) NSString * longPressAction;
@property (nonatomic, copy) void (^gestureActionHandler)(NSString *, CGPoint);
@property (nonatomic) long long activeFPS;
@property (nonatomic, copy) void (^frameHandler)(void);
@property (nonatomic, copy) void (^beforeFrameHandler)(void);
@property (nonatomic) BOOL layoutAnimating;
@property (nonatomic, copy) void (^hoverHandler)(BOOL, CGPoint, double);
@property (nonatomic, copy) void (^bubblePositionHandler)(CGPoint);
@property (nonatomic, copy) void (^hoverPositionHandler)(CGPoint, CGSize);
@property (nonatomic, readonly) unsigned long long hash;
@property (nonatomic, readonly) Class superclass;
@property (nonatomic, readonly, copy) NSString * description;
@property (nonatomic, readonly, copy) NSString * debugDescription;

- (id)initWithResourceURL:(id)arg1;
- (void)didMoveToSuperview;
- (void)setPaused:(BOOL)arg1;
- (void)setActiveFPS:(long long)arg1;
- (void)setLayoutAnimating:(BOOL)arg1;
- (void)updateFrameRate;
- (void)setInteractionEnabled:(BOOL)arg1;
- (void)singleTap:(id)arg1;
- (void)doubleTap:(id)arg1;
- (void)layoutSubviews;
- (void)updateInteractionRegion;
- (CGPoint)stagePoint:(CGPoint)arg1;
- (CGPoint)bubbleAnchorInSuperview;
- (void)publishBubblePosition;
- (void)setHoverPositionHandler:(void (^)(CGPoint, CGSize))arg1;
- (void)publishHoverPosition;
- (BOOL)pointInside:(CGPoint)arg1 withEvent:(id)arg2;
- (void)touchesBegan:(id)arg1 withEvent:(id)arg2;
- (void)touchesMoved:(id)arg1 withEvent:(id)arg2;
- (void)touchesEnded:(id)arg1 withEvent:(id)arg2;
- (void)touchesCancelled:(id)arg1 withEvent:(id)arg2;
- (void)cancelInteraction;
- (void)longPress:(id)arg1;
- (void)drawInMTKView:(id)arg1;
- (void)mtkView:(id)arg1 drawableSizeWillChange:(CGSize)arg2;
- (BOOL)interactionEnabled;
- (BOOL)stroking;
- (void)setStroking:(BOOL)arg1;
- (void (^)(NSString *, CGPoint))gestureActionHandler;
- (void)setGestureActionHandler:(void (^)(NSString *, CGPoint))arg1;
- (long long)activeFPS;
- (void (^)(void))frameHandler;
- (void)setFrameHandler:(void (^)(void))arg1;
- (void (^)(void))beforeFrameHandler;
- (void)setBeforeFrameHandler:(void (^)(void))arg1;
- (BOOL)layoutAnimating;
- (void (^)(BOOL, CGPoint, double))hoverHandler;
- (void)setHoverHandler:(void (^)(BOOL, CGPoint, double))arg1;
- (void (^)(CGPoint))bubblePositionHandler;
- (void)setBubblePositionHandler:(void (^)(CGPoint))arg1;
- (void (^)(CGPoint, CGSize))hoverPositionHandler;
- (CGPoint)lastBubblePosition;
- (void)setLastBubblePosition:(CGPoint)arg1;
- (BOOL)hasLastBubblePosition;
- (void)setHasLastBubblePosition:(BOOL)arg1;
- (CGPoint)lastHoverPosition;
- (void)setLastHoverPosition:(CGPoint)arg1;
- (double)lastHoverReach;
- (void)setLastHoverReach:(double)arg1;
- (CGSize)lastHoverViewport;
- (void)setLastHoverViewport:(CGSize)arg1;
- (BOOL)hasLastHoverPosition;
- (void)setHasLastHoverPosition:(BOOL)arg1;
- (BOOL)tapEligible;
- (void)setTapEligible:(BOOL)arg1;
- (BOOL)menuPressActive;
- (void)setMenuPressActive:(BOOL)arg1;
@end
