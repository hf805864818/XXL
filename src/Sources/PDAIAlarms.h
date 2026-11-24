//
//  PDAIAlarms : NSObject
//  逆向还原：ivar/方法/属性来自二进制元数据
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

@interface PDAIAlarms : NSObject {
    NSString * _file;
    NSMutableArray * _alarms;
    unsigned long long _next;
}

@property (nonatomic, copy) NSString * file;
@property (nonatomic, strong) NSMutableArray * alarms;
@property (nonatomic) unsigned long long next;

- (id)initWithFile:(id)arg1;
- (void)save;
- (id)label:(id)arg1;
- (id)nextClock:(id)arg1 after:(id)arg2;
- (id)list;
- (id)executeTool:(id)arg1 arguments:(id)arg2;
- (id)takeDue:(id)arg1;
- (unsigned long long)next;
- (void)setNext:(unsigned long long)arg1;
@end
