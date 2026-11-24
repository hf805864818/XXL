//
//  PDDeviceToolsDeclarations.h — 逆向还原
//
//  设备操控的 25 条 MCP 工具声明，以及「工具是否被允许」的判定。
//
//  二进制中的 C 函数：
//    NSArray *_PDDeviceToolDeclarations(void)                          0x64ad0
//    BOOL     _PDIsDeviceTool(NSString *name)                          0x64dc8
//    BOOL     _PDDeviceToolEnabled(NSString *name)                     0x64f24
//    NSString *_PDDeviceToolPermissionError(NSString *name, id args)   0x65188
//    NSString *_PDDeviceToolPrompt(NSArray<NSString *> *enabled)       0x6527c
//    NSDictionary *_PDDeviceToolResult(id result)                      0x65520
//

#import <Foundation/Foundation.h>

/// 25 条工具声明，形如 `{ type:"function", function:{ name, description, parameters } }`。
FOUNDATION_EXPORT NSArray<NSDictionary *> *PDDeviceToolDeclarations(void);

/// name 是否属于设备操控工具集（不检查权限）。
FOUNDATION_EXPORT BOOL PDIsDeviceTool(NSString *name);

/// 是否被用户允许：先要求 PDIsDeviceTool，
/// 再要求偏好 DeviceControlEnabled 为真，且 DeviceTool_<name> 为真。
FOUNDATION_EXPORT BOOL PDDeviceToolEnabled(NSString *name);

/// 若该工具不可用，返回给模型看的拒绝说明（中文）；可用时返回 nil。
/// args 用于 describe_screen 的 include_screenshot 特例判定。
FOUNDATION_EXPORT NSString *PDDeviceToolPermissionError(NSString *name, id args);

/// 生成「当前只允许这些工具」的系统提示片段。
FOUNDATION_EXPORT NSString *PDDeviceToolPrompt(NSArray<NSString *> *enabledTools);

/// 把工具返回值包装成结果信封 { receipt, failed, images }。
FOUNDATION_EXPORT NSDictionary *PDDeviceToolResult(id result);
