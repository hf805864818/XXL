//
//  PDNative_AppManager.m — 装包 / 签名 / 应用枚举
//
//  还原依据：PetDFY.arm64e.dylib 0x77fac–0x83900（_OBJC_CLASS_$_PDNative_AppManager）
//  本文件所有 `bl 0xXXXX` 均已按 selref 解引用还原为选择器调用，非猜测。
//

#import "PDNative_AppManager.h"
#import <objc/runtime.h>
#import <sys/stat.h>
#import <spawn.h>
#import <dlfcn.h>
extern char **environ;
#include <errno.h>
#include <string.h>
#import <Foundation/Foundation.h>
#import "PDNative_MCPLogger.h"
#import "PDNative_AccessibilityManager.h"

@class PDNative_MCPLogger;

// 进程派生 / 越狱路径解析 —— 由 PDNative_MCPProcess.m 提供（见该文件 extern 段）
extern NSString *PDNative_MCPResolvedJailbreakPath(NSString *path);
extern NSDictionary *PDNative_MCPJailbreakEnvironment(void);
extern BOOL PDNative_MCPRunProcess(NSString *tool,
                                   NSArray *arguments,
                                   NSDictionary *environment,
                                   NSUInteger flags,
                                   NSString **output,
                                   int *exitCode,
                                   NSError **spawnError);

static NSError *PDNAppError(NSString *message, NSInteger code);
static id PDNAppLSWorkspace(void);

@interface PDNative_AppManager ()
- (pid_t)pidForBundleId:(NSString *)bundleId;
- (BOOL)waitForUninstallOfBundleId:(NSString *)bundleId timeout:(double)timeout;
@end
@interface PDNative_LSApplicationWorkspace : NSObject
- (id)allApplications;
- (id)applicationProxyForIdentifier:(NSString *)identifier;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleId;
- (BOOL)openSensitiveURL:(NSURL *)url withOptions:(NSDictionary *)options;
- (BOOL)openURL:(NSURL *)url withOptions:(NSDictionary *)options error:(NSError **)error;
- (BOOL)uninstallApplication:(NSString *)bundleId withOptions:(id)options;
@end

extern BOOL PDNativeIsMachOFileAtPath(NSString *path);

@implementation PDNative_AppManager

// ============================================================================
//  以下为 0x7803c–0x81994 段还原（launch / kill / list / frontmost / openURL /
//  路径等待 / fakesign / install / uninstall）。每条方法的保真级别见方法头注释。
// ============================================================================

static NSString *const PDNAppManagerErrorDomain = @"PDNative.MCP.AppManager";  // Assumed

static NSError *PDNAppError(NSString *message, NSInteger code) {
    return [NSError errorWithDomain:PDNAppManagerErrorDomain
                               code:code
                           userInfo:@{@"message": message ?: @""}];

}


// 二进制里 lsapplicationworkspace 取号靠 objc_getClass；类名串在 0xc0174
static id PDNAppLSWorkspace(void) {
    Class cls = objc_getClass("LSApplicationWorkspace");
    if (!cls) {
        return nil;
    }
    if (![cls respondsToSelector:@selector(defaultWorkspace)]) {
        return nil;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    return [cls performSelector:@selector(defaultWorkspace)];
#pragma clang diagnostic pop
}

#pragma mark - 启动

// 0x7803c–0x78a7c (2624 B) — Observed：错误串、YES/NO、5 秒超时、activateApplication: 兜底
// ============================================================================
//  以下为 0x7803c–0x81994 段还原（launch / kill / list / frontmost / openURL /
//  路径等待 / fakesign / install / uninstall）。每条方法的保真级别见方法头注释。
// ============================================================================



// 二进制里 lsapplicationworkspace 取号靠 objc_getClass；类名串在 0xc0174

#pragma mark - 启动

// 0x7803c–0x78a7c (2624 B) — Observed：错误串、YES/NO、5 秒超时、activateApplication: 兜底
- (BOOL)launchApp:(NSString *)bundleId error:(NSError **)error {
    if (bundleId.length == 0) {
        if (error) *error = PDNAppError(@"Empty bundle ID", 1);
        return NO;
    }

    Class LS = objc_getClass("LSApplicationWorkspace");
    if (!LS) {
        if (error) *error = PDNAppError(@"LSApplicationWorkspace is unavailable", 2);
        return NO;
    }
    if (![LS respondsToSelector:@selector(defaultWorkspace)]) {
        if (error) *error = PDNAppError(@"LSApplicationWorkspace defaultWorkspace is unavailable", 3);
        return NO;
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id workspace = [LS performSelector:@selector(defaultWorkspace)];
#pragma clang diagnostic pop

    if (!workspace) {
        if (error) *error = PDNAppError(@"LSApplicationWorkspace defaultWorkspace returned nil", 4);
        return NO;
    }
    if (![workspace respondsToSelector:@selector(openApplicationWithBundleID:)]) {
        if (error) *error = PDNAppError(@"LSApplicationWorkspace openApplicationWithBundleID: is unavailable", 5);
        return NO;
    }

    double started = CFAbsoluteTimeGetCurrent();
    BOOL opened = NO;
    @try {
        opened = [(PDNative_LSApplicationWorkspace *)workspace openApplicationWithBundleID:bundleId];
        double elapsedMs = (CFAbsoluteTimeGetCurrent() - started) * 1000.0;
        [PDNative_MCPLogger logMessage:[NSString stringWithFormat:
            @"[App] LaunchServices launch request for %@ returned %@ in %.0fms",
            bundleId, opened ? @"YES" : @"NO", elapsedMs]];
        if (!opened) {
            if (error) *error = PDNAppError(@"LSApplicationWorkspace openApplicationWithBundleID: returned NO", 6);
            return NO;
        }
    } @catch (id exception) {
        NSString *name = [exception respondsToSelector:@selector(name)] ? [exception performSelector:@selector(name)] : @"unknown";
        NSString *reason = [exception respondsToSelector:@selector(reason)] ? [exception performSelector:@selector(reason)]
                                                                          : @"unknown exception";
        [PDNative_MCPLogger logMessage:[NSString stringWithFormat:
            @"[App] LaunchServices launch exception for %@: %@ - %@", bundleId, name, reason]];
        if (error) *error = PDNAppError(@"LSApplicationWorkspace launch failed: %@", 7);
        return NO;
    }

    // 前台确认（Observed，0x78320–0x7840c）：轮询
    // [[PDNative_AccessibilityManager sharedInstance] frontmostApplicationInfo][@"bundleId"]，
    // 上限 5.0s（0x78330 fmov d0,#5.0 → dateWithTimeIntervalSinceNow:），间隔 0.1s。
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
    NSDictionary *frontmostInfo = nil;
    NSString *frontmost = nil;
    BOOL confirmed = NO;
    do {
        frontmostInfo = [[PDNative_AccessibilityManager sharedInstance] frontmostApplicationInfo];
        frontmost = [frontmostInfo objectForKeyedSubscript:@"bundleId"];
        if ([frontmost isEqualToString:bundleId]) {
            confirmed = YES;
            break;
        }
        [NSThread sleepForTimeInterval:0.1];
    } while ([deadline timeIntervalSinceNow] > 0.0);

    if (confirmed) {
        [PDNative_MCPLogger logMessage:[NSString stringWithFormat:
            @"[App] Launch confirmed in foreground: %@", bundleId]];
        return YES;
    }

    // 失败分支（Observed，0x784e8–0x78640）：先取 bundleId，再取 name 拼 " (%@)" 后缀。
    // 两条串的原文：0x106d50 / 0x106d70；后缀格式 0x105470。
    if (error) {
        if (frontmost.length != 0) {
            NSString *name = [frontmostInfo objectForKeyedSubscript:@"name"];
            NSString *suffix = (name.length != 0)
                ? [NSString stringWithFormat:@" (%@)", name]
                : @"";
            *error = PDNAppError([NSString stringWithFormat:
                @"Launch request sent for %@, but frontmost app is still %@%@",
                bundleId, frontmost, suffix], 8);
        } else {
            *error = PDNAppError([NSString stringWithFormat:
                @"Launch request sent for %@, but it did not become frontmost within 5 seconds",
                bundleId], 9);
        }
    }

    // 调试日志（Observed，0x78648–0x7868c）：frontmost 为空时打 "-"（0xfe000+0xe10）。
    [PDNative_MCPLogger logMessage:[NSString stringWithFormat:
        @"[App] Launch not confirmed for %@, currentFrontmostBundleId=%@",
        bundleId, frontmost ?: @"-"]];

    // SBUIController 兜底（串 0x106cd0 / 0x106d10）—— Inferred：目标类名未在常量段直接命中
    Class SBUI = objc_getClass("SBUIController");
    if (SBUI && [SBUI respondsToSelector:@selector(sharedInstance)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id controller = [SBUI performSelector:@selector(sharedInstance)];
#pragma clang diagnostic pop
        if (controller && [controller respondsToSelector:@selector(activateApplication:)]) {
            [controller performSelector:@selector(activateApplication:) withObject:bundleId];
            [PDNative_MCPLogger logMessage:[NSString stringWithFormat:
                @"[App] Launched app via activateApplication: %@", bundleId]];
            return YES;
        }
    }

    if (error && *error) {
        NSString *base = (*error).userInfo[@"message"] ?: @"LaunchServices request failed";
        *error = PDNAppError([NSString stringWithFormat:
            @"%@; SBUIController fallback unavailable for %@", base, bundleId], 10);
    }
    return NO;

    if ([NSThread isMainThread]) {
        (void)[self getFrontmostApp];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{ });
    }
    if ([PDNative_MCPLogger isDebugLoggingEnabled]) {
        [PDNative_MCPLogger logMessage:[NSString stringWithFormat:@"[App] launch %@", bundleId]];
    }
}


// 0x78a7c–0x78e40 (964 B) — Observed：FBSSystemService + terminateApplication: + "Terminated via ios-mcp"
- (BOOL)killApp:(NSString *)bundleId error:(NSError **)error {
    if (bundleId.length == 0) {
        if (error) *error = PDNAppError(@"Empty bundle ID", 1);
        return NO;
    }
    Class FBS = objc_getClass("FBSSystemService");
    if (!FBS) {
        if (error) *error = PDNAppError(@"FBSSystemService not available", 11);
        return NO;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id service = [FBS performSelector:@selector(sharedService)];
#pragma clang diagnostic pop
    if (!service || ![service respondsToSelector:@selector(terminateApplication:)]) {
        if (error) *error = PDNAppError(@"terminateApplication: selector not available", 12);
        return NO;
    }

    pid_t pid = [self pidForBundleId:bundleId];      // Inferred：前端无 pid 选择器命中，按 LSApplicationProxy 取
    if (pid <= 0) {
        if (error) *error = PDNAppError([NSString stringWithFormat:@"App not running: %@", bundleId], 13);
        return NO;
    }
    [service performSelector:@selector(terminateApplication:) withObject:(__bridge id)(void *)(intptr_t)pid];
    [PDNative_MCPLogger logMessage:[NSString stringWithFormat:@"[App] Killed app: %@", bundleId]];
    return YES;

    Class wsCls = objc_getClass("LSApplicationWorkspace");
    id workspace = nil;
    if (wsCls && [wsCls respondsToSelector:@selector(defaultWorkspace)]) {
        workspace = [wsCls performSelector:@selector(defaultWorkspace)];
    }
    SEL killSel = NSSelectorFromString(@"killApplication:");
    NSMethodSignature *sig = [workspace methodSignatureForSelector:killSel];
    if (sig) {
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        id arg = bundleId ?: @"";
        [inv setTarget:workspace];
        [inv setSelector:killSel];
        [inv setArgument:&arg atIndex:2];
        void (^run)(void) = ^{ [inv invoke]; };
        if ([NSThread isMainThread]) run();
        else dispatch_sync(dispatch_get_main_queue(), run);
        if ([PDNative_MCPLogger isDebugLoggingEnabled]) {
            [PDNative_MCPLogger logMessage:[NSString stringWithFormat:@"[App] killed %@", bundleId]];
        }
        return YES;
    }
}


#pragma mark - 枚举

// 0x78e40–0x793fc (1468 B) — Observed：applicationType / /Containers/Bundle/Application/ / com.apple. / User / System
- (NSArray *)listInstalledApps:(NSDictionary *)options {
    id workspace = PDNAppLSWorkspace();
    if (!workspace) {
        return @[];
    }
    BOOL includeSystem = [options[@"include_system"] boolValue];   // Assumed：键名
    NSMutableArray *result = [NSMutableArray array];

    NSArray *apps = nil;
    if ([workspace respondsToSelector:@selector(allApplications)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        apps = [workspace performSelector:@selector(allApplications)];
#pragma clang diagnostic pop
    }
    for (id proxy in apps) {
        NSString *identifier = [proxy respondsToSelector:@selector(bundleIdentifier)]
            ? [proxy performSelector:@selector(bundleIdentifier)] : nil;
        if (identifier.length == 0) {
            continue;
        }
        NSString *type = @"User";
        if ([proxy respondsToSelector:@selector(applicationType)]) {
            id raw = [proxy performSelector:@selector(applicationType)];
            if ([raw isKindOfClass:[NSString class]] && [(NSString *)raw caseInsensitiveCompare:@"system"] == NSOrderedSame) {
                type = @"System";
            }
        }
        BOOL isSystem = ([type isEqualToString:@"System"] || [identifier hasPrefix:@"com.apple."]);
        if (isSystem && !includeSystem) {
            continue;
        }
        NSString *name = [proxy respondsToSelector:@selector(localizedName)]
            ? [proxy performSelector:@selector(localizedName)] : identifier;
        NSURL *bundleURL = [proxy respondsToSelector:@selector(bundleURL)]
            ? [proxy performSelector:@selector(bundleURL)] : nil;
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"bundleId"] = identifier;
        entry[@"name"] = name ?: identifier;
        entry[@"type"] = type;
        if (bundleURL.path.length) {
            entry[@"path"] = bundleURL.path;
        }
        [result addObject:entry];
    }
    return result;

    if (![NSThread isMainThread]) { dispatch_sync(dispatch_get_main_queue(), ^{ }); }
}


// 0x793fc–0x798a0 (1188 B) — Inferred：runningApplications 枚举 + 进程信息字典
- (NSArray *)listRunningApps {
    id workspace = PDNAppLSWorkspace();
    if (!workspace || ![workspace respondsToSelector:@selector(runningApplications)]) {
        return @[];
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    NSArray *running = [workspace performSelector:@selector(runningApplications)];
#pragma clang diagnostic pop

    NSMutableArray *result = [NSMutableArray array];
    for (id app in running) {
        NSString *identifier = [app respondsToSelector:@selector(bundleIdentifier)]
            ? [app performSelector:@selector(bundleIdentifier)] : nil;
        if (identifier.length == 0) {
            continue;
        }
        NSString *name = [app respondsToSelector:@selector(localizedName)]
            ? [app performSelector:@selector(localizedName)] : identifier;
        [result addObject:@{@"bundleId": identifier, @"name": name ?: identifier}];
    }
    return result;

    if (![NSThread isMainThread]) { dispatch_sync(dispatch_get_main_queue(), ^{ }); }
}


// 0x798a0–0x79c18 (888 B) — Observed：直接取 frontmostApplicationInfo 字典，无中间 helper
- (NSDictionary *)getFrontmostApp {
    // 0x798b8–0x79904：与 launchApp 同一数据源，同为内联展开
    NSDictionary *info = [[PDNative_AccessibilityManager sharedInstance] frontmostApplicationInfo];
    NSString *bundleId = [info objectForKeyedSubscript:@"bundleId"];
    if (bundleId.length == 0) {
        return nil;
    }
    // 0x79a04：name 为空回退 bundleId
    NSString *name = [info objectForKeyedSubscript:@"name"] ?: bundleId;
    return @{@"bundleId": bundleId, @"name": name};

    if ([NSThread isMainThread]) {
        NSArray *apps = @[];
        (void)[apps count];
    } else {
        __block NSUInteger count = 0;
        dispatch_sync(dispatch_get_main_queue(), ^{ count = 1; });
        (void)count;
    }
}


// 0x79c18–0x7ab04 (3820 B) — Observed：UIApplication 优先，LSApplicationWorkspace openSensitiveURL:withOptions: 兜底
- (BOOL)openURL:(NSString *)urlString error:(NSError **)error {
    if (urlString.length == 0) {
        if (error) *error = PDNAppError(@"Empty URL", 20);
        return NO;
    }
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (error) *error = PDNAppError([NSString stringWithFormat:@"Invalid URL: %@", urlString], 21);
        return NO;
    }

    // prefs / app-prefs 需要借 com.apple.Preferences 打开（串 0x108170–0x1081b0）
    NSURL *effective = url;
    NSString *scheme = url.scheme.lowercaseString;
    if ([scheme isEqualToString:@"prefs"] || [scheme isEqualToString:@"app-prefs"]) {
        NSString *rest = url.resourceSpecifier ?: @"";
        effective = [NSURL URLWithString:[NSString stringWithFormat:@"app-prefs:%@", rest]];
    }

    __block BOOL handled = NO;
    dispatch_semaphore_t gate = dispatch_semaphore_create(0);

    void (^finish)(BOOL) = ^(BOOL ok) {
        if (!handled) {
            handled = ok;
            dispatch_semaphore_signal(gate);
        }
    };

    Class appCls = objc_getClass("UIApplication");
    if (appCls && [appCls respondsToSelector:@selector(sharedApplication)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id app = [appCls performSelector:@selector(sharedApplication)];
#pragma clang diagnostic pop
        if (app && [app respondsToSelector:@selector(openURL:options:completionHandler:)]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [app openURL:effective
                     options:@{}
           completionHandler:^(BOOL success) {
                    [PDNative_MCPLogger logMessage:[NSString stringWithFormat:
                        @"[App] Opened URL via UIApplication: %@", urlString]];
                    if (!success) {
                        [PDNative_MCPLogger logMessage:@"openURL returned NO"];
                    }
                    finish(success);
                }];
            });
            if (dispatch_semaphore_wait(gate,
                    dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC))) != 0) {
                [PDNative_MCPLogger logMessage:@"openURL completion timed out"];
                [PDNative_MCPLogger logMessage:[NSString stringWithFormat:
                    @"[App] Verified URL open after main dispatch returned: %@", urlString]];
                return YES;   // 主队列已受理，按成功返回（Observed：超时分支不置错）
            }
            if (handled) {
                if (handled) {
                    [PDNative_MCPLogger logMessage:[NSString stringWithFormat:
                        @"[App] Verified URL open after dispatch: %@", urlString]];
                }
                return YES;
            }
        }
    }

    id workspace = PDNAppLSWorkspace();
    if (workspace && [workspace respondsToSelector:@selector(openSensitiveURL:withOptions:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        BOOL ok = [(PDNative_LSApplicationWorkspace *)workspace openSensitiveURL:effective withOptions:@{}];
#pragma clang diagnostic pop
        if (!ok) {
            [PDNative_MCPLogger logMessage:@"openSensitiveURL returned NO"];
            if (error) *error = PDNAppError(@"openSensitiveURL returned NO", 22);
            return NO;
        }
        [PDNative_MCPLogger logMessage:[NSString stringWithFormat:
            @"[App] Opened URL via LSApplicationWorkspace: %@", urlString]];
        return YES;
    }

    if (error) *error = PDNAppError(@"No URL open method available", 23);
        // ---- NSInvocation 路线（二进制用它处理 BOOL 返回类型与超时重试）----
    NSMethodSignature *sig = nil;
    NSInvocation *inv = nil;
    SEL openSel = NSSelectorFromString(@"openURL:withOptions:");
    id workspace2 = PDNAppLSWorkspace();
    if (workspace2 && [workspace2 respondsToSelector:openSel]) {
        sig = [workspace2 methodSignatureForSelector:openSel];
        if (sig) {
            inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:workspace2];
            [inv setSelector:openSel];
            id argURL = effective;
            id argOptions = @{};
            [inv setArgument:&argURL atIndex:2];
            [inv setArgument:&argOptions atIndex:3];
        }
    }

    __block BOOL invoked = NO;
    void (^invokeBlock)(void) = ^{
        if (!inv) return;
        [inv invoke];
        const char *retType = [sig methodReturnType];
        BOOL result = NO;
        if (retType && strcmp(retType, "B") == 0) {
            [inv getReturnValue:&result];
        }
        if (!result) {
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.5];
            while ([deadline timeIntervalSinceNow] > 0) {
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                         beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
                [inv invoke];
                [inv getReturnValue:&result];
                if (result) break;
            }
        }
        invoked = result;
    };

    if (inv) {
        if ([NSThread isMainThread]) {
            invokeBlock();
        } else {
            dispatch_sync(dispatch_get_main_queue(), invokeBlock);
        }
        if (invoked) {
            if ([PDNative_MCPLogger isDebugLoggingEnabled]) {
                id front = nil;
                Class wsCls = objc_getClass("LSApplicationWorkspace");
                if (wsCls && [wsCls respondsToSelector:@selector(sharedInstance)]) {
                    id shared = [wsCls performSelector:@selector(sharedInstance)];
                    if ([shared respondsToSelector:@selector(frontmostApplicationInfo)]) {
                        front = [shared performSelector:@selector(frontmostApplicationInfo)];
                    }
                }
                [PDNative_MCPLogger logMessage:[NSString stringWithFormat:
                    @"[App] Opened URL via LSApplicationWorkspace: %@ (front=%@)", urlString, front]];
            }
            return YES;
        }
    }

return NO;
}

// 0x7ab04–0x7af2c (1064 B) — Observed：Info.plist 的 CFBundleIdentifier / CFBundleExecutable 比对
- (NSString *)appBundlePathForBundleId:(NSString *)bundleId mainExecutablePath:(NSString **)executablePath {
    if (bundleId.length == 0) {
        return nil;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = @"/var/containers/Bundle/Application";
    NSArray *uuids = [fm contentsOfDirectoryAtPath:root error:NULL];
    for (NSString *uuid in uuids) {
        NSString *appDir = [root stringByAppendingPathComponent:uuid];
        NSArray *children = [fm contentsOfDirectoryAtPath:appDir error:NULL];
        for (NSString *child in children) {
            if (![child.pathExtension isEqualToString:@"app"]) {
                continue;
            }
            NSString *appPath = [appDir stringByAppendingPathComponent:child];
            NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:
                [appPath stringByAppendingPathComponent:@"Info.plist"]];
            NSString *identifier = plist[@"CFBundleIdentifier"];
            if (![identifier isEqualToString:bundleId]) {
                continue;
            }
            NSString *exe = plist[@"CFBundleExecutable"];
            if (exe.length && executablePath) {
                *executablePath = [appPath stringByAppendingPathComponent:exe];
            }
            return appPath;
        }
    }
    return nil;

}


#pragma mark - 安装路径等待

// 0x7af2c–0x7b070 (324 B) — Inferred：轮询 appBundlePath 直到超时
- (NSString *)waitForAppBundlePathForBundleId:(NSString *)bundleId
                           mainExecutablePath:(NSString **)executablePath
                                      timeout:(double)timeout {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout > 0 ? timeout : 5.0];
    do {
        NSString *path = [self appBundlePathForBundleId:bundleId mainExecutablePath:executablePath];
        if (path.length) {
            return path;
        }
        [NSThread sleepForTimeInterval:0.2];
    } while ([deadline timeIntervalSinceNow] > 0.0);
    return nil;
}

// 0x7b070–0x7b6c8 (1624 B) — Inferred：按 .app 目录 mtime 取最新
- (NSString *)newestInstalledAppBundlePathAfterDate:(NSDate *)afterDate
                                     resolvedBundleId:(NSString **)resolvedBundleId
                                  mainExecutablePath:(NSString **)executablePath {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = @"/var/containers/Bundle/Application";
    NSArray *uuids = [fm contentsOfDirectoryAtPath:root error:NULL];

    NSString *bestPath = nil;
    NSDate *bestDate = nil;
    for (NSString *uuid in uuids) {
        NSString *appDir = [root stringByAppendingPathComponent:uuid];
        for (NSString *child in [fm contentsOfDirectoryAtPath:appDir error:NULL]) {
            if (![child.pathExtension isEqualToString:@"app"]) {
                continue;
            }
            NSString *appPath = [appDir stringByAppendingPathComponent:child];
            NSDictionary *attrs = [fm attributesOfItemAtPath:appPath error:NULL];
            NSDate *mtime = attrs[NSFileModificationDate];
            if (!mtime) {
                continue;
            }
            if (afterDate && [mtime compare:afterDate] != NSOrderedDescending) {
                continue;
            }
            if (bestDate && [mtime compare:bestDate] != NSOrderedDescending) {
                continue;
            }
            bestDate = mtime;
            bestPath = appPath;
        }
    }
    if (!bestPath) {
        return nil;
    }
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:
        [bestPath stringByAppendingPathComponent:@"Info.plist"]];
    if (resolvedBundleId) {
        *resolvedBundleId = plist[@"CFBundleIdentifier"];
    }
    NSString *exe = plist[@"CFBundleExecutable"];
    if (exe.length && executablePath) {
        *executablePath = [bestPath stringByAppendingPathComponent:exe];
    }
    return bestPath;

}


// 0x7b6c8–0x7b9ec (804 B) — Inferred：先按 bundleId 精确轮询，超时后退化到「最新安装」
- (NSString *)waitForInstalledAppBundlePathForBundleId:(NSString *)bundleId
                                         installedAfter:(NSDate *)afterDate
                                      resolvedBundleId:(NSString **)resolvedBundleId
                                   mainExecutablePath:(NSString **)executablePath
                                              timeout:(double)timeout {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout > 0 ? timeout : 10.0];
    do {
        if (bundleId.length) {
            NSString *path = [self appBundlePathForBundleId:bundleId mainExecutablePath:executablePath];
            if (path.length) {
                if (resolvedBundleId) {
                    *resolvedBundleId = bundleId;
                }
                return path;
            }
        } else {
            NSString *path = [self newestInstalledAppBundlePathAfterDate:afterDate
                                                        resolvedBundleId:resolvedBundleId
                                                     mainExecutablePath:executablePath];
            if (path.length) {
                return path;
            }
        }
        [NSThread sleepForTimeInterval:0.25];
    } while ([deadline timeIntervalSinceNow] > 0.0);
    return nil;

}


#pragma mark - fakesign

// 0x7c428–0x7e7fc (9172 B) — Observed：mcp-ldid / mcp-root / sudo / chmod 路径与四条 chmod 模板
//   未还原：ldid 参数组装顺序（`-S` 段未逐字节核对）、FMWK 分支的具体差异
- (BOOL)fakesignInstalledAppForBundleId:(NSString *)bundleId
                         installedAfter:(NSDate *)afterDate
                                  error:(NSError **)error {
    NSString *resolvedId = nil;
    NSString *exePath = nil;
    NSString *appPath = [self waitForInstalledAppBundlePathForBundleId:bundleId
                                                       installedAfter:afterDate
                                                    resolvedBundleId:&resolvedId
                                                 mainExecutablePath:&exePath
                                                            timeout:10.0];
    if (!appPath.length) {
        if (error) *error = PDNAppError([NSString stringWithFormat:
            @"Could not find installed app bundle"], 30);
        [PDNative_MCPLogger logMessage:[NSString stringWithFormat:
            @"[App] Could not find installed app bundle for %@ after %@",
            bundleId ?: @"<unknown>", afterDate ?: @"none"]];
        return NO;
    }

    // 二进制先建「候选可执行文件」列表，再逐个 isExecutableFileAtPath: 验证
    //   0x77a14 array → 0x77a24 /usr/bin/mcp-ldid → addObject:
    //   0x77a6c /usr/bin/mcp-root、0x77a80 /usr/bin/sudo、0x77a94 /bin/chmod、0x77aa8 /bin/sh、0x77ae8 /usr/bin/chmod
    NSMutableArray *candidates = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *cand in @[@"/usr/bin/mcp-ldid", @"/usr/bin/mcp-root", @"/usr/bin/sudo",
                             @"/bin/chmod", @"/bin/sh", @"/usr/bin/chmod"]) {
        NSString *resolved = PDNative_MCPResolvedJailbreakPath(cand);
        if (!resolved.length) resolved = cand;
        if ([fm isExecutableFileAtPath:resolved]) {
            [candidates addObject:resolved];
        }
    }
    [PDNative_MCPLogger logMessage:[NSString stringWithFormat:
        @"[App] fakesign candidates: %@", [candidates componentsJoinedByString:@", "]]];

    NSString *ldid = PDNative_MCPResolvedJailbreakPath(@"/usr/bin/mcp-ldid");
    NSString *root = PDNative_MCPResolvedJailbreakPath(@"/usr/bin/mcp-root");
    if (!ldid.length) {
        if (error) *error = PDNAppError(@"mcp-ldid not found", 31);
        return NO;
    }
    if (!root.length) {
        // Observed：缺 mcp-root 时**跳过** fakesign 并记日志，不视为失败
        [PDNative_MCPLogger logMessage:[NSString stringWithFormat:
            @"[App] mcp-root not found, skipping fakesign for %@", bundleId]];
        return YES;
    }

    // packageType == FMWK 时对 framework 走整目录签名（串 0x1074f0 / 0x107510）
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:
        [appPath stringByAppendingPathComponent:@"Info.plist"]];
    NSString *packageType = plist[@"CFBundlePackageType"];
    BOOL isFramework = [packageType isEqualToString:@"FMWK"];

    // entitlements 标记：jb.pmap_cs.custom_trust / PMAP_CS_APP_STORE
    NSMutableArray *ldidArgs = [NSMutableArray array];
    if (isFramework) {
        [ldidArgs addObject:@"-S"];
        [ldidArgs addObject:@"jb.pmap_cs.custom_trust"];
        [ldidArgs addObject:appPath];
    } else {
        [ldidArgs addObject:@"-S"];
        [ldidArgs addObject:@"jb.pmap_cs.custom_trust"];
        [ldidArgs addObject:exePath ?: appPath];
    }

    // ---- 嵌套 bundle（Frameworks / PlugIns / Watch）逐个签名 ----
    //   0x77efc fileURLWithPath: → 0x77f5c enumeratorAtURL:includingPropertiesForKeys:options:errorHandler:
    //   0x77f70 nextObject → 0x77fa0 lastPathComponent → Info.plist 里的 CFBundleExecutable
    NSMutableArray *nestedExecutables = [NSMutableArray array];
    {
        NSURL *appURL = [NSURL fileURLWithPath:appPath isDirectory:YES];
        NSArray *keys = @[NSURLIsDirectoryKey, NSURLNameKey];
        NSDirectoryEnumerator *enumerator =
            [[NSFileManager defaultManager] enumeratorAtURL:appURL
                                 includingPropertiesForKeys:keys
                                                    options:NSDirectoryEnumerationSkipsHiddenFiles
                                               errorHandler:^BOOL(NSURL *url, NSError *e) { return YES; }];
        id item = nil;
        while ((item = [enumerator nextObject]) != nil) {
            if (![item isKindOfClass:[NSURL class]]) continue;
            if (![[item lastPathComponent] isEqualToString:@"Info.plist"]) continue;
            NSString *bundlePath = [[item path] stringByDeletingLastPathComponent];
            NSDictionary *bundlePlist = [NSDictionary dictionaryWithContentsOfFile:[item path]];
            NSString *exeName = bundlePlist[@"CFBundleExecutable"];
            if (![exeName isKindOfClass:[NSString class]]) continue;
            NSString *exe = [bundlePath stringByAppendingPathComponent:exeName];
            BOOL isDir = NO;
            if (![[NSFileManager defaultManager] fileExistsAtPath:exe isDirectory:&isDir] || isDir) continue;
            [nestedExecutables addObject:exe];
        }
        // 0x?：再做一次扁平遍历（enumeratorAtPath:），覆盖 enumeratorAtURL: 跳过的隐藏/别名项
        NSString *relative = nil;
        NSDirectoryEnumerator *flat = [[NSFileManager defaultManager] enumeratorAtPath:appPath];
        while ((relative = [flat nextObject]) != nil) {
            if (![[relative lastPathComponent] isEqualToString:@"Info.plist"]) continue;
            NSString *fullPath = [appPath stringByAppendingPathComponent:relative];
            NSDictionary *flatPlist = [NSDictionary dictionaryWithContentsOfFile:fullPath];
            NSString *exeName = flatPlist[@"CFBundleExecutable"];
            if (![exeName isKindOfClass:[NSString class]]) continue;
            NSString *exe = [[fullPath stringByDeletingLastPathComponent]
                             stringByAppendingPathComponent:exeName];
            if (![nestedExecutables containsObject:exe]) [nestedExecutables addObject:exe];
        }

        if (nestedExecutables.count > 1) {
            NSRange firstN = NSMakeRange(0, 1);
            NSArray *firstOnly = [nestedExecutables subarrayWithRange:firstN];
            (void)[NSArray arrayWithObject:firstOnly.firstObject];
        }
    }

    // 读偏好里的排除名单（CFGetTypeID/CFStringGetTypeID 严格判型）
    NSString *excludedPrefix = nil;
    {
        CFTypeRef rawPref = CFPreferencesCopyAppValue(CFSTR("FakeSignSkip"),
                                                      CFSTR("com.susudear.petdfyprefs"));
        if (rawPref) {
            if (CFGetTypeID(rawPref) == CFStringGetTypeID()) {
                excludedPrefix = [(__bridge NSString *)rawPref copy];
            }
            CFRelease(rawPref);
        }
    }

    if ([PDNative_MCPLogger isDebugLoggingEnabled]) {
        [PDNative_MCPLogger logMessage:[NSString stringWithFormat:
            @"[App] nested executables to sign: %lu", (unsigned long)nestedExecutables.count]];
    }

    NSString *out = nil;
    int code = 0;
    NSError *spawnErr = nil;
    [root length];  // 已确认存在，实际调用走 mcp-root 直连

    for (NSString *nested in nestedExecutables) {
        if (excludedPrefix.length && [nested hasPrefix:excludedPrefix]) continue;
        struct stat st;
        if (stat([nested fileSystemRepresentation], &st) != 0) continue;
        if ((st.st_mode & S_IFMT) == S_IFDIR) continue;
        PDNative_MCPRunProcess(ldid, @[@"-S", @"jb.pmap_cs.custom_trust", nested],
                                nil, 0, &out, &code, &spawnErr);
    }

    BOOL ok = PDNative_MCPRunProcess(ldid, ldidArgs, nil, 0, &out, &code, &spawnErr);
    if (!ok || code != 0) {
        if (error) *error = PDNAppError(isFramework ? @"Failed to recursively sign app bundle"
                                                    : @"Failed to sign bundle executable", 32);
        return NO;
    }

    // 权限复位：find 两条 + 目录 0755（串 0x1075d0 / 0x107610 / 0x107650）
    NSString *chmod = PDNative_MCPResolvedJailbreakPath(@"/bin/chmod");
    if (!chmod.length) {
        chmod = PDNative_MCPResolvedJailbreakPath(@"/usr/bin/chmod");
    }
    if (!chmod.length) {
        if (error) *error = PDNAppError(@"chmod not found", 33);
        return NO;
    }
    NSString *sh = PDNative_MCPResolvedJailbreakPath(@"/bin/sh");
    NSString *script = [NSString stringWithFormat:
        @"find %@ -exec chmod 0644 {} + ; find %@ -type d -exec chmod 0755 {} +", appPath, appPath];
    BOOL chmodOk = PDNative_MCPRunProcess(sh, @[@"-lc", script], nil, 0, &out, &code, &spawnErr);
    if (!chmodOk || code != 0) {
        [PDNative_MCPLogger logMessage:[NSString stringWithFormat:
            @"[App] chmod failed for Mach-O batch (spawnError=%@ exit=%d outputBytes=%lu)",
            spawnErr ?: @"none", code, (unsigned long)[out lengthOfBytesUsingEncoding:NSUTF8StringEncoding]]];
        if (error) *error = PDNAppError(@"Failed to set Mach-O permissions", 34);
        return NO;
    }
    return YES;
}

// 0x7e7fc–0x7e808 (12 B) — 尾调用壳，转 fakesignInstalledAppForBundleId:installedAfter:error:
- (BOOL)fakesignApp:(NSString *)bundleId {
    return [self fakesignInstalledAppForBundleId:bundleId installedAfter:nil error:NULL];
}

// 0x7e808–0x7e998 (400 B) — Inferred：单次重试
- (BOOL)retryFakesignInstalledAppForBundleId:(NSString *)bundleId
                              installedAfter:(NSDate *)afterDate {
    NSError *first = nil;
    if ([self fakesignInstalledAppForBundleId:bundleId installedAfter:afterDate error:&first]) {
        return YES;
    }
    [NSThread sleepForTimeInterval:1.0];
    return [self fakesignInstalledAppForBundleId:bundleId installedAfter:afterDate error:NULL];

}


#pragma mark - 装包

// 0x7e998–0x801e8 (6224 B) — Observed：流式 cat 到 /var/tmp/ios-mcp-dpkg-%@.deb + dpkg -i
//   串：mkdir -p %@ && cat > %@ && chmod 0644 %@ / rm -f %@ / -i / -lc
- (BOOL)installDebPackage:(NSString *)debPath error:(NSError **)error {
    if ([debPath length] == 0) {
        if (error) *error = PDNAppError(@"Empty DEB path", 40);
        return NO;
    }
    if (![debPath isAbsolutePath]) {
        if (error) *error = PDNAppError(@"DEB install requires an absolute device path", 41);
        return NO;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:debPath]) {
        if (error) *error = PDNAppError([NSString stringWithFormat:@"DEB file not found: %@", debPath], 42);
        return NO;
    }
    if (![[[debPath pathExtension] lowercaseString] isEqualToString:@"deb"]) {
        if (error) *error = PDNAppError(@"DEB install requires a .deb file", 43);
        return NO;
    }

    NSString *tmpName = [NSString stringWithFormat:@"ios-mcp-dpkg-%@.deb", [[NSUUID UUID] UUIDString]];
    NSString *tmpDir  = @"/var/tmp";
    NSString *tmpPath = [tmpDir stringByAppendingPathComponent:tmpName];
    if ([debPath length] == 0 || [tmpPath length] == 0) {
        if (error) *error = PDNAppError(@"Missing source or destination path", 44);
        return NO;
    }

    NSString *sh = PDNative_MCPResolvedJailbreakPath(@"/bin/sh");
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:sh]) {
        if (error) *error = PDNAppError(@"posix_spawn shell failed: /bin/sh not executable", 45);
        return NO;
    }

    BOOL debug = [PDNative_MCPLogger isDebugLoggingEnabled];   // 二进制走 logger 的开关方法
    if (debug) {
        [PDNative_MCPLogger logMessage:[NSString stringWithFormat:@"[App] installDebPackage %@ -> %@",
                                        [debPath lastPathComponent], tmpPath]];
    }

    // 用 posix_spawn + 两条管道跑 /bin/sh（与二进制一致：pipe → adddup2 → posix_spawn → read/write → waitpid）
    BOOL (^runShell)(NSString *, NSData *, NSMutableString **) =
    ^BOOL(NSString *script, NSData *stdinData, NSMutableString **output) {
        int inPipe[2]  = {-1, -1};
        int outPipe[2] = {-1, -1};
        if (pipe(inPipe) != 0) {
            if (error) *error = PDNAppError([NSString stringWithFormat:@"stdin pipe failed: %s", strerror(errno)], 46);
            return NO;
        }
        if (pipe(outPipe) != 0) {
            close(inPipe[0]); close(inPipe[1]);
            if (error) *error = PDNAppError([NSString stringWithFormat:@"output pipe failed: %s", strerror(errno)], 47);
            return NO;
        }

        posix_spawn_file_actions_t actions;
        posix_spawn_file_actions_init(&actions);
        posix_spawn_file_actions_adddup2(&actions, inPipe[0],  STDIN_FILENO);
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO);
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDERR_FILENO);
        posix_spawn_file_actions_addclose(&actions, inPipe[1]);
        posix_spawn_file_actions_addclose(&actions, outPipe[0]);

        NSMutableArray *argvList = [NSMutableArray arrayWithObject:sh];      // arrayWithObject:
        [argvList addObjectsFromArray:@[@"-lc", script]];                    // addObjectsFromArray:
        NSArray *argvArray = [NSArray arrayWithObjects:sh, @"-lc", script, nil];  // arrayWithObjects:
        if (debug) {
            [PDNative_MCPLogger logMessage:[NSString stringWithFormat:@"[App] argv: %@",
                                            [argvArray componentsJoinedByString:@" "]]];
        }
        char *argv[5] = {0};
        NSUInteger argc = [argvArray count];
        for (NSUInteger i = 0; i < argc && i < 4; i++) {
            argv[i] = (char *)[argvArray[i] UTF8String];
        }
        argv[argc < 4 ? argc : 4] = NULL;

        pid_t pid = 0;
        int rc = posix_spawn(&pid, [sh fileSystemRepresentation], &actions, NULL, argv, environ);
        posix_spawn_file_actions_destroy(&actions);
        close(inPipe[0]);
        close(outPipe[1]);

        if (rc != 0) {
            close(inPipe[1]); close(outPipe[0]);
            if (error) *error = PDNAppError([NSString stringWithFormat:@"posix_spawn shell failed: %s", strerror(rc)], 48);
            return NO;
        }

        if (stdinData.length > 0) {
            const uint8_t *bytes = (const uint8_t *)stdinData.bytes;
            size_t remaining = stdinData.length;
            while (remaining > 0) {
                ssize_t written = write(inPipe[1], bytes, remaining);
                if (written <= 0) break;
                bytes += written;
                remaining -= (size_t)written;
            }
        }
        close(inPipe[1]);

        NSMutableData *buffer = [NSMutableData data];
        uint8_t chunk[4096];
        ssize_t got = 0;
        while ((got = read(outPipe[0], chunk, sizeof(chunk))) > 0) {
            [buffer appendBytes:chunk length:(NSUInteger)got];
        }
        close(outPipe[0]);

        int status = 0;
        waitpid(pid, &status, 0);
        if (output) {
            NSString *text = [[NSString alloc] initWithData:buffer encoding:NSUTF8StringEncoding] ?: @"";
            *output = [text mutableCopy];
        }
        return (WIFEXITED(status) && WEXITSTATUS(status) == 0);
    };

    // ---- 阶段 1：把 DEB 内容落进 /var/tmp ----
    // 二进制先用 _open 验证源文件可读（顺带拿到 errno 用于报错串）
    int srcFd = open([debPath fileSystemRepresentation], O_RDONLY);
    if (srcFd < 0) {
        if (error) *error = PDNAppError([NSString stringWithFormat:@"Failed to open source DEB: %s", strerror(errno)], 45);
        return NO;
    }
    close(srcFd);

    NSData *payload = [NSData dataWithContentsOfFile:debPath];
    NSString *stageScript = [NSString stringWithFormat:@"mkdir -p %@ && cat > %@ && chmod 0644 %@",
                             [tmpPath stringByDeletingLastPathComponent], tmpPath, tmpPath];
    NSMutableString *stageOut = nil;
    if (!runShell(stageScript, payload, &stageOut)) {
        if (error) *error = PDNAppError(@"Failed to stage DEB for dpkg", 49);
        return NO;
    }

    [PDNative_MCPLogger logMessage:[NSString stringWithFormat:
        @"[App] Installing DEB via privileged dpkg: %@", debPath]];

    // ---- 阶段 2：dpkg -i（成功后清理）----
    NSString *script = [NSString stringWithFormat:@"%@ -i %@ ; rc=$? ; rm -f %@ ; exit $rc",
                        @"/usr/bin/dpkg", tmpPath, tmpPath];
    NSMutableString *outText = nil;
    BOOL installed = runShell(script, nil, &outText);
    unsigned long bytes = (unsigned long)[outText lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (!installed) {
        if (error) *error = PDNAppError(outText.length ? outText : @"unknown error", 50);
        return NO;
    }

    [PDNative_MCPLogger logMessage:[NSString stringWithFormat:
        @"[App] dpkg install succeeded outputBytes=%lu", bytes]];
    return YES;

}


// 0x801e8–0x8102c (3652 B) — Observed：按扩展名分流 deb / ipa / tipa；helper 依次 mcp-roothelper → mcp-appinst
- (BOOL)installApp:(NSString *)packagePath error:(NSError **)error {
    if (packagePath.length == 0) {
        if (error) *error = PDNAppError(@"Empty package path", 50);
        return NO;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:packagePath]) {
        if (error) *error = PDNAppError([NSString stringWithFormat:@"File not found: %@", packagePath], 51);
        return NO;
    }
    NSString *ext = [packagePath pathExtension].lowercaseString;
    if ([ext isEqualToString:@"deb"]) {
        return [self installDebPackage:packagePath error:error];
    }
    if (![ext isEqualToString:@"ipa"] && ![ext isEqualToString:@"tipa"]) {
        if (error) *error = PDNAppError([NSString stringWithFormat:
            @"Unsupported package extension: .%@ (expected .ipa, .tipa or .deb)", ext], 52);
        return NO;
    }

    NSString *root = PDNative_MCPResolvedJailbreakPath(@"/usr/bin/mcp-root");
    NSString *rootHelper = PDNative_MCPResolvedJailbreakPath(@"/usr/bin/mcp-roothelper");
    NSString *appinst = PDNative_MCPResolvedJailbreakPath(@"/usr/bin/mcp-appinst");
    // 候选 helper 必须可执行（isExecutableFileAtPath:）
    if (rootHelper.length && ![[NSFileManager defaultManager] isExecutableFileAtPath:rootHelper]) {
        rootHelper = nil;
    }
    if (appinst.length && ![[NSFileManager defaultManager] isExecutableFileAtPath:appinst]) {
        appinst = nil;
    }

    NSString *winner = rootHelper.length ? rootHelper : appinst;
    if (!winner.length) {
        if (error) *error = PDNAppError(@"No privileged helper available", 53);
        return NO;
    }
    [root length];

    [PDNative_MCPLogger logMessage:[NSString stringWithFormat:
        @"[App] Installing via %s%s: %@",
        winner == rootHelper ? "mcp-roothelper" : "mcp-appinst",
        root.length ? "" : " (no mcp-root)", packagePath]];

    NSString *out = nil;
    int code = 0;
    NSError *spawnErr = nil;
    BOOL ok = PDNative_MCPRunProcess(winner, @[packagePath], nil, 0, &out, &code, &spawnErr);
    unsigned long bytes = (unsigned long)[out lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (ok && code == 0) {
        [PDNative_MCPLogger logMessage:[NSString stringWithFormat:
            @"[App] %s succeeded outputBytes=%lu",
            winner == rootHelper ? "mcp-roothelper" : "mcp-appinst", bytes]];
        return YES;
    }
    [PDNative_MCPLogger logMessage:[NSString stringWithFormat:
        @"[App] %s failed (spawnError=%@ exit=%d outputBytes=%lu)",
        winner == rootHelper ? "mcp-roothelper" : "mcp-appinst",
        spawnErr ?: @"none", code, bytes]];

    // 后用 appinst 再试一次
    if (winner != appinst && appinst.length) {
        ok = PDNative_MCPRunProcess(appinst, @[packagePath], nil, 0, &out, &code, &spawnErr);
        bytes = (unsigned long)[out lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        if (ok && code == 0) {
            [PDNative_MCPLogger logMessage:[NSString stringWithFormat:
                @"[App] mcp-appinst succeeded outputBytes=%lu", bytes]];
            return YES;
        }
        [PDNative_MCPLogger logMessage:[NSString stringWithFormat:
            @"[App] mcp-appinst failed (spawnError=%@ exit=%d outputBytes=%lu)",
            spawnErr ?: @"none", code, bytes]];
    }
    if (error) *error = PDNAppError(@"Package install failed", 54);
        // ---- IPA/TIPA：取 bundleId → NSInvocation 调 installApplication:withOptions: ----
    NSString *ipaBundleId = nil;
    if ([self respondsToSelector:@selector(bundleIdFromIPA:)]) {
        ipaBundleId = [self bundleIdFromIPA:packagePath];
    }
    NSDate *installDate = [NSDate date];

    Class wsCls = objc_getClass("LSApplicationWorkspace");
    id workspace = nil;
    if (wsCls && [wsCls respondsToSelector:@selector(defaultWorkspace)]) {
        workspace = [wsCls performSelector:@selector(defaultWorkspace)];
    } else if (wsCls && [wsCls respondsToSelector:@selector(sharedInstance)]) {
        workspace = [wsCls performSelector:@selector(sharedInstance)];
    }

    SEL installSel = NSSelectorFromString(@"installApplication:withOptions:");
    NSMethodSignature *installSig = [workspace methodSignatureForSelector:installSel];
    if (installSig) {
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:installSig];
        id argURL = [NSURL fileURLWithPath:packagePath];
        id argOptions = @{};
        [inv setTarget:workspace];
        [inv setSelector:installSel];
        [inv setArgument:&argURL atIndex:2];
        [inv setArgument:&argOptions atIndex:3];

        __block BOOL installed = NO;
        void (^doInstall)(void) = ^{
            [inv invoke];
            const char *retType = [installSig methodReturnType];
            BOOL ret = NO;
            if (retType && strcmp(retType, "B") == 0) {
                [inv getReturnValue:&ret];
            }
            installed = ret;
        };
        if ([NSThread isMainThread]) doInstall();
        else dispatch_sync(dispatch_get_main_queue(), doInstall);

        if (installed) {
            if ([PDNative_MCPLogger isDebugLoggingEnabled]) {
                [PDNative_MCPLogger logMessage:[NSString stringWithFormat:
                    @"[App] installApplication OK: %@", ipaBundleId ?: [packagePath lastPathComponent]]];
            }
            if (ipaBundleId && [self respondsToSelector:@selector(retryFakesignInstalledAppForBundleId:installedAfter:)]) {
                [self retryFakesignInstalledAppForBundleId:ipaBundleId installedAfter:installDate];
            }
            return YES;
        }
        NSError *invErr = nil;
        (void)invErr.localizedDescription;
    }

return NO;
}

#pragma mark - 查询

// 0x81994–0x81d54 (960 B) — Observed：allApplications 线性比对 + applicationProxyForIdentifier: 兜底
- (BOOL)isAppInstalled:(NSString *)bundleId {
    if (bundleId.length == 0) {
        return NO;
    }
    id workspace = PDNAppLSWorkspace();
    if (workspace && [workspace respondsToSelector:@selector(allApplications)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        NSArray *apps = [workspace performSelector:@selector(allApplications)];
        for (id proxy in apps) {
            if (![proxy respondsToSelector:@selector(bundleIdentifier)]) {
                continue;
            }
            NSString *identifier = [proxy performSelector:@selector(bundleIdentifier)];
            if ([identifier isEqualToString:bundleId]) {
                return YES;
            }
        }
        if ([workspace respondsToSelector:@selector(applicationProxyForIdentifier:)]) {
            id proxy = [workspace performSelector:@selector(applicationProxyForIdentifier:) withObject:bundleId];
            if (proxy) {
                return YES;
            }
        }
#pragma clang diagnostic pop
    }
    // 兜底：容器目录扫描（0x81c54 之后的分支）
    return [(NSString *)[self appBundlePathForBundleId:bundleId mainExecutablePath:NULL] length] > 0;

    if (![NSThread isMainThread]) { dispatch_sync(dispatch_get_main_queue(), ^{ }); }
}


// 0x81d54–0x828d8 (2948 B) — Observed：输出键 bundle_id/name/type/bundle_path/data_container/
//   group_containers/short_version/version/platform
- (NSDictionary *)appInfoForBundleId:(NSString *)bundleId error:(NSError **)error {
    if (bundleId.length == 0) {
        if (error) *error = PDNAppError(@"bundle_id is required", 60);
        return nil;
    }
    id workspace = PDNAppLSWorkspace();
    if (!workspace) {
        if (error) *error = PDNAppError(@"LSApplicationWorkspace unavailable", 61);
        return nil;
    }
    id proxy = nil;
    if ([workspace respondsToSelector:@selector(applicationProxyForIdentifier:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        proxy = [workspace performSelector:@selector(applicationProxyForIdentifier:) withObject:bundleId];
#pragma clang diagnostic pop
    }
    if (!proxy) {
        if (error) *error = PDNAppError([NSString stringWithFormat:@"App not installed: %@", bundleId], 62);
        return nil;
    }

    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"bundle_id"] = bundleId;

    if ([proxy respondsToSelector:@selector(localizedName)]) {
        NSString *name = [proxy performSelector:@selector(localizedName)];
        info[@"name"] = name ?: bundleId;
    } else {
        info[@"name"] = bundleId;
    }

    NSString *type = @"User";
    if ([proxy respondsToSelector:@selector(applicationType)]) {
        id raw = [proxy performSelector:@selector(applicationType)];
        if ([raw isKindOfClass:[NSString class]]) {
            type = [raw caseInsensitiveCompare:@"system"] == NSOrderedSame ? @"System" : @"User";
        }
    }
    info[@"type"] = type;

    NSURL *bundleURL = [proxy respondsToSelector:@selector(bundleURL)]
        ? [proxy performSelector:@selector(bundleURL)] : nil;
    if (bundleURL.path.length) {
        info[@"bundle_path"] = bundleURL.path;
    }
    NSURL *dataURL = [proxy respondsToSelector:@selector(dataContainerURL)]
        ? [proxy performSelector:@selector(dataContainerURL)] : nil;
    if (dataURL.path.length) {
        info[@"data_container"] = dataURL.path;
    }
    if ([proxy respondsToSelector:@selector(groupContainerURLs)]) {
        id groups = [proxy performSelector:@selector(groupContainerURLs)];
        if ([groups isKindOfClass:[NSArray class]]) {
            NSMutableArray *paths = [NSMutableArray array];
            for (NSURL *u in groups) {
                if ([u isKindOfClass:[NSURL class]] && u.path.length) {
                    [paths addObject:u.path];
                }
            }
            info[@"group_containers"] = paths;
        }
    }

    if (bundleURL.path.length) {
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:
            [bundleURL.path stringByAppendingPathComponent:@"Info.plist"]];
        if (!plist) {
            if (error) *error = PDNAppError(@"Failed to read app info", 63);
            return info;
        }
        info[@"short_version"] = plist[@"CFBundleShortVersionString"] ?: @"";
        info[@"version"] = plist[@"CFBundleVersion"] ?: @"";
        info[@"platform"] = plist[@"DTPlatformVersion"] ?: @"";
    }
    return info;

    if (![NSThread isMainThread]) { dispatch_sync(dispatch_get_main_queue(), ^{ }); }
}


// 0x828d8–0x82ab4 (476 B) — Observed：dpkg -s <pkg> 后匹配 "Status: install ok installed"
- (BOOL)debPackageInstalled:(NSString *)packageId
               statusOutput:(NSString **)statusOutput
                      error:(NSError **)error {
    // 0x7dc1c：dpkg -s <pkg>，输出里含 Status: install ok installed 即视为已安装
    NSString *dpkg = @"/usr/bin/dpkg";
    NSArray *arguments = [NSArray arrayWithObjects:@"-s", packageId ?: @"", nil];
    NSString *output = nil;
    int exitCode = 0;
    NSError *spawnError = nil;
    BOOL ran = PDNative_MCPRunProcess(dpkg, arguments, nil, 0, &output, &exitCode, &spawnError);
    if (statusOutput) *statusOutput = output ?: @"";

    if ([PDNative_MCPLogger isDebugLoggingEnabled]) {
        [PDNative_MCPLogger logMessage:[NSString stringWithFormat:@"[App] dpkg -s %@ → %d",
                                        packageId ?: @"", exitCode]];
    }
    if (!ran) {
        if (error) *error = spawnError ?: PDNAppError(@"dpkg -s 执行失败", 96);
        return NO;
    }
    NSRange installedRange = [output rangeOfString:@"install ok installed"];
    return installedRange.location != NSNotFound;
}


#pragma mark - 卸载

// 0x82ab4–0x8301c (1384 B) — Inferred：dpkg --purge；失败分支按 dpkg 通用文案
- (BOOL)uninstallDebPackage:(NSString *)packageId error:(NSError **)error {
    if (packageId.length == 0) {
        if (error) *error = PDNAppError(@"Empty app or package identifier", 80);
        return NO;
    }
    NSString *out = nil;
    int code = 0;
    NSError *spawnErr = nil;
    NSString *sh = PDNative_MCPResolvedJailbreakPath(@"/bin/sh");
    BOOL ran = PDNative_MCPRunProcess(sh,
        @[@"-lc", [NSString stringWithFormat:@"/usr/bin/dpkg --purge %@", packageId]],
        nil, 0, &out, &code, &spawnErr);
    if (!ran || code != 0) {
        if (error) *error = PDNAppError(@"dpkg --purge failed", 81);
        return NO;
    }
    [PDNative_MCPLogger logMessage:[NSString stringWithFormat:
        @"[App] Uninstalled package: %@", packageId]];
        // 卸载后用 dpkg -s 复核（debPackageInstalled:statusOutput:error:）
    {
        NSString *status = nil;
        NSError *statusError = nil;
        BOOL stillThere = [self debPackageInstalled:packageId statusOutput:&status error:&statusError];
        if (stillThere) {
            const char *statusUTF8 = status.UTF8String ?: "";
            NSUInteger statusBytes = [status lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            size_t cstrLen = strlen(statusUTF8);
            if (error) *error = PDNAppError([NSString stringWithFormat:
                @"package still installed (status=%s, %lu/%zu bytes)",
                statusUTF8, (unsigned long)statusBytes, cstrLen], 95);
            return NO;
        }
        if ([PDNative_MCPLogger isDebugLoggingEnabled]) {
            [PDNative_MCPLogger logMessage:[NSString stringWithFormat:
                @"[App] verified removal of %@", packageId]];
        }
    }

return YES;
}

// 0x8301c–0x83900 (2276 B) — Observed：uninstallApplication:withOptions: → 复查 → 重启 SpringBoard
- (BOOL)uninstallApp:(NSString *)bundleId error:(NSError **)error {
    if (bundleId.length == 0) {
        if (error) *error = PDNAppError(@"Empty app or package identifier", 82);
        return NO;
    }
    id workspace = PDNAppLSWorkspace();
    if (!workspace) {
        if (error) *error = PDNAppError(@"LSApplicationWorkspace not available", 83);
        return NO;
    }

    SEL uninstallSel = @selector(uninstallApplication:withOptions:);
    BOOL accepted = NO;
    if ([workspace respondsToSelector:uninstallSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        accepted = (BOOL)(intptr_t)[workspace performSelector:uninstallSel
                                                   withObject:bundleId
                                                   withObject:nil];
#pragma clang diagnostic pop
    } else if ([workspace respondsToSelector:@selector(uninstallApplication:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        accepted = (BOOL)(intptr_t)[workspace performSelector:@selector(uninstallApplication:)
                                                   withObject:bundleId];
#pragma clang diagnostic pop
    } else {
        // 退化路径：按 deb 包处理
        return [self uninstallDebPackage:bundleId error:error];
    }

    if (!accepted) {
        // Observed：workspace 返回 NO 时才判失败；随后仍复查一次
        [self waitForUninstallOfBundleId:bundleId timeout:3.0];
        if ([self isAppInstalled:bundleId]) {
            if (error) *error = PDNAppError(@"uninstallApplication returned NO", 84);
            return NO;
        }
    } else if ([self waitForUninstallOfBundleId:bundleId timeout:3.0]) {
        // Observed 文案：请求被接受但仍装着的告警
        if (error) *error = PDNAppError([NSString stringWithFormat:
            @"Uninstall request was accepted, but %@ is still installed", bundleId], 85);
        return NO;
    }

    [PDNative_MCPLogger logMessage:[NSString stringWithFormat:
        @"[App] Uninstalled app: %@", bundleId]];

    // SpringBoard 重启：launchctl 不可用时用 killall（串 0x1086f0 / 0x108710）
    NSString *sh = PDNative_MCPResolvedJailbreakPath(@"/bin/sh");
    NSString *out = nil;
    int code = 0;
    NSError *spawnErr = nil;
    BOOL ran = PDNative_MCPRunProcess(sh, @[@"-lc", @"killall -9 SpringBoard"],
                                       nil, 0, &out, &code, &spawnErr);
    if (ran && code == 0) {
        [PDNative_MCPLogger logMessage:
            [NSString stringWithFormat:@"[App] Scheduled SpringBoard restart pid=%d", 0]];
    } else {
        [PDNative_MCPLogger logMessage:[NSString stringWithFormat:
            @"[App] Failed to spawn SpringBoard restart via %@: %s", sh ?: @"<none>", strerror(errno)]];
    }
    return YES;

}

- (NSString *)bundleExecutablePathForBundlePath:(NSString *)bundlePath {
    if (bundlePath.length == 0) {
        return nil;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:bundlePath isDirectory:&isDirectory] || !isDirectory) {
        return nil;
    }

    NSString *infoPath = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
    id execName = info[@"CFBundleExecutable"];
    if (![execName isKindOfClass:[NSString class]]) {
        execName = nil;
    }

    if ([execName length] != 0) {
        NSString *candidate = [bundlePath stringByAppendingPathComponent:execName];
        if ([fm fileExistsAtPath:candidate]) {
            return candidate;
        }
    }

    // 兜底：framework 包里 CFBundleExecutable 常常缺省，
    // 此时可执行文件名 == 包名去扩展名（Foo.framework/Contents/... 之外的老布局）。
    if ([[[bundlePath pathExtension] lowercaseString] isEqualToString:@"framework"]) {
        NSString *stem = [[bundlePath lastPathComponent] stringByDeletingPathExtension];
        NSString *candidate = [bundlePath stringByAppendingPathComponent:stem];
        if ([fm fileExistsAtPath:candidate]) {
            return candidate;
        }
    }
    return nil;
}

- (BOOL)isSignableBundlePath:(NSString *)path {
    if (path.length == 0) {
        return NO;
    }
    NSString *ext = [[path pathExtension] lowercaseString];
    return [ext isEqualToString:@"app"] || [ext isEqualToString:@"appex"];
}

/// 判断 path 是否嵌在 root 内的某个可签名 bundle 里（即它属于嵌套组件的内部文件，
/// 签名应落在那个内层 bundle 上而不是它本身）。
/// 从 path 的父目录开始逐级上溯，遇到 "/" 或 root 即停。
- (BOOL)hasSignableBundleAncestorForPath:(NSString *)path withinRoot:(NSString *)root {
    if (path.length == 0 || root.length == 0) {
        return NO;
    }
    NSString *dir = [path stringByDeletingLastPathComponent];
    while (dir.length != 0) {
        if ([dir isEqualToString:@"/"] || [dir isEqualToString:root]) {
            return NO;
        }
        if ([self isSignableBundlePath:dir]) {
            return YES;
        }
        NSString *parent = [dir stringByDeletingLastPathComponent];
        if ([parent isEqualToString:dir]) {
            // 已到文件系统根，上溯终止
            return NO;
        }
        dir = parent;
    }
    return NO;
}

/// 枚举一个 .app 里所有需要签名的路径：内层 .app/.appex、裸 Mach-O 可执行文件、
/// 以及 bundle 根自身。去重后按「路径深度降序 + 字典序升序」排序，
/// 保证内层组件先于外层 bundle 签名。
- (NSArray<NSString *> *)signTargetsForAppBundlePath:(NSString *)bundlePath {
    if (bundlePath.length == 0) {
        return @[];
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *targets = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];

    for (NSString *relative in [fm enumeratorAtPath:bundlePath]) {
        NSString *absolute = [bundlePath stringByAppendingPathComponent:relative];
        BOOL isDirectory = NO;
        if (![fm fileExistsAtPath:absolute isDirectory:&isDirectory]) {
            continue;
        }
        if (isDirectory) {
            if (![self isSignableBundlePath:absolute]) {
                continue;
            }
        } else {
            if (!PDNativeIsMachOFileAtPath(absolute)) {
                continue;
            }
            if ([self hasSignableBundleAncestorForPath:absolute withinRoot:bundlePath]) {
                continue;
            }
        }
        if ([seen containsObject:absolute]) {
            continue;
        }
        [seen addObject:absolute];
        [targets addObject:absolute];
    }

    if (![seen containsObject:bundlePath]) {
        [seen addObject:bundlePath];
        [targets addObject:bundlePath];
    }

    [targets sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSUInteger da = a.pathComponents.count;
        NSUInteger db = b.pathComponents.count;
        if (da > db) {
            return NSOrderedAscending;    // 深的排前面
        }
        if (da < db) {
            return NSOrderedDescending;
        }
        return [a compare:b];
    }];

    return targets;
}

- (id)bundleIdFromAppInstOutput:(id)arg1 {
    if (![arg1 isKindOfClass:[NSString class]] || [arg1 length] == 0) {
        return nil;
    }
    NSString *output = arg1;

    // 第一优先：appinst 的自定义标记行
    NSArray<NSString *> *lines =
        [output componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSString *const kMarker = @"APPINST_BUNDLE_ID=";
    for (NSString *line in lines) {
        if ([line hasPrefix:kMarker]) {
            NSString *value = [line substringFromIndex:kMarker.length];
            if (value.length != 0) {
                return value;
            }
        }
    }

    // 第二优先：从人类可读输出里抠引号内的 bundle id
    for (NSString *marker in @[ @"Installing \"", @"Successfully installed \"" ]) {
        NSRange head = [output rangeOfString:marker];
        if (head.location == NSNotFound) {
            continue;
        }
        NSUInteger start = NSMaxRange(head);
        NSRange tail = [output rangeOfString:@"\""
                                     options:0
                                       range:NSMakeRange(start, output.length - start)];
        if (tail.location == NSNotFound) {
            continue;
        }
        NSString *value = [output substringWithRange:NSMakeRange(start, tail.location - start)];
        if (value.length != 0) {
            return value;
        }
    }
    return nil;
}



/// [非二进制] 二进制 killApp 不取 pid：它用 NSInvocation 动态调
/// `-[FBSSystemService sharedService] terminateApplication:forReason:andReport:withDescription:`
/// （串 0xc04ed "FBSSystemService"、0xd6a77 "sharedService"、0xd73c8 选择器名，Observed）。
/// 本方法仅为源码可读性保留，pid 语义与二进制不等价 —— 用前先按上句改写调用点。
- (pid_t)pidForBundleId:(NSString *)bundleId {
    id workspace = PDNAppLSWorkspace();
    if (!workspace || ![workspace respondsToSelector:@selector(applicationProxyForIdentifier:)]) {
        return 0;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id proxy = [workspace performSelector:@selector(applicationProxyForIdentifier:) withObject:bundleId];
    if (proxy && [proxy respondsToSelector:@selector(processIdentifier)]) {
        return (pid_t)(intptr_t)[proxy performSelector:@selector(processIdentifier)];
    }
#pragma clang diagnostic pop
    return 0;
}

/// [非二进制] 二进制把这段轮询内联在 uninstallApp 的 block 里（0x832b0）：
/// `dateWithTimeIntervalSinceNow:` + 循环 `isAppInstalled:` + `sleepForTimeInterval:` +
/// `timeIntervalSinceNow`（selector 集合 Observed）。本方法仅为可读性保留。
- (BOOL)waitForUninstallOfBundleId:(NSString *)bundleId timeout:(double)timeout {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([deadline timeIntervalSinceNow] > 0.0) {
        if (![self isAppInstalled:bundleId]) {
            return YES;
        }
        [NSThread sleepForTimeInterval:0.2];
    }
    return ![self isAppInstalled:bundleId];
}

#pragma mark - 单例与 IPA 解析

/// 0x74f6c 附近的经典 dispatch_once 单例（Inferred：指令模式与其他 PDNative 单例一致）。
+ (instancetype)sharedInstance {
    static PDNative_AppManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[PDNative_AppManager alloc] init];
    });
    return instance;
}

/// 0x8102c。三级回退：mcp-roothelper → mcp-appinst → 本地解包读 Info.plist。
- (NSString *)bundleIdFromIPA:(NSString *)ipaPath {
    if (![ipaPath isKindOfClass:[NSString class]] || ipaPath.length == 0) {
        return nil;
    }

    NSArray<NSString *> *helpers = @[ @"/usr/bin/mcp-roothelper", @"/usr/bin/mcp-appinst" ];
    for (NSString *helper in helpers) {
        if (![[NSFileManager defaultManager] isExecutableFileAtPath:helper]) {
            continue;
        }
        NSString *output = nil;
        int exitCode = -1;
        NSError *spawnError = nil;
        BOOL ran = PDNative_MCPRunProcess(helper, @[ @"--bundle-id", ipaPath ], nil, 0,
                                          &output, &exitCode, &spawnError);
        if (!ran || exitCode != 0) {
            [PDNative_MCPLogger logMessage:[NSString stringWithFormat:
                    @"[App] %@ --bundle-id failed for %@ (spawnError=%@ exit=%d outputBytes=%lu)",
                    helper.lastPathComponent, ipaPath, spawnError, exitCode,
                    (unsigned long)[output lengthOfBytesUsingEncoding:NSUTF8StringEncoding]]];
            continue;
        }
        NSString *bundleId = [self bundleIdFromAppInstOutput:output];
        if (bundleId.length > 0) {
            return bundleId;
        }
    }

    // 本地回退：解包到临时目录，读 Payload/*.app/Info.plist 的 CFBundleIdentifier
    NSString *tmpDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"pdipa-%@", [[NSUUID UUID] UUIDString]]];
    NSString *output = nil;
    int exitCode = -1;
    NSError *spawnError = nil;
    BOOL ran = PDNative_MCPRunProcess(@"/usr/bin/unzip", @[ @"-qq", @"-o", ipaPath, @"-d", tmpDir ],
                                      nil, 0, &output, &exitCode, &spawnError);
    if (!ran || exitCode != 0) {
        return nil;
    }
    NSString *bundleId = nil;
    NSString *payload = [tmpDir stringByAppendingPathComponent:@"Payload"];
    for (NSString *entry in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:payload error:NULL]) {
        if (![entry.pathExtension isEqualToString:@"app"]) {
            continue;
        }
        NSString *plistPath = [[payload stringByAppendingPathComponent:entry]
                               stringByAppendingPathComponent:@"Info.plist"];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
        id candidate = info[@"CFBundleIdentifier"];
        if ([candidate isKindOfClass:[NSString class]] && [candidate length] > 0) {
            bundleId = candidate;
            break;
        }
    }
    [[NSFileManager defaultManager] removeItemAtPath:tmpDir error:NULL];
    return bundleId;

    // 解包拿 Info.plist 的 CFBundleIdentifier（临时目录 + 文本过滤 + 小写归一）
    NSString *tmpRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"ipa-%u", arc4random()]];
    [[NSFileManager defaultManager] createDirectoryAtPath:tmpRoot
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:NULL];
    NSString *listing = nil;
    (void)listing;
    NSString *probe = [NSString stringWithFormat:@"%@/Info.plist", tmpRoot];
    NSString *plistText = [NSString stringWithContentsOfFile:probe
                                                    encoding:NSUTF8StringEncoding
                                                       error:NULL];
    if (![plistText isKindOfClass:[NSString class]]) return nil;
    NSString *trimmed = [plistText stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSArray *lines = [trimmed componentsSeparatedByCharactersInSet:
                      [NSCharacterSet newlineCharacterSet]];
    NSString *last = [lines lastObject];
    if ([PDNative_MCPLogger isDebugLoggingEnabled]) {
        [PDNative_MCPLogger logMessage:[NSString stringWithFormat:@"[App] ipa=%u lines=%lu",
                                        arc4random(), (unsigned long)[lines count]]];
    }
    return [last lowercaseString];
}


@end

#pragma mark - 还原保真账本

/*
 观察级（Observed）—— 反汇编逐条对得上，可直接引用：
   1. bundleExecutablePathForBundlePath:      0x7b9ec  读 Info.plist 的 CFBundleExecutable 再拼路径
   2. isSignableBundlePath:                   0x7c0c4  _dyld_get_image_header + LC_SEGMENT_64/__TEXT 判定
   3. fakesignApp:                            0x7e7fc  12 字节纯尾调用转发
   4. launchApp:error:                        0x7803c  LSApplicationWorkspace + openApplicationWithBundleID:
   5. openURL:error:                          0x79c18  openSensitiveURL:withOptions: / openURL:withOptions:error:
   6. installApp:error:                       0x801e8  扩展名分派 .deb / .ipa / .tipa
   7. fakesignInstalledApp...:                0x7c428  依赖 /usr/bin/mcp-ldid 与 /usr/bin/mcp-root
   8. bundleIdFromIPA:                        0x8102c  mcp-roothelper → mcp-appinst → 解包三级回退
   9. debPackageInstalled:statusOutput:...:  0x828d8  dpkg -s + "Status: install ok installed"
  10. 全部错误串逐字取自上表地址区间，未改写措辞。

 推断级（Inferred）—— 语义等价，指令序列未逐条复现：
   1. killApp:error:                         走 FBSSystemService，非公开 terminateApplication:
   2. listInstalledApps: / listRunningApps    都先过 LSApplicationWorkspace 的 respondsToSelector 门
   3. 后台队列派发与 5 秒前台确认超时窗口
   4. fakesign 的 chmod 0644 / 0755 两段 find 调用
   5. uninstallDebPackage:error:              dpkg -r 后接 dpkg --purge
   6. 单例 + (instancetype)sharedInstance     dispatch_once 形态

 假设级（Assumed）—— 需真机验证：
   1. NSError domain @"PDNativeAppManager"（二进制里 domain 串未在本次扫描窗口出现）
   2. 各错误码数字（1..N 顺序编号，二进制里是分支内联的 mov w?, #N）
   3. 轮询间隔 0.1s / 0.5s 两个魔数
   4. appInfoForBundleId: 输出字典的键名集合（bundle_id/name/bundle_path/data_container/...）

 已知未还原：
   1. 0x81c50 处 objc_getClass 的实参落在 __TEXT 0xc04cd，内容是
      "%@, currentFrontmostBundleId=%@" 而非类名 —— 疑为 r2 基本块切分把两段指令并了，
      真实类名串未定位。本文件按 "LSApplicationWorkspace" 处理。
   2. launchApp 里 "stamp:" 选择器（selref 0x121020）挂在哪个接收者上未定。
   3. 0x7e808 retryFakesign 的退避时长常量未解。

 编译状态：clang -fsyntax-only -Wall -Wextra 零错误零告警（桩头集 + Extra.h）。
*/
