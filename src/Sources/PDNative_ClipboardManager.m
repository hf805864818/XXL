//
//  PDNative_ClipboardManager.m
//  逆向还原（PetDFY 1.2.1 arm64e）
//
//  反汇编来源：
//    -readClipboard            0x75f70  ~1127 指令
//    -writeText:               0x7710c  636 指令
//    辅助 func.000773a8        字符串归类（hasURL 判定）
//    辅助 func.00077600        Manifest.plist → 扁平文本
//    辅助 func.00077890        递归收集器（NSString / NSURL / NSArray / NSDictionary / NSNull）
//
//  关键实测（Observed）：
//    · 候选目录 4 条，取自 __objc_arrayobj @0x10fc80：
//        /private/var/mobile/Library/Caches/com.apple.Pasteboard
//        /var/mobile/Library/Caches/com.apple.Pasteboard
//        /var/jb/private/var/mobile/Library/Caches/com.apple.Pasteboard
//        /var/jb/var/mobile/Library/Caches/com.apple.Pasteboard
//    · 目录内条目名 = SHA1(utf8("com.apple.UIKit.pboard.general")) 的 40 位小写 hex
//      （CC_SHA1 @0xa8c50，输出缓冲 20 字节，stringWithCapacity:0x28，appendFormat:"%02x"）
//    · 条目内固定读 "Manifest.plist"，NSPropertyListSerialization 解析后扁平化
//    · 返回字典 4 键：text / hasImage / hasURL / cacheMiss
//    · 写路径：dispatch_async 到串行队列 + dispatch_semaphore_wait 5.0s（0x12a05f200 ns）
//    · 写用命名剪贴板 "com.witchan.ios-mcp.clipboard.write"，失败回落 generalPasteboard
//    · 三条日志逐字保留（见文件末尾账本）
//

#import "PDNative_ClipboardManager.h"
#import <objc/message.h>

#import <CommonCrypto/CommonDigest.h>
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>

#pragma mark - 常量（全部取自二进制）

static NSString *const kPDClipboardCacheName = @"com.apple.UIKit.pboard.general";
static NSString *const kPDClipboardWriteName = @"com.witchan.ios-mcp.clipboard.write";
static NSString *const kPDClipboardManifestName = @"Manifest.plist";

static const int64_t kPDClipboardTimeoutNanos = 5 * NSEC_PER_SEC;  // 0x12a05f200

static NSString *const kPDClipboardKeyText = @"text";
static NSString *const kPDClipboardKeyHasImage = @"hasImage";
static NSString *const kPDClipboardKeyHasURL = @"hasURL";
static NSString *const kPDClipboardKeyCacheMiss = @"cacheMiss";

#pragma mark - 日志

// 观测：三处日志都走 isDebugLoggingEnabled + logMessage:，且都带 "[Clipboard] " 前缀。
static void PDClipboardLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    Class loggerClass = NSClassFromString(@"PDLogger");
    if (loggerClass && [loggerClass respondsToSelector:@selector(sharedLogger)]) {
        id logger = [loggerClass performSelector:@selector(sharedLogger)];
        if ([logger respondsToSelector:@selector(isDebugLoggingEnabled)] &&
            [logger respondsToSelector:@selector(logMessage:)]) {
            BOOL enabled = ((BOOL (*)(id, SEL))objc_msgSend)(logger, @selector(isDebugLoggingEnabled));
            if (enabled) {
                ((void (*)(id, SEL, id))objc_msgSend)(logger, @selector(logMessage:), message);
            }
        }
    }
}

#pragma mark - 路径与哈希

// Observed：CC_SHA1(ctx, bytes, len, out20) 之后逐字节 appendFormat:"%02x"。
static NSString *PDClipboardSHA1Hex(NSString *input) {
    NSData *data = [input dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length == 0) return nil;

    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);

    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

// Observed：数组遍历 + fileExistsAtPath:isDirectory:，取第一个存在且是目录的。
static NSString *PDClipboardCacheDirectory(void) {
    NSArray<NSString *> *candidates = @[
        @"/private/var/mobile/Library/Caches/com.apple.Pasteboard",
        @"/var/mobile/Library/Caches/com.apple.Pasteboard",
        @"/var/jb/private/var/mobile/Library/Caches/com.apple.Pasteboard",
        @"/var/jb/var/mobile/Library/Caches/com.apple.Pasteboard",
    ];

    NSFileManager *manager = [NSFileManager defaultManager];
    for (NSString *candidate in candidates) {
        BOOL isDirectory = NO;
        if ([manager fileExistsAtPath:candidate isDirectory:&isDirectory] && isDirectory) {
            return candidate;
        }
    }
    return nil;
}

#pragma mark - Manifest 扁平化

// Observed（func.00077890）：
//   NSNull      → 跳过
//   NSString    → length > 0 时收下
//   NSURL       → 收 absoluteString
//   NSArray     → 逐元素递归
//   NSDictionary→ 逐 value 递归
// Inferred：NSNumber 走 stringValue（分支里只有 absoluteString / 递归两类可确认）。
static void PDClipboardCollect(id object, NSMutableArray<NSString *> *out) {
    if (!object || object == [NSNull null]) return;

    if ([object isKindOfClass:[NSString class]]) {
        if ([object length] > 0) [out addObject:object];
        return;
    }

    if ([object isKindOfClass:[NSURL class]]) {
        NSString *absolute = [object absoluteString];
        if (absolute.length > 0) [out addObject:absolute];
        return;
    }

    if ([object isKindOfClass:[NSNumber class]]) {
        [out addObject:[object stringValue]];
        return;
    }

    if ([object isKindOfClass:[NSArray class]]) {
        for (id element in (NSArray *)object) {
            PDClipboardCollect(element, out);
        }
        return;
    }

    if ([object isKindOfClass:[NSDictionary class]]) {
        for (id key in (NSDictionary *)object) {
            PDClipboardCollect([(NSDictionary *)object objectForKey:key], out);
        }
        return;
    }

    if ([object isKindOfClass:[NSData class]]) {
        // 图像等二进制负载：不转文本，由调用方按 hasImage 判定
        return;
    }

    NSString *description = [object description];
    if (description.length > 0) [out addObject:description];
}

// Observed（func.00077600）：NSPropertyListSerialization propertyListWithData:options:format:error:
// 解析失败时返回共享空数组（0xf8b78），不抛错。
static NSArray<NSString *> *PDClipboardFlattenManifest(NSData *data) {
    if (data.length == 0) return @[];

    NSError *error = nil;
    id plist = [NSPropertyListSerialization propertyListWithData:data
                                                         options:NSPropertyListImmutable
                                                          format:NULL
                                                           error:&error];
    if (!plist) return @[];

    NSMutableArray<NSString *> *out = [NSMutableArray array];
    PDClipboardCollect(plist, out);
    return out;
}

#pragma mark - URL 判定

// Observed（func.000773a8）：stringByStandardizingPath → lowercaseString → hasPrefix 三次
// 分别对 "http://" / "https://" / "file://"。
static BOOL PDClipboardStringLooksLikeURL(NSString *text) {
    NSString *lower = [[text stringByStandardizingPath] lowercaseString];
    if ([lower hasPrefix:@"http://"]) return YES;
    if ([lower hasPrefix:@"https://"]) return YES;
    if ([lower hasPrefix:@"file://"]) return YES;
    return NO;
}

#pragma mark - 串行队列

static dispatch_queue_t PDClipboardQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.witchan.ios-mcp.clipboard", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

#pragma mark - 实现

@implementation PDNative_ClipboardManager

+ (instancetype)sharedInstance {
    static PDNative_ClipboardManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[PDNative_ClipboardManager alloc] init];
    });
    return instance;
}

- (id)readClipboard {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    BOOL hasImage = NO;
    BOOL cacheMiss = NO;

    BOOL debug = [PDNative_MCPLogger isDebugLoggingEnabled];

    // 0x75f70 段：主线程时同步切到串行队列再读（避免读 IO 阻塞 UI）
    if ([NSThread isMainThread]) {
        dispatch_sync(PDClipboardQueue(), ^{
            // 读操作本身在下面完成；这里只做一次队列同步（与二进制的 dispatch_sync 对应）
        });
    }

    NSString *directory = PDClipboardCacheDirectory();
    if (![directory isKindOfClass:[NSString class]] || directory.length == 0) {
        PDClipboardLog(@"[Clipboard] Pasteboard cache directory missing");
        cacheMiss = YES;
    } else {
        NSFileManager *manager = [NSFileManager defaultManager];

        // 条目名 = SHA1("com.apple.UIKit.pboard.general") 的 40 位小写 hex
        NSString *entryName = nil;
        {
            NSData *nameData = [kPDClipboardCacheName dataUsingEncoding:NSUTF8StringEncoding];
            unsigned char digest[CC_SHA1_DIGEST_LENGTH];
            CC_SHA1(nameData.bytes, (CC_LONG)nameData.length, digest);
            NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
            for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
                [hex appendFormat:@"%02x", digest[i]];
            }
            entryName = hex;
        }

        // 枚举缓存目录并按修改时间倒序（二进制：contentsOfDirectoryAtPath + attributesOfItemAtPath + sortUsingComparator:）
        NSArray<NSString *> *entries = [manager contentsOfDirectoryAtPath:directory error:NULL];
        NSMutableArray<NSDictionary *> *candidates = [NSMutableArray arrayWithCapacity:entries.count];
        for (NSString *name in entries) {
            NSString *full = [directory stringByAppendingPathComponent:name];
            NSDictionary *attrs = [manager attributesOfItemAtPath:full error:NULL];
            NSDate *modified = [attrs isKindOfClass:[NSDictionary class]]
                ? (attrs[NSFileModificationDate] ?: [NSDate distantPast]) : [NSDate distantPast];
            unsigned long long bytes = [attrs[NSFileSize] unsignedLongLongValue];
            [candidates addObject:@{@"name": name, @"at": modified, @"size": @(bytes)}];
        }
        [candidates sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [b[@"at"] compare:a[@"at"]];
        }];

        NSString *chosen = nil;
        for (NSDictionary *cand in candidates) {
            if ([cand[@"name"] isEqualToString:entryName]) { chosen = cand[@"name"]; break; }
        }
        if (!chosen && candidates.count > 0) chosen = candidates.firstObject[@"name"];

        if (debug) {
            PDClipboardLog([NSString stringWithFormat:@"[Clipboard] cache entries=%lu chosen=%@",
                            (unsigned long)candidates.count, chosen ?: @"<none>"]);
        }

        NSString *entryPath = chosen ? [directory stringByAppendingPathComponent:chosen] : nil;
        BOOL entryIsDir = NO;
        if (!entryPath || ![manager fileExistsAtPath:entryPath isDirectory:&entryIsDir]) {
            cacheMiss = YES;
            [PDNative_MCPLogger logMessage:[NSString stringWithFormat:
                @"[Clipboard] cache entry missing: %@", entryPath ?: @"<nil>"]];
        } else {
            NSString *manifestPath = [entryPath stringByAppendingPathComponent:kPDClipboardManifestName];
            NSData *manifestData = [NSData dataWithContentsOfFile:manifestPath];
            if (manifestData.length == 0) {
                cacheMiss = YES;
            } else {
                NSArray<NSString *> *items = PDClipboardFlattenManifest(manifestData);
                NSMutableString *joined = [[NSMutableString alloc] initWithData:manifestData
                                                                       encoding:NSUTF8StringEncoding];
                for (NSString *item in items) {
                    [lines addObject:item];
                }
                id imageFlag = items.count ? @([self pd_manifestHasBinaryPayload:manifestData]) : @NO;
                hasImage = [imageFlag boolValue];
                (void)joined;
            }
        }
    }

    NSString *text = [lines componentsJoinedByString:@"\n"];

    // Observed：缓存未命中时回落直读，日志逐字为
    //   "[Clipboard] Pasteboard cache has no readable content; falling back to direct clipboard read"
    if (cacheMiss || text.length == 0) {
        PDClipboardLog(@"[Clipboard] Pasteboard cache has no readable content; falling back to direct clipboard read");

        __block NSString *directText = nil;
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        dispatch_async(PDClipboardQueue(), ^{
            UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
            directText = pasteboard.string;
            dispatch_semaphore_signal(semaphore);
        });

        if (dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, kPDClipboardTimeoutNanos)) != 0) {
            PDClipboardLog(@"[Clipboard] Direct clipboard read timed out after 5s; pasteboardd may be busy");
        } else if (directText.length > 0) {
            text = directText;
        }
    }

    BOOL hasURL = PDClipboardStringLooksLikeURL(text);
    if (!hasURL) {
        for (NSString *line in lines) {
            if (PDClipboardStringLooksLikeURL(line)) { hasURL = YES; break; }
        }
    }

    // Observed 日志模板：
    //   "Read pasteboard cache textChars=%lu hasImage=%@ hasURL=%@ files=%lu"
    PDClipboardLog(@"[Clipboard] Read pasteboard cache textChars=%lu hasImage=%@ hasURL=%@ files=%lu",
                   (unsigned long)text.length,
                   hasImage ? @"YES" : @"NO",
                   hasURL ? @"YES" : @"NO",
                   (unsigned long)lines.count);

    return @{
        kPDClipboardKeyText: text ?: @"",
        kPDClipboardKeyHasImage: @(hasImage),
        kPDClipboardKeyHasURL: @(hasURL),
        kPDClipboardKeyCacheMiss: @(cacheMiss),
    };
}

// Inferred：Manifest 里出现 NSData 值即视为含图像；具体键名未在反汇编中定位。
/// [非二进制] 内部辅助：判断 manifest 是否含二进制载荷。二进制内联在写入路径里。
- (BOOL)pd_manifestHasBinaryPayload:(NSData *)manifestData {
    NSError *error = nil;
    id plist = [NSPropertyListSerialization propertyListWithData:manifestData
                                                         options:NSPropertyListImmutable
                                                          format:NULL
                                                           error:&error];
    return [self pd_containsData:plist depth:0];
}

/// [非二进制] 内部递归辅助：深度受限的数据探测，被 pd_manifestHasBinaryPayload 调用。
/// 二进制内联在上层遍历里。
- (BOOL)pd_containsData:(id)object depth:(NSUInteger)depth {
    if (!object || depth > 8) return NO;
    if ([object isKindOfClass:[NSData class]]) return YES;
    if ([object isKindOfClass:[NSArray class]]) {
        for (id element in (NSArray *)object) {
            if ([self pd_containsData:element depth:depth + 1]) return YES;
        }
    }
    if ([object isKindOfClass:[NSDictionary class]]) {
        for (id key in (NSDictionary *)object) {
            if ([self pd_containsData:[(NSDictionary *)object objectForKey:key] depth:depth + 1]) return YES;
        }
    }
    return NO;
}

- (BOOL)writeText:(id)text {
    NSString *string = nil;
    if ([text isKindOfClass:[NSString class]]) {
        string = text;
    } else if ([text respondsToSelector:@selector(stringValue)]) {
        string = [(NSNumber *)text stringValue];
    } else {
        string = [text description];
    }
    if (string.length == 0) return NO;

    __block BOOL wrote = NO;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    dispatch_async(PDClipboardQueue(), ^{
        UIPasteboard *named = nil;
        if (@available(iOS 16.0, *)) {
            named = [UIPasteboard pasteboardWithName:kPDClipboardWriteName create:YES];
        }
        if (named) {
            [named setString:string];
            wrote = YES;
            // Observed："[Clipboard] Wrote clipboard directly textChars=%lu"
            PDClipboardLog(@"[Clipboard] Wrote clipboard directly textChars=%lu", (unsigned long)string.length);
        } else {
            [[UIPasteboard generalPasteboard] setString:string];
            wrote = YES;
            // Observed："[Clipboard] Wrote clipboard textChars=%lu"
            PDClipboardLog(@"[Clipboard] Wrote clipboard textChars=%lu", (unsigned long)string.length);
        }
        dispatch_semaphore_signal(semaphore);
    });

    if (dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, kPDClipboardTimeoutNanos)) != 0) {
        // Observed："[Clipboard] Write clipboard timed out after 5s; pasteboardd may be busy"
        PDClipboardLog(@"[Clipboard] Write clipboard timed out after 5s; pasteboardd may be busy");
        return NO;
    }
    return wrote;

    BOOL debug = [PDNative_MCPLogger isDebugLoggingEnabled];
    if ([NSThread isMainThread]) {
        dispatch_sync(PDClipboardQueue(), ^{ });
    }
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSProcessInfo *info = [NSProcessInfo processInfo];
        (void)[info processName];
        (void)[info operatingSystemVersion];
    });
    if (debug) {
        [PDNative_MCPLogger logMessage:[NSString stringWithFormat:@"[Clipboard] write len=%lu",
                                        (unsigned long)[[text description] length]]];
    }
}


@end

// ---------------------------------------------------------------------------
// 还原保真账本
//
// Observed（有指令级证据）
//   1. 四个候选缓存目录的完整字面值，来自 __objc_arrayobj @0x10fc80
//   2. 条目名 = SHA1(UTF-8) 的 40 位 hex：CC_SHA1 调用点 @0x760a0，
//      stringWithCapacity:0x28 @0x760d4，appendFormat:"%02x" @0x76100
//   3. 固定读 "Manifest.plist"，NSPropertyListSerialization @0xafa40
//   4. 返回字典 4 键：text(0xfc1b0) / hasImage(0x106790) / hasURL(0x1067b0) / cacheMiss(0x1067d0)
//   5. 5 秒超时常量 0x12a05f200 ns（dispatch_time + dispatch_semaphore_wait）
//   6. 写路径命名剪贴板 "com.witchan.ios-mcp.clipboard.write"（pasteboardWithName:create:）
//   7. 五条日志文案逐字
//
// Inferred（有结构证据，语义为推断）
//   1. hasImage 的判定依据（Manifest 内是否存在 NSData 负载）
//   2. 缓存目录条目内除 Manifest.plist 外的其他文件名
//   3. NSNumber → stringValue 的收集规则
//   4. iOS 版本分支的阈值（16.0）
//
// 已知未还原
//   1. readClipboard 中 size/modifiedAt 两个键的用途（属于另一条分支，
//      与本方法返回字典无关，推测为调试输出）
//   2. "%02x" 之外的 hex 大小写差异（二进制里是小写，已对齐）
// ---------------------------------------------------------------------------
