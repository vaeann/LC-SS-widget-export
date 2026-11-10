#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface LCOrbitPreferences : NSObject
- (nullable id)objectForKey:(NSString *)key;
- (void)setObject:(nullable id)value forKey:(NSString *)key;
- (void)removeObjectForKey:(NSString *)key;
- (BOOL)boolForKey:(NSString *)key;
- (NSInteger)integerForKey:(NSString *)key;
- (double)doubleForKey:(NSString *)key;
- (nullable NSString *)stringForKey:(NSString *)key;
- (nullable NSArray *)arrayForKey:(NSString *)key;
- (void)setBool:(BOOL)value forKey:(NSString *)key;
- (void)setInteger:(NSInteger)value forKey:(NSString *)key;
- (NSDictionary *)dictionaryRepresentation;
- (BOOL)synchronize;
@end
/// Existing LCFloatingMenu.* preference keys remain intact across migration.
@interface LCOrbitStorage : NSObject
+ (NSString *)key:(NSString *)key forModule:(NSString *)identifier;
+ (nullable id)objectForKey:(NSString *)key module:(NSString *)identifier;
+ (void)setObject:(nullable id)object forKey:(NSString *)key module:(NSString *)identifier;
+ (nullable NSString *)rootPath;
/// LC App Group 下的插件目录。宿主与游客拿到的是同一个物理路径，
/// 是唯一不依赖环境变量/路径反推的跨进程通道；不可用时为 nil。
+ (nullable NSString *)appGroupRootPath;
+ (LCOrbitPreferences *)preferences;
+ (BOOL)reloadWithError:(NSError * _Nullable * _Nullable)error;
+ (nullable NSError *)lastError;
@end
NS_ASSUME_NONNULL_END
