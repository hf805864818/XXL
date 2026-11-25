//
//  ApplicationServices/ApplicationServices.h  (shim)
//
//  iOS SDK 没有 macOS 的 ApplicationServices umbrella，但 T3 的 AX 桥
//  （PDNative_MCPAX*，5,217 行）在头文件里 import 了它。
//
//  这里只提供**编译期声明**：
//    - 真实符号在运行时由 ensureRuntimeAvailable 通过 dlsym 解析（私有 API）
//    - 链接期用 -Wl,-undefined,dynamic_lookup 放行
//
//  不要把这个文件当成可用实现：它在 iOS 上只是让编译通过。
//

#pragma once

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <sys/types.h>

typedef const struct __AXUIElement *AXUIElementRef;
typedef struct __AXValue *AXValueRef;
typedef struct __AXUIElement AXUIElement;
typedef CFIndex AXError;

#ifndef kAXErrorSuccess
enum { kAXErrorSuccess = 0 };
#endif

typedef CF_ENUM(CFIndex, AXValueType) {
    kAXValueIllegalType = 0,
    kAXValueCGPointType = 1,
    kAXValueCGSizeType  = 2,
    kAXValueCGRectType  = 3,
    kAXValueCFRangeType = 4,
    kAXValueAXErrorType = 5,
};

#ifdef __cplusplus
extern "C" {
#endif

AXUIElementRef AXUIElementCreateApplication(pid_t pid);
AXUIElementRef AXUIElementCreateSystemWide(void);
AXError AXUIElementCopyAttributeValue(AXUIElementRef element, CFStringRef attribute, CFTypeRef *value);
AXError AXUIElementSetAttributeValue(AXUIElementRef element, CFStringRef attribute, CFTypeRef value);
AXError AXUIElementCopyMultipleAttributeValues(AXUIElementRef element, CFArrayRef attributes, int options, CFArrayRef *values);
AXError AXUIElementCopyParameterizedAttributeValue(AXUIElementRef element, CFStringRef attribute, CFTypeRef parameter, CFTypeRef *value);
AXError AXUIElementCopyElementAtPosition(AXUIElementRef application, float x, float y, AXUIElementRef *element);
pid_t   AXUIElementGetPid(AXUIElementRef element, pid_t *pid);
AXError AXUIElementSetMessagingTimeout(AXUIElementRef element, float timeout_in_seconds);
AXValueRef AXValueCreate(AXValueType type, const void *value_ptr);
Boolean AXValueGetValue(AXValueRef value, AXValueType type, void *value_ptr);

/* 私有：仅声明，运行时用 dlsym 取 */
AXError AXUIElementCopyElementUsingContextIdAtPosition(AXUIElementRef application, float x, float y, CFTypeRef context, AXUIElementRef *element);
AXError AXUIElementCopyApplicationAndContextAtPosition(AXUIElementRef systemWide, float x, float y, AXUIElementRef *application, CFTypeRef *context);
AXError AXUIElementCopyApplicationAtPosition(AXUIElementRef systemWide, float x, float y, AXUIElementRef *application);
AXError AXUIElementSetClientType(AXUIElementRef element, CFStringRef type);


#pragma weak AXUIElementCreateApplication
#pragma weak AXUIElementCreateSystemWide
#pragma weak AXUIElementCopyAttributeValue
#pragma weak AXUIElementSetAttributeValue
#pragma weak AXUIElementCopyMultipleAttributeValues
#pragma weak AXUIElementCopyParameterizedAttributeValue
#pragma weak AXUIElementCopyElementAtPosition
#pragma weak AXUIElementGetPid
#pragma weak AXUIElementSetMessagingTimeout
#pragma weak AXValueCreate
#pragma weak AXValueGetValue

#ifdef __cplusplus
}
#endif
