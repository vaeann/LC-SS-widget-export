#import "LCOrbitStorage.h"
#import "LCOrbitHost.h"
#import <sys/file.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <math.h>

static NSError *StorageError;
static NSMutableDictionary<NSString *,NSDictionary *> *LastGood;
static const NSUInteger MaximumConfigSize=1048576;
static BOOL PluginKey(id key) {
    return [key isKindOfClass:NSString.class] &&
        ![key isEqualToString:@"LCFloatingMenu.previousMultitaskMode"] &&
        ([key hasPrefix:@"LCFloatingMenu."] || [key hasPrefix:@"LCOrbit.module."]);
}
static BOOL JSONValue(id value) {
    if([value isKindOfClass:NSString.class]) return YES;
    if([value isKindOfClass:NSNumber.class]) return isfinite([value doubleValue]);
    if([value isKindOfClass:NSArray.class]) {
        for(id item in value) if(!JSONValue(item)) return NO;
        return YES;
    }
    if([value isKindOfClass:NSDictionary.class]) {
        for(id key in value) if(![key isKindOfClass:NSString.class] || !JSONValue(value[key])) return NO;
        return YES;
    }
    return NO;
}
static BOOL PreferenceValue(NSString *key,id value) {
    if(!JSONValue(value)) return NO;
    NSString *name=[key hasPrefix:@"LCFloatingMenu."]?[key substringFromIndex:15]:key;
    if([@[@"favoritePaths",@"menuOrder",@"autoPiPApps"] containsObject:name]) {
        if(![value isKindOfClass:NSArray.class]) return NO;
        for(id item in value) if(![item isKindOfClass:NSString.class]) return NO;
    } else if([@[@"accentLight",@"accentDark"] containsObject:name]) {
        return [value isKindOfClass:NSString.class];
    } else if([key hasPrefix:@"LCOrbit.module."] ||
              [@[@"fullscreenMultitask",@"systemMultitaskMenu",@"autoSyncSharedTweaks",@"idleAlpha",@"menuExtension",@"menuCornerRadius",@"menuCurveSoftness",@"menuCompactIconSize",@"menuListIconSize",@"menuTopPadding",@"orbHandleStyle",@"orbHandleReach",@"orbHandleLength",@"orbCapsuleCorner",@"orbSoftness",@"orbGlowLength",@"orbGlowBrightness",@"orbSnapDuration",@"orbSnapDamping",@"fadeDelay",@"fadedOpacity",@"popAnimation",@"iconFrame",@"glowLine",@"roundedTop",@"previewFollowsMode",@"orbScale",@"orbWidth",@"orbY",@"onLeft",@"roundOrb",@"autoFade",@"haptic",@"confirm",@"showRestart",@"compactRestart",@"compactMode",@"panelScale",@"glassTint",@"clearGlass",@"appearanceMode",@"preferDarkIcons"] containsObject:name] ||
              [name hasPrefix:@"appAlpha."] || [name hasPrefix:@"override."] ||
              [name hasPrefix:@"doubleTap."] || [name hasPrefix:@"stealth."] || [name hasPrefix:@"appEnabled."]) {
        return [value isKindOfClass:NSNumber.class];
    }
    return YES;
}
static NSError *Error(NSString *description) {
    return [NSError errorWithDomain:@"LCOrbitStorage" code:1 userInfo:@{NSLocalizedDescriptionKey:description}];
}
static NSDictionary *LegacyValues(void) {
    NSDictionary *legacy=[[LCOrbitHost hostDefaults] dictionaryRepresentation];
    NSMutableDictionary *values=[NSMutableDictionary dictionary];
    for(NSString *key in legacy) if(PluginKey(key) && PreferenceValue(key,legacy[key])) values[key]=legacy[key];
    return values;
}
static NSString *ConfigPath(NSString *root) { return [root stringByAppendingPathComponent:@"config.json"]; }
static NSString *BackupPath(NSString *root) { return [root stringByAppendingPathComponent:@"config.last-good.json"]; }
// LC 的 App Group：宿主用系统 API 取真实路径后存进 NSUserDefaults.lcAppGroupPath，
// 游客侧的 containerURLForSecurityApplicationGroupIdentifier 被 LC hook 成直接返回
// 同一个路径（NSFileManager+GuestHooks.m）。所以这是主客唯一天然一致的目录，
// 不用猜 LC_HOME_PATH，也不用从 dylib 位置反推。
static NSString *LCAppGroupRoot(void) {
    static NSString *cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class defaults = NSClassFromString(@"NSUserDefaults");
        SEL selector = NSSelectorFromString(@"lcAppGroupPath");
        if(!defaults || ![defaults respondsToSelector:selector]) return;
        NSString *path = ((NSString *(*)(id,SEL))objc_msgSend)(defaults,selector);
        if(![path isKindOfClass:NSString.class] || !path.length) return;
        cached = [path stringByAppendingPathComponent:@"LCOrbit"];
    });
    return cached;
}
// 从本 dylib 的位置反推配置目录。<root>/Documents/Tweaks/LCFloatingMenu.dylib
// 往上找到 Tweaks，它的父目录就是 <root>/Documents。宿主和游客加载的是同一个
// dylib（或同一份拷贝），这条路不依赖任何环境变量，两边必然算出同一个目录。
// 注意：取的是「函数自身」的地址。dladdr 对函数地址可靠，对全局变量的数据
// 地址不保证能解析出所属模块（之前用 &StorageError 就因此静默失败过）。
static NSString *PluginStorageRoot(void) {
    Dl_info info;
    if(dladdr((void *)&PluginStorageRoot,&info)==0 || !info.dli_fname) return nil;
    NSString *dir=[@(info.dli_fname) stringByDeletingLastPathComponent];
    for(int depth=0;depth<4 && dir.length;depth++) {
        if([dir.lastPathComponent isEqualToString:@"Tweaks"])
            return [[dir stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"LCOrbit"];
        dir=[dir stringByDeletingLastPathComponent];
    }
    return nil;
}
static NSDictionary *ReadDocument(NSString *file,NSError **error) {
    struct stat info;
    if(lstat(file.fileSystemRepresentation,&info)!=0 || !S_ISREG(info.st_mode) || info.st_size<0 || (unsigned long long)info.st_size>MaximumConfigSize) {
        if(error) *error=Error(@"配置文件不可读取、不是普通文件或超过 1 MiB。");
        return nil;
    }
    NSData *data=[NSData dataWithContentsOfFile:file options:NSDataReadingMappedIfSafe error:error];
    id document=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:error]:nil;
    if(![document isKindOfClass:NSDictionary.class] ||
       ![document[@"schemaVersion"] isKindOfClass:NSNumber.class] ||
       [document[@"schemaVersion"] doubleValue]!=1 ||
       ![document[@"preferences"] isKindOfClass:NSDictionary.class]) {
        if(error && !*error) *error=Error(@"配置 JSON 格式或版本不受支持。");
        return nil;
    }
    NSDictionary *values=document[@"preferences"];
    for(id key in values) if(!PluginKey(key) || !PreferenceValue(key,values[key])) {
        if(error) *error=Error(@"配置包含不允许的键或不正确的值类型。");
        return nil;
    }
    return values;
}
// 宿主每次保存都会往 App Group 写一份镜像，游客只读这一份。
// 这样游客的 LC_HOME_PATH 指到哪里都无所谓，配置不会再静默回落到默认值。
static BOOL WriteDocument(NSString *path,NSDictionary *values,NSError **error);
static NSDictionary *ReadAppGroupMirror(void) {
    NSString *root=LCAppGroupRoot();
    if(!root.length) return nil;
    return ReadDocument(ConfigPath(root),nil);
}
static void WriteAppGroupMirror(NSDictionary *values) {
    NSString *root=LCAppGroupRoot();
    if(!root.length || !values) return;
    [NSFileManager.defaultManager createDirectoryAtPath:root
                            withIntermediateDirectories:YES attributes:nil error:nil];
    WriteDocument(ConfigPath(root),values,nil);
}
static NSData *DocumentData(NSDictionary *values,NSError **error) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"schemaVersion":@1,@"preferences":values}
        options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:error];
    if(data.length>MaximumConfigSize) {
        if(error) *error=Error(@"配置超过 1 MiB，未写入。");
        return nil;
    }
    return data;
}
static BOOL WriteDocument(NSString *path,NSDictionary *values,NSError **error) {
    struct stat info;
    if(lstat(path.fileSystemRepresentation,&info)==0 && !S_ISREG(info.st_mode)) {
        if(error) *error=Error(@"配置目标不是普通文件，未写入。");
        return NO;
    }
    NSData *data=DocumentData(values,error);
    return data && [data writeToFile:path options:NSDataWritingAtomic error:error];
}
static int LockRoot(NSString *root,NSError **error) {
    if(!root.length || ![NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:error]) return -1;
    struct stat info;
    if(lstat(root.fileSystemRepresentation,&info)!=0 || !S_ISDIR(info.st_mode)) {
        if(error) *error=Error(@"LCOrbit 配置目录不安全。");
        return -1;
    }
    NSString *path=[root stringByAppendingPathComponent:@".config.lock"];
    int lock=open(path.fileSystemRepresentation,O_CREAT|O_RDWR|O_NOFOLLOW,0600);
    if(lock<0 || flock(lock,LOCK_EX)!=0) {
        if(lock>=0) close(lock);
        if(error) *error=Error(@"无法锁定 LCOrbit 配置文件。");
        return -1;
    }
    return lock;
}
static void Unlock(int lock) { flock(lock,LOCK_UN);close(lock); }
// Called with process and file locks. Invalid existing documents stay untouched.
static NSDictionary *Load(NSString *root,BOOL *valid,NSError **error) {
    if(!LastGood) LastGood=[NSMutableDictionary dictionary];
    NSString *path=ConfigPath(root);struct stat info;NSDictionary *values=nil;
    if(lstat(path.fileSystemRepresentation,&info)!=0) {
        values=ReadDocument(BackupPath(root),nil) ?: LastGood[root] ?: LegacyValues();
        *valid=WriteDocument(path,values,error);
    } else {
        values=ReadDocument(path,error);*valid=values!=nil;
    }
    if(*valid) {
        LastGood[root]=[values copy];
        NSDictionary *backup=ReadDocument(BackupPath(root),nil);
        if(![backup isEqual:values]) WriteDocument(BackupPath(root),values,nil);
        return values;
    }
    NSDictionary *recovered=ReadDocument(BackupPath(root),nil) ?: LastGood[root] ?: LegacyValues();
    LastGood[root]=[recovered copy];
    return recovered;
}
static NSDictionary *ReadValues(void) {
    @synchronized(LCOrbitStorage.class) {
        // 游客优先读宿主写下的 App Group 镜像：它自己的 rootPath 可能指向
        // 沙盒里一份空配置，读出来全是默认值（保活时长 20、开关永远开）。
        if(![LCOrbitHost isHostUI]) {
            NSDictionary *mirror=ReadAppGroupMirror();
            if(mirror) return mirror;
        }
        NSError *error=nil;NSString *root=[LCOrbitStorage rootPath];int lock=LockRoot(root,&error);
        if(lock<0) {
            StorageError=error?:Error(@"无法访问 LC 宿主配置目录。");
            return (root?LastGood[root]:nil) ?: LegacyValues();
        }
        BOOL valid=NO;NSDictionary *values=Load(root,&valid,&error);
        Unlock(lock);StorageError=error;return values;
    }
}
@implementation LCOrbitPreferences
- (id)objectForKey:(NSString *)key {
    if(!PluginKey(key)) return [[LCOrbitHost hostDefaults] objectForKey:key];
    return ReadValues()[key];
}
- (void)setObject:(id)value forKey:(NSString *)key {
    if(!PluginKey(key)) {
        if(value) [[LCOrbitHost hostDefaults] setObject:value forKey:key];
        else [[LCOrbitHost hostDefaults] removeObjectForKey:key];
        return;
    }
    @synchronized(LCOrbitStorage.class) {
        if(value && !PreferenceValue(key,value)) { StorageError=Error(@"配置值类型不正确，未保存。");return; }
        NSError *error=nil;NSString *root=[LCOrbitStorage rootPath];int lock=LockRoot(root,&error);
        if(lock<0) {
            // A warm JSON configuration must not split into a second, stale
            // preference backend when its directory temporarily disappears.
            if(!root || !LastGood[root]) {
                if(value) [[LCOrbitHost hostDefaults] setObject:value forKey:key];
                else [[LCOrbitHost hostDefaults] removeObjectForKey:key];
            }
            StorageError=error?:Error(@"无法访问 LC 宿主配置目录，JSON 配置未保存。");return;
        }
        BOOL valid=NO;NSDictionary *current=Load(root,&valid,&error);
        if(valid) {
            NSMutableDictionary *next=[current mutableCopy];
            if(value) next[key]=value;else [next removeObjectForKey:key];
            if(WriteDocument(ConfigPath(root),next,&error)) {
                LastGood[root]=[next copy];WriteDocument(BackupPath(root),next,nil);
                if([LCOrbitHost isHostUI]) WriteAppGroupMirror(next);
            }
        }
        Unlock(lock);StorageError=error;
    }
}
- (void)removeObjectForKey:(NSString *)key { [self setObject:nil forKey:key]; }
- (BOOL)boolForKey:(NSString *)key { id value=[self objectForKey:key];return [value respondsToSelector:@selector(boolValue)]?[value boolValue]:NO; }
- (NSInteger)integerForKey:(NSString *)key { id value=[self objectForKey:key];return [value respondsToSelector:@selector(integerValue)]?[value integerValue]:0; }
- (double)doubleForKey:(NSString *)key { id value=[self objectForKey:key];return [value respondsToSelector:@selector(doubleValue)]?[value doubleValue]:0; }
- (NSString *)stringForKey:(NSString *)key { id value=[self objectForKey:key];return [value isKindOfClass:NSString.class]?value:nil; }
- (NSArray *)arrayForKey:(NSString *)key { id value=[self objectForKey:key];return [value isKindOfClass:NSArray.class]?value:nil; }
- (void)setBool:(BOOL)value forKey:(NSString *)key { [self setObject:@(value) forKey:key]; }
- (void)setInteger:(NSInteger)value forKey:(NSString *)key { [self setObject:@(value) forKey:key]; }
- (NSDictionary *)dictionaryRepresentation { return ReadValues(); }
- (BOOL)synchronize { return [LCOrbitStorage reloadWithError:nil]; }
@end
@implementation LCOrbitStorage
+ (NSString *)key:(NSString *)key forModule:(NSString *)identifier { return [NSString stringWithFormat:@"%@.%@",identifier,key]; }
+ (id)objectForKey:(NSString *)key module:(NSString *)identifier { return [[self preferences] objectForKey:[self key:key forModule:identifier]]; }
+ (void)setObject:(id)object forKey:(NSString *)key module:(NSString *)identifier { [[self preferences] setObject:object forKey:[self key:key forModule:identifier]]; }
+ (NSString *)rootPath {
    // Guest（尤其多任务 LiveProcess）不一定有 LC_HOME_PATH：那个变量是宿主
    // 透传过去的，透传不到时整个偏好系统会静默回落到默认值——保活时长永远
    // 是默认 20 分钟、保活开关永远是开，改了设置也不生效。
    // 所以这里按可信度排候选，并且优先选真正有 config.json 的那个，
    // 避免 LockRoot 在错误路径上凭空建出一个空配置。
    static NSString *resolved=nil;
    static dispatch_once_t once;
    dispatch_once(&once,^{
        NSMutableArray<NSString *> *candidates=[NSMutableArray array];
        // dylib 反推排第一：它和 dylib 的实际位置强绑定，主客必然一致。
        // 环境变量只作兜底——它们可能指向游客自己沙盒里的 Documents，
        // 那里 createDirectory 也会成功，于是文件写进去、宿主永远看不到。
        NSString *derived=PluginStorageRoot();
        if(derived.length) [candidates addObject:derived];
        const char *lc=getenv("LC_HOME_PATH");
        if(lc && lc[0]) [candidates addObject:
            [@(lc) stringByAppendingPathComponent:@"Documents/LCOrbit"]];
        const char *lp=getenv("LP_HOME_PATH");
        if(lp && lp[0]) [candidates addObject:
            [@(lp) stringByAppendingPathComponent:@"Documents/LCOrbit"]];
        NSFileManager *fm=NSFileManager.defaultManager;
        NSString *fallback=nil;
        for(NSString *path in candidates) {
            if([fm fileExistsAtPath:ConfigPath(path)]) { resolved=path; return; }
            if(!fallback && [fm fileExistsAtPath:path]) fallback=path;
        }
        resolved=fallback ?: candidates.firstObject;
    });
    return resolved;
}
+ (NSString *)appGroupRootPath {
    return LCAppGroupRoot();
}
+ (LCOrbitPreferences *)preferences {
    static LCOrbitPreferences *preferences;static dispatch_once_t once;
    dispatch_once(&once,^{preferences=[LCOrbitPreferences new];});return preferences;
}
+ (BOOL)reloadWithError:(NSError **)error {
    @synchronized(self) { ReadValues();if(error) *error=StorageError;return StorageError==nil; }
}
+ (NSError *)lastError { @synchronized(self) { return StorageError; } }

// ---- 微珠主题色（单一真相） -------------------------------------------------
// 完整对齐主面板配色公式：文字/背景/表面/边框都从自定义主题色
// （accentLight/accentDark，LCFloatingMenu 模块的键）按比例混合派生，含彩蛋模式。
static UIColor *ThemeFromHex(NSString *hex,unsigned fallback) {
    unsigned rgb=fallback;
    if([hex isKindOfClass:NSString.class] && hex.length==7 && [hex hasPrefix:@"#"]) {
        unsigned value=0;
        NSScanner *scanner=[NSScanner scannerWithString:[hex substringFromIndex:1]];
        if([scanner scanHexInt:&value] && scanner.isAtEnd) rgb=value;
    }
    return [UIColor colorWithRed:((rgb>>16)&255)/255.0
                           green:((rgb>>8)&255)/255.0
                            blue:(rgb&255)/255.0 alpha:1.0];
}
static UIColor *ThemeMix(UIColor *a,UIColor *b,CGFloat t) {
    CGFloat r1=0,g1=0,b1=0,a1=0,r2=0,g2=0,b2=0,a2=0;
    [a getRed:&r1 green:&g1 blue:&b1 alpha:&a1];
    [b getRed:&r2 green:&g2 blue:&b2 alpha:&a2];
    return [UIColor colorWithRed:r1+(r2-r1)*t green:g1+(g2-g1)*t blue:b1+(b2-b1)*t alpha:a1+(a2-a1)*t];
}
+ (NSString *)themeModuleKey:(NSString *)key {
    return [self key:key forModule:@"LCFloatingMenu"];
}
+ (UIColor *)themeColorForRole:(LCOrbitColorRole)role dark:(BOOL)dark {
    NSDictionary *prefs=[self preferences];
    BOOL egg=[[prefs objectForKey:[self themeModuleKey:@"easterEggIOSTheme"]] boolValue];
    NSString *accentHex=[prefs objectForKey:[self themeModuleKey:dark?@"accentDark":@"accentLight"]];
    UIColor *accent=ThemeFromHex(accentHex,dark?0x8AC9FF:0x245DAB);
    if(egg) {
        switch(role) {
            case LCOrbitColorAccent:     return ThemeFromHex(dark?@"#0A84FF":@"#007AFF",dark?0x0A84FF:0x007AFF);
            case LCOrbitColorText:       return ThemeFromHex(dark?@"#FFFFFF":@"#000000",dark?0xFFFFFF:0x000000);
            case LCOrbitColorSecondary:  return ThemeFromHex(@"#8E8E93",0x8E8E93);
            case LCOrbitColorBackground: return ThemeFromHex(dark?@"#000000":@"#F2F2F7",dark?0x000000:0xF2F2F7);
            case LCOrbitColorSurface:    return ThemeFromHex(dark?@"#1C1C1E":@"#FFFFFF",dark?0x1C1C1E:0xFFFFFF);
            case LCOrbitColorGlass:      return ThemeFromHex(dark?@"#2C2C2E":@"#E5E5EA",dark?0x2C2C2E:0xE5E5EA);
            case LCOrbitColorRow:        return ThemeFromHex(dark?@"#1C1C1E":@"#FFFFFF",dark?0x1C1C1E:0xFFFFFF);
            case LCOrbitColorTool:       return ThemeFromHex(dark?@"#2C2C2E":@"#E5E5EA",dark?0x2C2C2E:0xE5E5EA);
            case LCOrbitColorBorder:     return ThemeFromHex(dark?@"#38383A":@"#D1D1D6",dark?0x38383A:0xD1D1D6);
        }
    }
    UIColor *surface=ThemeFromHex(nil,dark?0x1A2537:0xFFFFFF);
    switch(role) {
        case LCOrbitColorAccent:     return accent;
        case LCOrbitColorText:       return ThemeFromHex(nil,dark?0xF3F7FF:0x182638);
        case LCOrbitColorSecondary:  return ThemeFromHex(nil,dark?0xC3CEDE:0x4B5B6C);
        case LCOrbitColorBackground: return ThemeMix(ThemeFromHex(nil,dark?0x0B1220:0xF7F9FD),accent,dark?.12:.085);
        case LCOrbitColorSurface:    return ThemeMix(surface,accent,dark?.21:.075);
        case LCOrbitColorGlass:      return ThemeMix(ThemeFromHex(nil,dark?0x22334A:0xF2F8FF),accent,.38);
        case LCOrbitColorRow:        return ThemeMix(surface,accent,dark?.36:.18);
        case LCOrbitColorTool:       return ThemeMix(surface,accent,dark?.43:.24);
        case LCOrbitColorBorder:     return ThemeMix(ThemeFromHex(nil,dark?0x6B829A:0x97A8B8),accent,.36);
    }
    return surface;
}
@end
