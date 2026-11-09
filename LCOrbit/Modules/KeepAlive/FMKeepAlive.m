// FMKeepAlive.m — 后台保活：切后台时每个进程播一路静音音频，保持不被系统挂起
//
// 机制来源：LiveContainer-zh 的 CZFHostKeepAlive（宿主侧）+ CZFKeepAlive（游客侧）。
// 本文件只实现引擎与设置页，不含它那套独立面板 / 空白长按手势 / 白名单 / 独立日志。
//
// 两层保活（进程独立、互不感知）：
//   宿主进程（LC 界面）   条件 = 开关开 && 已切后台 && 有游客在跑 → 播
//                        作用：宿主不被回收，LiveProcess 扩展才不被连带回收
//   游客进程（每个 Guest）条件 = 开关开 && 已切后台 → 播
//
// 起停：WillResignActive 提前起播（堵「先被掐、后才开播」的空档），
//       DidEnterBackground 确认；回前台三路信号任一即停。
//       扩展进程补 NSExtensionHost* 通知（UIApplication 的后台通知在扩展里不一定送达）。
//
// 看门狗（可关）：自适应 0-5min 30s / 5-10min 45s / >10min 60s。只做两件事：
//       判超时、查音频是否还在播（不在播就重建播放器重拉）。
//       局限：进程被挂起后 timer 不执行，只能救「音频断了但进程还活着」的窗口，
//       所以真正的第一道防线是提前起播和音频中断通知，看门狗只是兜底。
//
// 超时：后台满 10/20/30 分钟停播并标记，回前台复位。
//
// 接入点：+load 里装配，不 swizzle 任何上游方法；设置入口行由主文件补丁用
//        NSClassFromString(@"FMKeepAliveRow") 创建（避免测试 harness 跨单元链接）。

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>
#import "../../Core/LCOrbitStorage.h"
#import "../../Core/LCOrbitHost.h"
#import "../../Core/LCOrbitLog.h"

static NSString *const kModuleName = @"LCFloatingMenu";

// 偏好键（与主文件设置页共用同一 LCOrbitStorage 空间）。
static NSString *const kKeyEnabled = @"keepAliveEnabled";     // 默认 YES
static NSString *const kKeyMinutes = @"keepAliveMinutes";     // 10 / 20 / 30，默认 20
static NSString *const kKeyWatchdog = @"keepAliveWatchdog";   // 1 自适应 / 0 关闭，默认 1

// ---- 引擎状态 ---------------------------------------------------------------

static AVAudioPlayer *gPlayer = nil;
static NSTimer *gWatchdog = nil;
static BOOL gInBackground = NO;
static NSTimeInterval gBackgroundStart = 0;
static BOOL gTimedOut = NO;          // 本次后台已满时长，回前台才复位
static BOOL gInstalled = NO;
static BOOL gIsHost = NO;            // YES = 纯 LC 界面进程；NO = 游客进程
static UIBackgroundTaskIdentifier gBGTask;   // 宿主第二通道（UIBackgroundTaskInvalid 不是编译期常量，用标志位区分）
static BOOL gBGTaskActive = NO;

static void FMKRefresh(void);   // 前置声明：播放决策在多处被调用，定义在下方

// 与上游 FMThemeColor(FMColorText/FMColorSecondary) 完全对齐的配色：
//   文字   深色 #F3F7FF / 浅色 #182638
//   次要   深色 #C3CEDE / 浅色 #4B5B6C
// 外观偏好 appearanceMode：0 跟随系统 / 1 浅色 / 2 深色（与上游同键同语义）。
// 跟随系统时返回动态色，交给 trait 解析；强制模式返回固定色。
static UIColor *FMKThemeColor(BOOL secondary) {
    NSInteger mode = [[LCOrbitStorage objectForKey:@"appearanceMode" module:kModuleName] integerValue];
    BOOL forceDark = (mode == 2);
    BOOL forceLight = (mode == 1);
    UIColor *dark = [UIColor colorWithRed:(secondary ? 0xC3 : 0xF3) / 255.0
                                    green:(secondary ? 0xCE : 0xF7) / 255.0
                                     blue:(secondary ? 0xDE : 0xFF) / 255.0
                                    alpha:1.0];
    UIColor *light = [UIColor colorWithRed:(secondary ? 0x4B : 0x18) / 255.0
                                     green:(secondary ? 0x5B : 0x26) / 255.0
                                      blue:(secondary ? 0x6C : 0x38) / 255.0
                                     alpha:1.0];
    if(forceDark) return dark;
    if(forceLight) return light;
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? dark : light;
    }];
}

static void FMKLog(NSString *event, id details) {
    [LCOrbitLog appendEvent:event details:details kind:@"runtime"];
}

static id FMKPref(NSString *key) {
    return [LCOrbitStorage objectForKey:key module:kModuleName];
}

static void FMKSetPref(NSString *key, id value) {
    [LCOrbitStorage setObject:value forKey:key module:kModuleName];
}

static BOOL FMKEnabled(void) {
    id value = FMKPref(kKeyEnabled);
    return value ? [value boolValue] : YES;
}

static NSInteger FMKMinutes(void) {
    id value = FMKPref(kKeyMinutes);
    NSInteger minutes = value ? [value integerValue] : 20;
    if(minutes != 10 && minutes != 20 && minutes != 30) minutes = 20;
    return minutes;
}

// 1 = 自适应，0 = 关闭
static NSInteger FMKWatchdogMode(void) {
    id value = FMKPref(kKeyWatchdog);
    return value ? ([value integerValue] == 0 ? 0 : 1) : 1;
}

static NSTimeInterval FMKNow(void) {
    return NSDate.date.timeIntervalSince1970;
}

// ---- 静音音频 ---------------------------------------------------------------

// 1 秒静音 WAV（8000Hz 单声道 16bit PCM），内存合成一次后缓存，不落盘。
static NSData *FMKSilentWAVData(void) {
    static NSData *cached = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const uint32_t sampleRate = 8000;
        const uint16_t channels = 1;
        const uint16_t bitsPerSample = 16;
        const uint32_t dataSize = sampleRate * channels * (bitsPerSample / 8);
        const uint32_t chunkSize = 36 + dataSize;
        const uint16_t blockAlign = channels * (bitsPerSample / 8);
        const uint32_t byteRate = sampleRate * blockAlign;

        NSMutableData *data = [NSMutableData dataWithCapacity:44 + dataSize];
        [data appendBytes:"RIFF" length:4];
        [data appendBytes:&chunkSize length:4];
        [data appendBytes:"WAVE" length:4];
        [data appendBytes:"fmt " length:4];
        uint32_t subChunk1Size = 16;
        uint16_t audioFormat = 1;
        [data appendBytes:&subChunk1Size length:4];
        [data appendBytes:&audioFormat length:2];
        [data appendBytes:&channels length:2];
        [data appendBytes:&sampleRate length:4];
        [data appendBytes:&byteRate length:4];
        [data appendBytes:&blockAlign length:2];
        [data appendBytes:&bitsPerSample length:2];
        [data appendBytes:"data" length:4];
        [data appendBytes:&dataSize length:4];
        [data increaseLengthBy:dataSize];   // 补零 = 静音采样
        cached = [data copy];
    });
    return cached;
}

// ---- 宿主：是否有游客在跑 ---------------------------------------------------

// 宿主音频整进程一份，只有「有游客在跑」时才值得播——没游客就不耗电。
// 首选 LCOrbitMultitask.windows（宿主侧多任务窗口列表，是我们基线里的 ObjC 类，
// 虚拟窗口模式同样有效）；拿不到再退回 Swift dock 管理器与场景数。
// 注意：曾用「猜 Swift 类名 + connectedScenes.count>1」两路判定，实测在虚拟窗口
// 模式下两路都拿不到（dock 类名带模块前缀、Guest 场景不在 connectedScenes 里），
// 结果有游客在跑也判成"没有"，宿主保活从不启动。
static BOOL FMKGuestsRunning(void) {
    Class multitask = NSClassFromString(@"LCOrbitMultitask");
    if(multitask) {
        SEL windowsSel = NSSelectorFromString(@"windows");
        if([multitask respondsToSelector:windowsSel]) {
            id windows = ((id (*)(id, SEL))objc_msgSend)((id)multitask, windowsSel);
            if([windows respondsToSelector:@selector(count)]) return [windows count] > 0;
        }
    }
    // 次选：NSClassFromString 对 Swift @objc 类需带模块前缀，两种写法都试。
    Class dockClass = NSClassFromString(@"MultitaskDockManager")
                   ?: NSClassFromString(@"LiveContainerSwiftUI.MultitaskDockManager");
    if(dockClass) {
        SEL sharedSel = NSSelectorFromString(@"shared");
        if([dockClass respondsToSelector:sharedSel]) {
            id manager = ((id (*)(id, SEL))objc_msgSend)((id)dockClass, sharedSel);
            SEL appsSel = NSSelectorFromString(@"apps");
            if(manager && [manager respondsToSelector:appsSel]) {
                id apps = ((id (*)(id, SEL))objc_msgSend)(manager, appsSel);
                if([apps respondsToSelector:@selector(count)]) return [apps count] > 0;
            }
        }
    }
    // 两路都判不了：保守播。宿主保活多一路音频，比"判定失败导致扩展被回收"划算。
    // （不再用 connectedScenes.count 兜底：虚拟窗口模式下 Guest 场景不在
    // connectedScenes 里，恒为 1，会把"有游客"误判成"没有"。）
    return YES;
}

// ---- 播放控制 ---------------------------------------------------------------

static void FMKStopWatchdog(void) {
    [gWatchdog invalidate];
    gWatchdog = nil;
}

static void FMKEndBackgroundTask(void) {
    if(!gBGTaskActive) return;
    [UIApplication.sharedApplication endBackgroundTask:gBGTask];
    gBGTask = 0;
    gBGTaskActive = NO;
}

// 宿主第二通道：音频被打断时后台任务先顶住；过期时重开音频并续一个新任务。
static void FMKBeginBackgroundTask(void) {
    if(!gIsHost || gBGTaskActive) return;
    gBGTask = [UIApplication.sharedApplication beginBackgroundTaskWithExpirationHandler:^{
        FMKEndBackgroundTask();
        if(gInBackground && !gTimedOut) {
            gPlayer = nil;      // 会话/播放器一并重建
            FMKRefresh();
        }
    }];
    gBGTaskActive = YES;
}

static void FMKStartPlayback(NSString *trigger) {
    @try {
        if(gPlayer && gPlayer.isPlaying) {
            FMKBeginBackgroundTask();
            return;
        }
        if(!gPlayer) {
            AVAudioSession *session = AVAudioSession.sharedInstance;
            [session setCategory:AVAudioSessionCategoryPlayback
                     withOptions:AVAudioSessionCategoryOptionMixWithOthers
                           error:nil];
            [session setActive:YES error:nil];
            gPlayer = [[AVAudioPlayer alloc] initWithData:FMKSilentWAVData() error:nil];
            gPlayer.numberOfLoops = -1;     // 无限循环
            gPlayer.volume = 0.0;
            [gPlayer prepareToPlay];
        }
        [gPlayer play];
        FMKBeginBackgroundTask();
        FMKLog(@"keep-alive-start", @{@"role": gIsHost ? @"host" : @"guest",
                                       @"trigger": trigger ?: @"",
                                       @"pid": @(getpid())});
    } @catch (__unused NSException *e) {
        // 保活失败绝不能拖垮宿主/游客：静默放弃，下次触发再试。
    }
}

static void FMKStopPlayback(NSString *reason) {
    @try {
        FMKStopWatchdog();
        [gPlayer pause];
        [[AVAudioSession sharedInstance] setActive:NO
                                       withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                             error:nil];
        FMKEndBackgroundTask();
        if(gPlayer) FMKLog(@"keep-alive-stop", @{@"reason": reason ?: @"",
                                                  @"role": gIsHost ? @"host" : @"guest"});
    } @catch (__unused NSException *e) {}
}

// ---- 看门狗 ---------------------------------------------------------------

// 自适应分档：0-5 分钟 30 秒 / 5-10 分钟 45 秒 / 10 分钟以上 60 秒。0 = 不启用。
static NSTimeInterval FMKWatchdogInterval(void) {
    if(FMKWatchdogMode() == 0) return 0;
    NSTimeInterval elapsed = FMKNow() - gBackgroundStart;
    if(elapsed < 300.0) return 30.0;
    if(elapsed < 600.0) return 45.0;
    return 60.0;
}

static void FMKStartWatchdog(void) {
    FMKStopWatchdog();
    NSTimeInterval interval = FMKWatchdogInterval();
    if(interval <= 0) return;
    gWatchdog = [NSTimer scheduledTimerWithTimeInterval:interval repeats:NO block:^(NSTimer *timer) {
        if(!gInBackground) { FMKStopWatchdog(); return; }

        // 1) 超时判定
        NSInteger minutes = FMKMinutes();
        if(minutes > 0 && !gTimedOut) {
            NSTimeInterval elapsed = FMKNow() - gBackgroundStart;
            if(elapsed >= minutes * 60.0) {
                gTimedOut = YES;
                FMKLog(@"keep-alive-timeout", @{@"minutes": @(minutes),
                                                @"role": gIsHost ? @"host" : @"guest"});
                FMKStopPlayback(@"timeout");
                return;
            }
        }

        // 2) 音频存活检查：停了就重建（会话可能已失效，连 player 一起重建）
        if(!gTimedOut && (!gPlayer || !gPlayer.isPlaying)) {
            FMKLog(@"keep-alive-revive", @{@"role": gIsHost ? @"host" : @"guest"});
            gPlayer = nil;
            FMKStartPlayback(@"watchdog");
        }

        // 3) 重建自己，让间隔随时间自适应
        FMKStartWatchdog();
    }];
    // 允许系统合并唤醒，省一点电
    gWatchdog.tolerance = MIN(interval * 0.3, 10.0);
}

// ---- 播放决策 ---------------------------------------------------------------

// 所有触发点都走这里，避免多处状态打架。
static void FMKRefresh(void) {
    static BOOL lastSkipNoGuests = NO;   // 去重：同一状态只记一条
    if(!FMKEnabled()) { FMKStopPlayback(@"disabled"); return; }
    if(!gInBackground) { FMKStopPlayback(@"foreground"); return; }
    if(gTimedOut) { FMKStopPlayback(@"timeout"); return; }
    if(gIsHost && !FMKGuestsRunning()) {
        if(!lastSkipNoGuests) {
            lastSkipNoGuests = YES;
            FMKLog(@"keep-alive-skip", @{@"reason": @"no-guests"});
        }
        FMKStopPlayback(@"no-guests");
        return;
    }
    lastSkipNoGuests = NO;
    FMKStartPlayback(@"refresh");
    if(!gWatchdog) FMKStartWatchdog();
}

// ---- 前后台切换 ---------------------------------------------------------------

static void FMKEnterBackground(NSString *source) {
    if(gInBackground) { FMKRefresh(); return; }
    gInBackground = YES;
    gBackgroundStart = FMKNow();
    gTimedOut = NO;
    FMKLog(@"keep-alive-background", @{@"source": source ?: @"",
                                       @"role": gIsHost ? @"host" : @"guest"});
    FMKRefresh();
}

static void FMKEnterForeground(NSString *source) {
    if(!gInBackground) return;
    gInBackground = NO;
    gTimedOut = NO;
    FMKLog(@"keep-alive-foreground", @{@"source": source ?: @"",
                                       @"role": gIsHost ? @"host" : @"guest"});
    FMKStopPlayback(@"foreground");
}

// ---- 通知装配 ---------------------------------------------------------------

static void FMKAddObserver(NSString *name, id object, void (^block)(NSNotification *)) {
    [NSNotificationCenter.defaultCenter addObserverForName:name
                                                    object:object
                                                     queue:NSOperationQueue.mainQueue
                                                 usingBlock:block];
}

__attribute__((constructor))
static void FMKeepAliveInit(void) {
    @autoreleasepool {
        if(gInstalled) return;
        gInstalled = YES;
        gIsHost = [LCOrbitHost isHostUI];
        FMKLog(@"keep-alive-loaded", @{@"pid": @(getpid()),
                                       @"host": @(gIsHost),
                                       @"bundle": NSBundle.mainBundle.bundleIdentifier ?: @""});

        // 提前起播：WillResignActive 早于真正进后台，切后台时音频会话已是激活态。
        FMKAddObserver(UIApplicationWillResignActiveNotification, nil, ^(NSNotification *note) {
            FMKEnterBackground(@"resignActive");
        });
        FMKAddObserver(UIApplicationDidEnterBackgroundNotification, nil, ^(NSNotification *note) {
            FMKEnterBackground(@"didEnterBackground");
        });
        FMKAddObserver(UIApplicationDidBecomeActiveNotification, nil, ^(NSNotification *note) {
            FMKEnterForeground(@"becomeActive");
        });
        FMKAddObserver(UIApplicationWillEnterForegroundNotification, nil, ^(NSNotification *note) {
            FMKEnterForeground(@"willEnterForeground");
        });

        // 扩展进程：UIApplication 的后台通知不一定送达，宿主通知才是可靠的那路。
        // 两个常量不在公开头文件，用字符串字面量避免编译期找不到符号。
        FMKAddObserver(@"NSExtensionHostDidEnterBackgroundNotification", nil, ^(NSNotification *note) {
            FMKEnterBackground(@"extensionHostBg");
        });
        FMKAddObserver(@"NSExtensionHostWillEnterForegroundNotification", nil, ^(NSNotification *note) {
            FMKEnterForeground(@"extensionHostFg");
        });

        // 音频被打断（来电等）结束后，仍在后台就立即恢复——快路径，不受看门狗开关影响。
        FMKAddObserver(AVAudioSessionInterruptionNotification, AVAudioSession.sharedInstance,
                       ^(NSNotification *note) {
            NSNumber *typeNum = note.userInfo[AVAudioSessionInterruptionTypeKey];
            if(!typeNum) return;
            if((AVAudioSessionInterruptionType)typeNum.unsignedIntegerValue !=
               AVAudioSessionInterruptionTypeEnded) return;
            if(!gInBackground || gTimedOut) return;
            FMKLog(@"keep-alive-interruption-ended", nil);
            gPlayer = nil;      // 会话可能已失效，整体重建
            FMKRefresh();
        });

        // 音频服务崩溃重启：所有会话失效，必须重建 player 才会恢复。
        FMKAddObserver(AVAudioSessionMediaServicesWereResetNotification, AVAudioSession.sharedInstance,
                       ^(NSNotification *note) {
            if(!gInBackground || gTimedOut) return;
            FMKLog(@"keep-alive-services-reset", nil);
            gPlayer = nil;
            FMKRefresh();
        });

        // 冷启动就处于后台（极少见）
        dispatch_async(dispatch_get_main_queue(), ^{
            if(UIApplication.sharedApplication.applicationState == UIApplicationStateBackground)
                FMKEnterBackground(@"launchedInBackground");
        });
    }
}

// ---- 设置子页 ---------------------------------------------------------------

// 系统 grouped 背景色（同微珠模块的写法：这个 SDK 里 systemGroupedBackground
// 取不到，用动态色合成）。
static UIColor *FMKGroupedBackground(BOOL secondary) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        BOOL dark = traits.userInterfaceStyle == UIUserInterfaceStyleDark;
        if(secondary) {
            return dark ? [UIColor colorWithWhite:0.11 alpha:1.0]
                        : [UIColor colorWithWhite:1.00 alpha:1.0];
        }
        return dark ? [UIColor colorWithWhite:0.00 alpha:1.0]
                    : [UIColor colorWithWhite:0.949 alpha:1.0];
    }];
}

@interface FMKeepAliveController : UITableViewController
- (void)closeTapped;
@end

@implementation FMKeepAliveController {
    UISwitch *_enabledSwitch;
    UISegmentedControl *_minutesSegment;
    UISegmentedControl *_watchdogSegment;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"后台保活";
    self.view.backgroundColor = FMKGroupedBackground(NO);
    self.tableView.alwaysBounceVertical = NO;
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if(section == 0)
        return @"切到后台时循环播放一段听不见的音频，让系统认为进程还在工作，从而不被挂起。前台完全不播，零开销。";
    if(section == 1)
        return @"后台最多保活这么久，到点自动停，避免长时间挂在后台耗电。回到前台后重新计时。";
    return @"看门狗定时检查音频是否还在播，被系统停掉就重新拉起。自适应：前 5 分钟每 30 秒，5-10 分钟每 45 秒，之后每 60 秒；关闭后不再巡检（来电打断恢复仍然有效）。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView
        cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *reuse = [NSString stringWithFormat:@"row%ld", (long)indexPath.section];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if(!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                           reuseIdentifier:reuse];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = FMKGroupedBackground(YES);

    if(indexPath.section == 0) {
        cell.textLabel.text = @"后台保活";
        if(!_enabledSwitch) {
            _enabledSwitch = [[UISwitch alloc] init];
            _enabledSwitch.on = FMKEnabled();
            [_enabledSwitch addTarget:self action:@selector(enabledChanged:)
                     forControlEvents:UIControlEventValueChanged];
        }
        cell.accessoryView = _enabledSwitch;
    } else if(indexPath.section == 1) {
        cell.textLabel.text = @"保活时长";
        if(!_minutesSegment) {
            _minutesSegment = [[UISegmentedControl alloc] initWithItems:@[@"10 分钟", @"20 分钟", @"30 分钟"]];
            NSInteger minutes = FMKMinutes();
            _minutesSegment.selectedSegmentIndex = minutes == 10 ? 0 : (minutes == 30 ? 2 : 1);
            _minutesSegment.apportionsSegmentWidthsByContent = YES;
            [_minutesSegment addTarget:self action:@selector(minutesChanged:)
                      forControlEvents:UIControlEventValueChanged];
        }
        cell.accessoryView = _minutesSegment;
    } else {
        cell.textLabel.text = @"看门狗";
        if(!_watchdogSegment) {
            _watchdogSegment = [[UISegmentedControl alloc] initWithItems:@[@"自适应", @"关闭"]];
            _watchdogSegment.selectedSegmentIndex = FMKWatchdogMode() == 0 ? 1 : 0;
            _watchdogSegment.apportionsSegmentWidthsByContent = YES;
            [_watchdogSegment addTarget:self action:@selector(watchdogChanged:)
                       forControlEvents:UIControlEventValueChanged];
        }
        cell.accessoryView = _watchdogSegment;
    }
    return cell;
}

- (void)enabledChanged:(UISwitch *)sender {
    FMKSetPref(kKeyEnabled, @(sender.on));
    FMKRefresh();
    FMKLog(@"keep-alive-enabled-changed", @{@"on": @(sender.on)});
}

- (void)minutesChanged:(UISegmentedControl *)sender {
    NSInteger minutes = sender.selectedSegmentIndex == 0 ? 10
                      : (sender.selectedSegmentIndex == 2 ? 30 : 20);
    FMKSetPref(kKeyMinutes, @(minutes));
    FMKLog(@"keep-alive-minutes-changed", @{@"minutes": @(minutes)});
}

- (void)watchdogChanged:(UISegmentedControl *)sender {
    NSInteger mode = sender.selectedSegmentIndex == 1 ? 0 : 1;
    FMKSetPref(kKeyWatchdog, @(mode));
    // 看门狗模式变了，正在跑的要按新间隔重建
    if(gInBackground) FMKStartWatchdog();
    FMKLog(@"keep-alive-watchdog-changed", @{@"mode": mode ? @"adaptive" : @"off"});
}

@end

// 入口行：与上游 FMSettingsNavigationRow（侧边栏）同一套视觉规格——
// 标题 15pt Medium、副标题 12pt Regular、chevron 14x9、行高 60、圆角 12。
@interface FMKeepAliveRow : UIControl
@end

@implementation FMKeepAliveRow
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:CGRectMake(0, 0, 320, 60)];
    if(self) {
        self.backgroundColor = FMKGroupedBackground(YES);
        self.layer.cornerRadius = 12;
        self.layer.masksToBounds = YES;

        UIImageView *chevron = [[UIImageView alloc] initWithImage:
            [UIImage systemImageNamed:@"chevron.right"]];
        chevron.tintColor = FMKThemeColor(YES);
        chevron.contentMode = UIViewContentModeScaleAspectFit;
        chevron.translatesAutoresizingMaskIntoConstraints = NO;
        chevron.userInteractionEnabled = NO;
        [self addSubview:chevron];

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
        title.text = @"后台保活";
        title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        title.textColor = FMKThemeColor(NO);
        title.translatesAutoresizingMaskIntoConstraints = NO;
        title.userInteractionEnabled = NO;
        [self addSubview:title];

        UILabel *subtitle = [[UILabel alloc] initWithFrame:CGRectZero];
        subtitle.text = @"切后台后保持游客 App 不被挂起";
        subtitle.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        subtitle.textColor = FMKThemeColor(YES);
        subtitle.translatesAutoresizingMaskIntoConstraints = NO;
        subtitle.userInteractionEnabled = NO;
        [self addSubview:subtitle];

        [NSLayoutConstraint activateConstraints:@[
            [chevron.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
            [chevron.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [chevron.heightAnchor constraintEqualToConstant:14],
            [chevron.widthAnchor constraintEqualToConstant:9],
            [title.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
            [title.topAnchor constraintEqualToAnchor:self.topAnchor constant:11],
            [title.trailingAnchor constraintLessThanOrEqualToAnchor:chevron.leadingAnchor constant:-10],
            [subtitle.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
            [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:2],
            [subtitle.trailingAnchor constraintLessThanOrEqualToAnchor:chevron.leadingAnchor constant:-10],
        ]];
        self.accessibilityLabel = @"后台保活";
        self.accessibilityTraits = UIAccessibilityTraitButton;
        [self addTarget:self action:@selector(opened) forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
}

- (void)opened {
    UIViewController *presenter = nil;
    UIResponder *responder = self.nextResponder;
    while(responder && ![responder isKindOfClass:UIViewController.class])
        responder = responder.nextResponder;
    presenter = (UIViewController *)responder;
    if(!presenter) {
        UIWindow *window = self.window;
        presenter = window.rootViewController;
        while(presenter.presentedViewController) presenter = presenter.presentedViewController;
    }
    if(!presenter) return;

    FMKeepAliveController *controller = [[FMKeepAliveController alloc]
        initWithStyle:UITableViewStyleInsetGrouped];
    if(!controller) return;
    UINavigationController *nav = [[UINavigationController alloc]
        initWithRootViewController:controller];
    nav.modalPresentationStyle = UIModalPresentationAutomatic;
    UIBarButtonItem *close = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                           target:controller
                                                                           action:@selector(closeTapped)];
    controller.navigationItem.rightBarButtonItem = close;
    [presenter presentViewController:nav animated:YES completion:nil];
}
@end
