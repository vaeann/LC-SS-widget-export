#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
// 微珠主题角色：主面板与各模块子页/入口行共用同一套配色计算（见 themeColorForRole:）。
typedef NS_ENUM(NSUInteger, LCOrbitColorRole) {
    LCOrbitColorAccent, LCOrbitColorText, LCOrbitColorSecondary, LCOrbitColorBackground,
    LCOrbitColorSurface, LCOrbitColorGlass, LCOrbitColorRow, LCOrbitColorTool, LCOrbitColorBorder
};
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
// 主题色单一真相：完整对齐微珠主面板配色（自定义主题色混合 + 彩蛋模式），
// 保活/显隐子页与入口行也走这里，改自定义颜色或切日夜间全局同步。
+ (nullable UIColor *)themeColorForRole:(LCOrbitColorRole)role dark:(BOOL)dark;
@end
NS_ASSUME_NONNULL_END
