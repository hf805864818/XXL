//
//  PDVoiceTextReveal : NSObject
//  逆向还原：ivar/方法/属性来自二进制元数据
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

@interface PDVoiceTextReveal : NSObject {
    BOOL _hasResultTime;
    NSString * _displayedText;
    double _nextAdvanceTime;
    NSString * _targetText;
    NSString * _pendingCorrection;
    NSArray * _boundaries;
    NSMutableArray * _speedSamples;
    NSMutableArray * _growthIntervals;
    unsigned long long _cumulativeAddedCount;
    double _characterInterval;
    double _lastResultTime;
    double _elapsed;
    double _lastGrowthTime;
    double _typingAnchor;
}

@property (nonatomic, copy) NSString * displayedText;
@property (nonatomic, copy) NSString * targetText;
@property (nonatomic, copy) NSString * pendingCorrection;
@property (nonatomic, copy) NSArray * boundaries;
@property (nonatomic, strong) NSMutableArray * speedSamples;
@property (nonatomic, strong) NSMutableArray * growthIntervals;
@property (nonatomic) unsigned long long cumulativeAddedCount;
@property (nonatomic) double characterInterval;
@property (nonatomic) double lastResultTime;
@property (nonatomic) double elapsed;
@property (nonatomic) double lastGrowthTime;
@property (nonatomic) double typingAnchor;
@property (nonatomic) double nextAdvanceTime;
@property (nonatomic) BOOL hasResultTime;
@property (nonatomic, readonly) BOOL pending;

- (id)init;
- (BOOL)isPending;
- (void)recordResultAtTime:(double)arg1 addedCount:(unsigned long long)arg2;
- (void)updateText:(NSString *)arg1 atTime:(double)arg2;
- (void)advanceAtTime:(double)arg1;
- (void)finishWithText:(NSString *)arg1;
- (void)flush;
@end
