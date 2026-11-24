//
//  PDComposerTextView : UITextView
//  逆向还原：ivar/方法/属性来自二进制元数据
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

@interface PDComposerTextView : UITextView {
    BOOL _multiline;
    UILabel * _placeholder;
    double _unit;
    void (^_imagePasteHandler)(NSArray *);
}

@property (nonatomic, strong) UILabel * placeholder;
@property (nonatomic) double unit;
@property (nonatomic) BOOL multiline;
@property (nonatomic, copy) void (^imagePasteHandler)(NSArray *);

- (id)init;
- (BOOL)canPerformAction:(SEL)arg1 withSender:(id)arg2;
- (void)paste:(id)arg1;
- (void)layoutSubviews;
@end
