//
//  PDOverlayController : NSObject
//  逆向还原：ivar/方法/属性来自二进制元数据
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

/// keyboardAnimation 承载的结构。
/// 编码（objc_full.json, _keyboardAnimation @offset 200, size 80）：
///   {?="active"B"started"d"sampledAt"d"duration"d
///      "from"{?="scale"d"floorY"d}"to"{?="scale"d"floorY"d}"velocity"{?="scale"d"floorY"d}}
/// 字段语义依据 -advanceKeyboardAnimation:（0xc0ec）：阻尼弹簧一步推进，
/// from 存当前值、to 存目标值、velocity 存速度，四者收敛后 active 清零并把 to 抄回 from。
typedef struct {
    BOOL active;        // +0x00
    double started;     // +0x08
    double sampledAt;   // +0x10  上一次积分时刻
    double duration;    // +0x18  10.0/duration 为角频率
    struct { double scale; double floorY; } from;      // +0x20 当前值
    struct { double scale; double floorY; } to;        // +0x30 目标值
    struct { double scale; double floorY; } velocity;  // +0x40 速度
} PDKeyboardAnimation;

@interface PDOverlayController : NSObject {
    BOOL _started;
    BOOL _pendingEntrance;
    BOOL _lastAvoidingKeyboard;
    PDWindow * _window;
    PDRootController * _root;
    PDPetView * _pet;
    PDPreferences * _preferences;
    PDAssetManager * _assets;
    NSTimer * _monitor;
    id _backlightController;
    PDActiveInterfaceOrientationMonitor * _orientationMonitor;
    PDKeyboardMonitor * _keyboardMonitor;
    double _lastPetSize;
    double _lastBottom;
    double _lastSafeTop;
    NSString * _loadedAppearance;
    NSString * _lastError;
    NSArray * _hoverButtons;
    NSArray * _hoverActions;
    PDAIPetRuntime * _ai;
    PDChatController * _chatController;
    UIWindow * _previousKeyWindow;
    double _hoverButtonDiameter;
    void (^_hoverDismissBlock)(void);
    CGSize _lastSize;
    PDKeyboardAnimation _keyboardAnimation;
}

@property (nonatomic, strong) PDWindow * window;
@property (nonatomic, strong) PDRootController * root;
@property (nonatomic, strong) PDPetView * pet;
@property (nonatomic, strong) PDPreferences * preferences;
@property (nonatomic, strong) PDAssetManager * assets;
@property (nonatomic, strong) NSTimer * monitor;
@property (nonatomic, strong) id backlightController;
@property (nonatomic, strong) PDActiveInterfaceOrientationMonitor * orientationMonitor;
@property (nonatomic, strong) PDKeyboardMonitor * keyboardMonitor;
@property (nonatomic) BOOL started;
@property (nonatomic) BOOL pendingEntrance;
@property (nonatomic) CGSize lastSize;
@property (nonatomic) double lastPetSize;
@property (nonatomic) double lastBottom;
@property (nonatomic) double lastSafeTop;
@property (nonatomic) BOOL lastAvoidingKeyboard;
@property (nonatomic) PDKeyboardAnimation keyboardAnimation;
@property (nonatomic, copy) NSString * loadedAppearance;
@property (nonatomic, copy) NSString * lastError;
@property (nonatomic, strong) NSArray * hoverButtons;
@property (nonatomic, strong) NSArray * hoverActions;
@property (nonatomic, strong) PDAIPetRuntime * ai;
@property (nonatomic, strong) PDChatController * chatController;
@property (nonatomic, strong) UIWindow * previousKeyWindow;
@property (nonatomic) double hoverButtonDiameter;
@property (nonatomic, copy) void (^hoverDismissBlock)(void);

/// ---- 可编辑化扩展层接口（本仓库 src/Ext，非二进制还原） ----
/// 发色 / 布局 / 服装目录变化后的热刷新入口。
- (void)reloadEditableAppearance;
/// 通知回调：收到 PDHairTintDidChangeNotification / PDLayoutConfigDidChangeNotification。
- (void)onEditableConfigChanged:(NSNotification *)note;

- (void)start;
- (void)setVisibilityPolling:(BOOL)arg1;
- (id)performDeviceScreenCapture:(id (^)(void))arg1;
- (void)backlightController:(id)arg1 didTransitionToBacklightState:(long long)arg2 source:(long long)arg3;
- (id)mainScene;
- (BOOL)ensureWindow;
- (void)discardAssetViews;
- (void)setChatKeyboardFocus:(BOOL)arg1;
- (void)showChat;
- (void)ensureChat;
- (id)hoverIcon:(id)arg1 label:(id)arg2 action:(SEL)arg3;
- (void)hideHoverButtons;
- (void)layoutHoverButtonsAt:(CGPoint)arg1 reach:(double)arg2;
- (void)showVoiceInput;
- (void)hoverPressed:(id)arg1;
- (void)petHoverChanged:(BOOL)arg1 point:(CGPoint)arg2;
- (void)rotateHostWindowWithDuration:(double)arg1;
- (void)applyAppearance;
- (void)systemAppearanceDidChange;
- (void)reloadPreferences;
- (void)updateVisibility;
- (void)layoutPet;
- (void)stopKeyboardAnimation;
- (void)advanceKeyboardAnimation:(id)arg1;
- (void)performCommand:(id)arg1;
- (BOOL)started;
- (void)setStarted:(BOOL)arg1;
- (BOOL)pendingEntrance;
- (void)setPendingEntrance:(BOOL)arg1;
- (CGSize)lastSize;
- (void)setLastSize:(CGSize)arg1;
- (double)lastPetSize;
- (void)setLastPetSize:(double)arg1;
- (double)lastBottom;
- (void)setLastBottom:(double)arg1;
- (double)lastSafeTop;
- (void)setLastSafeTop:(double)arg1;
- (BOOL)lastAvoidingKeyboard;
- (void)setLastAvoidingKeyboard:(BOOL)arg1;
- (PDKeyboardAnimation)keyboardAnimation;
- (void)setKeyboardAnimation:(PDKeyboardAnimation)arg1;
- (double)hoverButtonDiameter;
- (void)setHoverButtonDiameter:(double)arg1;
- (void (^)(void))hoverDismissBlock;
- (void)setHoverDismissBlock:(void (^)(void))arg1;

+ (instancetype)sharedController;
@end
