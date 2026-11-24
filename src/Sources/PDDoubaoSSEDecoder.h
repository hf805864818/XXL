//
//  PDDoubaoSSEDecoder : NSObject
//  逆向还原：ivar/方法/属性来自二进制元数据
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

@interface PDDoubaoSSEDecoder : NSObject {
    BOOL _complete;
    BOOL _afterCR;
    NSError * _error;
    NSMutableData * _line;
    NSMutableString * _event;
    NSMutableData * _audio;
}

@property (nonatomic, strong) NSMutableData * line;
@property (nonatomic, strong) NSMutableString * event;
@property (nonatomic, strong) NSMutableData * audio;
@property (nonatomic) BOOL complete;
@property (nonatomic) BOOL afterCR;
@property (nonatomic, strong) NSError * error;

- (id)init;
- (void)consumeEvent;
- (void)consumeLine;
- (void)appendData:(id)arg1;
- (id)finish;
- (BOOL)complete;
- (void)setComplete:(BOOL)arg1;
- (BOOL)afterCR;
- (void)setAfterCR:(BOOL)arg1;
@property (nonatomic, copy) void (^onAudio)(NSData *);
@property (nonatomic, copy) void (^onComplete)(NSData *, NSError *);

@end
