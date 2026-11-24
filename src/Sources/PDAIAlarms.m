//
//  PDAIAlarms.m — 逆向还原实现（可运行）
//
//  还原依据：PetDFY.dylib arm64e 切片反汇编（/tmp/alarms.txt）
//  类：PDAIAlarms（AI 定时提醒）
//
//  数据结构（来自 ivar_list）：
//    _file   NSString *        闹钟 JSON 文件路径
//    _alarms NSMutableArray *  闹钟条目数组
//    _next   unsigned long long 下一个序号
//
//  条目格式（从 save / list / executeTool 反推）：
//    { "at": <unix 时间戳 double>, "text": <提醒文本>, "id": <序号> }
//

#import "PDAIAlarms.h"

@implementation PDAIAlarms

#pragma mark - 初始化

- (instancetype)initWithFile:(NSString *)file {
    self = [super init];
    if (!self) return nil;
    _file = [file copy];
    _alarms = [NSMutableArray array];
    _next = 1;

    // 从磁盘加载已保存的闹钟
    if (_file.length) {
        NSData *data = [NSData dataWithContentsOfFile:_file];
        if (data.length) {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            if ([json isKindOfClass:[NSArray class]]) {
                [_alarms addObjectsFromArray:(NSArray *)json];
                // 恢复序号：取现有最大 id + 1
                for (NSDictionary *item in _alarms) {
                    if (![item isKindOfClass:[NSDictionary class]]) continue;
                    unsigned long long v = [item[@"id"] unsignedLongLongValue];
                    if (v >= _next) _next = v + 1;
                }
            }
        }
    }
    return self;
}

#pragma mark - 持久化

- (BOOL)save {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *path = [self file];
    if (![path isKindOfClass:[NSString class]]) return NO;

    [fm createDirectoryAtPath:[path stringByDeletingLastPathComponent]
  withIntermediateDirectories:YES
                   attributes:nil
                        error:NULL];

    NSDictionary *payload = @{ @"next": @([self next]),
                               @"items": [self alarms] ?: @[] };
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
    if (json) [json writeToFile:path options:NSDataWritingAtomic error:NULL];
    return YES;
}


#pragma mark - 查询

- (NSArray *)list {
    // 证据：二进制返回前做了 sortedArrayUsingComparator:（按 at 升序）
    NSArray *snapshot = [_alarms copy];
    if (![snapshot isKindOfClass:[NSArray class]]) return @[];
    return [snapshot sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        double ta = [a isKindOfClass:[NSDictionary class]] ? [a[@"at"] doubleValue] : 0.0;
        double tb = [b isKindOfClass:[NSDictionary class]] ? [b[@"at"] doubleValue] : 0.0;
        if (ta < tb) return NSOrderedAscending;
        if (ta > tb) return NSOrderedDescending;
        return NSOrderedSame;
    }];
}

- (NSString *)label:(NSDictionary *)item {
    if (![item isKindOfClass:[NSDictionary class]]) return @"";
    NSString *text = item[@"text"];
    if (![text isKindOfClass:[NSString class]]) text = @"";
    double at = [item[@"at"] doubleValue];
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:at];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"MM-dd HH:mm";
    return [NSString stringWithFormat:@"%@ · %@", [fmt stringFromDate:date], text];
}


#pragma mark - 时间推算（核心）

/// 求 now 之后、符合 HH:mm 的最近时刻。
/// 反汇编对应：取 components 的 hour/minute，逐级比较进位。
- (NSDate *)nextClock:(NSDate *)now after:(NSString *)hhmm {
    if (![hhmm isKindOfClass:[NSString class]] || hhmm.length == 0) return nil;
    if (![now isKindOfClass:[NSDate class]]) now = [NSDate date];

    NSArray<NSString *> *parts = [hhmm componentsSeparatedByString:@":"];
    if (parts.count < 2) return nil;
    NSInteger hour = [parts[0] integerValue];
    NSInteger minute = [parts[1] integerValue];
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return nil;

    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *comp = [cal components:(NSCalendarUnitYear | NSCalendarUnitMonth |
                                             NSCalendarUnitDay | NSCalendarUnitHour |
                                             NSCalendarUnitMinute | NSCalendarUnitSecond)
                                    fromDate:now];
    comp.hour = hour;
    comp.minute = minute;
    comp.second = 0;

    NSDate *candidate = [cal dateFromComponents:comp];
    // 如果今天的该时刻已过，顺延到明天（反汇编里是 +86400 的等价逻辑）
    if ([candidate timeIntervalSinceDate:now] <= 0) {
        candidate = [candidate dateByAddingTimeInterval:24 * 60 * 60];
    }
    return candidate;
}

#pragma mark - 到期取出

/// 取出所有已到期（at <= now）的条目并从列表移除。
- (NSArray *)takeDue:(NSDate *)now {
    if (![now isKindOfClass:[NSDate class]]) now = [NSDate date];
    double ts = [now timeIntervalSince1970];

    NSMutableArray *due = [NSMutableArray array];
    NSMutableArray *keep = [NSMutableArray array];
    for (NSDictionary *item in _alarms) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        double at = [item[@"at"] doubleValue];
        if (at > 0 && at <= ts) [due addObject:item];
        else [keep addObject:item];
    }
    if (due.count) {
        [_alarms setArray:keep];
        [self save];
    }
    return due;
}


#pragma mark - 工具入口（供 AI 调用）

/// 支持的动作：
///   add    {"at":"2026-11-19 08:00","text":"起床"}   添加
///   list   {}                                        列出
///   remove {"id":3}                                   删除
///   clear  {}                                         清空
- (id)executeTool:(NSString *)tool arguments:(NSDictionary *)args {
    if (![tool isKindOfClass:[NSString class]]) return nil;
    if (![args isKindOfClass:[NSDictionary class]]) args = @{};

    if ([tool isEqualToString:@"list"]) {
        NSMutableArray *out = [NSMutableArray array];
        for (NSDictionary *item in _alarms) {
            [out addObject:@{@"id": item[@"id"] ?: @0,
                             @"at": item[@"at"] ?: @0,
                             @"text": item[@"text"] ?: @"",
                             @"label": [self label:item]}];
        }
        return @{@"alarms": out, @"count": @(out.count)};
    }

    if ([tool isEqualToString:@"add"]) {
        NSString *text = args[@"text"];
        if (![text isKindOfClass:[NSString class]]) text = @"";
        text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

        NSDate *when = nil;
        id at = args[@"at"];
        if ([at isKindOfClass:[NSNumber class]]) {
            when = [NSDate dateWithTimeIntervalSince1970:[at doubleValue]];
        } else if ([at isKindOfClass:[NSString class]]) {
            NSString *s = [at stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
            fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            // 依次尝试几种常见格式
            for (NSString *pattern in @[@"yyyy-MM-dd HH:mm:ss", @"yyyy-MM-dd HH:mm", @"HH:mm"]) {
                fmt.dateFormat = pattern;
                when = [fmt dateFromString:s];
                if (when) break;
            }
            // 只给了 HH:mm 的情况：推算最近的下一次
            if (!when && [s rangeOfString:@":"].location != NSNotFound && s.length <= 5) {
                when = [self nextClock:[NSDate date] after:s];
            }
        }
        if (!when) return @{@"ok": @NO, @"error": @"时间格式无法识别"};

        unsigned long long ident = _next++;
        NSDictionary *item = @{@"id": @(ident),
                               @"at": @([when timeIntervalSince1970]),
                               @"text": text};
        [_alarms addObject:item];
        [self save];
        return @{@"ok": @YES, @"id": @(ident), @"label": [self label:item]};
    }

    if ([tool isEqualToString:@"remove"]) {
        unsigned long long ident = [args[@"id"] unsignedLongLongValue];
        NSMutableArray *keep = [NSMutableArray array];
        BOOL found = NO;
        for (NSDictionary *item in _alarms) {
            if ([item[@"id"] unsignedLongLongValue] == ident) { found = YES; continue; }
            [keep addObject:item];
        }
        if (found) { [_alarms setArray:keep]; [self save]; }
        return @{@"ok": @(found)};
    }

    if ([tool isEqualToString:@"clear"]) {
        [_alarms removeAllObjects];
        [self save];
        return @{@"ok": @YES};
    }

    return @{@"ok": @NO, @"error": @"未知动作"};

    NSString *rawTime = [args isKindOfClass:[NSDictionary class]] ? args[@"time"] : nil;
    if ([rawTime isKindOfClass:[NSString class]]) {
        NSString *cleaned = [rawTime stringByReplacingOccurrencesOfString:@"：" withString:@":"];
        cleaned = [cleaned stringByReplacingOccurrencesOfString:@" " withString:@""];
        NSArray *parts = [cleaned componentsSeparatedByString:@":"];
        if ([parts count] >= 2) {
            NSString *hh = parts[0], *mm = parts[1];

            NSDate *next = [[NSDate date] dateByAddingTimeInterval:
                            (double)([hh integerValue] * 3600 + [mm integerValue] * 60)];
            [self setNext:(unsigned long long)[next timeIntervalSince1970]];
        }
        if ([cleaned length] > 1) (void)[cleaned substringFromIndex:1];
    }
}


#pragma mark - 二进制存取器（逐条 8-16 指令，纯 ivar 读写）
- (void)setFile:(id)v { _file = v; }
- (void)setAlarms:(id)v { _alarms = v; }
- (void)setNext:(unsigned long long)v { _next = v; }

#pragma mark - 二进制存取器（逐条 8-16 指令，纯 ivar 读写）
- (id)file { return _file; }
- (id)alarms { return _alarms; }
- (unsigned long long)next { return _next; }

@end
