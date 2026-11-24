//
//  PDRootController : UIViewController
//  逆向还原：ivar/方法/属性来自二进制元数据
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

@interface PDRootController : UIViewController {
    PDOverlayController * _owner;
}

@property (nonatomic, weak) PDOverlayController * owner;

- (void)loadView;
- (void)viewDidLayoutSubviews;
- (BOOL)shouldAutorotate;
- (unsigned long long)supportedInterfaceOrientations;
- (BOOL)prefersStatusBarHidden;
- (void)traitCollectionDidChange:(id)arg1;
@property (nonatomic) NSInteger overrideUserInterfaceStyle;
@end
