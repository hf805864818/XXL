//
//  PDDeviceAXScope : NSObject
//  逆向还原：ivar/方法/属性来自二进制元数据
//
//  method_t types（objc_full.json，类方法在 metaclass 上）：
//    -closeOnMain   v16@0:8
//    -finish        v16@0:8
//    +recoverInterruptedScope                        v16@0:8
//    +acquireWithRead:write:mark:warmup:duration:error:  @64@0:8@?16@?24@?32d40d48^@56
//    +acquireWithError:                              @24@0:8^@16
//
//  三个 block ivar 在 types 里是泛型 @?，真实签名由调用点反推（Observed）：
//    readState   = BOOL (^)(void)   acquire 块体 0x6fda4 把它的返回值喂给 setReady:
//    writeState  = void (^)(BOOL)   0x6fd90 传 1；closeOnMain 0x70150 传 0
//    markRestore = void (^)(BOOL)   同上
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

typedef BOOL (^PDDeviceAXReadBlock)(void);
typedef void (^PDDeviceAXWriteBlock)(BOOL);
typedef void (^PDDeviceAXMarkBlock)(BOOL);

@interface PDDeviceAXScope : NSObject {
    BOOL _closed;
    BOOL _changed;
    BOOL _ready;
    PDDeviceAXReadBlock _readState;
    PDDeviceAXWriteBlock _writeState;
    PDDeviceAXMarkBlock _markRestore;
}

@property (nonatomic, copy) PDDeviceAXReadBlock readState;
@property (nonatomic, copy) PDDeviceAXWriteBlock writeState;
@property (nonatomic, copy) PDDeviceAXMarkBlock markRestore;
@property (nonatomic) BOOL closed;
@property (nonatomic) BOOL changed;
@property (nonatomic) BOOL ready;

- (void)closeOnMain;
- (void)finish;

+ (void)recoverInterruptedScope;
+ (id)acquireWithRead:(PDDeviceAXReadBlock)read
                write:(PDDeviceAXWriteBlock)write
                 mark:(PDDeviceAXMarkBlock)mark
               warmup:(double)warmup
             duration:(double)duration
                error:(NSError **)error;
+ (id)acquireWithError:(NSError **)error;

@end
