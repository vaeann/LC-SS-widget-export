#import "LCOrbitPluginUpdater.h"
#import "LCOrbitHost.h"
#import <CommonCrypto/CommonDigest.h>
#import <mach-o/loader.h>
#import <mach/machine.h>
#import <sys/stat.h>
#import <errno.h>
#import <stdio.h>

static BOOL URegular(NSString *p) {
    struct stat s;
    return p.length && lstat(p.fileSystemRepresentation,&s)==0 && S_ISREG(s.st_mode);
}
static BOOL UDirectory(NSString *p) {
    struct stat s;
    return p.length && lstat(p.fileSystemRepresentation,&s)==0 && S_ISDIR(s.st_mode);
}
static NSError *UErr(NSInteger code,NSString *message) {
    return [NSError errorWithDomain:@"LCOrbit.PluginUpdate" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}
static BOOL UFail(NSError **error,NSInteger code,NSString *message) {
    if(error) *error=UErr(code,message);
    return NO;
}
// Check an in-memory Mach-O image. `available` is how many bytes we actually
// hold; `total` is the real file size, so a header-only read still validates.
static BOOL UPluginImage(const uint8_t *bytes,NSUInteger available,NSUInteger total) {
    if(available<sizeof(struct mach_header_64) || total<sizeof(struct mach_header_64) ||
       total>16*1024*1024) return NO;
    const struct mach_header_64 *header=(const void *)bytes;
    if(header->magic!=MH_MAGIC_64 || header->cputype!=CPU_TYPE_ARM64 || header->filetype!=MH_DYLIB)
        return NO;
    NSUInteger offset=sizeof(*header);
    if(header->sizeofcmds>total-offset || header->ncmds>10000) return NO;
    NSUInteger commandsEnd=offset+header->sizeofcmds;
    // Load commands sit at the very front of the file; refuse rather than guess
    // if a pathological header would need more bytes than we buffered.
    if(commandsEnd>available) return NO;
    BOOL expectedInstallName=NO;
    for(uint32_t i=0;i<header->ncmds;i++) {
        if(offset+sizeof(struct load_command)>commandsEnd) return NO;
        const struct load_command *command=(const void *)(bytes+offset);
        if(command->cmdsize<sizeof(*command) || command->cmdsize>commandsEnd-offset) return NO;
        if(command->cmd==LC_ID_DYLIB) {
            if(command->cmdsize<sizeof(struct dylib_command)) return NO;
            const struct dylib_command *dylib=(const void *)command;
            NSUInteger pos=dylib->dylib.name.offset;
            if(pos>=command->cmdsize) return NO;
            const char *name=(const char *)command+pos;
            const char *end=memchr(name,0,command->cmdsize-pos);
            if(!end) return NO;
            expectedInstallName=strcmp(name,"@rpath/LCFloatingMenu.dylib")==0;
        }
        offset+=command->cmdsize;
    }
    return expectedInstallName;
}
static BOOL UBinaryIsPlugin(NSData *binary) {
    if(![binary isKindOfClass:NSData.class]) return NO;
    return UPluginImage(binary.bytes,binary.length,binary.length);
}
// Identify an installed dylib by its LC_ID_DYLIB install name instead of its
// filename. Mapping keeps the scan cheap even when the folder holds big tweaks.
static BOOL UFileIsPlugin(NSString *path) {
    NSData *mapped=[NSData dataWithContentsOfFile:path
        options:NSDataReadingMappedIfSafe error:nil];
    if(!mapped) return NO;
    return UPluginImage(mapped.bytes,mapped.length,mapped.length);
}
static BOOL UHasMatchingDigest(NSData *binary,NSString *digest) {
    if(![digest isKindOfClass:NSString.class] || digest.length!=71 ||
       ![digest hasPrefix:@"sha256:"]) return NO;
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(binary.bytes,(CC_LONG)binary.length,hash);
    NSMutableString *hex=[NSMutableString stringWithCapacity:64];
    for(NSUInteger i=0;i<sizeof(hash);i++) [hex appendFormat:@"%02x",hash[i]];
    return [digest.lowercaseString isEqualToString:[@"sha256:" stringByAppendingString:hex]];
}
static BOOL UReplaceableName(NSString *name) {
    if(![name isKindOfClass:NSString.class] || !name.length || [name hasPrefix:@"."]) return NO;
    // LC's native Tweaks page renames a disabled dylib to "<name>.dylib.disabled";
    // the replacement must keep that suffix so the user's disabled state survives.
    return [name hasSuffix:@".dylib"] || [name hasSuffix:@".dylib.disabled"];
}
// LC keeps whatever filename the user imported, so "LCFloatingMenu-1.0.36v25.dylib"
// is a perfectly normal install and must still be updatable. The canonical name is
// preferred for ordering, but every matching copy is refreshed so a stale duplicate
// cannot keep being loaded alongside the new build.
static NSArray<NSString *> *UInstalledPlugins(NSString *directory,NSUInteger *scanned) {
    NSMutableArray *found=[NSMutableArray array];
    NSString *canonical=[directory stringByAppendingPathComponent:@"LCFloatingMenu.dylib"];
    NSString *canonicalDisabled=[canonical stringByAppendingString:@".disabled"];
    if(URegular(canonical)) [found addObject:canonical];
    if(URegular(canonicalDisabled)) [found addObject:canonicalDisabled];
    if(!UDirectory(directory)) return found;
    NSArray *entries=[NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil]?:@[];
    NSMutableArray *named=[NSMutableArray array],*others=[NSMutableArray array];
    for(NSString *entry in entries) {
        if(!UReplaceableName(entry)) continue;
        if([entry isEqualToString:@"TweakLoader.dylib"]) continue;
        NSString *path=[directory stringByAppendingPathComponent:entry];
        if([found containsObject:path]) continue;
        if(!URegular(path)) continue;
        if(scanned) (*scanned)++;
        if([entry hasPrefix:@"LCFloatingMenu"]) [named addObject:path];
        else [others addObject:path];
    }
    for(NSString *path in [named arrayByAddingObjectsFromArray:others])
        if(UFileIsPlugin(path)) [found addObject:path];
    return found;
}
static NSString *UPluginListDescription(NSString *directory,NSUInteger limit) {
    NSArray *entries=[NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil]?:@[];
    NSMutableArray *names=[NSMutableArray array];
    for(NSString *entry in entries)
        if(UReplaceableName(entry)) [names addObject:entry];
    if(!names.count) return @"目录里没有任何 dylib";
    NSString *joined=nil;
    if([names count]>limit)
        joined=[NSString stringWithFormat:@"%@ 等",[[names subarrayWithRange:NSMakeRange(0,limit)]
            componentsJoinedByString:@"、"]];
    else joined=[names componentsJoinedByString:@"、"];
    return joined;
}
static NSString *UMissingPluginMessage(NSString *directory) {
    if(!UDirectory(directory))
        return @"未找到 LC 私有插件目录 Documents/Tweaks，请通过原生 Tweaks 页面安装一次。";
    NSArray *entries=[NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil]?:@[];
    NSUInteger dylibs=0;
    for(NSString *entry in entries) if(UReplaceableName(entry)) dylibs++;
    if(!dylibs)
        return @"LC 私有插件目录里没有任何 dylib，请通过原生 Tweaks 页面安装一次。";
    return [NSString stringWithFormat:
        @"LC 私有插件目录里有 %lu 个 dylib，但没有一个能识别为微珠（%@）。请在原生 Tweaks 页面重新导入微珠一次。",
        (unsigned long)dylibs,UPluginListDescription(directory,4)];
}
static NSString *USharedPluginHint(void) {
    NSString *group=[LCOrbitHost appGroupPath];
    if(!group.length) return nil;
    NSString *shared=[group stringByAppendingPathComponent:@"LiveContainer/Tweaks"];
    NSUInteger scanned=0;
    NSArray *found=UInstalledPlugins(shared,&scanned);
    if(!found.count) return nil;
    return @"检测到微珠安装在 LC 的共享插件目录 LiveContainer/Tweaks，本页只更新私有插件目录 Documents/Tweaks。请在原生 Tweaks 页面手动替换共享插件，或把微珠改放到私有目录后再用本页更新。";
}
@implementation LCOrbitPluginUpdater
+ (BOOL)replacePluginData:(NSData *)binary expectedSHA256:(NSString *)digest
             destination:(NSString *)destination
                   error:(NSError **)error {
    if(!UBinaryIsPlugin(binary)) return UFail(error,1,@"下载的文件不是有效的 arm64 LCFloatingMenu.dylib。");
    if(!UHasMatchingDigest(binary,digest)) return UFail(error,2,@"SHA-256 校验失败，已拒绝安装。");
    if(!UReplaceableName(destination.lastPathComponent) || !URegular(destination))
        return UFail(error,3,@"原插件不是预期的普通文件，未进行替换。");
    struct stat old;
    if(lstat(destination.fileSystemRepresentation,&old)!=0) return UFail(error,4,@"无法读取原插件信息。");
    NSFileManager *fm=NSFileManager.defaultManager;
    // Verify a staged file, then atomically replace the destination. Until
    // rename succeeds, the old dylib remains intact; no .bak is created.
    NSString *temporary=[destination stringByAppendingFormat:@".%@.tmp",NSUUID.UUID.UUIDString];
    if(![binary writeToFile:temporary options:NSDataWritingAtomic error:error]) {
        [fm removeItemAtPath:temporary error:nil];
        return NO;
    }
    BOOL prepared=chmod(temporary.fileSystemRepresentation,old.st_mode&0777)==0 &&
        URegular(temporary) && [fm attributesOfItemAtPath:temporary error:nil]!=nil &&
        UHasMatchingDigest([NSData dataWithContentsOfFile:temporary],digest);
    if(!prepared || rename(temporary.fileSystemRepresentation,destination.fileSystemRepresentation)!=0) {
        [fm removeItemAtPath:temporary error:nil];
        return UFail(error,6,@"替换插件失败，旧插件未被覆盖；备份已保留。");
    }
    return YES;
}
+ (BOOL)installDownloadedPlugin:(NSData *)binary expectedSHA256:(NSString *)digest error:(NSError **)error {
    if(![LCOrbitHost isHostUI]) return UFail(error,7,@"请在 LC 主界面的微珠设置中心更新插件。");
    const char *root=getenv("LC_HOME_PATH");
    if(!root || !root[0]) return UFail(error,8,@"无法找到 LC 私有插件目录，未进行替换。");
    NSString *home=[NSString stringWithUTF8String:root];
    NSString *directory=[home stringByAppendingPathComponent:@"Documents/Tweaks"];
    // Only replace a plugin actually loaded from LC's own private Tweaks root.
    // Never tamper with a bundle, an assigned guest folder, or shared LC root.
    NSUInteger scanned=0;
    NSArray<NSString *> *targets=UInstalledPlugins(directory,&scanned);
    if(!targets.count) {
        NSString *shared=USharedPluginHint();
        return UFail(error,9,shared?:UMissingPluginMessage(directory));
    }
    // Every matching copy is refreshed so an older duplicate cannot keep being
    // loaded, but a single failure still reports the untouched plugin.
    NSError *firstError=nil;
    NSUInteger replaced=0;
    for(NSString *target in targets) {
        NSError *one=nil;
        if([self replacePluginData:binary expectedSHA256:digest destination:target error:&one]) replaced++;
        else if(!firstError) firstError=one;
    }
    // LC loads every .dylib in the folder. Two live copies of the micro-bead run
    // the constructor twice with independent globals, and the two instances
    // overwrite each other's state files — the panel then shows only one side.
    // Keep exactly one live copy; the others are renamed to .disabled (kept on
    // disk, so nothing is destroyed and the user can rename them back).
    if(replaced == targets.count) {
        NSString *keep=nil;
        for(NSString *target in targets)
            if([target.lastPathComponent isEqualToString:@"LCFloatingMenu.dylib"]) { keep=target; break; }
        if(!keep) for(NSString *target in targets)
            if([target.lastPathComponent hasSuffix:@".dylib"]) { keep=target; break; }
        if(keep && targets.count > 1) {
            for(NSString *target in targets) {
                if([target isEqualToString:keep]) continue;
                if([target.lastPathComponent hasSuffix:@".disabled"]) continue;
                [NSFileManager.defaultManager moveItemAtPath:target
                                                       toPath:[target stringByAppendingString:@".disabled"]
                                                        error:nil];
            }
        }
        return YES;
    }
    if(error) *error=firstError?:UErr(10,@"替换插件失败，旧插件未被覆盖。");
    return NO;
}
@end
