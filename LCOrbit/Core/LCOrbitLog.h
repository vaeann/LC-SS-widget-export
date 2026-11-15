#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Structured, bounded plugin logs. Callers provide plugin events only.
@interface LCOrbitLog : NSObject
+ (nullable NSString *)pathForKind:(NSString *)kind;
+ (void)appendEvent:(NSString *)event details:(nullable id)details kind:(NSString *)kind;
+ (NSData *)dataForKind:(NSString *)kind;
+ (void)clearKind:(NSString *)kind;
// 总开关：关闭后 appendEvent 直接返回，不格式化、不入队、不写盘。
+ (BOOL)loggingEnabled;
+ (void)setLoggingEnabled:(BOOL)enabled;
@end
NS_ASSUME_NONNULL_END
