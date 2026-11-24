//
//  PDAIMemory : NSObject
//  逆向还原：ivar/方法/属性来自二进制元数据
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

@interface PDAIMemory : NSObject {
    NSString * _root;
}

@property (nonatomic, readonly, copy) NSString * root;

- (id)initWithRoot:(id)arg1;
- (id)path:(id)arg1;
- (id)writablePath:(id)arg1 error:(NSError **)arg2;
- (BOOL)prepareWrite:(id)arg1 error:(NSError **)arg2;
- (id)files;
- (id)read:(id)arg1 error:(NSError **)arg2;
- (id)imageForHandle:(id)arg1;
- (id)systemContext;
- (BOOL)isProtectedFile:(id)arg1;
- (BOOL)protected:(id)arg1;
- (BOOL)removeGeneratedFiles:(NSError **)arg1;
- (BOOL)removeConversationHandoffs:(NSError **)arg1;
- (BOOL)removeFilesForConversationOnly:(BOOL)arg1 error:(NSError **)arg2;
- (NSString *)snapshot:(id)arg1 operation:(id)arg2;
- (BOOL)write:(id)arg1 path:(id)arg2 operation:(id)arg3 error:(NSError **)arg4;
- (NSRange)lineRange:(id)arg1 args:(id)arg2;
- (id)lines:(id)arg1;
- (id)glob:(id)arg1;
- (id)executeTool:(id)arg1 arguments:(id)arg2;
- (id)run:(id)arg1 arguments:(id)arg2;
+ (id)protectedFileNames;
@end
