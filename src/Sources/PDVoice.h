//
//  PDVoice : NSObject
//  逆向还原：ivar/方法/属性来自二进制元数据
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

@interface PDVoice : NSObject {
    BOOL _busy;
    AVAudioPlayerNode * _node;
}

@property (nonatomic, strong) AVAudioPlayerNode * node;
@property (nonatomic) BOOL busy;

- (BOOL)busy;
- (void)setBusy:(BOOL)arg1;
@end
