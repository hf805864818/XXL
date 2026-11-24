//
//  PDWindow : UIWindow
//  逆向还原：ivar/方法/属性来自二进制元数据
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

@interface PDWindow : UIWindow {
    BOOL _pdAllowsKey;
}

@property (nonatomic) BOOL pdAllowsKey;

- (instancetype)initWithWindowScene:(id)scene;
- (BOOL)canBecomeKeyWindow;
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event;
- (BOOL)pdAllowsKey;
- (void)setPdAllowsKey:(BOOL)arg1;
@end
