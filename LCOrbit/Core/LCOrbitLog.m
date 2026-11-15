#import "LCOrbitLog.h"
#import "LCOrbitStorage.h"
#import "LCOrbitHost.h"
#import <sys/file.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>

@interface LCOrbitStorage (LogDirectory)
+ (nullable NSString *)rootPath;
@end

static const NSUInteger LogLimit=262144;
static BOOL LogEnabled=YES;
static BOOL LogEnabledResolved=NO;
// 批量写：原来每条事件都「读整个 JSON → 追加 → 原子重写」，一次展开 3~6 条就是 3~6 次全量写。
// 现在先进内存队列，400ms 内合并成一次落盘。
static NSMutableDictionary<NSString *,NSMutableArray<NSDictionary *> *> *PendingEvents;
static NSMutableSet<NSString *> *PendingKinds;
static dispatch_queue_t LogFlushQueue;
static id PendingToken;
static void EnsurePending(void) {
    static dispatch_once_t once;
    dispatch_once(&once,^{
        PendingEvents=[NSMutableDictionary dictionary];
        PendingKinds=[NSMutableSet set];
        PendingToken=[NSObject new];
        LogFlushQueue=dispatch_queue_create("orbit.log.flush",DISPATCH_QUEUE_SERIAL);
    });
}
static BOOL Kind(NSString *kind) { return [kind isEqual:@"runtime"] || [kind isEqual:@"tweaks"]; }
static BOOL Regular(NSString *path) {
    struct stat info;
    return lstat(path.fileSystemRepresentation,&info)==0 && S_ISREG(info.st_mode);
}
static NSData *Encode(NSArray *events) {
    return [NSJSONSerialization dataWithJSONObject:@{@"schemaVersion":@1,@"events":events}
        options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];
}
static NSArray *ReadEvents(NSString *path) {
    if(!Regular(path) || [[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil] fileSize]>LogLimit) return nil;
    NSData *bytes=[NSData dataWithContentsOfFile:path];
    NSDictionary *document=bytes?[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil]:nil;
    if(![document isKindOfClass:NSDictionary.class] || ![document[@"schemaVersion"] isEqual:@1] ||
       ![document[@"events"] isKindOfClass:NSArray.class]) return nil;
    for(id event in document[@"events"])
        if(![event isKindOfClass:NSDictionary.class] || ![event[@"event"] isKindOfClass:NSString.class]) return nil;
    return document[@"events"];
}
static NSString *OldPath(NSString *path) {
    return [path.stringByDeletingPathExtension stringByAppendingString:@".old.json"];
}
static NSDictionary *Event(NSString *event,id details) {
    static NSISO8601DateFormatter *format;
    static dispatch_once_t once;
    dispatch_once(&once,^{ format=[NSISO8601DateFormatter new]; });
    NSString *guest=[LCOrbitHost guestIdentifier]?:@"unknown";
    NSMutableDictionary *record=[@{@"timestamp":[format stringFromDate:NSDate.date],
        @"guestID":guest,@"context":[LCOrbitHost isHostUI]?@"lc-host":@"guest",
        @"pid":@(getpid()),@"event":[event isKindOfClass:NSString.class]?event:@"unknown"} mutableCopy];
    if(details) record[@"details"]=details;
    if(![NSJSONSerialization isValidJSONObject:record]) record[@"details"]=[details description]?:@"";
    NSData *encoded=Encode(@[record]);
    if(encoded.length>LogLimit/2) {
        NSString *text=[details description]?:@"";
        record[@"details"]=[text substringToIndex:MIN(text.length,8192)];
        record[@"truncated"]=@YES;
        record[@"event"]=[record[@"event"] substringToIndex:MIN([record[@"event"] length],256)];
        record[@"guestID"]=[guest substringToIndex:MIN(guest.length,512)];
    }
    return record;
}
static BOOL EnsureDirectory(NSString *directory) {
    NSFileManager *fm=NSFileManager.defaultManager;
    if(![fm createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]) return NO;
    struct stat info;
    return lstat(directory.fileSystemRepresentation,&info)==0 && S_ISDIR(info.st_mode);
}
static int Lock(NSString *path) {
    // Validate the parent root before creating logs beneath it. Checking only
    // the final logs directory would follow a replaced/symlinked LCOrbit root.
    NSString *root=[LCOrbitStorage rootPath];
    if(!root.length || !EnsureDirectory(root)) return -1;
    if(!EnsureDirectory(path.stringByDeletingLastPathComponent)) return -1;
    NSString *lock=[path stringByAppendingString:@".lock"];
    int descriptor=open(lock.fileSystemRepresentation,O_CREAT|O_RDWR|O_NOFOLLOW,0600);
    if(descriptor<0) return -1;
    if(flock(descriptor,LOCK_EX)!=0) {close(descriptor);return -1;}
    return descriptor;
}
static void Unlock(int descriptor) { flock(descriptor,LOCK_UN);close(descriptor); }
static NSString *LegacyRoot(void) {
    NSString *group=[LCOrbitHost appGroupPath];
    if(group.length) return [group stringByAppendingPathComponent:@"LiveContainer/LCFloatingMenu"];
    const char *home=getenv("LC_HOME_PATH");
    return home && home[0]?[[NSString stringWithUTF8String:home] stringByAppendingPathComponent:@"Documents/LCFloatingMenu"]:nil;
}
static BOOL WriteImportedEvents(NSArray *events,NSString *path) {
    NSMutableArray *current=[NSMutableArray array];
    NSData *previous=nil;
    for(NSDictionary *event in events) {
        [current addObject:event];
        NSData *bytes=Encode(current);
        if(bytes.length>LogLimit) {
            [current removeLastObject];previous=Encode(current);
            [current removeAllObjects];[current addObject:event];
        }
    }
    if(previous && ![previous writeToFile:OldPath(path) atomically:YES]) return NO;
    return [Encode(current) writeToFile:path atomically:YES];
}
// A separate marker survives rotation and clear, so old plaintext history is
// never resurrected after the user clears the JSON log.
static void ImportLegacy(NSString *path,NSString *kind) {
    NSString *marker=[path stringByAppendingString:@".migrated"];
    NSFileManager *fm=NSFileManager.defaultManager;
    if([fm fileExistsAtPath:marker]) return;
    if(Regular(path)) {
        [NSData.data writeToFile:marker atomically:YES];
        return;
    }
    NSString *legacy=[LegacyRoot() stringByAppendingPathComponent:[kind isEqual:@"runtime"]?@"diagnostics.log":@"tweaks.log"];
    NSMutableArray *events=[NSMutableArray array];
    if(legacy) for(NSString *file in @[[legacy stringByAppendingString:@".old"],legacy]) {
        if(!Regular(file)) continue;
        // Read a bounded tail from old logs without loading unbounded user files.
        NSFileHandle *handle=[NSFileHandle fileHandleForReadingAtPath:file];
        unsigned long long length=[handle seekToEndOfFile];
        [handle seekToFileOffset:length>LogLimit?length-LogLimit:0];
        NSData *tail=[handle readDataOfLength:LogLimit];[handle closeFile];
        NSString *text=nil;
        for(NSUInteger skip=0;!text && skip<MIN((NSUInteger)4,tail.length);skip++)
            text=[[NSString alloc] initWithData:[tail subdataWithRange:NSMakeRange(skip,tail.length-skip)] encoding:NSUTF8StringEncoding];
        for(NSUInteger offset=0;offset<text.length;) {
            NSRange range=[text rangeOfComposedCharacterSequencesForRange:NSMakeRange(offset,MIN((NSUInteger)16384,text.length-offset))];
            [events addObject:Event(@"legacy-import",@{@"source":file.lastPathComponent,@"text":[text substringWithRange:range]})];
            offset=NSMaxRange(range);
        }
    }
    if(WriteImportedEvents(events,path)) [NSData.data writeToFile:marker atomically:YES];
}
static NSMutableArray *CurrentEvents(NSString *path) {
    NSArray *events=ReadEvents(path);
    if(events) return [events mutableCopy];
    if(Regular(path)) {
        NSString *corrupt=[path.stringByDeletingPathExtension stringByAppendingString:@".corrupt.json"];
        [NSFileManager.defaultManager removeItemAtPath:corrupt error:nil];
        [NSFileManager.defaultManager moveItemAtPath:path toPath:corrupt error:nil];
        return [NSMutableArray arrayWithObject:Event(@"log-recovered",@"Invalid JSON log preserved as .corrupt.json")];
    }
    return [NSMutableArray array];
}

// 一次落盘：把一批事件合并进文件。锁顺序与旧实现一致（文件 flock），跨进程仍安全。
static void WriteBatch(NSString *kind,NSArray *batch) {
    if(!batch.count) return;
    @try { @synchronized([LCOrbitLog class]) {
        NSString *path=[LCOrbitLog pathForKind:kind];if(!path) return;
        int descriptor=Lock(path);if(descriptor<0) return;
        @try {
            ImportLegacy(path,kind);
            NSMutableArray *events=CurrentEvents(path);
            [events addObjectsFromArray:batch];
            NSData *bytes=Encode(events);
            if(bytes.length>LogLimit) {
                NSArray *previous=[events subarrayWithRange:NSMakeRange(0,events.count-batch.count)];
                NSData *old=Encode(previous);
                if(old.length<=LogLimit && ![old writeToFile:OldPath(path) atomically:YES]) return;
                bytes=Encode(batch);
            }
            if(bytes.length<=LogLimit) [bytes writeToFile:path atomically:YES];
        } @finally { Unlock(descriptor); }
    } } @catch(NSException *exception) { }
}
static void FlushKind(NSString *kind) {
    EnsurePending();
    NSArray *batch=nil;
    @synchronized(PendingToken) {
        batch=[PendingEvents[kind] copy];
        [PendingEvents removeObjectForKey:kind];
        [PendingKinds removeObject:kind];
    }
    WriteBatch(kind,batch);
}
@implementation LCOrbitLog
+ (NSString *)pathForKind:(NSString *)kind {
    if(!Kind(kind)) return nil;
    NSString *root=[LCOrbitStorage rootPath];
    return root.length?[[root stringByAppendingPathComponent:@"logs"] stringByAppendingPathComponent:[kind stringByAppendingString:@".json"]]:nil;
}
+ (BOOL)loggingEnabled {
    // 首次查询时从配置里解析：TweakAudit 等模块可能在 FloatingMenu 启动前就写日志，
    // 只有惰性读配置才能保证"关掉之后一条都不落"（含启动早期的审计事件）。
    if(!LogEnabledResolved) {
        LogEnabledResolved=YES;
        id value=[LCOrbitStorage objectForKey:@"logsEnabled" module:@"LCFloatingMenu"];
        if([value isKindOfClass:NSNumber.class]) LogEnabled=[value boolValue];
    }
    return LogEnabled;
}
+ (void)setLoggingEnabled:(BOOL)enabled {
    LogEnabledResolved=YES;
    LogEnabled=enabled;
    if(enabled) return;
    EnsurePending();
    @synchronized(PendingToken) {
        [PendingEvents removeAllObjects];
        [PendingKinds removeAllObjects];
    }
}
+ (void)appendEvent:(NSString *)event details:(id)details kind:(NSString *)kind {
    // 总开关关掉时连格式化都不做：调用方已经拼好字符串，这里直接返回。
    if(!LogEnabled || !Kind(kind)) return;
    @try {
        NSDictionary *record=Event(event,details);
        EnsurePending();
        // 大事件或积压到一定量就必须立刻落盘：文件大小/轮转是外部可见的契约，
        // 不能为了省 IO 让一次 16KB 的写入拖到 400ms 之后。
        NSUInteger size=[[NSJSONSerialization dataWithJSONObject:record options:0 error:nil] length];
        BOOL urgent=NO,schedule=NO;
        @synchronized(PendingToken) {
            NSMutableArray *array=PendingEvents[kind];
            if(!array) { array=[NSMutableArray array]; PendingEvents[kind]=array; }
            [array addObject:record];
            urgent=(size>4096 || array.count>=6);
            if(![PendingKinds containsObject:kind]) {
                [PendingKinds addObject:kind];
                schedule=YES;
            }
        }
        if(urgent) { FlushKind(kind); return; }
        if(schedule) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.4*NSEC_PER_SEC)),
            LogFlushQueue,^{ FlushKind(kind); });
    } @catch(NSException *exception) { /* Logging must never break the guest. */ }
}
+ (NSData *)dataForKind:(NSString *)kind {
    FlushKind(kind);
    @try { @synchronized(self) {
        NSString *path=[self pathForKind:kind];if(!path) return Encode(@[]);
        int descriptor=Lock(path);if(descriptor<0) return Encode(@[]);
        @try {
            ImportLegacy(path,kind);
            NSMutableArray *events=[NSMutableArray arrayWithArray:ReadEvents(OldPath(path))?:@[]];
            [events addObjectsFromArray:ReadEvents(path)?:@[]];
            return Encode(events)?:Encode(@[]);
        } @finally { Unlock(descriptor); }
    } } @catch(NSException *exception) { return Encode(@[]); }
}
+ (void)clearKind:(NSString *)kind {
    EnsurePending();
    @synchronized(PendingToken) {
        [PendingEvents removeObjectForKey:kind];
        [PendingKinds removeObject:kind];
    }
    @try { @synchronized(self) {
        NSString *path=[self pathForKind:kind];if(!path) return;
        int descriptor=Lock(path);if(descriptor<0) return;
        @try {
            if([Encode(@[]) writeToFile:path atomically:YES]) {
                [NSData.data writeToFile:[path stringByAppendingString:@".migrated"] atomically:YES];
                [NSFileManager.defaultManager removeItemAtPath:OldPath(path) error:nil];
                [NSFileManager.defaultManager removeItemAtPath:[path.stringByDeletingPathExtension stringByAppendingString:@".corrupt.json"] error:nil];
            }
        } @finally { Unlock(descriptor); }
    } } @catch(NSException *exception) { }
}
@end
