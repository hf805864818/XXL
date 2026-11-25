//
//  PDBootstrap.m — 加载标记 + 启动入口
//  用途：确认 PetDFY.dylib 是否真的被 ellekit 加载。
//  如果 /var/mobile/Media/petdfy-main-loaded.txt 出现，说明 dylib 已加载；
//  如果 probe 仍看不到 PDOverlayController，则是类注册/初始化问题。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <unistd.h>
#import "PDOverlayController.h"

__attribute__((constructor))
static void PDBootstrap(void) {
    @autoreleasepool {
        NSString *marker = [NSString stringWithFormat:@"PetDFY main loaded\npid=%d\ndate=%@\n",
                            getpid(), [NSDate date]];
        [marker writeToFile:@"/var/mobile/Media/petdfy-main-loaded.txt"
                 atomically:YES
                   encoding:NSUTF8StringEncoding
                      error:NULL];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[PDOverlayController sharedController] start];
        });
    }
}
