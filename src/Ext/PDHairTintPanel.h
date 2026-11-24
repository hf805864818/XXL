//
//  PDHairTintPanel.h
//  PetDFY 可编辑源码 · 长发色面板（宠物身上直接开）
//
//  为什么做在运行时而不是设置 App 里：设置 App 的偏好包是编译好的二进制，
//  改它要重编 846 KB 的 PetDFYPrefs；而这个面板挂在桌宠自己的窗口上，
//  源码完全在我们手里，滑一下立刻能看到效果，还能做「预设色板」。
//
//  设置 App 里同样有发色分页（PSGroupCell + PSSliderCell 纯 plist 实现），
//  两处写的是同一组 CFPreferences 键，互相看得见。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

extern NSString * const PDHairTintDidChangeNotification;

@interface PDHairTintPanel : UIView

/// 在指定窗口底部弹出面板；window 为 nil 时用当前 keyWindow。
+ (void)presentInWindow:(UIWindow *)window;

/// 关闭面板。
+ (void)dismiss;

/// 把当前面板中的值写回 CFPreferences（外部按钮也可调用）。
- (void)commit;

@end
