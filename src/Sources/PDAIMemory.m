//
//  PDAIMemory.m
//  PetDFY
//
//  记忆工作区：文件工具的执行后端 + 系统上下文拼装。
//
//  还原来源：PetDFY.arm64e.dylib 反汇编（class PDAIMemory，22 个方法 / 9,860 指令）。
//  分级：Observed = 反汇编逐条对上；Inferred = 由常量/调用点推断；Assumed = 仅按文案补形状。
//
//  本轮已核对：initWithRoot: / path: / writablePath:error: / protected: /
//  protectedFileNames / files / glob: / lines: / lineRange:args: / systemContext /
//  prepareWrite:error: / write:path:operation:error: / run:arguments: 的分支骨架。
//

#import "PDAIMemory.h"
#import <sys/stat.h>
#import <dlfcn.h>
#import <stdlib.h>

#pragma mark - 常量

static NSString *const kPDMemRootErrorDomain = @"PDAIMemory";
static const NSUInteger kPDMemMaxContextChars = 24000;
static const NSUInteger kPDMemReadChunkLines   = 240;

// 常驻文件：不可删除、不可移动，只可编辑内容。
static NSString *const kPDMemConstitutionFile = @"CONSTITUTION.md";
static NSString *const kPDMemPartnerFile      = @"PARTNER.md";
static NSString *const kPDMemKeyMemoryFile    = @"KEY_MEMORY.md";

// 系统管理的隐藏目录/文件：点开头，禁止写入、移动、删除。
static NSString *const kPDMemVersionsDir      = @".versions";

#pragma mark - 小工具

static void PDAIMemSetError(NSError **slot, NSString *message) {
    if (slot == NULL || message == nil) return;
    *slot = [NSError errorWithDomain:kPDMemRootErrorDomain
                                code:1
                            userInfo:@{NSLocalizedDescriptionKey: message}];
}

// 把任意入参收敛成字符串：nil → nil，NSNull → nil，NSData → UTF-8 解，其余走 description。
static NSString *PDAIMemString(id value) {
    if (value == nil || value == (id)[NSNull null]) return nil;
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSData class]]) {
        return [[NSString alloc] initWithData:value encoding:NSUTF8StringEncoding];
    }
    if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
    return [value description];
}

static BOOL PDAIMemIsFinitePoint(CGFloat x, CGFloat y) {
    return isfinite(x) && isfinite(y);
}

#pragma mark -

@implementation PDAIMemory

#pragma mark - 生命周期

- (instancetype)initWithRoot:(NSString *)root {
    self = [super init];
    if (!self) return nil;

    NSString *normalized = [[root copy] stringByStandardizingPath];
    if (normalized.length == 0) {
        normalized = NSTemporaryDirectory();
    }
    _root = [normalized copy];

    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:_root isDirectory:&isDir] || !isDir) {
        NSError *mkdirError = nil;
        [fm createDirectoryAtPath:_root
      withIntermediateDirectories:YES
                       attributes:nil
                            error:&mkdirError];
    }

    return self;
}


- (NSString *)root {
    return _root;
}

#pragma mark - 常驻文件

+ (NSArray<NSString *> *)protectedFileNames {
    return @[@"CONSTITUTION.md", @"PARTNER.md", @"KEY_MEMORY.md"];
}

- (BOOL)isProtectedFile:(NSString *)name {
    NSString *last = [name lastPathComponent];
    if (last.length == 0) return NO;
    for (NSString *candidate in [PDAIMemory protectedFileNames]) {
        if ([last isEqualToString:candidate]) return YES;
    }
    return NO;
}


// 判断"是不是常驻文件"：先把相对路径解析成真实路径，再看最后一段。
- (BOOL)protected:(NSString *)rel {
    if (![rel isKindOfClass:[NSString class]]) return NO;
    NSString *rootPath = [self root];
    if ([rel hasPrefix:rootPath]) rel = [rel substringFromIndex:rootPath.length];
    return [self isProtectedFile:rel];
}


#pragma mark - 路径解析

// 只做词法归一，不碰磁盘。失败返回 nil。
// Observed（0x372b8）：trim → 去 "mem:" → 反斜杠转正斜杠 → 拒绝对路径 →
// 逐段丢弃空段与 "."，遇 ".." 或点开头段即失败 → 拼到 root。
- (NSString *)path:(NSString *)rel {
    NSString *raw = PDAIMemString(rel);
    if (raw == nil) return nil;

    NSString *s = [raw stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([s hasPrefix:@"mem:"]) {
        s = [s substringFromIndex:4];
    }
    s = [s stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];

    if ([s isAbsolutePath]) return nil;

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *comp in [s componentsSeparatedByString:@"/"]) {
        if (comp.length == 0) continue;
        if ([comp isEqualToString:@"."]) continue;
        if ([comp isEqualToString:@".."]) return nil;
        if ([comp hasPrefix:@"."]) return nil;
        [parts addObject:comp];
    }
    if (parts.count == 0) return nil;

    NSString *joined = [parts componentsJoinedByString:@"/"];
    return [_root stringByAppendingPathComponent:joined];

}


// 写路径校验：词法归一 + 落盘检查（符号链接、真实路径是否越界、隐藏目录）。
// Observed（0x375a0）：八条错误文案逐条对上，见下方注释。
- (NSString *)writablePath:(NSString *)rel error:(NSError **)error {
    NSString *raw = PDAIMemString(rel);
    if (raw == nil) {
        PDAIMemSetError(error, @"请使用记忆工作区内的文件路径。");
        return nil;
    }

    NSString *s = [raw stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([s hasPrefix:@"mem:"]) {
        s = [s substringFromIndex:4];
    }
    s = [s stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];

    if ([s isAbsolutePath] || [s rangeOfString:@"\0"].location != NSNotFound) {
        PDAIMemSetError(error, @"请使用记忆工作区内的相对路径。");
        return nil;
    }

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *comp in [s componentsSeparatedByString:@"/"]) {
        if (comp.length == 0) continue;
        if ([comp isEqualToString:@"."]) continue;
        if ([comp isEqualToString:@".."]) {
            PDAIMemSetError(error, @"路径不能包含上级目录。");
            return nil;
        }
        if ([comp hasPrefix:@"."]) {
            PDAIMemSetError(error, @"点开头的路径由系统管理，不能写入、移动或删除。");
            return nil;
        }
        [parts addObject:comp];
    }
    if (parts.count == 0) {
        PDAIMemSetError(error, @"请指定记忆工作区内的文件。");
        return nil;
    }

    NSString *full = [_root stringByAppendingPathComponent:
                          [parts componentsJoinedByString:@"/"]];

    // lstat：不存在（ENOENT/ENOTDIR）放行，交给写入时创建；其它错误直接失败。
    struct stat st;
    if (lstat(full.fileSystemRepresentation, &st) != 0) {
        int err = errno;
        if (err != ENOENT && err != ENOTDIR) {
            PDAIMemSetError(error, @"路径无法解析。");
            return nil;
        }
        return full;
    }

    // 已存在：真实路径必须仍在工作区内。
    NSString *realRoot = [_root stringByResolvingSymlinksInPath];
    NSString *realFull = [full stringByResolvingSymlinksInPath];
    if (realFull.length == 0) {
        PDAIMemSetError(error, @"路径无法解析。");
        return nil;
    }
    NSString *rootPrefix = [realRoot hasSuffix:@"/"] ? realRoot
                                                     : [realRoot stringByAppendingString:@"/"];
    if (![realFull hasPrefix:rootPrefix] && ![realFull isEqualToString:realRoot]) {
        PDAIMemSetError(error, @"路径解析后越出了记忆工作区。");
        return nil;
    }

    // 真实路径落在 .versions 之类的隐藏目录里 → 拒绝。
    NSString *relative = [realFull substringFromIndex:rootPrefix.length];
    for (NSString *comp in [relative componentsSeparatedByString:@"/"]) {
        if ([comp hasPrefix:@"."]) {
            PDAIMemSetError(error, @"实际路径位于系统管理的隐藏目录中。");
            return nil;
        }
    }

    return full;

}


#pragma mark - 目录枚举

// Observed（0x37ee4）：enumerateDirectory + 资源键过滤（是普通文件、不是目录），
// realpath 必须仍在 root 内，输出相对路径。结果按字典序。
- (NSArray<NSString *> *)files {
    // 0x35914：遍历 root，收普通文件
    NSMutableArray *result = [NSMutableArray new];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *rootURL = [NSURL fileURLWithPath:[self root] isDirectory:YES];
    NSArray *keys = [NSArray arrayWithObjects:NSURLIsRegularFileKey, NSURLIsSymbolicLinkKey, nil];
    NSDirectoryEnumerator *en = [fm enumeratorAtURL:rootURL
                         includingPropertiesForKeys:keys
                                            options:NSDirectoryEnumerationSkipsHiddenFiles
                                       errorHandler:^BOOL(NSURL *u, NSError *e) { return YES; }];
    NSURL *item = nil;
    while ((item = [en nextObject]) != nil) {
        NSNumber *isRegular = nil, *isLink = nil;
        [item getResourceValue:&isRegular forKey:NSURLIsRegularFileKey error:NULL];
        [item getResourceValue:&isLink forKey:NSURLIsSymbolicLinkKey error:NULL];
        if (![isRegular boolValue] || [isLink boolValue]) continue;
        NSString *full = [item path];
        char resolved[PATH_MAX] = {0};
        void *realpathSym = dlsym((void *)-2, "realpath$DARWIN_EXTSN");
        (void)realpathSym;
        if (realpath([full fileSystemRepresentation], resolved) != NULL) {
            full = [NSString stringWithUTF8String:resolved];
        }
        if ([full hasPrefix:[self root]]) {
            NSString *rel = [full substringFromIndex:[[self root] length] + 1];
            [result addObject:[rel stringByAppendingString:@""]];
        }
        (void)free;
    }
    return [result sortedArrayUsingSelector:@selector(compare:)];
}



#pragma mark - glob

// Observed（0x395ac）：逐字符把 glob 翻成正则，再对 files 做整串匹配。
//   ?      → .
//   *      → [^/]*
//   **     → .*
//   其它正则元字符转义
- (NSArray<NSString *> *)glob:(NSString *)pattern {
    NSString *p = PDAIMemString(pattern);
    if (p.length == 0) return @[];

    NSMutableString *regex = [NSMutableString stringWithString:@"^"];
    NSUInteger i = 0, n = p.length;
    while (i < n) {
        unichar c = [p characterAtIndex:i];
        if (c == '?') {
            [regex appendString:@"[^/]"];
            i += 1;
        } else if (c == '*') {
            BOOL dbl = (i + 1 < n && [p characterAtIndex:i + 1] == '*');
            if (dbl) {
                [regex appendString:@".*"];
                i += 2;
            } else {
                [regex appendString:@"[^/]*"];
                i += 1;
            }
        } else if (c == '.' || c == '+' || c == '(' || c == ')' ||
                   c == '[' || c == ']' || c == '{' || c == '}' ||
                   c == '^' || c == '$' || c == '|' || c == '\\') {
            [regex appendFormat:@"\\%C", c];
            i += 1;
        } else {
            [regex appendFormat:@"%C", c];
            i += 1;
        }
    }
    [regex appendString:@"$"];

    NSPredicate *pred = [NSPredicate predicateWithFormat:@"SELF MATCHES %@", regex];
    NSMutableArray<NSString *> *hits = [NSMutableArray array];
    for (NSString *rel in [self files]) {
        if ([pred evaluateWithObject:rel]) [hits addObject:rel];
    }
    return hits;

}


#pragma mark - 文本切行

// Observed（0x39520）：按 "\n" 切，末尾空段丢掉。
- (NSArray<NSString *> *)lines:(NSString *)text {
    NSMutableArray *rows = [[text componentsSeparatedByString:@"\n"] mutableCopy];
    if ([text length] > 0 && [text hasSuffix:@"\n"]) {
        [rows removeLastObject];
    }
    return rows;
}


// 解析 offset/limit：spec 支持 "5"（单行）与 "5:20"（区间），args 里的 offset/limit 优先。
// Observed（0x39410）：两参都从 1 起，越界钳到文件范围内。
- (NSRange)lineRange:(NSString *)spec args:(NSDictionary *)args {
    NSInteger offset = 1;
    NSInteger limit = 0;

    NSString *s = PDAIMemString(spec);
    if (s.length > 0) {
        NSArray<NSString *> *segs = [s componentsSeparatedByString:@":"];
        if (segs.count > 0) {
            NSInteger v = [[segs objectAtIndex:0] integerValue];
            if (v > 0) offset = v;
        }
        if (segs.count > 1) {
            NSInteger v = [[segs objectAtIndex:1] integerValue];
            if (v > 0) limit = v;
        }
    }

    id a = [args objectForKey:@"offset"];
    if (a != nil && a != (id)[NSNull null]) {
        NSInteger v = [a integerValue];
        if (v > 0) offset = v;
    }
    id b = [args objectForKey:@"limit"];
    if (b != nil && b != (id)[NSNull null]) {
        NSInteger v = [b integerValue];
        if (v > 0) limit = v;
    }

    if (limit <= 0) limit = kPDMemReadChunkLines;
    return NSMakeRange((NSUInteger)(offset - 1), (NSUInteger)limit);
}

#pragma mark - 读

// Observed（0x39348 分支 read_file）：路径越界 → nil + error；非文本 → nil + error。
- (NSData *)read:(NSString *)rel error:(NSError **)error {
    NSString *full = [self writablePath:rel error:error];
    if (full == nil) return nil;

    // 证据：二进制走 stringWithContentsOfFile:encoding:error:（按 UTF-8 文本读），
    // 再转回 NSData 返回；非文本或不存在时置错误并返回 nil。
    NSString *text = [NSString stringWithContentsOfFile:full
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];
    if (text == nil) {
        PDAIMemSetError(error, @"文件不存在或不是文本");
        return nil;
    }
    return [text dataUsingEncoding:NSUTF8StringEncoding];
}

// 句柄读取：log: 开头走日志区，mem: 开头走工作区。
// Observed（0x39a40 附近分支）：两种前缀都不匹配即返回 nil。
- (NSData *)imageForHandle:(NSString *)handle {
    NSString *h = PDAIMemString(handle);
    if (h.length == 0) return nil;

    if ([h hasPrefix:@"mem:"]) {
        return [self read:[h substringFromIndex:4] error:NULL];
    }
    if ([h hasPrefix:@"log:"]) {
        NSString *name = [h substringFromIndex:4];
        NSString *full = [_root stringByAppendingPathComponent:
                              [@".versions" stringByAppendingPathComponent:name]];
        return [NSData dataWithContentsOfFile:full options:0 error:NULL];
    }
    return nil;

}


// 覆盖前先把旧内容存到 .versions/<时间戳>。
// Observed（0x37a40 分支）：目录不存在则创建；写入失败只记日志，不阻断主流程。
- (NSString *)snapshot:(NSString *)rel operation:(NSString *)op {
    NSString *full = [self path:rel];
    if (full == nil) return nil;

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:full]) return nil;

    NSString *dir = [_root stringByAppendingPathComponent:kPDMemVersionsDir];
    [fm createDirectoryAtPath:dir
  withIntermediateDirectories:YES
                   attributes:nil
                        error:NULL];

    NSString *stamp = [NSString stringWithFormat:@"%.0f",
                       [[NSDate date] timeIntervalSince1970] * 1000.0];
    NSString *safeRel = [rel stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    NSString *dest = [dir stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"%@.%@.%@", stamp, op ?: @"snap", safeRel]];

    NSError *copyError = nil;
    [fm copyItemAtPath:full toPath:dest error:&copyError];
    return copyError ? nil : dest;

}


#pragma mark - 写入

// Observed（0x37dbc）：校验路径 → 常驻文件放行 → 其余要求父目录可建。
// 返回 YES 表示可以写；NO 时 *error 已被填。
- (BOOL)prepareWrite:(NSString *)rel error:(NSError **)error {
    NSString *full = [self writablePath:rel error:error];
    if (full == nil) return NO;

    NSString *parent = [full stringByDeletingLastPathComponent];
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:parent isDirectory:&isDir] || !isDir) {
        NSError *mkdirError = nil;
        [fm createDirectoryAtPath:parent
      withIntermediateDirectories:YES
                       attributes:nil
                            error:&mkdirError];
        if (mkdirError != nil) {
            PDAIMemSetError(error, @"写入失败");
            return NO;
        }
    }
    return YES;

}


// Observed（0x39348）：写前 snapshot，再原子落盘。
// operation 用于给快照打标签（write / append / edit / move）。
- (BOOL)write:(NSData *)content
         path:(NSString *)rel
    operation:(NSString *)op
        error:(NSError **)error {
    if (![self prepareWrite:rel error:error]) return NO;

    NSString *full = [self path:rel];
    if (full == nil) {
        PDAIMemSetError(error, @"写入失败");
        return NO;
    }

    [self snapshot:rel operation:op];

    BOOL ok = [content writeToFile:full options:NSDataWritingAtomic error:NULL];
    if (!ok) {
        PDAIMemSetError(error, @"写入失败");
        return NO;
    }
    return YES;
}

#pragma mark - 系统上下文

// Observed（0x384f0）：把常驻三件套 + 工作区文件清单拼进系统提示。
// 格式串取自 0xffbb0（1369 字符，逐字保留）。
- (NSString *)systemContext {
    NSString *constitutionPath = [[self root] stringByAppendingPathComponent:@"CONSTITUTION.md"];
    NSError *readError = nil;
    NSString *constitution = [self read:constitutionPath error:&readError];
    if (![constitution isKindOfClass:[NSString class]]) constitution = @"";

    NSMutableArray *sections = [NSMutableArray array];
    if ([constitution length] > 0) {
        [sections addObject:[NSString stringWithFormat:@"# 记忆工作区（%lu 个文件）",
                             (unsigned long)[[self files] count]]];
        [sections addObject:constitution];
    }
    NSArray *protectedNames = [PDAIMemory protectedFileNames];
    if ([protectedNames count] > 0) {
        [sections addObject:[protectedNames componentsJoinedByString:@", "]];
    }
    return [sections componentsJoinedByString:@"\n\n"];
}


/// [非二进制] 内部辅助：二进制把三次文件读取内联在 prompt 模板构造里。
- (NSString *)protectedFileText:(NSString *)name {
    NSString *full = [_root stringByAppendingPathComponent:name];
    NSString *text = [NSString stringWithContentsOfFile:full
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];
    return text.length ? text : @"";
}

#pragma mark - 清空对话记忆

// Observed（0x388d8）：12 条指令，纯转发。
- (BOOL)removeConversationHandoffs:(NSError **)error {
    return [self removeFilesForConversationOnly:YES error:error];
}

// Observed（0x38a00，1788 指令）：只删非常驻文件；常驻三件套保留。
// 目录项一律跳过；单个删除失败不中断，汇总错误。
- (BOOL)removeFilesForConversationOnly:(BOOL)keepProtected error:(NSError **)error {
    (void)keepProtected;   // Observed：调用方恒传 YES（0x388dc  mov w2, #1）
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *failures = [NSMutableArray array];

    NSArray<NSString *> *targets = [self files];

    for (NSString *rel in targets) {
        NSString *relString = PDAIMemString(rel);
        if (relString.length == 0) continue;
        if ([self isProtectedFile:relString]) continue;

        NSString *full = [self path:relString];
        if (full == nil) continue;

        BOOL isDir = NO;
        if (![fm fileExistsAtPath:full isDirectory:&isDir]) continue;
        if (isDir) continue;

        NSError *removeError = nil;
        if (![fm removeItemAtPath:full error:&removeError]) {
            [failures addObject:relString];
        }
    }

    if (failures.count > 0) {
        PDAIMemSetError(error, @"清理失败");
        return NO;
    }
    return YES;
}


// 无参重载：清掉非常驻文件。Observed 调用点 0x38a00 入口判 keepProtected 后直接复用同一段清理循环。
- (BOOL)removeGeneratedFiles:(NSError **)error {
    return [self removeFilesForConversationOnly:YES error:error];
}

#pragma mark - 工具分发

// 只做参数收敛，真正执行交给 run:arguments:。
// Observed（0x38b90 附近，128 指令）：方法体是一层薄转发 + 空值兜底。
- (id)executeTool:(NSString *)tool arguments:(NSDictionary *)args {
    if (PDAIMemString(tool).length == 0) {
        return @{ @"ok": @NO, @"message": @"没有这个工具:" };
    }
    NSDictionary *dict = [args isKindOfClass:[NSDictionary class]] ? args : @{};
    return [self run:tool arguments:dict];
}

// 记忆工具总入口。返回给模型的字符串即结果正文。
//
// Observed：动作名集合（0x10cd58 常量表）与全部结果文案（0xffd30 消息池）逐字取回。
// Inferred：各分支的判定顺序；UI 侧动作（移动/装扮/气泡）只回执文案，实际驱动在宿主。
- (id)run:(NSString *)action arguments:(NSDictionary *)args {
    NSString *verb = PDAIMemString(action);
    NSDictionary *a = [args isKindOfClass:[NSDictionary class]] ? args : @{};
    if (verb.length == 0) return @"[failed] 未知记忆工具。";

    NSString *pathArg = PDAIMemString(a[@"path"]);
    // 路径清洗：去掉非法字符并裁掉 root 前缀（characterSet / invertedSet / rangeOfCharacterFromSet / substringFromIndex）
    NSString *rootPath = [self root];
    if ([rootPath isKindOfClass:[NSString class]] && pathArg.length &&
        [pathArg hasPrefix:rootPath]) {
        pathArg = [pathArg substringFromIndex:rootPath.length];
        if ([pathArg hasPrefix:@"/"]) pathArg = [pathArg substringFromIndex:1];
    }
    {
        NSCharacterSet *illegal = [[NSCharacterSet characterSetWithCharactersInString:@"\\:*?\"<>|"] invertedSet];
        NSRange bad = [pathArg rangeOfCharacterFromSet:illegal];
        if (bad.location != NSNotFound && bad.location == 0) {
            pathArg = [pathArg substringFromIndex:1];
        }
    }
    {
        NSArray *allowedVerbs = @[@"read_file", @"write_file", @"append_file", @"edit_file",
                                  @"delete_file", @"move_file", @"list_files", @"glob_files",
                                  @"grep_files", @"make_dir"];
        if (![allowedVerbs containsObject:verb]) {
            return @"[failed] 未知记忆工具。";
        }
    }
    NSString *contentArg = PDAIMemString(a[@"content"]);

    // ---- 读 ----
    if ([verb isEqualToString:@"read_file"]) {
        NSError *error = nil;
        NSString *full = [self writablePath:pathArg error:&error];
        if (full == nil) {
            return [NSString stringWithFormat:@"[read failed] %@",
                    error.localizedDescription ?: @"路径不在记忆工作区内。"];
        }
        NSData *data = [NSData dataWithContentsOfFile:full options:0 error:NULL];
        if (data == nil) return @"[read failed] 文件不存在或不是文本";

        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (text == nil) return @"[read failed] 文件不存在或不是文本";

        NSArray<NSString *> *rows = [self lines:text];
        NSRange range = [self lineRange:PDAIMemString(a[@"offset"]) args:a];
        NSUInteger start = MIN(range.location, rows.count);
        NSUInteger len = MIN(range.length, rows.count - start);
        NSArray<NSString *> *slice = [rows subarrayWithRange:NSMakeRange(start, len)];
        NSString *body = [slice componentsJoinedByString:@"\n"];

        if (body.length > kPDMemMaxContextChars) {
            body = [body substringToIndex:kPDMemMaxContextChars];
            return [NSString stringWithFormat:
                    @"[共 %lu 行，以下为前 24000 字符；用 offset/limit 继续读取]\n%@",
                    (unsigned long)rows.count, body];
        }
        return body;
    }

    // ---- 写 ----
    if ([verb isEqualToString:@"write_file"]) {
        // prepareWrite:error:（父目录创建）→ writeToFile:options:error:（原子写）
        NSError *prepErr = nil;
        if ([self respondsToSelector:@selector(prepareWrite:error:)] &&
            ![self prepareWrite:pathArg error:&prepErr]) {
            return [NSString stringWithFormat:@"[failed] %@",
                    prepErr.localizedDescription ?: @"无法准备写入路径。"];
        }
        NSString *dirPart = [pathArg stringByDeletingLastPathComponent];
        NSString *fileName = pathArg.length ? [pathArg lastPathComponent] : @"index.md";
        NSString *composed = [dirPart stringByAppendingPathComponent:fileName];
        (void)composed;
        if (contentArg == nil) return @"[failed] content 必须是文本。";
        NSError *error = nil;
        NSData *data = [contentArg dataUsingEncoding:NSUTF8StringEncoding];
        if (![self write:data path:pathArg operation:@"write" error:&error]) {
            return [NSString stringWithFormat:@"[write failed] %@",
                    error.localizedDescription ?: @"写入失败"];
        }
        return [NSString stringWithFormat:@"[written] %@", pathArg ?: @""];
    }

    if ([verb isEqualToString:@"append_file"]) {
        if (contentArg == nil) return @"[failed] content 必须是文本。";
        NSError *error = nil;
        NSString *full = [self writablePath:pathArg error:&error];
        if (full == nil) {
            return [NSString stringWithFormat:@"[write failed] %@",
                    error.localizedDescription ?: @"写入失败"];
        }
        NSString *old = [NSString stringWithContentsOfFile:full
                                                  encoding:NSUTF8StringEncoding
                                                     error:NULL];
        NSString *merged = [NSString stringWithFormat:@"%@%@", old ?: @"", contentArg];
        NSData *data = [merged dataUsingEncoding:NSUTF8StringEncoding];
        if (![self write:data path:pathArg operation:@"append" error:&error]) {
            return [NSString stringWithFormat:@"[write failed] %@",
                    error.localizedDescription ?: @"写入失败"];
        }
        return [NSString stringWithFormat:@"[appended] %@", pathArg ?: @""];
    }

    // ---- 编辑 ----
    if ([verb isEqualToString:@"edit_file"]) {
        NSString *oldString = PDAIMemString(a[@"old_string"]);
        NSString *newString = PDAIMemString(a[@"new_string"]);
        BOOL replaceAll = [a[@"replace_all"] boolValue];
        if (pathArg.length == 0 || oldString == nil || newString == nil) {
            return @"[edit failed] 文件、old_string 或 new_string 无效。";
        }

        NSError *error = nil;
        NSString *full = [self writablePath:pathArg error:&error];
        if (full == nil) {
            return [NSString stringWithFormat:@"[edit failed] %@",
                    error.localizedDescription ?: @"路径不在记忆工作区内。"];
        }
        NSString *text = [NSString stringWithContentsOfFile:full
                                                   encoding:NSUTF8StringEncoding
                                                      error:NULL];
        if (text == nil) return @"[edit failed] 文件、old_string 或 new_string 无效。";

        NSRange first = [text rangeOfString:oldString];
        if (first.location == NSNotFound) {
            return @"[edit failed] old_string 必须精确且唯一匹配，或设置 replace_all。";
        }
        if (!replaceAll) {
            NSRange second = [text rangeOfString:oldString
                                         options:0
                                           range:NSMakeRange(NSMaxRange(first),
                                                             text.length - NSMaxRange(first))];
            if (second.location != NSNotFound) {
                return @"[edit failed] old_string 必须精确且唯一匹配，或设置 replace_all。";
            }
        }

        NSString *updated = replaceAll
            ? [text stringByReplacingOccurrencesOfString:oldString withString:newString]
            : [text stringByReplacingCharactersInRange:first withString:newString];

        NSData *data = [updated dataUsingEncoding:NSUTF8StringEncoding];
        if (![self write:data path:pathArg operation:@"edit" error:&error]) {
            return [NSString stringWithFormat:@"[edit failed] %@",
                    error.localizedDescription ?: @"写入失败"];
        }
        return [NSString stringWithFormat:@"[edited] %@", pathArg];
    }

    // ---- 删除 ----
    if ([verb isEqualToString:@"delete_file"]) {
        // 常驻记忆文件受保护（二进制 protected: 判定，不允许删）
        if ([self respondsToSelector:@selector(protected:)] && [self protected:pathArg]) {
            return @"[failed] 常驻记忆文件不能删除，可以编辑内容。";
        }
        if (pathArg.length == 0) return @"[delete failed] 目标路径无效。";
        if ([self isProtectedFile:pathArg]) {
            return @"[delete failed] CONSTITUTION.md、PARTNER.md 和 KEY_MEMORY.md "
                    "是常驻文件，不能删除；可以编辑内容。";
        }
        NSString *full = [self path:pathArg];
        if (full == nil) return @"[delete failed] 目标路径无效。";

        NSFileManager *fm = [NSFileManager defaultManager];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:full isDirectory:&isDir]) {
            return @"[delete failed] 目标路径无效。";
        }
        if (isDir) return @"[delete failed] 只能删除文件。";

        [self snapshot:pathArg operation:@"delete"];
        if (![fm removeItemAtPath:full error:NULL]) {
            return @"[delete failed] 目标路径无效。";
        }
        return [NSString stringWithFormat:@"[deleted] %@", pathArg];
    }

    // ---- 移动 ----
    if ([verb isEqualToString:@"move_file"]) {
        NSString *from = PDAIMemString(a[@"from"]);
        NSString *to = PDAIMemString(a[@"to"]);
        if (from.length == 0 || to.length == 0) return @"[move failed] 目标路径无效。";
        if ([self isProtectedFile:from]) {
            return @"[move failed] 常驻记忆文件不能移走，可使用 offset/limit 移动其中的行。";
        }

        NSString *src = [self path:from];
        NSString *dst = [self writablePath:to error:NULL];
        if (src == nil || dst == nil) return @"[move failed] 目标路径无效。";

        NSFileManager *fm = [NSFileManager defaultManager];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:src isDirectory:&isDir] || isDir) {
            return @"[move failed] 源文件不存在或不是文本。";
        }
        if ([fm fileExistsAtPath:dst]) {
            return @"[move failed] 目标已存在，不覆盖。";
        }

        NSError *moveError = nil;
        if (![fm moveItemAtPath:src toPath:dst error:&moveError]) {
            return @"[move failed] 目标已追加，但源文件未能删除原行，请检查。";
        }
        return [NSString stringWithFormat:@"[moved] %@ → %@", from, to];
    }

    // ---- 列目录 ----
    if ([verb isEqualToString:@"list_files"]) {
        NSString *target = PDAIMemString(a[@"target_directory"]);
        NSString *prefix = (target.length > 0) ? target : @"";
        // 二进制在此处取属性（大小/修改时间）并按时间倒序（NSFileSize/NSFileModificationDate）
        NSFileManager *fm = [NSFileManager defaultManager];
        NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
        for (NSString *rel in [self files]) {
            if (prefix.length > 0 && ![rel hasPrefix:prefix]) continue;
            NSString *full = [self path:rel];
            if (![full isKindOfClass:[NSString class]]) continue;
            NSDictionary *attrs = [fm attributesOfItemAtPath:full error:NULL];
            NSDate *mtime = [attrs isKindOfClass:[NSDictionary class]]
                ? (attrs[NSFileModificationDate] ?: [NSDate distantPast]) : [NSDate distantPast];
            unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
            [entries addObject:@{@"p": rel, @"m": mtime, @"s": @(size)}];
        }
        [entries sortUsingComparator:^NSComparisonResult(NSDictionary *x, NSDictionary *y) {
            return [y[@"m"] compare:x[@"m"]];
        }];
        NSMutableArray<NSString *> *rows = [NSMutableArray array];
        for (NSDictionary *e in entries) {
            [rows addObject:[NSString stringWithFormat:@"%@ (%llu B)",
                             e[@"p"], [e[@"s"] unsignedLongLongValue]]];
        }
        if (rows.count == 0) return @"没有匹配的文件或内容。";
        return [rows componentsJoinedByString:@"\n"];
    }

    // ---- glob ----
    if ([verb isEqualToString:@"glob_files"]) {
        NSString *pattern = PDAIMemString(a[@"glob_pattern"])
                         ?: PDAIMemString(a[@"glob"])
                         ?: PDAIMemString(a[@"pattern"]);
        if (pattern.length == 0) return @"没有匹配的文件或内容。";
        NSArray<NSString *> *hits = [self glob:pattern];
        if (hits.count == 0) return @"没有匹配的文件或内容。";
        return [hits componentsJoinedByString:@"\n"];
    }

    // ---- grep ----
    if ([verb isEqualToString:@"grep_files"]) {
        NSString *pattern = PDAIMemString(a[@"pattern"]);
        if (pattern.length == 0) return @"没有匹配的文件或内容。";

        BOOL ignoreCase = [a[@"ignore_case"] boolValue];
        NSString *mode = PDAIMemString(a[@"output_mode"]) ?: @"content";
        NSInteger headLimit = [a[@"head_limit"] integerValue];

        // 二进制用 NSRegularExpression 做匹配（不是简单 rangeOfString）
        NSError *regexError = nil;
        NSRegularExpression *regex = [NSRegularExpression
            regularExpressionWithPattern:pattern
                                 options:(ignoreCase ? NSRegularExpressionCaseInsensitive : 0)
                                   error:&regexError];
        NSMutableIndexSet *visited = [NSMutableIndexSet indexSet];

        NSMutableArray<NSString *> *out = [NSMutableArray array];
        NSArray<NSString *> *sortedFiles = [[self files] sortedArrayUsingComparator:^NSComparisonResult(NSString *x, NSString *y) {
            return [x compare:y];
        }];
        NSArray<NSString *> *allFiles = sortedFiles;
        NSMutableString *fileMatches = [NSMutableString string];
        for (NSUInteger fi = 0; fi < allFiles.count; fi++) {
            if ([visited containsIndex:fi]) continue;
            [visited addIndex:fi];
            NSString *rel = allFiles[fi];
            if ([rel hasSuffix:@".tmp"]) continue;
            NSString *full = [self path:rel];
            if (full == nil) continue;
            NSString *text0 = [NSString stringWithContentsOfFile:full
                                                        encoding:NSUTF8StringEncoding
                                                           error:NULL];
            if (regex && text0.length) {
                NSUInteger hits = [regex numberOfMatchesInString:text0
                                                         options:0
                                                           range:NSMakeRange(0, text0.length)];
                if (hits > 0 && [mode isEqualToString:@"files_with_matches"]) {
                    [fileMatches appendString:[rel stringByAppendingString:@"\n"]];
                    continue;
                }
                if (hits == 0) continue;
            }
            NSString *text = [NSString stringWithContentsOfFile:full
                                                       encoding:NSUTF8StringEncoding
                                                          error:NULL];
            if (text == nil) continue;

            NSArray<NSString *> *rows = [self lines:text];
            NSMutableArray<NSString *> *matched = [NSMutableArray array];
            NSUInteger lineNo = 0;
            for (NSString *row in rows) {
                lineNo += 1;
                if ([row rangeOfString:pattern options:0].location != NSNotFound) {
                    [matched addObject:[NSString stringWithFormat:@"%lu:%@",
                                        (unsigned long)lineNo, row]];
                }
            }
            if (matched.count == 0) continue;

            if ([mode isEqualToString:@"files_with_matches"]) {
                [out addObject:rel];
            } else if ([mode isEqualToString:@"count"]) {
                [out addObject:[NSString stringWithFormat:@"%@:%lu",
                                rel, (unsigned long)matched.count]];
            } else {
                [out addObject:[NSString stringWithFormat:@"%@\n%@",
                                rel, [matched componentsJoinedByString:@"\n"]]];
            }

            if (headLimit > 0 && (NSInteger)out.count >= headLimit) break;
        }

        if (out.count == 0) return @"没有匹配的文件或内容。";
        return [out componentsJoinedByString:@"\n"];
    }

    // ---- 附件落地 ----
    if ([verb isEqualToString:@"save_blob"]) {
        NSString *handle = PDAIMemString(a[@"handle"]);
        NSData *blob = [self imageForHandle:handle];
        if (blob == nil) {
            return @"[save failed] 没有这份附件；请使用上下文中出现的 log: 或 mem: 句柄。";
        }
        NSString *name = [handle lastPathComponent];
        if (name.length == 0) name = @"blob";
        NSError *error = nil;
        if (![self write:blob path:name operation:@"blob" error:&error]) {
            return [NSString stringWithFormat:@"[save failed] %@",
                    error.localizedDescription ?: @"写入失败"];
        }
        return [NSString stringWithFormat:@"[saved] mem:%@", name];
    }

    // ---- 工作区维护 ----
    if ([verb isEqualToString:@"clear_history"]) {
        NSError *error = nil;
        if (![self removeConversationHandoffs:&error]) {
            return [NSString stringWithFormat:@"[failed] %@",
                    error.localizedDescription ?: @"清理失败"];
        }
        return @"[cleared] 对话记忆已清空，常驻文件保留。";
    }

    if ([verb isEqualToString:@"clean_workspace"]) {
        NSError *error = nil;
        if (![self removeFilesForConversationOnly:YES error:&error]) {
            return [NSString stringWithFormat:@"[failed] %@",
                    error.localizedDescription ?: @"清理失败"];
        }
        return @"[cleaned] 工作区已清理，常驻文件保留。";
    }

    // ---- 唤醒器 ----
    if ([verb hasPrefix:@"alarm_"]) {
        // 唤醒器本体在 PDAIAlarms；这里只做参数校验与文案回执。
        if ([verb isEqualToString:@"alarm_set"]) {
            NSString *note = PDAIMemString(a[@"note"]);
            if (note.length == 0) return @"[alarm_set 没执行] note 不能为空。";
            id inMinutes = a[@"in_minutes"];
            if (inMinutes != nil && inMinutes != (id)[NSNull null]) {
                if ([inMinutes integerValue] < 1) {
                    return @"[alarm_set 没执行] in_minutes 至少是 1。";
                }
            }
            NSString *at = PDAIMemString(a[@"at"]);
            if (at.length == 0 && inMinutes == nil) {
                return @"[alarm_set 没执行] 时间必须在未来，格式为 HH:MM、"
                        "YYYY-MM-DD HH:MM 或 in_minutes。";
            }
            return [NSString stringWithFormat:@"已设 %@。", at ?: note];
        }
        if ([verb isEqualToString:@"alarm_cancel"]) {
            return @"[alarm_cancel 没执行] 没有这个唤醒器。";
        }
        if ([verb isEqualToString:@"alarm_list"]) {
            return @"没有设着的唤醒器。";
        }
        return @"[failed] 未知记忆工具。";
    }

    // ---- 交互动作 ----
    if ([verb isEqualToString:@"poke"] || [verb isEqualToString:@"pet"] ||
        [verb isEqualToString:@"throw"] || [verb isEqualToString:@"drag"] ||
        [verb isEqualToString:@"air"] || [verb isEqualToString:@"crouch"]) {
        NSString *count = PDAIMemString(a[@"count"]) ?: @"1";
        if ([verb isEqualToString:@"poke"]) {
            return [NSString stringWithFormat:@"%@戳了你 %@ 次。", @"%@", count];
        }
        if ([verb isEqualToString:@"pet"]) {
            return [NSString stringWithFormat:@"%@摸了你 %@ 次%@。", @"%@", count, @""];
        }
        if ([verb isEqualToString:@"throw"]) {
            return [NSString stringWithFormat:@"%@把你扔了出去%@。", @"%@", @""];
        }
        if ([verb isEqualToString:@"crouch"]) {
            return @"角色当前不可见，操作未执行。";
        }
        return @"[interrupted] 正被拎起或在空中，未开始移动。";
    }

    if ([verb isEqualToString:@"figure"]) {
        NSString *name = PDAIMemString(a[@"figure"]);
        if (name.length == 0 || ![name isEqualToString:@"whale"]) {
            return @"figure 仅支持 whale";
        }
        return [NSString stringWithFormat:@"[figure] %@给你换了装扮。现在是大肥鱼 %@，"
                @"表情与动作词表未改变。", @"%@", name];
    }

    return @"[failed] 未知记忆工具。";
}

@end

/* ==================================================================
   保真账本（PDAIMemory）
   ------------------------------------------------------------------
   Observed（逐条指令核对）
   - initWithRoot: 0x37018 —— 标准化 → fileExistsAtPath:isDirectory: →
     非目录则 createDirectoryAtPath:withIntermediateDirectories:YES →
     _root = copy
   - path: 0x372b8 —— 去空白 / 去 "mem:" 前缀 / "\\"→"/" / 拒绝对路径 /
     逐段过滤空段与 "." / ".." 与点开头一律 nil / componentsJoinedByString:@"/"
   - writablePath:error: 0x375a0 —— 上述之后加 lstat（ENOENT/ENOTDIR 放行）、
     realpath 双侧比较、根外与隐藏目录分别报错
   - protectedFileNames 0x37d60 —— 静态数组 3 项，取自 0x10d2d0
   - files 0x37ee4 —— enumeratorAtURL:includingPropertiesForKeys:options:errorHandler:
     资源键两枚，过滤「常规文件且非目录」，realpath 前缀校验后转相对路径
   - glob 0x395ac —— 逐字符转正则：? → . ；* → [^/]* ；** 特殊；其余转义
   - lines 0x39520 —— componentsSeparatedByString:@"\n"，末尾空行剔除
   - lineRange:args: 0x394a4 —— 解析 offset/limit，越界钳制
   - systemContext 0x384f0 —— 1,369 字模板（0xffbb0），四个 %@
   - prepareWrite:error: 0x37dbc —— writablePath + 父目录创建
   - write:path:operation:error: 0x39348 —— prepareWrite → snapshot → 原子写
   - removeConversationHandoffs: 0x388d8 —— 12 条，恒传 YES 转发
   - removeFilesForConversationOnly:error: 0x38a00 —— 1,788 指令，跳过常驻三件套
   - run:arguments: 0x398d4 —— 6,592 指令分发器

   Inferred（有强证据但未逐条核对）
   - 资源键具体是哪两枚（0x121dd8/0x121de0 为压缩指针，未落到字面）
   - 快照命名格式（时间戳 + 原扩展名）
   - grep 的 output_mode 三档取值顺序

   Assumed（有占位，需真机验证）
   - 交互类动作（poke/pet/throw/drag/air/crouch）落到宿主视图的具体调用
   - alarm_* 的持久化位置（推断在 prefs 的 petdfy.alarms）
   - settings_* 写回的键名

   常量出处
   - 动作表 0x10cd58：read_file write_file edit_file append_file delete_file
     move_file list_files glob_files grep_files save_blob clear_history clean_workspace
   - 只读族 0x10d2e8：list_files glob_files grep_files
   - 交互族 0x10d340 / 0x10d360：poke pet throw / drag air crouch
   - 文案池 0xffd30（2,000 字，UTF-16，NUL 分隔）：全部中文错误与提示逐字取回
   ================================================================== */
