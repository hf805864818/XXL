//
//  PDNative_MCPLogger.h
//  PetDFY
//
//  还原自 PetDFY.arm64e.dylib —— 类 PDNative_MCPLogger（全部为类方法，instanceSize=8，无 ivar）
//
//  二进制事实（Observed）
//    · 日志目录：/var/mobile/Library/Logs/iOSMCP          (@0x105d70)
//    · 主日志：  ios-mcp.log                              (@0x105d90)
//    · 上一份：  ios-mcp.1.log                            (@0x105db0)
//    · 归档：    ios-mcp.%lu.log                          (@0x105dd0)
//    · 锁文件：  ios-mcp.lock                             (@0x105df0)
//    · 偏好域：  com.witchan.ios-mcp.preferences          (@0x105f50)
//    · 开关键：  debugLoggingEnabled                      (@0x105f30)
//    · 控制台：  [witchan][ios-mcp] %@                    (@0x105e10)
//    · 行前缀：  %@ pid=%d %@                             (@0x105e30)
//  这些常量是硬编码在 __TEXT,__cstring + __objc_classrefs 里的，不从配置文件读。
//

#import <Foundation/Foundation.h>

@interface PDNative_MCPLogger : NSObject

/// 调试日志总开关。读 NSUserDefaults[debugLoggingEnabled]，带 2 秒进程内节流缓存。
+ (BOOL)isDebugLoggingEnabled;

+ (NSString *)logDirectoryPath;
+ (NSString *)logFilePath;
+ (NSString *)previousLogFilePath;
+ (NSString *)archivedLogFilePathAtIndex:(NSUInteger)index;
+ (NSArray *)allLogFilePaths;
+ (NSString *)lockFilePath;
+ (NSString *)lastLogError;

/// printf 风格入口：整串格式化后转 logMessage:，同时打一份到 NSLog。
+ (void)log:(NSString *)format, ...;

/// 落盘入口：做换行折叠、4096 字符截断、加 pid 前缀、加锁、按 2 MB 轮转。
+ (void)logMessage:(NSString *)message;

/// 清空全部日志（主日志 + previous + 归档）。失败回填 NSError。
+ (BOOL)clearLogsWithError:(NSError **)error;

@end
