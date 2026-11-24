//
//  PDVoiceTextReveal.m
//  逐字显示节拍器（打字机效果的时间/速率模型）
//
//  还原依据：PDVoiceTextReveal 的 5 个已命名方法体 + 3 个短方法 + 1 个导出 C 函数
//  保真分级见文件末尾「还原保真账本」。
//

#import "PDVoiceTextReveal.h"

#pragma mark - 导出 C 函数

/// 两个字符串的公共前缀长度（UTF-16 单位），并把结果回退到
/// composed character sequence 边界，保证不切开组合字符。
/// 对应二进制符号 _PDVoiceTextCommonPrefixLength @ 0x62780。
NSUInteger PDVoiceTextCommonPrefixLength(NSString *a, NSString *b) {
    if (a == nil || b == nil) {
        return 0;
    }

    NSUInteger lenA = [a length];
    NSUInteger lenB = [b length];
    NSUInteger limit = lenA < lenB ? lenA : lenB;

    NSUInteger length = 0;
    while (length < limit) {
        if ([a characterAtIndex:length] != [b characterAtIndex:length]) {
            break;
        }
        length++;
    }

    // 回退到组合字符边界：两端都检查，取更保守的那个。
    while (length != 0) {
        NSUInteger probe = length - 1;

        NSRange rangeA = [a rangeOfComposedCharacterSequenceAtIndex:probe];
        NSRange rangeB = [b rangeOfComposedCharacterSequenceAtIndex:probe];

        NSUInteger endA = rangeA.location + rangeA.length;
        NSUInteger endB = rangeB.location + rangeB.length;

        NSUInteger candidate = length < rangeA.location ? length : rangeA.location;
        candidate = endA > length ? candidate : length;

        NSUInteger clamped = candidate < rangeB.location ? candidate : rangeB.location;
        clamped = endB > length ? clamped : candidate;

        if (clamped == length) {
            break;
        }
        length = clamped;
    }

    return length;
}

#pragma mark - 边界表

/// text 的每个组合字符结束位置（UTF-16 下标），升序。
/// 对应二进制 func.00063148 + block 0x635e4：
///   enumerateSubstringsInRange:options:0x202 usingBlock:
///   → addObject:@(NSMaxRange(substringRange))
static NSArray<NSNumber *> *PDVoiceTextBoundaries(NSString *text) {
    NSMutableArray<NSNumber *> *boundaries = [NSMutableArray array];
    if (text.length == 0) {
        return boundaries;
    }

    // 0x202 = ByComposedCharacterSequences(2) | SubstringNotRequired(1 << 9)
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:(2UL | (1UL << 9))
                          usingBlock:^(NSString *substring, NSRange substringRange,
                                       NSRange enclosingRange, BOOL *stop) {
        NSUInteger end = substringRange.location + substringRange.length;
        [boundaries addObject:[NSNumber numberWithUnsignedInteger:end]];
    }];

    return boundaries;
}

#pragma mark - 实现

@implementation PDVoiceTextReveal

- (id)init {
    self = [super init];
    if (self) {
        _displayedText = @"";
        _targetText = @"";
        _boundaries = @[];
        _speedSamples = [NSMutableArray array];
        _growthIntervals = [NSMutableArray array];
        _characterInterval = 0.1;
    }
    return self;
}

- (BOOL)isPending {
    return ![_displayedText isEqualToString:_targetText];
}

/// 属性 pending 的实际实现（只读，等价于 isPending）
- (BOOL)pending {
    return [self isPending];
}

- (void)recordResultAtTime:(double)time addedCount:(unsigned long long)added {
    if (isnan(time) || isinf(time)) {
        return;
    }

    if (_hasResultTime && _lastResultTime < time) {
        _elapsed += time - _lastResultTime;
    }
    _lastResultTime = time;
    _hasResultTime = YES;

    if (added != 0) {
        double median = 0.0;
        double elapsed = _elapsed;
        double lastGrowth = _lastGrowthTime;
        NSMutableArray<NSNumber *> *intervals = _growthIntervals;

        if (intervals.count >= 3) {
            NSArray<NSNumber *> *sorted = [intervals sortedArrayUsingSelector:@selector(compare:)];
            NSUInteger count = sorted.count;
            NSUInteger half = count >> 1;
            if (count & 1) {
                median = [[sorted objectAtIndexedSubscript:half] doubleValue];
            } else {
                double lower = [[sorted objectAtIndexedSubscript:half - 1] doubleValue];
                double upper = [[sorted objectAtIndexedSubscript:half] doubleValue];
                median = (lower + upper) * 0.5;
            }
        }

        double delta = elapsed - lastGrowth;

        if (_cumulativeAddedCount != 0 && median > 0.0 && delta > median * 2.5) {
            // 输入速率突然掉到中位数的 2.5 倍间隔之外：判定为停顿，清空窗口
            [_speedSamples removeAllObjects];
        } else if (_cumulativeAddedCount != 0 && delta > 0.0) {
            [_growthIntervals addObject:[NSNumber numberWithDouble:delta]];
            if (_growthIntervals.count >= 6) {
                [_growthIntervals removeObjectAtIndex:0];
            }
        }

        _lastGrowthTime = _elapsed;
    }

    _cumulativeAddedCount += added;

    NSArray<NSNumber *> *sample = @[ [NSNumber numberWithDouble:_elapsed],
                                     [NSNumber numberWithUnsignedLongLong:_cumulativeAddedCount] ];
    [_speedSamples addObject:sample];

    // 只保留最近 1 秒的采样（至少留 2 个），供速率估计使用
    if (_speedSamples.count >= 3) {
        NSMutableArray<NSArray<NSNumber *> *> *samples = _speedSamples;
        NSUInteger dropCount = 0;
        NSUInteger index = 1;

        while (YES) {
            NSArray<NSNumber *> *item = [samples objectAtIndexedSubscript:index];
            double stamp = [[item objectAtIndexedSubscript:0] doubleValue];
            double windowStart = _elapsed - 1.0;

            if (stamp > windowStart) {
                dropCount = index - 1;
                break;
            }

            index++;
            if (samples.count - (index - 1) <= 2) {
                dropCount = samples.count - 2;
                break;
            }
        }

        if (dropCount != 0) {
            [samples removeObjectsInRange:NSMakeRange(0, dropCount)];
        }
    }

    if (added != 0) {
        NSArray<NSNumber *> *first = [_speedSamples firstObject];
        double span = _elapsed - [[first objectAtIndexedSubscript:0] doubleValue];
        unsigned long long counted = _cumulativeAddedCount -
            [[first objectAtIndexedSubscript:1] unsignedLongLongValue];

        if (span > 0.0 && counted != 0) {
            _characterInterval = fmin(span / (double)counted, 0.1);
        }
    }

}


- (void)updateText:(NSString *)text atTime:(double)time {
    if (isnan(time) || isinf(time)) {
        return;
    }

    NSString *newText = text ?: @"";

    BOOL sameText = [newText isEqualToString:_targetText];
    NSArray<NSNumber *> *candidate = sameText ? _boundaries : PDVoiceTextBoundaries(newText);

    NSUInteger newCount = candidate.count;
    NSUInteger oldCount = _boundaries.count;
    unsigned long long added = newCount > oldCount ? (unsigned long long)(newCount - oldCount) : 0;

    [self recordResultAtTime:time addedCount:added];

    if (sameText) {
        return;
    }

    BOOL wasPending = [self isPending];

    NSString *correction = nil;
    if (candidate.count > _boundaries.count) {
        NSString *displayed = _displayedText;
        NSUInteger commonPrefix = PDVoiceTextCommonPrefixLength(displayed, newText);

        if (commonPrefix != displayed.length) {
            NSArray<NSNumber *> *displayedBoundaries = PDVoiceTextBoundaries(displayed);
            NSUInteger usable = displayedBoundaries.count < candidate.count
                ? displayedBoundaries.count : candidate.count;

            if (usable != 0) {
                NSUInteger end = [[candidate objectAtIndexedSubscript:usable - 1] unsignedIntegerValue];
                correction = [newText substringToIndex:end];
            }
        }
    }

    _pendingCorrection = correction;
    _targetText = newText;
    _boundaries = candidate;

    double nextAdvance = time;

    if ([self isPending]) {
        if (_pendingCorrection == nil) {
            if (!wasPending) {
                _typingAnchor = time - _characterInterval;
            }
            double scheduled = _typingAnchor + _characterInterval;
            nextAdvance = fmax(nextAdvance, scheduled);
        }
    } else {
        _pendingCorrection = nil;
        nextAdvance = 0.0;
    }

    _nextAdvanceTime = nextAdvance;
}

- (void)advanceAtTime:(double)time {
    if (isnan(time) || isinf(time)) {
        return;
    }
    if (![self isPending]) {
        return;
    }
    if (_nextAdvanceTime > time) {
        return;
    }

    if (_pendingCorrection != nil) {
        _displayedText = _pendingCorrection;
        _pendingCorrection = nil;
    } else {
        NSString *target = _targetText;
        NSUInteger length = _displayedText.length;
        NSRange range = [target rangeOfComposedCharacterSequenceAtIndex:length];
        _displayedText = [target substringToIndex:range.location + range.length];
    }

    _typingAnchor = time;
    _nextAdvanceTime = [self isPending] ? time + _characterInterval : 0.0;
}

- (void)finishWithText:(NSString *)text {
    NSString *newText = text ?: @"";
    _targetText = newText;
    _boundaries = PDVoiceTextBoundaries(newText);
    [self flush];
}

- (void)flush {
    _displayedText = _targetText;
    _pendingCorrection = nil;
    _nextAdvanceTime = 0.0;
    _typingAnchor = 0.0;
}

#pragma mark - 还原保真账本
//
//  Observed（直接对照反汇编）
//    - init：displayedText/targetText 置 @""、characterInterval = 0.1（0x3fb999999999999a）
//    - isPending：![displayedText isEqualToString:targetText]
//    - recordResultAtTime:addedCount:
//        · 时间回填：hasResultTime && lastResultTime < time 时 elapsed += time - lastResultTime
//        · 中位数：growthIntervals.count >= 3 时排序取中位；偶数取中间两数均值
//        · 停顿判定：cumulativeAddedCount != 0 && median > 0 && delta > median * 2.5
//          → 清空 speedSamples（清空后 lastGrowthTime 仍更新为 elapsed）
//        · 间隔入队上限 6，超出丢最早
//        · 采样三元组 @[elapsed, cumulativeAddedCount]，1 秒窗口外丢弃、至少留 2 个
//        · 速率：span = elapsed - first.elapsed；counted = cumulative - first.count；
//          characterInterval = fmin(span / counted, 0.1)（封顶字面量 0xc5d68 = 0.1）
//    - updateText:atTime:
//        · NaN/Inf 直接返回
//        · sameText 时沿用旧 boundaries，仍记录速率，然后返回
//        · 增长量 = max(0, newCount - oldCount)
//        · 校正：文本变长且公共前缀 != displayedText.length 时，
//          correction = newText 到第 min(displayedBoundaries.count, newCount) 个组合字符末尾的前缀
//        · 有 correction → nextAdvanceTime = time（立刻显示）
//        · 无 correction 且此前不 pending → typingAnchor = time - interval，next = max(time, anchor + interval)
//        · 不再 pending → correction = nil，nextAdvanceTime = 0
//    - advanceAtTime:
//        · 前置三问：有限时间 / isPending / nextAdvanceTime <= time
//        · 有 correction 直接上屏并清空；否则取 target 的 rangeOfComposedCharacterSequenceAtIndex:displayed.length 追加一个组合字符
//        · typingAnchor = time；next = pending ? time + characterInterval : 0
//    - finishWithText:：重置 target + boundaries，再 flush
//    - flush：displayed = target，correction = nil，nextAdvanceTime = 0，typingAnchor = 0
//    - PDVoiceTextCommonPrefixLength：逐 UTF-16 单元比较，再按两端 composed character
//      边界双向回退（0x62780 的循环结构逐句照搬）
//    - PDVoiceTextBoundaries：enumerateSubstringsInRange:options:0x202，
//      block 内 addObject:@(NSMaxRange(substringRange))（block 0x635e4）
//
//  Inferred（结构确定、常量/类型按上下文定）
//    - 属性 pending 为 isPending 的只读别名（元数据里有该属性，未见独立实现）
//    - median 的“偶数取均值”分支按 fadd + fmul 0.5 的指令序列还原
//
//  Assumed（需要真机验证）
//    - _speedSamples 窗口裁剪的下标语义按指令流逐条推导，未跑时序回归
//    - NSNumber 装箱类型（double / unsigned long long）按调用点 selector 定
//
#pragma mark - 二进制存取器（逐条 8-16 指令，纯 ivar 读写）
- (void)setDisplayedText:(id)v { _displayedText = v; }
- (void)setNextAdvanceTime:(double)v { _nextAdvanceTime = v; }
- (void)setTargetText:(id)v { _targetText = v; }
- (void)setPendingCorrection:(id)v { _pendingCorrection = v; }
- (void)setBoundaries:(id)v { _boundaries = v; }
- (void)setSpeedSamples:(id)v { _speedSamples = v; }
- (void)setGrowthIntervals:(id)v { _growthIntervals = v; }
- (void)setCumulativeAddedCount:(unsigned long long)v { _cumulativeAddedCount = v; }
- (void)setCharacterInterval:(double)v { _characterInterval = v; }
- (void)setLastResultTime:(double)v { _lastResultTime = v; }
- (void)setElapsed:(double)v { _elapsed = v; }
- (void)setLastGrowthTime:(double)v { _lastGrowthTime = v; }
- (void)setTypingAnchor:(double)v { _typingAnchor = v; }
- (void)setHasResultTime:(BOOL)v { _hasResultTime = v; }

#pragma mark - 二进制存取器（逐条 8-16 指令，纯 ivar 读写）
- (id)displayedText { return _displayedText; }
- (double)nextAdvanceTime { return _nextAdvanceTime; }
- (id)targetText { return _targetText; }
- (id)pendingCorrection { return _pendingCorrection; }
- (id)boundaries { return _boundaries; }
- (id)speedSamples { return _speedSamples; }
- (id)growthIntervals { return _growthIntervals; }
- (unsigned long long)cumulativeAddedCount { return _cumulativeAddedCount; }
- (double)characterInterval { return _characterInterval; }
- (double)lastResultTime { return _lastResultTime; }
- (double)elapsed { return _elapsed; }
- (double)lastGrowthTime { return _lastGrowthTime; }
- (double)typingAnchor { return _typingAnchor; }
- (BOOL)hasResultTime { return _hasResultTime; }

@end
