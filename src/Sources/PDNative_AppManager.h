//
//  PDNative_AppManager : NSObject
//  逆向还原：ivar/方法/属性来自二进制元数据
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PetDFY.h"

@interface PDNative_AppManager : NSObject {
}

- (BOOL)launchApp:(id)arg1 error:(NSError **)arg2;
- (BOOL)killApp:(id)arg1 error:(NSError **)arg2;
- (id)listInstalledApps:(id)arg1;
- (id)listRunningApps;
- (id)getFrontmostApp;
- (BOOL)openURL:(id)arg1 error:(NSError **)arg2;
- (id)appBundlePathForBundleId:(id)arg1 mainExecutablePath:(NSString **)arg2;
- (id)waitForAppBundlePathForBundleId:(id)arg1 mainExecutablePath:(NSString **)arg2 timeout:(double)arg3;
- (id)newestInstalledAppBundlePathAfterDate:(id)arg1 resolvedBundleId:(NSString **)arg2 mainExecutablePath:(NSString **)arg3;
- (id)waitForInstalledAppBundlePathForBundleId:(id)arg1 installedAfter:(id)arg2 resolvedBundleId:(NSString **)arg3 mainExecutablePath:(NSString **)arg4 timeout:(double)arg5;
- (NSString *)bundleExecutablePathForBundlePath:(NSString *)bundlePath;
- (BOOL)isSignableBundlePath:(NSString *)path;
- (BOOL)hasSignableBundleAncestorForPath:(NSString *)path withinRoot:(NSString *)root;
- (NSArray<NSString *> *)signTargetsForAppBundlePath:(NSString *)bundlePath;
- (NSString *)bundleIdFromAppInstOutput:(NSString *)output;
- (BOOL)fakesignInstalledAppForBundleId:(id)arg1 installedAfter:(id)arg2 error:(NSError **)arg3;
- (BOOL)fakesignApp:(id)arg1;
- (BOOL)retryFakesignInstalledAppForBundleId:(id)arg1 installedAfter:(id)arg2;
- (BOOL)installDebPackage:(id)arg1 error:(NSError **)arg2;
- (BOOL)installApp:(id)arg1 error:(NSError **)arg2;
- (NSString *)bundleIdFromIPA:(NSString *)ipaPath;
- (BOOL)isAppInstalled:(id)arg1;
- (id)appInfoForBundleId:(id)arg1 error:(NSError **)arg2;
- (BOOL)debPackageInstalled:(id)arg1 statusOutput:(NSString **)arg2 error:(NSError **)arg3;
- (BOOL)uninstallDebPackage:(id)arg1 error:(NSError **)arg2;
- (BOOL)uninstallApp:(id)arg1 error:(NSError **)arg2;
+ (id)sharedInstance;
@end
