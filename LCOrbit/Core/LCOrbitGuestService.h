#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *const LCOrbitGuestErrorDomain;
typedef NS_ENUM(NSInteger, LCOrbitGuestError) {
    LCOrbitGuestErrorInvalidTarget=1, LCOrbitGuestErrorIneligible,
    LCOrbitGuestErrorMissingAPI, LCOrbitGuestErrorMissingScheme,
    LCOrbitGuestErrorInvalidURL, LCOrbitGuestErrorRejected,
    LCOrbitGuestErrorSideStoreMissing
};
@interface LCOrbitGuestService : NSObject
// Complete installed inventory, including current, JIT, hidden and locked apps.
// Use this for listing, favorites and plugin assignments, not launch permission.
// Each item carries a scope-aware identity, launchable flag and concise status.
+ (NSArray<NSDictionary*> *)installedApps;
// 安装/隐藏/锁定发生变化后调用，下一次 installedApps 会重新扫描。
// 微珠从自己的抽屉启动 App 时，LC 的 App 列表启动流程不会执行，
// 因此 LCAppInfo.plist 的 lastLaunched 不会更新 → "上次打开"排序停在原位。
// 这里按 LC 自己的写法补一次（它同样是直接改这个键并整份保存）。
+ (BOOL)markGuestLaunched:(NSDictionary *)app;
+ (void)invalidateInstalledAppsCache;
// 复用 LiveContainer 自己的排序设置（LCAppSortType / LCCustomSortOrder）。
+ (NSString *)appSortType;
+ (NSArray<NSString *> *)customSortOrder;
// Only for callers that specifically require a validated quick-launch target.
+ (NSArray<NSDictionary*> *)launchableApps;
+ (NSArray<NSString*> *)inventoryDiagnostics;
+ (BOOL)isCurrentGuest:(NSDictionary *)app;
+ (BOOL)isBuiltInSideStoreAvailable;
+ (BOOL)isEligibleGuestPath:(NSString *)path uuid:(nullable NSString *)uuid;
// Prefer the identity-aware entrypoint for UI selections. It re-reads disk state.
+ (BOOL)launchGuest:(NSDictionary *)app error:(NSError * _Nullable * _Nullable)error;
+ (BOOL)launchGuestPath:(NSString *)path uuid:(nullable NSString *)uuid error:(NSError * _Nullable * _Nullable)error;
+ (BOOL)launchBuiltInSideStoreWithError:(NSError * _Nullable * _Nullable)error;
@end
NS_ASSUME_NONNULL_END
