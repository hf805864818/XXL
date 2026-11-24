//
//  Batch4.m — 逆向还原：PDRootController / PDKeyboardMonitor / PDInteractionView / PDDeviceTools
//
//  PDRootController  (9 方法 / 153 指令)   根控制器
//  PDKeyboardMonitor (9 方法 / 161 指令)   键盘状态监听
//  PDInteractionView (9 方法 / 235 指令)   交互视图
//  PDDeviceTools    (14 方法 / 246 指令)   设备工具执行器
//

#import "PDRootController.h"
#import "PDKeyboardMonitor.h"
#import "PDInteractionView.h"
#import "PDDeviceTools.h"
#import "PDPetView.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>

#pragma mark - PDRootController

@implementation PDRootController

/// 61 条指令。手动建 view（不用 nib）。
- (void)loadView {
    UIView *v = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    v.backgroundColor = [UIColor clearColor];
    v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.view = v;

    [self.view setUserInteractionEnabled:YES];
    [self.view setClipsToBounds:NO];
}


/// 23 条指令。布局：子视图铺满。
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    for (UIView *sub in self.view.subviews) {
        sub.frame = self.view.bounds;
    }

    (void)[self owner];
    [[self owner] layoutPet];
}


/// 44 条指令。深色模式切换。
/// 反汇编：traitCollection → userInterfaceStyle → systemAppearanceDidChange
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (@available(iOS 12.0, *)) {
        if (previous.userInterfaceStyle == self.traitCollection.userInterfaceStyle) return;
    }
    if ([self respondsToSelector:NSSelectorFromString(@"systemAppearanceDidChange")]) {
        ((void (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"systemAppearanceDidChange"));
    }

    [[self owner] applyAppearance];
}


- (id)owner { return _owner; }
- (void)setOwner:(id)v { _owner = v; }

#pragma mark - 二进制存取器（逐条 8-16 指令，纯 ivar 读写）
- (BOOL)shouldAutorotate { return NO; }   // Observed 0x5ef0: mov w0,#0
- (unsigned long long)supportedInterfaceOrientations { return 0x1eULL; }  // Observed 0x5ef8: mov w0,#0x1e
- (BOOL)prefersStatusBarHidden { return NO; }  // Observed 0x5f00

@end

