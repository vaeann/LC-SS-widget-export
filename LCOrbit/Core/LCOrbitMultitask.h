#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *const LCOrbitMultitaskLaunchFailedNotification;
FOUNDATION_EXPORT NSString *const LCOrbitMultitaskMenuRequestedNotification;
FOUNDATION_EXPORT NSString *const LCOrbitMultitaskConfigurationChangedNotification;

// Runs in the injected LC host. Guest processes keep the classic launch path.
@interface LCOrbitMultitask : NSObject
+ (BOOL)isEnabled;
// System mode never participates in window geometry/visibility enforcement.
+ (BOOL)isManagingWindows;
+ (BOOL)setEnabled:(BOOL)enabled error:(NSError * _Nullable * _Nullable)error;
+ (BOOL)usesSystemMenu;
+ (BOOL)setUseSystemMenu:(BOOL)system error:(NSError * _Nullable * _Nullable)error;
+ (BOOL)shouldShowFloatingMenu;
+ (BOOL)launchGuest:(NSDictionary *)guest error:(NSError * _Nullable * _Nullable)error;
+ (BOOL)isCurrentGuest:(NSDictionary *)guest;
+ (BOOL)togglePiPForActiveWindow:(NSError * _Nullable * _Nullable)error;
// Close the actual AVKit PiP session, not the running Guest process.
+ (BOOL)isPiPActive;
+ (BOOL)stopPiPIfActive:(NSError * _Nullable * _Nullable)error;
+ (BOOL)automaticPiPEnabledForGuest:(NSDictionary *)guest;
+ (BOOL)setAutomaticPiPEnabled:(BOOL)enabled forGuest:(NSDictionary *)guest error:(NSError * _Nullable * _Nullable)error;
+ (nullable NSDictionary *)activeGuestForAutomaticPiP;
+ (void)showHome;
+ (BOOL)closeCurrentGuest;
// Exact target close: no fallback to the foreground task or a namesake app.
+ (BOOL)isRunningGuest:(NSDictionary *)guest;
// 一次性快照：逐 App 查询 isRunningGuest 每次都要解析 canonical 路径（磁盘符号链接），
// 19 个 App 展开一轮就是几十次系统调用。需要批量判断时改用这三个。
+ (NSArray<NSDictionary *> *)runningTaskKeys;
+ (nullable NSDictionary *)activeTaskKey;
+ (nullable NSDictionary *)foregroundTaskKey;
+ (BOOL)closeGuest:(NSDictionary *)guest error:(NSError * _Nullable * _Nullable)error;
// 一次结束全部运行中的任务（微珠底部"关闭"按钮长按）。返回实际发出关闭请求的个数。
+ (NSUInteger)closeAllGuests;
+ (NSArray *)windows;
+ (nullable id)activeWindow;
+ (void)recordWindow:(id)window bundle:(NSString *)bundle container:(NSString *)container;
+ (void)forgetWindow:(nullable id)window;
+ (void)didActivateWindow:(id)window;
+ (void)didHideWindow:(id)window;
+ (void)requestMenu;
@end

// UIKit adapter installs guarded runtime hooks without linking LC classes.
@interface LCOrbitMultitask (Presentation)
+ (BOOL)installHooksWithError:(NSError * _Nullable * _Nullable)error;
+ (void)refreshPresentation;
// Legacy switch API: YES = v5 physical avoidance; NO = v6 Guest-owned top inset.
+ (BOOL)usesAppTopInsetForBundle:(NSString *)bundle;
+ (void)setUsesAppTopInset:(BOOL)enabled forBundle:(NSString *)bundle;
@end
NS_ASSUME_NONNULL_END
