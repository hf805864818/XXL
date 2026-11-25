//
//  PDAIGlobals.m
//  补齐 PetDFY.h 中只有声明、没有实现的全局函数。
//  这些符号缺失时，dyld 在 dlopen 阶段会报 symbol not found，
//  ellekit 静默跳过整个 PetDFY.dylib。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "PetDFY.h"

static NSString *PDAIGlobalJailbreakRoot(void) {
    const char *env = getenv("JB_ROOT_PATH");
    if (env && env[0]) return [NSString stringWithUTF8String:env];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *apps = [fm contentsOfDirectoryAtPath:@"/var/containers/Bundle/Application" error:NULL];
    for (NSString *name in apps) {
        if (![name hasPrefix:@".jbroot-"]) continue;
        NSString *root = [@"/var/containers/Bundle/Application" stringByAppendingPathComponent:name];
        if ([fm fileExistsAtPath:[root stringByAppendingPathComponent:@"Library"]]) return root;
    }
    if ([fm fileExistsAtPath:@"/var/jb/Library"]) return @"/var/jb";
    return nil;
}

NSString *PDDataPath(void) {
    NSString *path = @"/var/mobile/Library/Application Support/PetDFY";
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:NULL];
    }
    return path;
}

id PDAIPreference(NSString *key, id fallback) {
    if (![key isKindOfClass:[NSString class]] || key.length == 0) return fallback;
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        CFSTR("com.susudear.petdfyprefs"));
    if (value) return (__bridge_transfer id)value;
    return fallback;
}

void PDAIWritePreferences(NSDictionary *values) {
    if (![values isKindOfClass:[NSDictionary class]]) return;
    CFStringRef domain = CFSTR("com.susudear.petdfyprefs");
    for (id key in values) {
        if (![key isKindOfClass:[NSString class]]) continue;
        CFPreferencesSetAppValue((__bridge CFStringRef)key,
                                 (__bridge CFPropertyListRef)values[key],
                                 domain);
    }
    CFPreferencesAppSynchronize(domain);
}

NSString *PDAIString(id value) {
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) return [(NSNumber *)value stringValue];
    if (value) return [value description];
    return @"";
}

NSString *PDLocalizedString(NSString *key) {
    if (![key isKindOfClass:[NSString class]]) return @"";
    NSString *language = [[NSLocale preferredLanguages] firstObject] ?: @"en";
    NSString *root = PDAIGlobalJailbreakRoot();
    NSString *bundlePath = @"/Library/Application Support/PetDFY.bundle";
    if (root) {
        NSString *candidate = [root stringByAppendingPathComponent:bundlePath];
        if ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) bundlePath = candidate;
    }
    NSBundle *bundle = [NSBundle bundleWithPath:bundlePath];
    NSString *value = [bundle localizedStringForKey:key value:nil table:nil];
    if (value && ![value isEqualToString:key]) return value;
    (void)language;
    return key;
}

double PDAINumber(id value, double fallback) {
    if ([value isKindOfClass:[NSNumber class]]) return [(NSNumber *)value doubleValue];
    if ([value isKindOfClass:[NSString class]]) {
        NSScanner *scanner = [NSScanner scannerWithString:value];
        double d = 0;
        if ([scanner scanDouble:&d]) return d;
    }
    return fallback;
}

NSString *PDAIDefaultEnvironment(void) {
    NSDictionary *env = [[NSProcessInfo processInfo] environment];
    NSData *data = [NSJSONSerialization dataWithJSONObject:(env ?: @{}) options:0 error:NULL];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
}

NSDictionary *PDAIPromptValues(void) {
    return @{ @"language": [[NSLocale preferredLanguages] firstObject] ?: @"en",
              @"platform": @"ios" };
}

BOOL PDNativeIsMachOFileAtPath(NSString *path) {
    if (![path isKindOfClass:[NSString class]]) return NO;
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return NO;
    NSData *head = [fh readDataOfLength:4];
    [fh closeFile];
    if (head.length < 4) return NO;
    const uint8_t *b = head.bytes;
    return (b[0] == 0xcf && b[1] == 0xfa && b[2] == 0xed && b[3] == 0xfe) ||
           (b[0] == 0xca && b[1] == 0xfe && b[2] == 0xba && b[3] == 0xbe) ||
           (b[0] == 0xce && b[1] == 0xfa && b[2] == 0xed && b[3] == 0xfe) ||
           (b[0] == 0xfe && b[1] == 0xed && b[2] == 0xfa && b[3] == 0xce);
}

id _PDPerformScreenCaptureWithExcludedLayer(CALayer *layer, id (^block)(void)) {
    BOOL old = layer.hidden;
    layer.hidden = YES;
    id result = block ? block() : nil;
    layer.hidden = old;
    return result;
}
