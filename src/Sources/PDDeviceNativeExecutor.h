//
//  PDDeviceNativeExecutor.h — 逆向还原
//
//  24 个设备工具的 MCP 分发表。无 ivar（实例大小 8 字节），无单例，
//  由 PDDeviceTools 持有并调用 execute:arguments:。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

@interface PDDeviceNativeExecutor : NSObject
+ (instancetype)sharedInstance;

/// 总入口：权限 → AX 作用域 → 锁屏检查 → 分发。
- (id)execute:(NSString *)tool arguments:(NSDictionary *)args;

/// 25 个工具名的 isEqual: 瀑布分发（0x6e84c / 1304 指令）。
- (id)executeAllowed:(NSString *)tool arguments:(NSDictionary *)args;

#pragma mark - 单个工具

- (id)executeScreenInfo:(NSString *)tool;
- (id)executeScreenshot:(NSString *)tool args:(NSDictionary *)args;
- (id)executeGetUIElements:(NSString *)tool args:(NSDictionary *)args;
- (id)executeGetElementAtPoint:(NSString *)tool args:(NSDictionary *)args;
- (id)executeDescribeScreen:(NSString *)tool args:(NSDictionary *)args;
- (id)executeTap:(NSString *)tool args:(NSDictionary *)args;
- (id)executeSwipe:(NSString *)tool args:(NSDictionary *)args;
- (id)executeLongPress:(NSString *)tool args:(NSDictionary *)args;
- (id)executeDoubleTap:(NSString *)tool args:(NSDictionary *)args;
- (id)executeDragAndDrop:(NSString *)tool args:(NSDictionary *)args;
- (id)executeTapElement:(NSString *)tool args:(NSDictionary *)args;
- (id)executeWaitForElement:(NSString *)tool args:(NSDictionary *)args waitForAppear:(BOOL)appear;
- (id)executeInputText:(NSString *)tool args:(NSDictionary *)args;
- (id)executeTypeText:(NSString *)tool args:(NSDictionary *)args;
- (id)executePressKey:(NSString *)tool args:(NSDictionary *)args;
- (id)executeGetClipboard:(NSString *)tool;
- (id)executeSetClipboard:(NSString *)tool args:(NSDictionary *)args;
- (id)executeLaunchApp:(NSString *)tool args:(NSDictionary *)args;
- (id)executeKillApp:(NSString *)tool args:(NSDictionary *)args;
- (id)executeListApps:(NSString *)tool args:(NSDictionary *)args;
- (id)executeListRunningApps:(NSString *)tool;
- (id)executeGetFrontmostApp:(NSString *)tool args:(NSDictionary *)args;
- (id)executeGetAppInfo:(NSString *)tool args:(NSDictionary *)args;
- (id)executeOpenURL:(NSString *)tool args:(NSDictionary *)args;

#pragma mark - 参数与结果

/// 取一个必填/可选的 double 参数；支持 NSNumber 与可解析的 NSString。
/// required=YES 且缺失时通过 *error 返回「Missing required parameter: %@」。
- (BOOL)readDouble:(NSDictionary *)args key:(NSString *)key required:(BOOL)required
            out:(double *)out fallback:(double)fallback error:(NSString **)error;

/// 解析 text / identifier / role / match / index / exact 六个匹配参数。
- (BOOL)parseElementMatchArgs:(NSDictionary *)args text:(NSString **)text exact:(BOOL *)exact
                         type:(NSString **)type index:(NSInteger *)index error:(NSString **)error;

/// 以 clickableOnly=YES 拉一次紧凑元素列表，返回 payload 字典。
- (NSDictionary *)fetchCompactElementsClickableOnly:(BOOL)clickableOnly;

#pragma mark - 载荷清洗

- (id)sanitizeUIElement:(id)element debug:(BOOL)debug;
- (id)sanitizeUIElementsPayload:(id)payload debug:(BOOL)debug;
- (id)sanitizeElementAtPointPayload:(id)payload debug:(BOOL)debug;
- (id)sanitizeScreenshotContent:(id)content debug:(BOOL)debug;
- (id)sanitizeFrontmostInfo:(id)info debug:(BOOL)debug;
- (id)sanitizeAccessibilityFailurePayload:(id)payload debug:(BOOL)debug;

#pragma mark - MCP 信封

- (id)mcpSuccess:(id)tool text:(NSString *)text isError:(BOOL)isError;
- (id)mcpSuccess:(id)tool structuredContent:(id)content isError:(BOOL)isError;
- (id)mcpSuccess:(id)tool text:(NSString *)text structuredContent:(id)content isError:(BOOL)isError;
- (id)mcpError:(id)tool code:(NSInteger)code message:(NSString *)message;

- (NSString *)jsonTextForObject:(id)object;
- (NSString *)jsonTextForDictionary:(NSDictionary *)dictionary;

/// 截图 payload（走 PDOverlayController.performDeviceScreenCapture:）。
- (NSDictionary *)takeDeviceScreenshotPayload;

@end
