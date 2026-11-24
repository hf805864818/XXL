//
//  PDNative_ClipboardManager : NSObject
//  逆向还原：ivar/方法/属性来自二进制元数据
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

@interface PDNative_ClipboardManager : NSObject {
}

- (id)readClipboard;
- (BOOL)writeText:(id)arg1;
+ (id)sharedInstance;
@end
