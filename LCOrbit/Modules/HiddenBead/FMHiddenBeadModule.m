// FMHiddenBeadModule — 微珠显隐：隐藏微珠（含横屏自动隐藏）+ 原微珠位置点击呼出 + 摇一摇显隐
//
// 功能（全部通过运行时接入，不改上游业务逻辑）：
//   * beadHidden         YES = 隐藏吸附在屏幕边缘的微珠（把手）；
//   * beadHideLandscape  YES = 横屏时自动隐藏微珠、竖屏恢复（需上游「左横屏自适应」开启，
//                        模块侧自动补开）；beadHidden 优先，不受方向影响；
//   * shakeToggleBead    摇一摇在「显示微珠」和「隐藏微珠」之间切换。
//
// 呼出方式：点击微珠隐藏前所在的同一位置（透明热区挂在微珠父视图上）。
// 早期版本做过长按空白 / 双击空白 / 钩住 UIApplication 收事件 三种全屏手势，均因多任务
// 模式下 Guest 进程的触摸派发路径（BackBoard 按 CAContext 路由、FBScene 转发不经
// UIApplication 的收事件入口）与 App 自身手势竞争而不可靠，已全部移除。
//
// 设置入口：设置页 → 显示方式 → 微珠显隐（入口行由本模块导出的
// FMBeadVisibilityRow() 生成，子页是本模块自己的 ViewController）。
//
// 接入点（六个 swizzle，都是"先调原实现，再补一句"）：
//   -[LCFloatingMenuModule orbitDidStartWithContext:]              模块启动 → 迁移 + 同步
//   -[LCFloatingMenuModule orbitDidReceiveLifecycleEvent:scene:]   前后台/场景切换 → 同步
//   -[LCFloatingMenuModule orbitWillStop]                          模块停止
//   -[FMManager drawOrb]                                           画完把手 → 按开关隐藏
//   -[FMManager applyMorphProgress:]                               形变每帧 → 低进度淡出面板
//   -[UIWindow motionEnded:withEvent:]                             摇一摇
//
// 上游改了下列符号名，本模块会安静失效（不崩溃），并记一条 gesture-hook-missing。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>
#import "../../Core/LCOrbitStorage.h"
#import "../../Core/LCOrbitHost.h"
#import "../../Core/LCOrbitLog.h"

static NSString *const kFMModuleName = @"LCFloatingMenu";

// 偏好键。
//   beadHidden         YES = 隐藏微珠（对应旧版 orbHandleStyle=2，启动时迁移）
//   beadHideLandscape  YES = 横屏时自动隐藏微珠、竖屏恢复（beadHidden 优先）
//   shakeToggleBead    摇一摇显隐微珠，默认关
static NSString *const kKeyHidden = @"beadHidden";
static NSString *const kKeyHideLandscape = @"beadHideLandscape";
static NSString *const kKeyShake = @"shakeToggleBead";

// 形变进度低于此范围时把面板整体淡出，避开收合末尾插值出的把手轮廓。
static const CGFloat kFMFadeFloor = 0.02;
static const CGFloat kFMFadeSpan = 0.16;


static CGFloat FMGClamp(CGFloat value, CGFloat low, CGFloat high) {    return value < low ? low : (value > high ? high : value);
}

// 系统 grouped 背景色。UIColor 的 systemGroupedBackground 与
// secondarySystemGroupedBackground 在这个 SDK 编译环境里取不到（方括号与
// 点语法都报 not found），用动态色自己合成，色值对齐系统：
//   secondary: 浅色 #FFFFFF / 深色 #1C1C1E
//   primary:   浅色 #F2F2F7 / 深色 #000000
static UIColor *FMGroupedBackground(BOOL secondary) {
    // 背景与主设置页同源：自定义色混合的 Background/Surface，不再用系统 grouped 灰。
    LCOrbitColorRole role=secondary?LCOrbitColorSurface:LCOrbitColorBackground;
    NSInteger mode=[[LCOrbitStorage objectForKey:@"appearanceMode" module:kFMModuleName] integerValue];
    if(mode==1) return [LCOrbitStorage themeColorForRole:role dark:NO];
    if(mode==2) return [LCOrbitStorage themeColorForRole:role dark:YES];
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return [LCOrbitStorage themeColorForRole:role
                                            dark:traits.userInterfaceStyle==UIUserInterfaceStyleDark];
    }];
}
// 与上游 FMThemeColor(FMColorText/FMColorSecondary) 完全对齐的配色：
//   文字   深色 #F3F7FF / 浅色 #182638
//   次要   深色 #C3CEDE / 浅色 #4B5B6C
// 外观偏好 appearanceMode：0 跟随系统 / 1 浅色 / 2 深色（与上游同键同语义）。
// 跟随系统时返回动态色，交给 trait 解析；强制模式返回固定色。
static UIColor *FMBeadThemeColor(BOOL secondary) {
    // 色值走 Core 主题（自定义 accent 混合 + 彩蛋 + 日夜间），与主面板完全同源。
    LCOrbitColorRole role=secondary?LCOrbitColorSecondary:LCOrbitColorText;
    NSInteger mode=[[LCOrbitStorage objectForKey:@"appearanceMode" module:kFMModuleName] integerValue];
    if(mode==1) return [LCOrbitStorage themeColorForRole:role dark:NO];
    if(mode==2) return [LCOrbitStorage themeColorForRole:role dark:YES];
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return [LCOrbitStorage themeColorForRole:role
                                            dark:traits.userInterfaceStyle==UIUserInterfaceStyleDark];
    }];
}
static void FMLog(NSString *event, id details) {
    [LCOrbitLog appendEvent:event details:details kind:@"runtime"];
}

// ---- 偏好 -------------------------------------------------------------------

static id FMPref(NSString *key) {
    return [LCOrbitStorage objectForKey:key module:kFMModuleName];
}

static void FMSetPref(NSString *key, id value) {
    [LCOrbitStorage setObject:value forKey:key module:kFMModuleName];
}

// 微珠隐藏开关。首次运行时把旧版形态键（orbHandleStyle=2）迁移成 beadHidden，
// 迁移只做一次；迁移后 orbHandleStyle 回到胶囊，形态选择恢复三项原样。
static void FMMigrateLegacy(void) {
    if([FMPref(@"beadHiddenMigrated") boolValue]) return;
    NSNumber *style = FMPref(@"orbHandleStyle");
    if(style && [style doubleValue] >= 1.5) {
        FMSetPref(kKeyHidden, @YES);
        FMSetPref(@"orbHandleStyle", @0);
        FMSetPref(@"orbDropletPull", @NO);
        FMLog(@"bead-hidden-migrated", @{@"from": @"orbHandleStyle=2"});
    }
    FMSetPref(@"beadHiddenMigrated", @YES);
}

// 用户显式隐藏（设置页开关 / 摇一摇切的结果）。
static BOOL FMHiddenMode(void) {
    return [FMPref(kKeyHidden) boolValue];
}

// 界面是否横屏。用 overlay 窗口自身的 bounds 判断——它跟随设备旋转，
// 比 UIDevice.orientation 稳（后者在平放、锁屏等场景会给出无关值）。
static BOOL FMIsLandscape(UIView *orb) {
    UIWindow *window = orb.window;
    if(!window) return NO;
    CGSize size = window.bounds.size;
    if(size.width <= 0 || size.height <= 0) return NO;
    return size.width > size.height;
}

// 实际显隐状态 = 用户显式隐藏 ||（横屏隐藏开启 && 当前横屏）。
// 显式隐藏优先：用户明确隐藏后，竖屏也保持隐藏，不受横屏开关影响。
static BOOL FMHiddenEffective(UIView *orb) {
    if([FMPref(kKeyHidden) boolValue]) return YES;
    if(![FMPref(kKeyHideLandscape) boolValue]) return NO;
    return FMIsLandscape(orb);
}

static BOOL FMShakeToggle(void) {
    return [FMPref(kKeyShake) boolValue];
}

// 震动开关沿用上游的 haptic 偏好（默认开）。
static BOOL FMHapticEnabled(void) {
    id value = FMPref(@"haptic");
    return value ? [value boolValue] : YES;
}

static void FMHapticLight(void) {
    if(!FMHapticEnabled()) return;
    UIImpactFeedbackGenerator *feedback =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [feedback impactOccurred];
}

#pragma mark - 运行时访问上游对象

static id FMSharedManager(void) {
    Class cls = NSClassFromString(@"FMManager");
    SEL shared = NSSelectorFromString(@"shared");
    if(!cls || ![cls respondsToSelector:shared]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)((id)cls, shared);
}

static id FMObject(id object, NSString *selectorName) {
    if(!object) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if(![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static BOOL FMBool(id object, NSString *selectorName) {
    if(!object) return NO;
    SEL selector = NSSelectorFromString(selectorName);
    if(![object respondsToSelector:selector]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}

// 读对象型实例变量（如 _orb）。
static id FMIvar(id object, const char *name) {
    if(!object) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    return ivar ? object_getIvar(object, ivar) : nil;
}

// 读标量实例变量（如 _morphActive）。
static const void *FMIvarAddress(id object, const char *name) {
    if(!object) return NULL;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    if(!ivar) return NULL;
    return (const char *)(__bridge void *)object + ivar_getOffset(ivar);
}

static BOOL FMBoolIvar(id object, const char *name) {
    const void *address = FMIvarAddress(object, name);
    return address ? *(const BOOL *)address : NO;
}

// 面板此刻是否处于"不该有把手/胶囊"的状态（展开、设置页、形变中）。
static BOOL FMManagerBusy(void) {
    id manager = FMSharedManager();
    if(!manager) return YES;
    return FMBool(manager, @"isOpen") || FMObject(manager, @"settingsWindow") != nil ||
           FMBoolIvar(manager, "_morphActive");
}

// 面板收合时呼出。每个拒绝条件都记 open-rejected + 具体原因，
// 避免"调了 toggle 但面板没出来"却看不到是哪道检查拦的。
static void FMOpenPanel(NSString *trigger) {
    id manager = FMSharedManager();
    if(!manager) { FMLog(@"open-rejected", @{@"reason": @"no-manager"}); return; }
    if(FMBool(manager, @"isOpen")) { FMLog(@"open-rejected", @{@"reason": @"already-open"}); return; }
    if(FMObject(manager, @"settingsWindow")) { FMLog(@"open-rejected", @{@"reason": @"settings-window"}); return; }
    if(FMBoolIvar(manager, "_morphActive")) { FMLog(@"open-rejected", @{@"reason": @"morph-active"}); return; }

    SEL toggle = NSSelectorFromString(@"toggle");
    if(![manager respondsToSelector:toggle]) { FMLog(@"open-rejected", @{@"reason": @"no-toggle"}); return; }
    ((void (*)(id, SEL))objc_msgSend)(manager, toggle);
    FMHapticLight();
    FMLog(@"hidden-bead-open", trigger ? @{@"trigger": trigger} : nil);
}

#pragma mark - 原微珠位置热区（呼出方式 0）

// 微珠隐藏后，在它原来的位置放一块透明点击区：单击呼出侧栏。
// 相比全屏手势的优势：零竞争（就是一枚按钮）、只占微珠大小的区域不挡
// App、挂在微珠父视图上——微珠在哪个进程显示，热区就在哪个进程收点击
// （复刻上游"点微珠呼出"的交互路径，这条路是验证过可靠的）。
static char kFMHotZoneKey;

@interface FMBeadHotZone : UIButton
- (void)tapped;
@end

@implementation FMBeadHotZone
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if(self) {
        self.backgroundColor = UIColor.clearColor;
        self.accessibilityLabel = @"呼出侧栏";
        [self addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
}
- (void)tapped {
    FMOpenPanel(@"bead-zone");
}
@end

// 把热区同步到微珠当前位置。drawOrb 每次绘制都会走到这里，
// 上游移动/吸附微珠时热区跟着走。
static void FMSyncHotZone(UIView *orb) {
    if(![orb isKindOfClass:UIView.class]) return;
    FMBeadHotZone *zone = objc_getAssociatedObject(orb, &kFMHotZoneKey);
    BOOL want = FMHiddenEffective(orb);

    // 孤儿清理：上游切换场景/重挂时会销毁并重建微珠，关联在旧微珠上的
    // 热区会残留在 overlayView 上变成"幽灵点击区"。每次同步都把不属于
    // 当前微珠的热区清掉。
    for(UIView *sub in [orb.superview.subviews copy]) {
        if([sub isKindOfClass:FMBeadHotZone.class] && sub != zone) [sub removeFromSuperview];
    }

    if(want) {
        if(!zone) {
            zone = [[FMBeadHotZone alloc] initWithFrame:orb.frame];
            objc_setAssociatedObject(orb, &kFMHotZoneKey, zone, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        // 微珠换了父视图（重挂场景）时补挂。
        if(zone.superview != orb.superview && orb.superview) {
            [zone removeFromSuperview];
            [orb.superview addSubview:zone];
        }
        zone.frame = orb.frame;
        zone.hidden = orb.hidden ? NO : YES;   // 微珠隐藏时热区才可点
    } else if(zone) {
        zone.hidden = YES;
    }
}

// 同步微珠显隐 + 热区。偏好变化、上游重绘、方向变化、生命周期事件后调用。
static void FMSyncUI(void) {
    // 横屏隐藏依赖上游「左横屏自适应」开启：关掉它就等于锁竖屏，横屏隐藏永不触发。
    // 用户开了本功能说明就是想用横屏，自动把前提补开，不用回上游设置里翻。
    if([FMPref(kKeyHideLandscape) boolValue] &&
       ![[LCOrbitStorage objectForKey:@"unlockOrientation" module:kFMModuleName] boolValue]) {
        FMSetPref(@"unlockOrientation", @YES);
        FMLog(@"bead-landscape-unlock-linked", nil);
    }

    id manager = FMSharedManager();
    UIView *orb = FMIvar(manager, "_orb");
    if([orb isKindOfClass:UIView.class]) {
        // 上游点亮把手的地方写的都是 alpha，没有人碰 hidden，
        // 所以这里压一次 hidden 就够，不必逐个 swizzle 那些 alpha 写入点。
        BOOL hidden = FMHiddenEffective(orb);
        orb.hidden = hidden;
        orb.userInteractionEnabled = hidden ? NO : !FMBool(manager, @"isOpen");
        FMSyncHotZone(orb);
    }
}


#pragma mark - 设置子页

// 子页：三行设置。
//   隐藏微珠        开关（ON = 隐藏）
//   呼出侧栏        长按空白 / 双击空白
//   摇一摇显隐微珠   开关
@interface FMBeadVisibilityController : UITableViewController
- (void)closeTapped;
@end

// 入口行：仿上游 FMSettingsNavigationRow 的观感（标题 + 副标题 + 右箭头），
// 但完全自绘——上游那组是 static 函数，别的编译单元引用不到。
// 上游补丁用 NSClassFromString(@"FMBeadVisibilityRow") 创建本类，避免跨编译
// 单元链接（测试 harness 只编译主文件，直接链接会 undefined symbol）。
@interface FMBeadVisibilityRow : UIControl
@end

@implementation FMBeadVisibilityRow
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:CGRectMake(0, 0, 320, 60)];
    if(self) {
        self.backgroundColor = FMGroupedBackground(YES);
        self.layer.cornerRadius = 12;
        self.layer.masksToBounds = YES;

        // 视觉规格对齐上游 FMSettingsNavigationRow（「侧边栏」行）：默认 chevron 图标。
        UIImageView *chevron =
            [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
        chevron.tintColor = FMBeadThemeColor(YES);
        chevron.contentMode = UIViewContentModeScaleAspectFit;
        chevron.translatesAutoresizingMaskIntoConstraints = NO;
        chevron.userInteractionEnabled = NO;
        [self addSubview:chevron];

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
        title.text = @"微珠显隐";
        title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        title.textColor = FMBeadThemeColor(NO);
        title.translatesAutoresizingMaskIntoConstraints = NO;
        title.userInteractionEnabled = NO;
        [self addSubview:title];

        UILabel *subtitle = [[UILabel alloc] initWithFrame:CGRectZero];
        subtitle.text = @"微珠隐藏、手势呼出、摇一摇显隐";
        subtitle.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        subtitle.textColor = FMBeadThemeColor(YES);
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
            [title.trailingAnchor constraintLessThanOrEqualToAnchor:chevron.leadingAnchor constant:-8],
            [subtitle.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
            [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:2],
            [subtitle.trailingAnchor constraintLessThanOrEqualToAnchor:chevron.leadingAnchor constant:-8],
        ]];
        self.accessibilityLabel = @"微珠显隐";
        self.accessibilityTraits = UIAccessibilityTraitButton;
        [self addTarget:self action:@selector(opened) forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
}

- (void)opened {
    // 从 responder 链上找设置页的 VC，让它来 present 子页。
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

    FMBeadVisibilityController *controller = [[FMBeadVisibilityController alloc]
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

// 子页：两行设置（接口声明见上方）。
@implementation FMBeadVisibilityController {
    UISwitch *_hiddenSwitch;
    UISwitch *_shakeSwitch;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"微珠显隐";
    self.view.backgroundColor = FMGroupedBackground(NO);
    self.tableView.alwaysBounceVertical = NO;
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if(section == 0) return @"隐藏后不再显示吸附的微珠；点击微珠原来所在的位置即可呼出侧栏。横屏自动隐藏见「屏幕与旋转」分组。";
    return @"摇一摇手机在「显示微珠」和「隐藏微珠」之间切换。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView
        cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *reuse = [NSString stringWithFormat:@"row%ld", (long)indexPath.section];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if(!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                           reuseIdentifier:reuse];
    cell.accessoryView = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = FMGroupedBackground(YES);

    if(indexPath.section == 0) {
        cell.textLabel.text = @"隐藏微珠";
        if(!_hiddenSwitch) {
            _hiddenSwitch = [[UISwitch alloc] init];
            _hiddenSwitch.on = FMHiddenMode();
            [_hiddenSwitch addTarget:self action:@selector(hiddenChanged:)
                    forControlEvents:UIControlEventValueChanged];
        }
        cell.accessoryView = _hiddenSwitch;
    } else {
        cell.textLabel.text = @"摇一摇显隐微珠";
        if(!_shakeSwitch) {
            _shakeSwitch = [[UISwitch alloc] init];
            _shakeSwitch.on = FMShakeToggle();
            [_shakeSwitch addTarget:self action:@selector(shakeChanged:)
                   forControlEvents:UIControlEventValueChanged];
        }
        cell.accessoryView = _shakeSwitch;
    }
    return cell;
}

- (void)hiddenChanged:(UISwitch *)sender {
    FMSetPref(kKeyHidden, @(sender.on));
    FMSyncUI();
    FMHapticLight();
    FMLog(@"bead-hidden-changed", @{@"on": @(sender.on)});
}

- (void)shakeChanged:(UISwitch *)sender {
    FMSetPref(kKeyShake, @(sender.on));
    FMHapticLight();
    FMLog(@"bead-shake-changed", @{@"on": @(sender.on)});
}

@end

#pragma mark - Swizzle

static void (*FMOriginalStart)(id, SEL, id);
static void (*FMOriginalLifecycle)(id, SEL, NSString *, UIWindowScene *);
static void (*FMOriginalStop)(id, SEL);
static void (*FMOriginalDrawOrb)(id, SEL);
static void (*FMOriginalMorphProgress)(id, SEL, CGFloat);
static void (*FMOriginalMotion)(id, SEL, UIEventSubtype, UIEvent *);

static void FMReplacementStart(id self, SEL _cmd, id context) {
    if(FMOriginalStart) FMOriginalStart(self, _cmd, context);
    dispatch_async(dispatch_get_main_queue(), ^{
        FMMigrateLegacy();
        FMSyncUI();
        if(FMHiddenEffective(FMIvar(FMSharedManager(), "_orb")))
            FMLog(@"hidden-bead-active", @{@"hidden": @YES});
    });
}

static void FMReplacementLifecycle(id self, SEL _cmd, NSString *event, UIWindowScene *scene) {
    if(FMOriginalLifecycle) FMOriginalLifecycle(self, _cmd, event, scene);
    dispatch_async(dispatch_get_main_queue(), ^{
        FMSyncUI();
    });
}

static void FMReplacementStop(id self, SEL _cmd) {
    if(FMOriginalStop) FMOriginalStop(self, _cmd);
}

static void FMReplacementDrawOrb(id self, SEL _cmd) {
    if(FMOriginalDrawOrb) FMOriginalDrawOrb(self, _cmd);
    FMSyncUI();
}

static void FMReplacementMorphProgress(id self, SEL _cmd, CGFloat progress) {
    if(FMOriginalMorphProgress) FMOriginalMorphProgress(self, _cmd, progress);
    UIView *orb = FMIvar(self, "_orb");
    if(![orb isKindOfClass:UIView.class] || !FMHiddenEffective(orb)) return;
    UIView *panel = FMObject(self, @"panel");
    if(![panel isKindOfClass:UIView.class]) return;
    // 形变在进度接近 0 时会把面板插值成把手的轮廓；把手不可见时那一帧只剩一团
    // "微珠形状"。按进度淡出面板，收合时就在成形之前透明掉。
    panel.alpha = FMGClamp((progress - kFMFadeFloor) / kFMFadeSpan, 0, 1);
}

// 摇一摇：motionEnded 是 UIResponder 的方法，直接改 UIWindow 会污染整个继承链，
// 所以先用 class_addMethod 给 UIWindow 装一份自己的实现。
static void FMReplacementMotion(id self, SEL _cmd, UIEventSubtype motion, UIEvent *event) {
    if(motion == UIEventSubtypeMotionShake && FMShakeToggle() && !FMManagerBusy()) {
        // 按当前实际显隐状态取反（横屏态下实际=隐藏，摇一下即固化隐藏），
        // 避免"摇了但看起来没反应"。
        UIView *orb = FMIvar(self, "_orb");
        BOOL next = ![orb isKindOfClass:UIView.class] ? !FMHiddenMode()
                                                      : !FMHiddenEffective(orb);
        FMSetPref(kKeyHidden, @(next));
        FMSyncUI();
        FMHapticLight();
        FMLog(@"bead-shake-toggle", @{@"hidden": @(next)});
        return;   // 摇一摇已被我们消费，不往下传，避免连带触发系统的撤销提示
    }
    if(FMOriginalMotion) FMOriginalMotion(self, _cmd, motion, event);
}

static BOOL FMSwizzleInstance(Class cls, NSString *selectorName, IMP replacement, IMP *original) {
    if(!cls) return NO;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod(cls, selector);
    if(!method) return NO;
    if(original) *original = method_getImplementation(method);
    method_setImplementation(method, replacement);
    return YES;
}

// 覆盖从父类继承来的方法（如 UIWindow 的 motionEnded:withEvent:）：
// 在子类上新增一份实现，父类不受影响。
static BOOL FMSwizzleOverride(Class cls, NSString *selectorName, IMP replacement, IMP *original) {
    if(!cls) return NO;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod(cls, selector);
    if(!method) return NO;
    IMP inherited = method_getImplementation(method);
    if(original) *original = inherited;
    if(class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) return YES;
    method_setImplementation(method, replacement);
    return YES;
}

#pragma mark - 加载入口

// 单例容器：早期版本是 recognizer 的 target/delegate，手势方案移除后
// 只作为模块的加载入口（+load 挂在它上面）保留。
@interface FMSummonCenter : NSObject
+ (instancetype)shared;
@end

@implementation FMSummonCenter

+ (instancetype)shared {
    static FMSummonCenter *center;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ center = [FMSummonCenter new]; });
    return center;
}

+ (void)load {
    FMLog(@"hidden-bead-loaded", @{@"pid": @(getpid()),
                                    @"hostUI": @([LCOrbitHost isHostUI]),
                                    @"bundle": NSBundle.mainBundle.bundleIdentifier ?: @""});
    Class module = NSClassFromString(@"LCFloatingMenuModule");
    Class manager = NSClassFromString(@"FMManager");

    BOOL ok = YES;
    ok &= FMSwizzleInstance(module, @"orbitDidStartWithContext:", (IMP)FMReplacementStart, (IMP *)&FMOriginalStart);
    ok &= FMSwizzleInstance(module, @"orbitDidReceiveLifecycleEvent:scene:", (IMP)FMReplacementLifecycle, (IMP *)&FMOriginalLifecycle);
    ok &= FMSwizzleInstance(module, @"orbitWillStop", (IMP)FMReplacementStop, (IMP *)&FMOriginalStop);
    ok &= FMSwizzleInstance(manager, @"drawOrb", (IMP)FMReplacementDrawOrb, (IMP *)&FMOriginalDrawOrb);
    ok &= FMSwizzleInstance(manager, @"applyMorphProgress:", (IMP)FMReplacementMorphProgress, (IMP *)&FMOriginalMorphProgress);
    ok &= FMSwizzleOverride(UIWindow.class, @"motionEnded:withEvent:", (IMP)FMReplacementMotion, (IMP *)&FMOriginalMotion);

    // 同步兜底，三条线：
    //   1) 回到前台 / 新窗口可见——Guest 的主窗口常在模块启动之后才创建，
    //      只依赖启动时机会漏掉晚到的窗口；
    //   2) overlay 布局变化（LCOrbitOverlayViewController 在方向转场时发）——
    //      横屏隐藏要靠它重算：转场完成后 overlay 的 bounds 已是新方向，
    //      此时同步一次，微珠显隐和热区位置都跟上。
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                 usingBlock:^(NSNotification *note) {
        FMSyncUI();
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:UIWindowDidBecomeVisibleNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                 usingBlock:^(NSNotification *note) {
        FMSyncUI();
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:@"LCOrbitOverlayLayoutDidChangeNotification"
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                 usingBlock:^(NSNotification *note) {
        FMSyncUI();
    }];

    if(!ok) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            FMLog(@"gesture-hook-missing", @{@"LCFloatingMenuModule": @(module != nil),
                                            @"FMManager": @(manager != nil)});
        });
    }
}

@end
