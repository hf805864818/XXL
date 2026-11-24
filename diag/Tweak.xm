//
//  PetDFYDiag — 只读诊断 tweak
//
//  目的：搞清楚 PetDFY 为什么不在 SpringBoard 上建窗口。
//  做法：hook -[PDOverlayController ensureWindow]，读它的返回值与内部状态，
//        再定时 dump 偏好键与关键文件，全部写入文件。
//
//  只读：不修改任何状态，不改偏好，不碰素材。
//  输出：/var/mobile/Library/Caches/petdfy-diag.log（同时 NSLog）
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <unistd.h>

// 双写：Caches 目录（标准位置）+ Media 目录（Filza / 文件 App 直接可见）
static NSString *const kLogPath = @"/var/mobile/Library/Caches/petdfy-diag.log";
static NSString *const kLogPathUser = @"/var/mobile/Media/petdfy-diag.log";
static NSString *const kPrefsDomain = @"com.susudear.petdfyprefs";
static NSString *const kBundlePath = @"/Library/Application Support/PetDFY.bundle";

static void PDLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSLog(@"[PetDFYDiag] %@", msg);

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (NSString *path in @[kLogPath, kLogPathUser]) {
            if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
                [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
                // 让 Media 下的文件对 Filza / 文件 App 可读
                [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0644}
                                                 ofItemAtPath:path error:NULL];
            }
        }
    });

    NSString *line = [NSString stringWithFormat:@"[%@] %@\n",
                      [NSDate dateWithTimeIntervalSince1970:[[NSDate date] timeIntervalSince1970]],
                      msg];
    NSData *payload = [line dataUsingEncoding:NSUTF8StringEncoding];
    for (NSString *path in @[kLogPath, kLogPathUser]) {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) continue;
        @try {
            [fh seekToEndOfFile];
            [fh writeData:payload];
            [fh closeFile];
        } @catch (NSException *e) {
            NSLog(@"[PetDFYDiag] write %@ failed: %@", path, e.reason);
        }
    }
}

#pragma mark - 状态读取

static NSString *PDBoolStr(BOOL b) { return b ? @"YES" : @"NO"; }

static void PDDumpController(id c) {
    if (!c) { PDLog(@"  controller = nil"); return; }
    PDLog(@"  controller = %@ (%p)", NSStringFromClass([c class]), c);

    // assets.ready
    @try {
        id assets = [c valueForKey:@"assets"];
        BOOL ready = NO;
        if ([assets respondsToSelector:NSSelectorFromString(@"ready")]) {
            NSNumber *v = [assets performSelector:NSSelectorFromString(@"ready")];
            ready = [v boolValue];
        }
        PDLog(@"  assets = %@  ready = %@",
              assets ? NSStringFromClass([assets class]) : @"nil", PDBoolStr(ready));
    } @catch (NSException *e) {
        PDLog(@"  assets dump failed: %@", e.reason);
    }

    // lastError
    @try {
        id err = [c valueForKey:@"lastError"];
        PDLog(@"  lastError = %@", err ?: @"(nil)");
    } @catch (NSException *e) {
        PDLog(@"  lastError dump failed: %@", e.reason);
    }

    // mainScene / windows
    @try {
        id scene = [c valueForKey:@"mainScene"];
        NSUInteger n = 0;
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            n = [(UIWindowScene *)scene windows].count;
        }
        PDLog(@"  mainScene = %@  windows = %lu",
              scene ? NSStringFromClass([scene class]) : @"nil", (unsigned long)n);
    } @catch (NSException *e) {
        PDLog(@"  mainScene dump failed: %@", e.reason);
    }

    // 窗口
    @try {
        id win = [c valueForKey:@"window"];
        PDLog(@"  window = %@ hidden = %@", win ? NSStringFromClass([win class]) : @"nil",
              win ? PDBoolStr([win isHidden]) : @"-");
    } @catch (NSException *e) {
        PDLog(@"  window dump failed: %@", e.reason);
    }

    // pet
    @try {
        id pet = [c valueForKey:@"pet"];
        PDLog(@"  pet = %@", pet ? NSStringFromClass([pet class]) : @"nil");
    } @catch (NSException *e) {
        PDLog(@"  pet dump failed: %@", e.reason);
    }
}

static void PDDumpFiles(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *model = [kBundlePath stringByAppendingPathComponent:@"live/model.json"];
    NSString *man = [kBundlePath stringByAppendingPathComponent:@"asset-manifest.json"];
    NSString *tex = [kBundlePath stringByAppendingPathComponent:@"originals/tex"];
    PDLog(@"  bundle exists     = %@", PDBoolStr([fm fileExistsAtPath:kBundlePath]));
    PDLog(@"  live/model.json   = %@", PDBoolStr([fm fileExistsAtPath:model]));
    PDLog(@"  asset-manifest    = %@", PDBoolStr([fm fileExistsAtPath:man]));
    PDLog(@"  originals/tex dir = %@", PDBoolStr([fm fileExistsAtPath:tex]));
    NSArray *texList = [fm contentsOfDirectoryAtPath:tex error:NULL];
    PDLog(@"  originals/tex 文件数 = %lu", (unsigned long)texList.count);
    NSString *outfits = [kBundlePath stringByAppendingPathComponent:@"originals/outfits"];
    NSArray *of = [fm contentsOfDirectoryAtPath:outfits error:NULL];
    PDLog(@"  originals/outfits 套数 = %lu (%@)", (unsigned long)of.count,
          [[of subarrayWithRange:NSMakeRange(0, MIN(of.count, 5))] componentsJoinedByString:@","]);
}

static void PDDumpPrefs(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kPrefsDomain);
    CFArrayRef keys = CFPreferencesCopyKeyList((__bridge CFStringRef)kPrefsDomain,
                                               kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (!keys) { PDLog(@"  prefs: (空)"); return; }
    NSArray *list = CFBridgingRelease(keys);
    PDLog(@"  prefs 键数 = %lu", (unsigned long)list.count);
    for (NSString *k in [list sortedArrayUsingSelector:@selector(compare:)]) {
        id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)k,
                                                           (__bridge CFStringRef)kPrefsDomain));
        PDLog(@"    %-24s = %@", [k UTF8String], v);
    }
}

#pragma mark - hook

%hook PDOverlayController

- (BOOL)ensureWindow {
    BOOL r = %orig;
    PDLog(@"---- ensureWindow -> %@ ----", PDBoolStr(r));
    PDDumpController(self);
    return r;
}

- (void)setLastError:(id)err {
    PDLog(@"setLastError: %@", err);
    %orig;
}

%end

%ctor {
    PDLog(@"================ PetDFYDiag loaded (pid=%d) ================", getpid());

    Class cls = objc_getClass("PDOverlayController");
    PDLog(@"PDOverlayController 类: %@", cls ? @"存在（hook 已生效）" : @"不存在（dylib 没加载或类名变了）");
    PDLog(@"PetDFY 主 dylib 是否加载: %@",
          objc_getClass("PDPetView") ? @"是" : @"否");
    PDLog(@"--- 文件检查 ---");
    PDDumpFiles();
    PDLog(@"--- 偏好检查 ---");
    PDDumpPrefs();

    // 5 秒后再 dump 一次，避免首次调用早于素材初始化
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        PDLog(@"---- 5s 后再查一次 ----");
        Class c = objc_getClass("PDOverlayController");
        if (c) {
            @try {
                id shared = nil;
                SEL sel = NSSelectorFromString(@"sharedController");
                if ([c respondsToSelector:sel]) {
                    shared = ((id (*)(id, SEL))objc_msgSend)(c, sel);
                }
                PDLog(@"sharedController = %@", shared ?: @"(无此方法或为 nil)");
                if (shared) PDDumpController(shared);
            } @catch (NSException *e) {
                PDLog(@"5s dump failed: %@", e.reason);
            }
        }
        PDDumpFiles();
    });
}
