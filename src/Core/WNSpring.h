//
//  WNSpring : NSObject
//  逆向还原：ivar/方法/属性来自二进制元数据
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

@interface WNSpring : NSObject {
    double x;
    double v;
    double k;
    double c;
    double limit;
}

- (double)step:(double)arg1 dt:(double)arg2;
@end
