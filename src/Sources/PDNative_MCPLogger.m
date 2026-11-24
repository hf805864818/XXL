//
//  PDNative_MCPLogger.m
//  PetDFY
//
//  还原自 PetDFY.arm64e.dylib —— PDNative_MCPLogger
//
//  ── 还原保真账本 ─────────────────────────────────────────────
//  Observed（反汇编直接读到，地址可核）
//    1. 全部 11 个方法都是类方法（+），instanceSize=8、无 ivar —— 纯静态命名空间类。
//    2. 六个路径/文件名常量逐字取自 __cstring：见 .h 顶部表。
//    3. log: 的实现是 initWithFormat:arguments: + NSLog(@"[witchan][ios-mcp] %@")
//       + logMessage:，va_list 版本（0xacba0 / NSLog / 0xaddc0）。
//    4. logMessage: 的四道工序：
//         a. isDebugLoggingEnabled 为假 → 直接返回（0x70d10 入口即判）
//         b. 换行折叠 + 4096 字符截断，截断后缀 @"...<truncated>"（0x70ad0–0x70b10，
//            阈值为 mov w?, #0x1000）
//         c. 拼行 "%@ pid=%d %@"，第一个 %@ 用 [witchan][ios-mcp]（0x105e30）
//         d. mkdir -p 目录 → 打开锁文件 flock → stat 主日志 → 超过 0x200000（2 MB）
//            则轮转 → 追加写 → 失败走 log_write 错误文案
//    5. 轮转文件名格式 @"%s.%03d%s"（0x105fb0），路径按 utf8String 取出后 snprintf 拼。
//    6. 每一步失败的诊断键是固定短串：createDirectory failed / open_lock / flock /
//       stat / unlink_previous / rotate / open_log / log_write（0x105e50–0x105ff0），
//       统一走 @"%@ failed errno=%d error=%s"（0x105fd0）。
//    7. isDebugLoggingEnabled 带 2.0 秒节流：静态 CFAbsoluteTime，命中则复用上次结果。
//       （0x7054c，fccmp 立即数 2.0）
//    8. clearLogsWithError: 在串行队列上用 dispatch_sync 执行（0x7138c），
//       逐个 unlink 主日志/previous/归档，成功清空 lastLogError。
//
//  Inferred（结构对得上，但细节按 ARM64 惯用法补全）
//    · 锁用 open(lockFilePath, O_CREAT|O_RDWR, 0644) + flock(fd, LOCK_EX)：
//      二进制里 open_lock / flock 两个阶段串是分开的，具体 open 的 flag 位未逐位核。
//    · 归档上限：allLogFilePaths 的枚举上界没在常量表里找到，按主日志 + previous +
//      编号归档 0..N 拼；N 取 5（与 rotate 时 unlink_previous 的链式命名一致）。
//    · 清空队列的队列名取 "com.witchan.ios-mcp.log"，队列本身在 __DATA 里是懒建的。
//
//  Assumed（必须真机验证）
//    · 行尾是否补 '\n'：写进去的内容以 utf8 追加，二进制里看不到显式换行串。
//    · O_APPEND 与 O_CREAT 的具体组合。
//
//  未还原
//    · lastLogError 的写入时机只覆盖到 log_write 失败分支；
//      createDirectory / flock / stat 失败是否也回写，未逐个分支核。
//  ────────────────────────────────────────────────────────────
//

#import "PDNative_MCPLogger.h"
#include <stdarg.h>

#import <sys/stat.h>
#import <sys/file.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>
#import <stdio.h>

/// 硬编码路径（Observed @0x105d70 / 0x105d90 / 0x105db0 / 0x105dd0 / 0x105df0）
static NSString *const kPDLogDirectory      = @"/var/mobile/Library/Logs/iOSMCP";
static NSString *const kPDLogFileName       = @"ios-mcp.log";
static NSString *const kPDPreviousLogName   = @"ios-mcp.1.log";
static NSString *const kPDArchivedLogFormat = @"ios-mcp.%lu.log";
static NSString *const kPDLockFileName      = @"ios-mcp.lock";

/// 偏好域与开关键（Observed @0x105f50 / 0x105f30）
static NSString *const kPDPreferencesDomain = @"com.witchan.ios-mcp.preferences";
static NSString *const kPDDebugLoggingKey   = @"debugLoggingEnabled";

/// 控制台前缀与行前缀（Observed @0x105e10 / 0x105e30）
static NSString *const kPDConsolePrefix     = @"[witchan][ios-mcp]";
static NSString *const kPDLineFormat        = @"%@ pid=%d %@";

/// 上限（Observed：4096 字符截断 @0x70ad0；2 MB 轮转 @0x70f30）
static const NSUInteger kPDMaxLineLength    = 0x1000;
static const off_t      kPDMaxLogFileSize   = 0x200000;

/// 换行折叠用的替换串（Observed @0x105f70 是空串，即把 CR/LF 换成空格前的中间产物）
static NSString *const kPDTruncationSuffix  = @"...<truncated>";

/// 诊断键（Observed @0x105e50–0x105ff0）
static NSString *const kPDStageCreateDirectory = @"createDirectory failed";
static NSString *const kPDStageOpenLock        = @"open_lock";
static NSString *const kPDStageFlock           = @"flock";
static NSString *const kPDStageStat            = @"stat";
static NSString *const kPDStageUnlinkPrevious  = @"unlink_previous";
static NSString *const kPDStageRotate          = @"rotate";
static NSString *const kPDStageOpenLog         = @"open_log";
static NSString *const kPDStageLogWrite        = @"log_write";

/// 2 秒节流缓存（Observed：静态 CFAbsoluteTime + fccmp 2.0 @0x7054c）
static CFAbsoluteTime sPDLastDebugCheck = 0.0;
static BOOL           sPDLastDebugValue = NO;

/// 清空用的串行队列（Inferred）
static dispatch_queue_t sPDLogQueue = NULL;

/// lastLogError（Observed：类方法读取；存放位置为 __DATA 静态）
static NSString *sPDLastLogError = nil;

@implementation PDNative_MCPLogger

#pragma mark - 开关

+ (BOOL)isDebugLoggingEnabled {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();

    // 2 秒内复用上次结果（Observed: fsub + fccmp 2.0 + b.le 走缓存）
    if (sPDLastDebugCheck != 0.0 && (now - sPDLastDebugCheck) < 2.0) {
        return sPDLastDebugValue;
    }

    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kPDPreferencesDomain];
    BOOL enabled = [defaults boolForKey:kPDDebugLoggingKey];

    sPDLastDebugCheck = now;
    sPDLastDebugValue = enabled;
    return enabled;
}

#pragma mark - 路径

+ (NSString *)logDirectoryPath {
    // Observed：dispatch_once 缓存在静态变量里（func.00070cbc）
    return kPDLogDirectory;
}

+ (NSString *)logFilePath {
    return [kPDLogDirectory stringByAppendingPathComponent:kPDLogFileName];
}

+ (NSString *)previousLogFilePath {
    return [kPDLogDirectory stringByAppendingPathComponent:kPDPreviousLogName];
}

+ (NSString *)archivedLogFilePathAtIndex:(NSUInteger)index {
    NSString *name = [NSString stringWithFormat:kPDArchivedLogFormat, (unsigned long)index];
    return [kPDLogDirectory stringByAppendingPathComponent:name];
}

+ (NSString *)lockFilePath {
    return [kPDLogDirectory stringByAppendingPathComponent:kPDLockFileName];
}

+ (NSArray *)allLogFilePaths {
    NSMutableArray *paths = [NSMutableArray arrayWithCapacity:8];
    [paths addObject:[self logFilePath]];
    [paths addObject:[self previousLogFilePath]];

    // Inferred：归档编号 0..4，存在才加
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSUInteger i = 0; i < 5; i++) {
        NSString *p = [self archivedLogFilePathAtIndex:i];
        if ([fm fileExistsAtPath:p]) {
            [paths addObject:p];
        }
    }
    return paths;
}

+ (NSString *)lastLogError {
    return sPDLastLogError;
}

#pragma mark - 写入

+ (void)log:(NSString *)format, ... {
    if (format.length == 0) {
        return;
    }
    if (![self isDebugLoggingEnabled]) {
        return;
    }

    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    // Observed：先打一份到控制台（NSLog(@"[witchan][ios-mcp] %@", line)）
    NSLog(@"%@ %@", kPDConsolePrefix, line);

    [self logMessage:line];
}

+ (void)logMessage:(NSString *)message {
    if (![self isDebugLoggingEnabled]) {
        return;
    }
    if (message == nil) {
        message = @"(null)";
    }

    // ── b. 换行折叠 + 截断（Observed 0x70ad0–0x70b10）──
    NSString *flat = [message stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    flat = [flat stringByReplacingOccurrencesOfString:@"\r" withString:@" "];

    if (flat.length > kPDMaxLineLength) {
        flat = [[flat substringToIndex:kPDMaxLineLength] stringByAppendingString:kPDTruncationSuffix];
    }

    // ── c. 行前缀（Observed "%@ pid=%d %@" @0x105e30）──
    NSString *line = [NSString stringWithFormat:kPDLineFormat,
                      kPDConsolePrefix, (int)getpid(), flat];
    NSData *payload = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (payload.length == 0) {
        return;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *dirError = nil;

    // ── d1. 建目录（Observed stage "createDirectory failed"）──
    if (![fm createDirectoryAtPath:kPDLogDirectory
       withIntermediateDirectories:YES
                        attributes:nil
                             error:&dirError]) {
        sPDLastLogError = [NSString stringWithFormat:@"%s failed errno=%d error=%s",
                           kPDStageCreateDirectory.UTF8String, errno,
                           dirError.localizedDescription.UTF8String ?: ""];
        return;
    }

    // ── d2. 开锁文件 + flock（Observed stage "open_lock" / "flock"）──
    const char *lockPath = [self lockFilePath].UTF8String;
    int lockFD = open(lockPath, O_CREAT | O_RDWR, 0644);
    if (lockFD < 0) {
        sPDLastLogError = [NSString stringWithFormat:@"%s failed errno=%d error=%s",
                           kPDStageOpenLock.UTF8String, errno, strerror(errno)];
        return;
    }
    if (flock(lockFD, LOCK_EX) != 0) {
        sPDLastLogError = [NSString stringWithFormat:@"%s failed errno=%d error=%s",
                           kPDStageFlock.UTF8String, errno, strerror(errno)];
        close(lockFD);
        return;
    }

    const char *logPath = [self logFilePath].UTF8String;

    // ── d3. stat + 按 2 MB 轮转（Observed stage "stat" / "rotate" / "unlink_previous"）──
    struct stat st;
    if (stat(logPath, &st) == 0) {
        if ((off_t)(st.st_size + (off_t)payload.length) > kPDMaxLogFileSize) {
            // 先删 previous，再把当前改名为 .1.log（"%s.%03d%s" 用于带编号的归档名）
            const char *prevPath = [self previousLogFilePath].UTF8String;
            if (unlink(prevPath) != 0 && errno != ENOENT) {
                sPDLastLogError = [NSString stringWithFormat:@"%s failed errno=%d error=%s",
                                   kPDStageUnlinkPrevious.UTF8String, errno, strerror(errno)];
            }
            if (rename(logPath, prevPath) != 0) {
                sPDLastLogError = [NSString stringWithFormat:@"%s failed errno=%d error=%s",
                                   kPDStageRotate.UTF8String, errno, strerror(errno)];
            }
        }
    } else if (errno != ENOENT) {
        sPDLastLogError = [NSString stringWithFormat:@"%s failed errno=%d error=%s",
                           kPDStageStat.UTF8String, errno, strerror(errno)];
    }

    // ── d4. 追加写（Observed stage "open_log" / "log_write"）──
    int fd = open(logPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) {
        sPDLastLogError = [NSString stringWithFormat:@"%s failed errno=%d error=%s",
                           kPDStageOpenLog.UTF8String, errno, strerror(errno)];
        flock(lockFD, LOCK_UN);
        close(lockFD);
        return;
    }

    const void *bytes = payload.bytes;
    size_t remaining = (size_t)payload.length;
    BOOL writeFailed = NO;
    while (remaining > 0) {
        ssize_t wrote = write(fd, bytes, remaining);
        if (wrote <= 0) {
            writeFailed = YES;
            break;
        }
        bytes = (const uint8_t *)bytes + wrote;
        remaining -= (size_t)wrote;
    }
    if (writeFailed) {
        sPDLastLogError = [NSString stringWithFormat:@"%s failed errno=%d error=%s",
                           kPDStageLogWrite.UTF8String, errno, strerror(errno)];
    }

    close(fd);
    flock(lockFD, LOCK_UN);
    close(lockFD);
}

#pragma mark - 清理

+ (BOOL)clearLogsWithError:(NSError **)error {
    if (sPDLogQueue == NULL) {
        sPDLogQueue = dispatch_queue_create("com.witchan.ios-mcp.log", DISPATCH_QUEUE_SERIAL);
    }

    __block BOOL ok = YES;
    __block NSString *failure = nil;

    dispatch_sync(sPDLogQueue, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *path in [self allLogFilePaths]) {
            NSError *rmError = nil;
            if (![fm removeItemAtPath:path error:&rmError] && rmError != nil) {
                if (rmError.code != NSFileNoSuchFileError) {
                    ok = NO;
                    failure = rmError.localizedDescription;
                }
            }
        }
        if (ok) {
            sPDLastLogError = nil;
        }
    });

    if (!ok && error != NULL) {
        *error = [NSError errorWithDomain:@"PDNative_MCPLogger"
                                     code:errno
                                 userInfo:@{NSLocalizedDescriptionKey: failure ?: @"clearLogs failed"}];
    }
    return ok;
}

@end
