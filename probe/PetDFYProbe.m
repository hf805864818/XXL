//
//  PetDFYProbe — 极简探针
//
//  目的：只回答一个问题 —— "ellekit 到底有没有加载我们的 dylib"。
//
//  设计原则（关键）：
//    1. 不用 %hook，不调用任何 substrate 符号（MSHookMessageEx 等）
//    2. 只用 __attribute__((constructor)) + Foundation
//    3. 同步写文件，不依赖任何 UI/队列
//
//  如果这个探针也写不出文件 → 问题在注入链，不在代码。
//  如果能写出文件 → 说明加载正常，之前 diag 是 %hook 的符号依赖导致加载失败。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <unistd.h>

static NSString *const kProbePath = @"/var/mobile/Media/petdfy-probe.txt";
static NSString *const kProbePath2 = @"/var/mobile/Library/Caches/petdfy-probe.txt";

__attribute__((constructor))
static void PDProbeInit(void) {
    @autoreleasepool {
        NSMutableString *s = [NSMutableString string];

        [s appendString:@"==== PetDFYProbe loaded ====\n"];
        [s appendFormat:@"pid        = %d\n", getpid()];
        [s appendFormat:@"process    = %@\n", [[NSProcessInfo processInfo] processName]];
        [s appendFormat:@"date       = %@\n", [NSDate date]];
        [s appendFormat:@"bundle_id  = %@\n", [[NSBundle mainBundle] bundleIdentifier] ?: @"(nil)"];

        // 别的 tweak 是否已加载（判断注入时机）
        [s appendFormat:@"PDOverlayController = %@\n", objc_getClass("PDOverlayController") ? @"YES" : @"NO"];
        [s appendFormat:@"PDPetView           = %@\n", objc_getClass("PDPetView") ? @"YES" : @"NO"];
        [s appendFormat:@"WNRenderer          = %@\n", objc_getClass("WNRenderer") ? @"YES" : @"NO"];

        // 关键文件是否可见（RootHide 路径重定向是否正确）
        NSFileManager *fm = [NSFileManager defaultManager];
        [s appendFormat:@"model.json  = %@\n",
            [fm fileExistsAtPath:@"/Library/Application Support/PetDFY.bundle/live/model.json"] ? @"YES" : @"NO"];
        [s appendFormat:@"originals   = %@\n",
            [fm fileExistsAtPath:@"/Library/Application Support/PetDFY.bundle/originals"] ? @"YES" : @"NO"];
        [s appendFormat:@"JB env      = %@\n", [[[NSProcessInfo processInfo] environment] objectForKey:@"JB_ROOT_PATH"] ?: @"(none)"];

        // 兜底：列出 jbroot 实际路径
        NSArray *dirs = [fm contentsOfDirectoryAtPath:@"/var/containers/Bundle/Application" error:NULL];
        NSMutableArray *roots = [NSMutableArray array];
        for (NSString *d in dirs) {
            if ([d hasPrefix:@".jbroot-"]) [roots addObject:d];
        }
        [s appendFormat:@"jbroot dirs = %@\n", [roots componentsJoinedByString:@","] ?: @"(none)"];

        // 写两份（Media 给 Filza，Caches 兜底）
        NSString *text = s;
        BOOL ok1 = [text writeToFile:kProbePath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        BOOL ok2 = [text writeToFile:kProbePath2 atomically:YES encoding:NSUTF8StringEncoding error:NULL];

        NSLog(@"[PetDFYProbe] loaded pid=%d media=%d caches=%d", getpid(), ok1, ok2);
        NSLog(@"[PetDFYProbe]\n%@", text);
    }
}
