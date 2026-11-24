//
//  Batch5.m — 逆向还原：4 个类
//
//  PDActiveInterfaceOrientationMonitor (15 方法 / 277 指令)
//  PDReplySpeech                       (32 方法 / 332 指令)
//  PDNative_MCPAXQueryContext          (21 方法 / 332 指令)
//  PDComposerTextView                  (13 方法 / 364 指令)
//

#import "PDActiveInterfaceOrientationMonitor.h"
#import "PDReplySpeech.h"
#import "PDNative_MCPAXQueryContext.h"
#import "PDComposerTextView.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>

#pragma mark - PDComposerTextView

@implementation PDComposerTextView

/// 86 条指令。初始化输入框。
- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _unit = 1.0;
    self.backgroundColor = [UIColor clearColor];
    self.textContainerInset = UIEdgeInsetsMake(6, 8, 6, 8);
    self.font = [UIFont systemFontOfSize:15];
    self.returnKeyType = UIReturnKeyDefault;
    return self;
}


/// 51 条指令。判断能否执行某个动作（粘贴等）。
/// 反汇编：generalPasteboard → hasImages → imagePasteHandler
- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
    if (action == @selector(paste:)) {
        UIPasteboard *pb = [UIPasteboard generalPasteboard];
        BOOL hasImages = NO;
        if (@available(iOS 10.0, *)) {
            hasImages = pb.hasImages;
        } else {
            hasImages = pb.image != nil;
        }
        if (hasImages && _imagePasteHandler) return YES;
    }
    return [super canPerformAction:action withSender:sender];
}

/// 63 条指令。粘贴处理：图片走自定义 handler。
- (void)paste:(id)sender {
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    BOOL hasImages = NO;
    if (@available(iOS 10.0, *)) hasImages = pb.hasImages;
    else hasImages = pb.image != nil;

    if (hasImages && _imagePasteHandler) {
        NSArray *imgs = pb.images;
        if (imgs.count) { _imagePasteHandler(imgs); return; }
    }
    [super paste:sender];
}

/// 112 条指令。布局：按 unit 缩放行高。
/// 反汇编：unit → font → lineHeight → multiline → textContainerInset
- (void)layoutSubviews {
    [super layoutSubviews];

    double unit = _unit;
    if (unit <= 0) unit = 1.0;

    UIFont *f = self.font;
    if (f) {
        CGFloat base = f.lineHeight;
        CGFloat target = base * unit;
        // 用 paragraphStyle 控制行高
        NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
        ps.minimumLineHeight = target;
        ps.maximumLineHeight = target;
        NSDictionary *attrs = @{NSFontAttributeName: f,
                                NSParagraphStyleAttributeName: ps,
                                NSForegroundColorAttributeName: self.textColor ?: [UIColor labelColor]};
        if (self.text.length) {
            self.attributedText = [[NSAttributedString alloc] initWithString:self.text attributes:attrs];
        }
    }
    // 垂直内边距按 unit 缩放
    CGFloat inset = 6.0 * unit;
    self.textContainerInset = UIEdgeInsetsMake(inset, 8, inset, 8);

    CGRect b = [self bounds];
    UILabel *ph = [self placeholder];
    if (ph) {
        [ph setFont:[self font]];
        [ph setFrame:CGRectInset(b, 8.0, 6.0)];
        [ph setHidden:([[self text] length] > 0)];
    }
    (void)[self multiline];
}


- (UILabel *)placeholder { return _placeholder; }
- (void)setPlaceholder:(UILabel *)v { _placeholder = v; }

#pragma mark - 二进制存取器（逐条 8-16 指令，纯 ivar 读写）
- (void)setUnit:(double)v { _unit = v; }
- (void)setMultiline:(BOOL)v { _multiline = v; }
- (void)setImagePasteHandler:(id)v { _imagePasteHandler = v; }

#pragma mark - 二进制存取器（逐条 8-16 指令，纯 ivar 读写）
- (double)unit { return _unit; }
- (BOOL)multiline { return _multiline; }

@end
