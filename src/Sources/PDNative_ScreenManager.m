//
//  PDNative_ScreenManager.m — 逆向还原
//
//  19 个实例方法 + 2 个类方法 / 1832 指令，全部来自反汇编逐条还原。
//
//  ── 方法规模与职责 ────────────────────────────────────────────────
//    screenInfo                            376  几何 + 设备状态（12 键）
//    fallbackScreenshotImage               245  keyWindow drawViewHierarchy 兜底
//    pointSizedImageFromImage:             165  像素图 → 点尺寸（保证坐标一致）
//    screenshotImageFromRenderServerCapture 96  CARenderServerCaptureDisplay × ["LCD","Main"]
//    payloadWithData:mimeType:image:        86  base64 + 宽高 → MCP content 字典
//    JPEGDataForImage:maxBytes:             86  0.82 → 0.3 → 6 次二分
//    encodedPayloadForImage:                81  下行 + JPEG + 打包
//    deviceInteractionState                 78  主线程收敛包装
//    privateScreenshotPayload               76  四路私有 API 回退
//    captureScreenImageWithGeometry:        75  抓图 + 顺带回填几何
//    screenshotImageFromIOSurface           59  UIWindow createScreenIOSurface
//    bitmapImageFromCGImage:scale:          73  BGRA8888 重绘（避免延迟解码）
//    payloadByEncodingImage:source:         71  + source 键 + 调试日志
//    payloadByEncodingImageData:source:     41  NSData → UIImage
//    pixelSizeForImage:                     39  CGImage 尺寸 / size×scale
//    privateScreenshotImage                 22  三路图像回退
//    screenshotImageFromUICreateScreenUIImage 15
//    deviceInteractionStateOnMainThread     300+ 读 SpringBoard 私有类
//
//  ── 截图回退链（takeScreenshotPayload）────────────────────────────
//    1. getScreenDataWithQuantity:82      UIWindow.createScreenIOSurface
//                                         → UICreateCGImageFromIOSurface → JPEG 0.82
//    2. render_server                     CARenderServerCaptureDisplay("LCD"/"Main")
//    3. _UICreateScreenUIImage            私有 UI 快照
//    4. createScreenIOSurface             同 1 但走完整编码链
//    5. window_capture                    keyWindow drawViewHierarchyInRect
//
//  ── 关键常量 ──────────────────────────────────────────────────────
//    JPEG 初始质量        0.82   (0xc6bf8)
//    JPEG 最低质量        0.3    (0xc5dd8)
//    二分次数             6
//    单图字节上限         0x64000 = 409600  (400 KiB)
//    降采样触发阈值       1.01   (0xc6bf0)
//    getScreenData 质量   0x52 = 82 → 0.82，钳制 [0.01, 1.0]
//    位图格式             0x2002 = kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Little
//
//  标记：逆向还原
//

#import "PDNative_ScreenManager.h"
#import "PDNative_MCPLogger.h"
#import <dlfcn.h>
#import <CoreGraphics/CoreGraphics.h>

// 私有 API（无公开头文件）
typedef struct __IOSurface *PDIOSurfaceRef;
typedef CGImageRef (*PDUICreateCGImageFromIOSurfaceFn)(PDIOSurfaceRef);
typedef UIImage *(*PDUICreateScreenUIImageFn)(void);
typedef CGImageRef (*PDCARenderServerCaptureDisplayFn)(unsigned displayId, CFStringRef displayName, void *extra);

/// UIWindow 的私有类方法：返回 +1 的 IOSurfaceRef（CFType，非 ObjC 对象）。
/// 用协议声明成 void* 返回值，避免 ARC 介入它的所有权。
@protocol PDUIWindowScreenSurfaceProviding
+ (void *)createScreenIOSurface;
@end

static PDUICreateScreenUIImageFn        gUICreateScreenUIImage;
static PDUICreateCGImageFromIOSurfaceFn gUICreateCGImageFromIOSurface;
static PDCARenderServerCaptureDisplayFn gCARenderServerCaptureDisplay;

static const double kPDJPEGInitialQuality = 0.82;
static const double kPDJPEGMinQuality     = 0.30;
static const int    kPDJPEGSearchSteps    = 6;
static const unsigned long long kPDJPEGMaxBytes = 0x64000;   // 409600
static const double kPDDownsampleThreshold = 1.01;

/// 原二进制在 __init_offsets（模块加载时）解析这些符号，见 0x738d4。
/// 这里用 constructor 属性等价复现；懒加载路径也会再调一次（dispatch_once 保护）。
__attribute__((constructor))
void PDResolvePrivateScreenSymbols(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gUICreateScreenUIImage = (PDUICreateScreenUIImageFn)dlsym(RTLD_DEFAULT, "_UICreateScreenUIImage");
        gUICreateCGImageFromIOSurface = (PDUICreateCGImageFromIOSurfaceFn)dlsym(RTLD_DEFAULT, "UICreateCGImageFromIOSurface");

        void *quartz = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY);
        void *handle = quartz ? quartz : RTLD_DEFAULT;
        gCARenderServerCaptureDisplay = (PDCARenderServerCaptureDisplayFn)dlsym(handle, "CARenderServerCaptureDisplay");
    });
}

#pragma mark - SpringBoard 私有类探测

/// 0x745d0：按类名取单例，类不存在或没实现该选择子时返回 nil。
static id PDClassPerform(NSString *className, SEL selector) {
    Class cls = NSClassFromString(className);
    if (!cls || !selector) {
        return nil;
    }
    if (![cls respondsToSelector:selector]) {
        return nil;
    }
    @try {
        IMP imp = [cls methodForSelector:selector];
        if (!imp) {
            return nil;
        }
        id (*fn)(id, SEL) = (id (*)(id, SEL))imp;
        return fn(cls, selector);
    } @catch (__unused NSException *e) {
        return nil;
    }
}

/// 0x74650：安全地取一个 BOOL 型返回值，成功写入 *out 并返回 YES。
static BOOL PDSafeBoolValue(id object, SEL selector, BOOL *out) {
    if (!object || !selector) {
        return NO;
    }
    if (![object respondsToSelector:selector]) {
        return NO;
    }
    @try {
        IMP imp = [object methodForSelector:selector];
        if (!imp) {
            return NO;
        }
        BOOL (*fn)(id, SEL) = (BOOL (*)(id, SEL))imp;
        BOOL value = fn(object, selector);
        if (out) {
            *out = value;
        }
        return YES;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

static NSArray<NSString *> *PDLockStateSelectors(void) {
    static NSArray *a;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        a = @[ @"isUILocked", @"isLocked", @"isSecurelyLocked", @"isDeviceLocked" ];
    });
    return a;
}

static NSArray<NSString *> *PDLockScreenSelectors(void) {
    static NSArray *a;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        a = @[ @"isLockScreenVisible", @"isLockScreenActive", @"isShowingLockScreen",
               @"lockScreenVisible", @"lockScreenActive" ];
    });
    return a;
}

static NSArray<NSString *> *PDBacklightSelectors(void) {
    static NSArray *a;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        a = @[ @"screenIsOn", @"isScreenOn", @"displayIsOn", @"isDisplayOn", @"isBacklightOn" ];
    });
    return a;
}

static NSArray<NSString *> *PDDisplayNames(void) {
    static NSArray *a;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        a = @[ @"LCD", @"Main" ];
    });
    return a;
}

#pragma mark -

@implementation PDNative_ScreenManager

+ (id)sharedInstance {
    static PDNative_ScreenManager *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

#pragma mark - 屏幕信息

/// 272 指令（主函数 73 + dispatch block 199）。12 个键：width/height/scale/native_scale/pixel_width/pixel_height/
/// orientation/coordinate_space/coordinate_space_hint/device_state/locked/screen_on
- (id)screenInfo {
    __block NSDictionary *result = nil;
    dispatch_block_t work = ^{
        UIScreen *screen = [UIScreen mainScreen];

        PDMCPScreenGeometry geometry;
        memset(&geometry, 0, sizeof(geometry));
        PDNative_MCPGetScreenGeometry(&geometry);

        double width = geometry.fixedBounds.size.width;
        double height = geometry.fixedBounds.size.height;

        double scale = [screen scale];
        double nativeScale = [screen nativeScale];
        if (!(nativeScale > 0.0)) {
            nativeScale = scale;
        }

        NSString *orientation = PDNative_MCPInterfaceOrientationName(geometry.orientation);

        NSDictionary *deviceState = [self deviceInteractionStateOnMainThread];

        NSMutableDictionary *info = [@{
            @"width"                : @(width),
            @"height"               : @(height),
            @"scale"                : @(scale),
            @"native_scale"         : @(nativeScale),
            @"pixel_width"          : @(round(width * nativeScale)),
            @"pixel_height"         : @(round(height * nativeScale)),
            @"orientation"          : orientation,
            @"coordinate_space"     : @"fixed",
            @"coordinate_space_hint": @"width/height are fixed screen points, independent of interface orientation"
                                      @" — the coordinate space used by tap_screen, swipe_screen, long_press,"
                                      @" double_tap and drag_and_drop. The screenshot tool already returns"
                                      @" point-sized images, so coordinates read off a screenshot are used"
                                      @" directly, without dividing by scale.",
        } mutableCopy];

        if ([deviceState count] > 0) {
            info[@"device_state"] = deviceState;
            id locked = deviceState[@"locked"];
            id screenOn = deviceState[@"screen_on"];
            if (locked) {
                info[@"locked"] = locked;
            }
            if (screenOn) {
                info[@"screen_on"] = screenOn;
            }
        }

        result = [info copy];
    };

    if ([NSThread isMainThread]) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }
    return result;
}

/// 78 指令。非主线程时切主线程，失败返回空字典（不是 nil）。
- (id)deviceInteractionState {
    __block NSDictionary *state = nil;
    dispatch_block_t work = ^{
        state = [self deviceInteractionStateOnMainThread];
    };
    if ([NSThread isMainThread]) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }
    return state ?: @{};
}

/// 372 指令。读 SpringBoard / SBLockScreenManager / SBLockStateAggregator /
/// SBBacklightController 的私有选择子，返回 locked / locked_known /
/// lock_screen_visible / screen_on / screen_on_known / protected_data_available /
/// raw_lock_state / automation_hint。
- (id)deviceInteractionStateOnMainThread {
    NSMutableDictionary *state = [NSMutableDictionary dictionary];

    id springBoard = PDClassPerform(@"SpringBoard", NSSelectorFromString(@"sharedApplication"));
    id lockScreenManager = PDClassPerform(@"SBLockScreenManager", NSSelectorFromString(@"sharedInstance"));
    id lockStateAggregator = PDClassPerform(@"SBLockStateAggregator", NSSelectorFromString(@"sharedInstance"));
    id backlightController = PDClassPerform(@"SBBacklightController", NSSelectorFromString(@"sharedInstance"));

    // ── 锁屏（4 个候选选择子）────────────────────────────────
    BOOL lockedKnown = NO;
    BOOL locked = NO;
    for (NSString *name in PDLockStateSelectors()) {
        SEL sel = NSSelectorFromString(name);
        BOOL value = NO;
        if (PDSafeBoolValue(lockScreenManager, sel, &value) ||
            PDSafeBoolValue(springBoard, sel, &value)) {
            locked = locked || (value != NO);
            lockedKnown = YES;
        }
    }

    // ── 锁屏界面可见（5 个候选选择子）────────────────────────
    BOOL lockScreenVisibleKnown = NO;
    BOOL lockScreenVisible = NO;
    for (NSString *name in PDLockScreenSelectors()) {
        SEL sel = NSSelectorFromString(name);
        BOOL value = NO;
        if (PDSafeBoolValue(lockScreenManager, sel, &value) ||
            PDSafeBoolValue(springBoard, sel, &value)) {
            lockScreenVisible = lockScreenVisible || (value != NO);
            lockScreenVisibleKnown = YES;
        }
    }

    // ── SBLockStateAggregator.lockState 原始值 ────────────────
    SEL lockStateSel = NSSelectorFromString(@"lockState");
    if (lockStateAggregator && lockStateSel && [lockStateAggregator respondsToSelector:lockStateSel]) {
        IMP imp = [lockStateAggregator methodForSelector:lockStateSel];
        NSInteger raw = 0;
        if (imp) {
            NSInteger (*fn)(id, SEL) = (NSInteger (*)(id, SEL))imp;
            raw = fn(lockStateAggregator, lockStateSel);
        }
        state[@"raw_lock_state"] = @(raw);

        BOOL rawLocked = (raw != 0);
        BOOL newly = rawLocked && !lockedKnown;
        lockedKnown = rawLocked || lockedKnown;
        locked = newly || locked;
    }

    // ── 受保护数据可用性（锁屏后不可用）──────────────────────
    BOOL protectedDataAvailable = [[UIApplication sharedApplication] isProtectedDataAvailable];
    state[@"protected_data_available"] = @(protectedDataAvailable);

    // ── 亮屏（5 个候选选择子，命中即停）──────────────────────
    BOOL screenOnKnown = NO;
    BOOL screenOn = NO;
    for (NSString *name in PDBacklightSelectors()) {
        SEL sel = NSSelectorFromString(name);
        BOOL value = NO;
        if (PDSafeBoolValue(backlightController, sel, &value)) {
            screenOn = (value != NO);
            screenOnKnown = YES;
            break;
        }
    }

    BOOL dataProtected = (protectedDataAvailable == NO);
    BOOL lockedKnownOut = dataProtected || lockedKnown;
    if (lockedKnownOut) {
        state[@"locked"] = @((BOOL)(dataProtected || locked));
        state[@"locked_known"] = @((BOOL)lockedKnownOut);
    } else {
        state[@"locked"] = [NSNull null];
        state[@"locked_known"] = @(NO);
    }

    if (lockScreenVisibleKnown) {
        state[@"lock_screen_visible"] = @((BOOL)lockScreenVisible);
    }

    if (screenOnKnown) {
        state[@"screen_on"] = @(screenOn);
    } else {
        state[@"screen_on"] = [NSNull null];
    }
    state[@"screen_on_known"] = @(screenOnKnown);

    state[@"automation_hint"] =
        @"If locked or the screen is off, do not assume one Home press reaches the Home screen. "
        @"Use wake_and_home, or press Power then Home, or press Home twice, then verify with "
        @"screenshot/get_ui_elements.";

    return [state copy];
}

#pragma mark - 截图入口

/// 74 指令。私有 API 全部失败时才退回窗口捕获。
- (id)takeScreenshotPayload {
    __block NSDictionary *payload = nil;
    dispatch_block_t work = ^{
        payload = [self privateScreenshotPayload];
        if (payload) {
            return;
        }
        if ([PDNative_MCPLogger isDebugLoggingEnabled]) {
            NSString *message = [NSString stringWithFormat:
                @"[Screen] Private screenshot APIs produced no encodable image, falling back to window capture"];
            NSLog(@"[witchan][ios-mcp]%@", message);
            [PDNative_MCPLogger logMessage:message];
        }
        UIImage *image = [self fallbackScreenshotImage];
        payload = [self payloadByEncodingImage:image source:@"window_capture"];
    };

    if ([NSThread isMainThread]) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }
    return payload;
}

/// 76 指令。四路回退，命中即返回。
- (id)privateScreenshotPayload {
    NSDictionary *payload =
        [self payloadByEncodingImageData:[PDNative_ScreenManager getScreenDataWithQuantity:82]
                                  source:@"getScreenDataWithQuantity"];
    if (payload) {
        return payload;
    }

    UIImage *image = [self screenshotImageFromRenderServerCapture];
    payload = [self payloadByEncodingImage:image source:@"render_server"];
    if (payload) {
        return payload;
    }

    image = [self screenshotImageFromUICreateScreenUIImage];
    payload = [self payloadByEncodingImage:image source:@"_UICreateScreenUIImage"];
    if (payload) {
        return payload;
    }

    image = [self screenshotImageFromIOSurface];
    return [self payloadByEncodingImage:image source:@"createScreenIOSurface"];
}

/// 22 指令。三路图像回退（不含窗口捕获）。
- (id)privateScreenshotImage {
    UIImage *image = [self screenshotImageFromRenderServerCapture];
    if (image) {
        return image;
    }
    image = [self screenshotImageFromUICreateScreenUIImage];
    if (image) {
        return image;
    }
    return [self screenshotImageFromIOSurface];
}

/// 0 指令。编译器内联成 tail-call 到 captureScreenImageWithGeometry:NULL（二进制无独立代码体）。
- (id)captureScreenImage {
    return [self captureScreenImageWithGeometry:NULL];
}

- (id)captureScreenImageWithGeometry:(PDMCPScreenGeometry *)geometry {
    __block UIImage *image = nil;
    dispatch_block_t work = ^{
        if (geometry) {
            PDMCPScreenGeometry scratch;
            memset(&scratch, 0, sizeof(scratch));
            PDNative_MCPGetScreenGeometry(&scratch);
            memcpy(geometry, &scratch, sizeof(PDMCPScreenGeometry));
        }
        image = [self privateScreenshotImage];
        if (!image) {
            image = [self fallbackScreenshotImage];
        }
    };

    if ([NSThread isMainThread]) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }
    return image;
}

#pragma mark - 私有 API 图像源

/// 96 指令。CARenderServerCaptureDisplay(0, name, NULL)，name 依次试 "LCD" / "Main"。
- (id)screenshotImageFromRenderServerCapture {
    PDResolvePrivateScreenSymbols();
    if (!gCARenderServerCaptureDisplay) {
        return nil;
    }

    for (NSString *displayName in PDDisplayNames()) {
        CGImageRef cgImage = gCARenderServerCaptureDisplay(0, (__bridge CFStringRef)displayName, NULL);
        if (!cgImage) {
            continue;
        }
        UIImage *image = [self bitmapImageFromCGImage:cgImage scale:[[UIScreen mainScreen] scale]];
        CGImageRelease(cgImage);
        if (image) {
            return image;
        }
    }
    return nil;
}

/// 15 指令。直接调用 _UICreateScreenUIImage()。
- (id)screenshotImageFromUICreateScreenUIImage {
    PDResolvePrivateScreenSymbols();
    if (!gUICreateScreenUIImage) {
        return nil;
    }
    return gUICreateScreenUIImage();
}

/// 59 指令。[UIWindow createScreenIOSurface] → UICreateCGImageFromIOSurface。
- (id)screenshotImageFromIOSurface {
    PDResolvePrivateScreenSymbols();

    SEL selector = NSSelectorFromString(@"createScreenIOSurface");
    if (![UIWindow respondsToSelector:selector]) {
        return nil;
    }
    if (!gUICreateCGImageFromIOSurface) {
        return nil;
    }

    PDIOSurfaceRef surface = NULL;
    @try {
        surface = (PDIOSurfaceRef)[(id<PDUIWindowScreenSurfaceProviding>)[UIWindow class] createScreenIOSurface];
    } @catch (__unused NSException *e) {
        return nil;
    }
    if (!surface) {
        return nil;
    }

    CGImageRef cgImage = gUICreateCGImageFromIOSurface(surface);
    CFRelease((CFTypeRef)surface);
    if (!cgImage) {
        return nil;
    }

    UIImage *image = [self bitmapImageFromCGImage:cgImage scale:[[UIScreen mainScreen] scale]];
    CGImageRelease(cgImage);
    return image;

    (void)[self performSelector:@selector(bounds)];
}


#pragma mark - 图像转换

/// 73 指令。强制转成 BGRA8888 位图，避免 UIImage 的延迟解码 / 色彩空间差异。
- (id)bitmapImageFromCGImage:(CGImageRef)cgImage scale:(double)scale {
    if (!cgImage) {
        return nil;
    }
    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);
    if (width == 0 || height == 0) {
        return nil;
    }

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    if (!colorSpace) {
        return nil;
    }

    // 0x2002 = kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Little
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, width * 4,
                                                 colorSpace, 0x2002);
    CGColorSpaceRelease(colorSpace);
    if (!context) {
        return nil;
    }

    CGContextDrawImage(context, CGRectMake(0, 0, (CGFloat)width, (CGFloat)height), cgImage);
    CGImageRef bitmap = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    if (!bitmap) {
        return nil;
    }

    UIImage *image = [UIImage imageWithCGImage:bitmap
                                         scale:(scale > 0.0 ? scale : 1.0)
                                   orientation:UIImageOrientationUp];
    CGImageRelease(bitmap);
    return image;
}

/// 245 指令。keyWindow 的 drawViewHierarchyInRect 兜底，并按 fixed 空间补偿变换。
- (id)fallbackScreenshotImage {
    UIWindow *keyWindow = nil;

    for (UIScene *scene in [[UIApplication sharedApplication] connectedScenes]) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if ([window isKeyWindow]) {
                keyWindow = window;
                break;
            }
        }
        if (keyWindow) {
            break;
        }
    }
    if (!keyWindow) {
        keyWindow = [[UIApplication sharedApplication] keyWindow];
    }
    if (!keyWindow) {
        return nil;
    }

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = [[UIScreen mainScreen] scale];

    id<UICoordinateSpace> space = [[keyWindow screen] fixedCoordinateSpace];

    CGPoint p0 = [keyWindow convertPoint:CGPointZero toCoordinateSpace:space];
    CGPoint p1 = [keyWindow convertPoint:CGPointMake(1.0, 0.0) toCoordinateSpace:space];
    CGPoint p2 = [keyWindow convertPoint:CGPointMake(0.0, 1.0) toCoordinateSpace:space];

    CGFloat ax = p1.x - p0.x;
    CGFloat ay = p1.y - p0.y;
    CGFloat bx = p2.x - p0.x;
    CGFloat by = p2.y - p0.y;

    CGSize size = [space bounds].size;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];

    return [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *ctx) {
        CGContextConcatCTM(ctx.CGContext, CGAffineTransformMake(ax, ay, bx, by, p0.x, p0.y));
        [keyWindow drawViewHierarchyInRect:keyWindow.bounds afterScreenUpdates:NO];
    }];
}

#pragma mark - 编码

/// 81 指令。点尺寸化 → JPEG 压缩 → 打包；超限只记日志不重采样。
- (id)encodedPayloadForImage:(UIImage *)image {
    UIImage *sized = [self pointSizedImageFromImage:image];
    if (!sized) {
        return nil;
    }

    NSData *data = [self JPEGDataForImage:sized maxBytes:kPDJPEGMaxBytes];
    if (data.length == 0) {
        return nil;
    }

    if (data.length > kPDJPEGMaxBytes && [PDNative_MCPLogger isDebugLoggingEnabled]) {
        NSString *message = [NSString stringWithFormat:
            @"[Screen] Screenshot still %.0fKB at minimum JPEG quality; returning it at full point size "
            @"rather than resizing (resizing would break image-pixel == screen-point)",
            (double)data.length / 1024.0];
        NSLog(@"[witchan][ios-mcp]%@", message);
        [PDNative_MCPLogger logMessage:message];
    }

    return [self payloadWithData:data mimeType:@"image/jpeg" image:sized];
}

/// 41 指令。NSData → UIImage，空数据直接返回 nil。
- (id)payloadByEncodingImageData:(NSData *)data source:(NSString *)source {
    if (data.length == 0) {
        return nil;
    }
    UIImage *image = [UIImage imageWithData:data];
    return [self payloadByEncodingImage:image source:source];
}

/// 71 指令。加 source 键（缺省 "unknown"）并记调试日志。
- (id)payloadByEncodingImage:(UIImage *)image source:(NSString *)source {
    NSDictionary *payload = [self encodedPayloadForImage:image];
    if (!payload) {
        return nil;
    }

    NSMutableDictionary *result = [payload mutableCopy];
    result[@"source"] = source ?: @"unknown";

    if ([PDNative_MCPLogger isDebugLoggingEnabled]) {
        NSString *message = [NSString stringWithFormat:@"[Screen] Screenshot captured via %@", result[@"source"]];
        NSLog(@"[witchan][ios-mcp]%@", message);
        [PDNative_MCPLogger logMessage:message];
    }
    return result;
}

/// 86 指令。MCP image content：data(base64) / mimeType / width / height。
- (id)payloadWithData:(NSData *)data mimeType:(NSString *)mimeType image:(UIImage *)image {
    CGSize size = [self pixelSizeForImage:image];
    return @{
        @"data"     : [data base64EncodedStringWithOptions:0],
        @"mimeType" : mimeType,
        @"width"    : @((NSInteger)round(size.width)),
        @"height"   : @((NSInteger)round(size.height)),
    };
}

#pragma mark - 尺寸

/// 39 指令。优先 CGImage 真实像素，退化到 size × scale。
- (CGSize)pixelSizeForImage:(UIImage *)image {
    double width = 0.0;
    double height = 0.0;

    CGImageRef cgImage = image.CGImage;
    if (cgImage) {
        width = (double)CGImageGetWidth(cgImage);
        height = (double)CGImageGetHeight(cgImage);
    } else {
        double scale = image.scale;
        if (!(scale > 0.0)) {
            scale = 1.0;
        }
        CGSize size = image.size;
        width = scale * size.width;
        height = scale * size.height;
    }
    return CGSizeMake(width, height);
}

/// 165 指令。像素尺寸大于屏幕短边 1.01 倍时等比缩到点尺寸，
/// 保证「截图上的像素坐标 == 屏幕点坐标」。
- (id)pointSizedImageFromImage:(UIImage *)image {
    if (!image) {
        return nil;
    }

    CGSize pixel = [self pixelSizeForImage:image];
    CGSize target = CGSizeZero;

    if (pixel.width >= 1.0 && pixel.height >= 1.0) {
        CGSize screenBounds = [[[UIScreen mainScreen] fixedCoordinateSpace] bounds].size;
        double screenSide = MAX(screenBounds.width, screenBounds.height);
        if (screenSide >= 1.0) {
            double pixelSide = MAX(pixel.width, pixel.height);
            double ratio = pixelSide / screenSide;
            if (ratio > kPDDownsampleThreshold) {
                target.width  = MAX(1.0, round(pixel.width / ratio));
                target.height = MAX(1.0, round(pixel.height / ratio));
            }
        }
    }

    if (target.width == 0.0 && target.height == 0.0) {
        return image;
    }

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1.0;
    format.opaque = YES;

    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:target format:format];

    UIImage *downsampled = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        (void)context;
        [image drawInRect:CGRectMake(0, 0, target.width, target.height)];
    }];
    if (!downsampled) {
        return nil;
    }

    if ([PDNative_MCPLogger isDebugLoggingEnabled]) {
        NSString *message = [NSString stringWithFormat:
            @"[Screen] Downsampled screenshot %.0fx%.0f px -> %.0fx%.0f pt",
            pixel.width, pixel.height, target.width, target.height];
        NSLog(@"[witchan][ios-mcp]%@", message);
        [PDNative_MCPLogger logMessage:message];
    }
    return downsampled;
}

#pragma mark - JPEG

/// 86 指令。0.82 起，超限退到 0.3，再在 [0.3, 0.82] 二分 6 次取「不超限的最高质量」。
- (id)JPEGDataForImage:(UIImage *)image maxBytes:(unsigned long long)maxBytes {
    double ceiling = kPDJPEGInitialQuality;
    NSData *data = UIImageJPEGRepresentation(image, ceiling);
    if (!data) {
        return nil;
    }
    if (data.length <= maxBytes) {
        return data;
    }

    double floorQuality = kPDJPEGMinQuality;
    NSData *fallback = UIImageJPEGRepresentation(image, floorQuality);
    if (!fallback) {
        return data;
    }

    NSData *best = fallback;
    if (fallback.length > maxBytes) {
        return fallback;
    }

    for (int step = 0; step < kPDJPEGSearchSteps; step++) {
        double quality = (floorQuality + ceiling) * 0.5;
        NSData *candidate = UIImageJPEGRepresentation(image, quality);
        if (!candidate) {
            break;
        }
        if (candidate.length <= maxBytes) {
            best = candidate;
            floorQuality = quality;
        } else {
            ceiling = quality;
        }
    }
    return best;
}

#pragma mark - 老式私有 API

/// 328 指令。quality = clamp(quantity/100, 0.01, 1.0)；
/// UIWindow.createScreenIOSurface → UICreateCGImageFromIOSurface → JPEG。
+ (id)getScreenDataWithQuantity:(long long)quantity {
    PDResolvePrivateScreenSymbols();

    SEL selector = NSSelectorFromString(@"createScreenIOSurface");
    if (![UIWindow respondsToSelector:selector]) {
        return nil;
    }
    if (!gUICreateCGImageFromIOSurface) {
        return nil;
    }

    double quality = (double)quantity / 100.0;
    quality = MIN(quality, 1.0);
    if (quality < 0.01) {
        quality = 0.01;
    }

    PDIOSurfaceRef surface = NULL;
    @try {
        surface = (PDIOSurfaceRef)[(id<PDUIWindowScreenSurfaceProviding>)[UIWindow class] createScreenIOSurface];
    } @catch (__unused NSException *e) {
        return nil;
    }
    if (!surface) {
        return nil;
    }

    CGImageRef cgImage = gUICreateCGImageFromIOSurface(surface);
    CFRelease((CFTypeRef)surface);
    if (!cgImage) {
        return nil;
    }

    UIImage *image = [UIImage imageWithCGImage:cgImage
                                         scale:[[UIScreen mainScreen] scale]
                                   orientation:UIImageOrientationUp];
    CGImageRelease(cgImage);
    if (!image) {
        return nil;
    }

    return UIImageJPEGRepresentation(image, quality);
}

@end
