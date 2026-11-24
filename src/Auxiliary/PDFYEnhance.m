//
//  PDFYEnhance.m
//  PetDFY 可编辑源码 · 增强层（透明度 / 仅主屏显示 / 单击气泡）
//
//  还原依据：PDFYEnhance.dylib（arm64，5 个函数 / 855 条指令）
//    _pdfy_enhance_init      写标记文件 → dispatch_after(2s) → _loop
//    _loop                  找 PDWindow → setAlpha(PetOpacity) → 按 PetScope 决定 setHidden
//                            → 动态注册 PDFYTapHandler → 挂 UITapGestureRecognizer → 写标记
//    _onTap                  state 判定 + PetTapBubble 开关 → 建透明 UIWindow + UILabel("我在呢～")
//    __showBubble_block_invoke  延时移除气泡
//
//  说明：本文件是「行为等价重建」。原二进制里循环的重投递频率、标记文件内容以外的
//  细节无法从 855 条指令完全确定，凡属推断处均以 [推断] 标注，并且都做成了可改的常量。
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString * const kPrefsDomain = @"com.susudear.petdfyprefs";
static NSString * const kMarkerHooked = @"/var/mobile/Library/Preferences/.pdfy_enhance.hooked";
static NSString * const kMarkerTap = @"/var/mobile/Library/Preferences/.pdfy_enhance.tap";
static NSString * const kBubbleText = @"我在呢～";     // 原文串 @0x505d

#pragma mark - 偏好读取

static id PDFYPref(NSString *key, id fallback) {
    id v = (__bridge_transfer id)CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                           (__bridge CFStringRef)kPrefsDomain);
    return v ?: fallback;
}

static double PDFYDouble(NSString *key, double fallback) {
    id v = PDFYPref(key, nil);
    if ([v isKindOfClass:[NSNumber class]]) return [v doubleValue];
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v doubleValue];
    return fallback;
}

static void PDFYWriteMarker(NSString *path, const char *text) {
    [[NSString stringWithFormat:@"%s", text] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

#pragma mark - 单击气泡

@interface PDFYTapHandler : NSObject
- (void)onTap:(UITapGestureRecognizer *)gesture;
@end

static UIWindow *PDFYBubbleWindow = nil;

@implementation PDFYTapHandler

/// 原文串顺序：state → PetTapBubble → boolValue → UIScreen → … → setText("我在呢～")
- (void)onTap:(UITapGestureRecognizer *)gesture {
    if (!gesture || gesture.state != UIGestureRecognizerStateEnded) return;
    if (![PDFYPref(@"PetTapBubble", @YES) boolValue]) return;

    if (PDFYBubbleWindow) {
        PDFYBubbleWindow.hidden = YES;
        PDFYBubbleWindow = nil;
    }

    CGRect bounds = [UIScreen mainScreen].bounds;
    UIWindow *w = [[UIWindow alloc] initWithFrame:bounds];
    w.userInteractionEnabled = NO;
    w.windowLevel = UIWindowLevelAlert + 1;
    w.backgroundColor = [UIColor clearColor];
    UIViewController *vc = [[UIViewController alloc] init];
    w.rootViewController = vc;

    UILabel *label = [[UILabel alloc] init];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 2;
    label.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    label.textColor = [UIColor whiteColor];
    label.backgroundColor = [UIColor blackColor];
    label.clipsToBounds = YES;
    label.layer.cornerRadius = 14;
    label.text = kBubbleText;

    CGPoint p = [gesture locationInView:nil];
    CGFloat bw = 160, bh = 44;
    CGFloat x = p.x - bw / 2.0;
    CGFloat y = p.y - bh - 18.0;
    if (x < 8) x = 8;
    if (x + bw > bounds.size.width - 8) x = bounds.size.width - bw - 8;
    if (y < 60) y = p.y + 18.0;
    [vc.view addSubview:label];
    label.frame = CGRectMake(x, y, bw, bh);

    w.hidden = NO;
    PDFYBubbleWindow = w;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        PDFYBubbleWindow.hidden = YES;
        PDFYBubbleWindow = nil;
    });
}

@end

#pragma mark - 主循环

static void PDFYApply(void);
static void PDFYSchedule(double delay);

static UIWindow *PDFYFindPetWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    NSArray *windows = app.windows;
    for (NSUInteger i = 0; i < windows.count; i++) {
        UIWindow *w = [windows objectAtIndex:i];
        const char *cls = object_getClassName(w);
        if (!cls) continue;
        NSString *name = [NSString stringWithUTF8String:cls];
        if ([name isEqualToString:@"PDWindow"]) return w;
    }
    return nil;
}

static BOOL PDFYIsLocked(void) {
    Class mgr = objc_getClass("SBLockScreenManager");
    if (!mgr) return NO;
    id shared = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    if ([mgr respondsToSelector:@selector(sharedInstance)]) {
        shared = [mgr performSelector:@selector(sharedInstance)];
    }
    if ([shared respondsToSelector:@selector(isUILocked)]) return [shared performSelector:@selector(isUILocked)] ? YES : NO;
#pragma clang diagnostic pop
    return NO;
}

static BOOL PDFYIsHomeScreen(void) {
    Class appCls = objc_getClass("UIApplication");
    if (!appCls) return NO;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id app = [appCls performSelector:@selector(sharedApplication)];
    if ([app respondsToSelector:@selector(_accessibilityFrontMostApplication)]) {
        id front = [app performSelector:@selector(_accessibilityFrontMostApplication)];
        if ([front respondsToSelector:@selector(bundleIdentifier)]) {
            id bid = [front performSelector:@selector(bundleIdentifier)];
            if ([bid isKindOfClass:[NSString class]] &&
                [(NSString *)bid isEqualToString:@"com.apple.springboard"]) return YES;
        }
    }
#pragma clang diagnostic pop
    return NO;
}

static void PDFYApply(void) {
    UIWindow *petWindow = PDFYFindPetWindow();
    if (!petWindow) {
        PDFYSchedule(1.0);   // [推断] 未找到窗口 1s 后重试（springboard 启动晚于本层）
        return;
    }

    CGFloat opacity = (CGFloat)PDFYDouble(@"PetOpacity", 1.0);
    id scope = PDFYPref(@"PetScope", @"all");
    if (![scope isKindOfClass:[NSString class]]) scope = @"all";

    // 1) 透明度
    petWindow.alpha = opacity;

    // 2) 作用域："home" = 只在主屏幕显示
    BOOL hidden = NO;
    if ([(NSString *)scope isEqualToString:@"home"]) {
        hidden = PDFYIsLocked() || !PDFYIsHomeScreen();
    }
    petWindow.hidden = hidden;

    PDFYWriteMarker(kMarkerHooked, "ok: PDWindow found, alpha applied\n");

    // 3) 单击气泡：动态造类 + 挂手势（只挂一次）
    if (!objc_getClass("PDFYTapHandlerAttached")) {
        Class handlerCls = objc_getClass("PDFYTapHandler");
        if (!handlerCls) {
            handlerCls = objc_allocateClassPair([NSObject class], "PDFYTapHandler", 0);
            if (handlerCls) {
                class_addMethod(handlerCls, sel_registerName("onTap:"),
                                class_getMethodImplementation([PDFYTapHandler class], @selector(onTap:)),
                                "v@:@");
                objc_registerClassPair(handlerCls);
            }
        }
        id handler = [PDFYTapHandler new];
        UITapGestureRecognizer *tap =
            [[UITapGestureRecognizer alloc] initWithTarget:handler action:@selector(onTap:)];
        tap.cancelsTouchesInView = NO;
        [petWindow addGestureRecognizer:tap];
        PDFYWriteMarker(kMarkerTap, "tap gesture attached\n");
    }
}

static void PDFYSchedule(double delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        PDFYApply();
    });
}

#pragma mark - 构造

__attribute__((constructor))
static void pdfy_enhance_init(void) {
    // 原作者串：先 open(O_WRONLY|O_CREAT|O_TRUNC, 0644) 写 loaded 标记 → 再 2s 后跑 _loop
    NSString *marker = @"/var/mobile/Library/Preferences/.pdfy_enhance.loaded";
    [@"loaded: PDFYEnhance v3 constructor ran" writeToFile:marker
                                                 atomically:YES
                                                   encoding:NSUTF8StringEncoding
                                                      error:NULL];
    PDFYSchedule(2.0);
}
