// FMHiddenBeadModule — 微珠显隐：隐藏微珠 + 两种呼出手势 + 摇一摇显隐
//
// 功能（全部通过运行时接入，不改上游业务逻辑）：
//   * beadHidden        隐藏吸附在屏幕边缘的微珠（把手）；
//   * beadSummonGesture 微珠隐藏后的呼出方式：
//                         0 长按空白（默认）/ 1 双击空白；
//   * shakeToggleBead   摇一摇在「显示微珠」和「隐藏微珠」之间切换。
//
// 设置入口：设置页 → 显示方式 → 微珠显隐（入口行由本模块导出的
// FMBeadVisibilityRow() 生成，子页是本模块自己的 ViewController）。
//
// 接入点（七个 swizzle，都是"先调原实现，再补一句"）：
//   -[LCFloatingMenuModule orbitDidStartWithContext:]              模块启动 → 迁移 + 同步
//   -[LCFloatingMenuModule orbitDidReceiveLifecycleEvent:scene:]   前后台/场景切换 → 同步
//   -[LCFloatingMenuModule orbitWillStop]                          模块停止 → 取消计时
//   -[FMManager drawOrb]                                           画完把手 → 按开关隐藏
//   -[FMManager applyMorphProgress:]                               形变每帧 → 低进度淡出面板
//   -[UIWindow motionEnded:withEvent:]                             摇一摇
//   window 级 UILongPress/UIScreenEdge  recognizer                    呼出手势（长按/双击空白）
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
//   beadHidden          YES = 隐藏微珠（对应旧版 orbHandleStyle=2，启动时迁移）
//   beadSummonGesture   0 长按空白（默认）/ 1 双击空白
//   shakeToggleBead     摇一摇显隐微珠，默认关
static NSString *const kKeyHidden = @"beadHidden";
static NSString *const kKeySummon = @"beadSummonGesture";
static NSString *const kKeyShake = @"shakeToggleBead";

// 长按判定。按压时间短了会和 App 自己的长按打架，长了手感拖沓；
// allowableMovement 给到手抖余量——12pt 在真实握持下太容易超，超了手势直接失败。
static const CGFloat kFMPressDuration = 0.40;
static const CGFloat kFMPressMovement = 28.0;
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

static BOOL FMHiddenMode(void) {
    return [FMPref(kKeyHidden) boolValue];
}

// 呼出方式：0 长按空白 / 1 双击空白。（历史上短暂出现过 2=左胶囊按钮，
// 读到旧值一律降级为默认的长按空白。）
static NSInteger FMSummonStyle(void) {
    id value = FMPref(kKeySummon);
    NSInteger style = value ? [value integerValue] : 0;
    if(style != 1) style = 0;
    return style;
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

#pragma mark - 空白判定

// "空白页面"的判定标准：触摸点不能落在任何可交互控件、文本输入、
// 列表单元格或网页视图上。命中这些就交给 App 自己处理，我们不抢。
// 注意：只排除具体的内容视图，不排除 UITableView/UICollectionView 这类
// 容器——容器本身的空白区域（cell 之外的滚动区）也算空白。
static BOOL FMTouchIsBlank(UITouch *touch) {
    UIView *view = touch.view;
    if(!view) return YES;   // 触摸没落在任何视图上，就是 window 背景，算空白。
    for(UIView *current = view; current; current = current.superview) {
        if([current isKindOfClass:UIControl.class]) return NO;
        if([current isKindOfClass:UITextView.class]) return NO;
        if([current isKindOfClass:UITextField.class]) return NO;
        if([current isKindOfClass:NSClassFromString(@"UITableViewCell")]) return NO;
        if([current isKindOfClass:NSClassFromString(@"UICollectionViewCell")]) return NO;
        if([current isKindOfClass:NSClassFromString(@"UITableViewHeaderFooterView")]) return NO;
        if([current isKindOfClass:NSClassFromString(@"WKWebView")]) return NO;
    }
    return YES;
}

// not-blank 时记录从触摸点向上的视图链（前 8 层）+ 第一个黑名单类。
// App 内容层级深，整条链能直接看出是谁在拦。
static NSString *FMTouchBlockerName(UITouch *touch) {
    UIView *view = touch.view;
    if(!view) return @"nil-view";
    NSMutableArray *chain = [NSMutableArray array];
    NSString *blocker = nil;
    int depth = 0;
    for(UIView *current = view; current && depth < 8; current = current.superview, depth++) {
        [chain addObject:NSStringFromClass(current.class)];
        if(blocker) continue;
        if([current isKindOfClass:UIControl.class]) blocker = NSStringFromClass(current.class);
        else if([current isKindOfClass:UITextView.class]) blocker = @"UITextView";
        else if([current isKindOfClass:UITextField.class]) blocker = @"UITextField";
        else if([current isKindOfClass:NSClassFromString(@"UITableViewCell")]) blocker = @"UITableViewCell";
        else if([current isKindOfClass:NSClassFromString(@"UICollectionViewCell")]) blocker = @"UICollectionViewCell";
        else if([current isKindOfClass:NSClassFromString(@"UITableViewHeaderFooterView")]) blocker = @"HeaderFooterView";
        else if([current isKindOfClass:NSClassFromString(@"WKWebView")]) blocker = @"WKWebView";
    }
    NSString *path = [chain componentsJoinedByString:@" < "];
    return blocker ? [NSString stringWithFormat:@"%@  ||链: %@", blocker, path] : path;
}

#pragma mark - 呼出手势（recognizer 级）

// 方案演变（三次失败换来的教训，改动前先读）：
//   v9   recognizer + simultaneous=YES：LC 宿主有效；Guest App 内被 App 自己的
//        手势（scrollview pan 等）挤掉——App 的 pan 一旦 Began 会"没收"触摸，
//        window 级 longPress 永远不触发。
//   v11-v15  swizzle UIWindow/UIApplication.sendEvent:：宿主有效；但 Guest 进程内
//        的触摸不经 window.sendEvent（LC 多任务容器派发），Guest 侧零事件。
//   v16  回到 recognizer，竞争策略改为 shouldRequireFailureOfGestureRecognizer：
//        App 的手势必须等我们的长按失败（移动超限或松手即失败）。长按不动 0.4s
//        我们触发呼出；用户想滚动时长按立即失败、App 滚动继续。双击与 App 手势
//        并行（双击快、且只收空白处触摸，不延迟 App 点击）。
//        竞争处理参考 LiveContainer-zh 的 TweakLoader 边缘手势实现。

static char kFMPressGestureKey;
static char kFMDoubleGestureKey;

// recognizer 的 target 与 delegate。单例，所有窗口共用。
@interface FMSummonCenter : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)handlePress:(UILongPressGestureRecognizer *)gesture;
- (void)handleDoubleTap:(UITapGestureRecognizer *)gesture;
@end

static BOOL FMIsOwnOverlayWindow(UIWindow *window) {
    // Overlay 是 LCOrbitPassThroughWindow，挂在 Normal+75；它的触摸不会到这里。
    return [NSStringFromClass(window.class) isEqualToString:@"LCOrbitPassThroughWindow"];
}

static void FMSyncUI(void);

// 每个前台普通 window 按呼出方式装/拆 recognizer。手势始终生效（不依赖微珠
// 显隐，v14 起解除绑定）；切换方式时旧的会被拆掉，不重复、不残留。
static void FMInstallInScene(UIWindowScene *scene) {
    if(!scene) return;
    FMSummonCenter *center = [FMSummonCenter shared];
    NSInteger style = FMSummonStyle();
    BOOL wantPress = style == 0;
    BOOL wantDouble = style == 1;
    NSInteger installed = 0;
    NSMutableArray *skipped = [NSMutableArray array];

    for(UIWindow *window in scene.windows) {
        if(window.hidden) { [skipped addObject:[NSString stringWithFormat:@"%@(hidden)", window.class]; continue; }
        if(window.windowLevel >= UIWindowLevelAlert) { [skipped addObject:[NSString stringWithFormat:@"%@(alert)", window.class]; continue; }
        if(FMIsOwnOverlayWindow(window)) { [skipped addObject:[NSString stringWithFormat:@"%@(overlay)", window.class]; continue; }

        UILongPressGestureRecognizer *press = objc_getAssociatedObject(window, &kFMPressGestureKey);
        if(wantPress && !press) {
            press = [[UILongPressGestureRecognizer alloc] initWithTarget:center
                                                                  action:@selector(handlePress:)];
            press.minimumPressDuration = kFMPressDuration;
            press.allowableMovement = kFMPressMovement;
            press.numberOfTouchesRequired = 1;
            // 不吞触摸：App 自己的点击、滚动都照常工作。
            press.cancelsTouchesInView = NO;
            press.delaysTouchesEnded = NO;
            press.delegate = center;
            [window addGestureRecognizer:press];
            objc_setAssociatedObject(window, &kFMPressGestureKey, press, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else if(!wantPress && press) {
            [window removeGestureRecognizer:press];
            objc_setAssociatedObject(window, &kFMPressGestureKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }

        UITapGestureRecognizer *doubleTap = objc_getAssociatedObject(window, &kFMDoubleGestureKey);
        if(wantDouble && !doubleTap) {
            doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:center
                                                                action:@selector(handleDoubleTap:)];
            doubleTap.numberOfTapsRequired = 2;
            doubleTap.numberOfTouchesRequired = 1;
            doubleTap.cancelsTouchesInView = NO;
            doubleTap.delaysTouchesEnded = NO;
            doubleTap.delegate = center;
            [window addGestureRecognizer:doubleTap];
            objc_setAssociatedObject(window, &kFMDoubleGestureKey, doubleTap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else if(!wantDouble && doubleTap) {
            [window removeGestureRecognizer:doubleTap];
            objc_setAssociatedObject(window, &kFMDoubleGestureKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }

        if((wantPress && press) || (wantDouble && doubleTap)) installed++;
    }

    // 安装诊断：窗口清单 + 实际装上的数量。宿主正常、Guest 失效时，
    // 这条能直接看出是没遍历到窗口、还是窗口被跳过条件滤掉。
    static NSInteger FMLastInstalledCount = -1;
    static NSTimeInterval FMLastInstallLog = 0;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if(installed != FMLastInstalledCount || now - FMLastInstallLog > 30.0) {
        FMLastInstalledCount = installed;
        FMLastInstallLog = now;
        FMLog(@"gesture-install", @{@"style": @(style),
                                    @"installed": @(installed),
                                    @"skipped": skipped,
                                    @"sceneState": @(scene.activationState)});
    }
}

// 遍历所有前台场景安装。每个触发点都全量刷：Guest 的主窗口创建得晚，
// 任何单一时机都可能只看到部分窗口。
static void FMInstallEverywhere(void) {
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if(![scene isKindOfClass:UIWindowScene.class]) continue;
        UISceneActivationState state = scene.activationState;
        if(state != UISceneActivationStateForegroundActive &&
           state != UISceneActivationStateForegroundInactive) continue;
        FMInstallInScene((UIWindowScene *)scene);
    }
}

static void FMRemoveAllGestures(void) {
    char *gestureKeys[2] = {&kFMPressGestureKey, &kFMDoubleGestureKey};
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if(![scene isKindOfClass:UIWindowScene.class]) continue;
        for(UIWindow *window in ((UIWindowScene *)scene).windows) {
            for(int index = 0; index < 2; index++) {
                char *key = gestureKeys[index];
                UIGestureRecognizer *gesture = objc_getAssociatedObject(window, key);
                if(!gesture) continue;
                [window removeGestureRecognizer:gesture];
                objc_setAssociatedObject(window, key, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    }
}

// 同步微珠显隐 + 手势装拆。偏好变化、上游重绘、生命周期事件后调用。
static void FMSyncUI(void) {
    id manager = FMSharedManager();
    UIView *orb = FMIvar(manager, "_orb");
    if([orb isKindOfClass:UIView.class]) {
        // 上游点亮把手的地方写的都是 alpha，没有人碰 hidden，
        // 所以这里压一次 hidden 就够，不必逐个 swizzle 那些 alpha 写入点。
        BOOL hidden = FMHiddenMode();
        orb.hidden = hidden;
        orb.userInteractionEnabled = hidden ? NO : !FMBool(manager, @"isOpen");
    }
    FMInstallEverywhere();
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

        UIImageSymbolConfiguration *small =
            [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold];
        UIImageView *chevron =
            [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"
                                                          withConfiguration:small]];
        chevron.tintColor = [UIColor secondaryLabelColor];
        chevron.contentMode = UIViewContentModeScaleAspectFit;
        chevron.translatesAutoresizingMaskIntoConstraints = NO;
        chevron.userInteractionEnabled = NO;
        [self addSubview:chevron];

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
        title.text = @"微珠显隐";
        title.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        title.textColor = [UIColor labelColor];
        title.translatesAutoresizingMaskIntoConstraints = NO;
        title.userInteractionEnabled = NO;
        [self addSubview:title];

        UILabel *subtitle = [[UILabel alloc] initWithFrame:CGRectZero];
        subtitle.text = @"微珠隐藏、手势呼出、摇一摇显隐";
        subtitle.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        subtitle.textColor = [UIColor secondaryLabelColor];
        subtitle.translatesAutoresizingMaskIntoConstraints = NO;
        subtitle.userInteractionEnabled = NO;
        [self addSubview:subtitle];

        [NSLayoutConstraint activateConstraints:@[
            [chevron.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
            [chevron.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [chevron.widthAnchor constraintEqualToConstant:12],
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

// 子页：三行设置（接口声明见上方）。
@implementation FMBeadVisibilityController {
    UISwitch *_hiddenSwitch;
    UISegmentedControl *_summonSegment;
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

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if(section == 0) return @"隐藏后不再显示吸附的微珠，用下面的手势呼出侧栏。";
    if(section == 1) return @"微珠隐藏时生效：长按或双击页面的空白区域呼出侧栏。";
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
    } else if(indexPath.section == 1) {
        cell.textLabel.text = @"呼出侧栏";
        if(!_summonSegment) {
            _summonSegment = [[UISegmentedControl alloc] initWithItems:@[@"长按空白", @"双击空白"]];
            _summonSegment.selectedSegmentIndex = FMSummonStyle();
            _summonSegment.apportionsSegmentWidthsByContent = YES;
            [_summonSegment addTarget:self action:@selector(summonChanged:)
                     forControlEvents:UIControlEventValueChanged];
        }
        cell.accessoryView = _summonSegment;
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

- (void)summonChanged:(UISegmentedControl *)sender {
    FMSetPref(kKeySummon, @(sender.selectedSegmentIndex));
    FMSyncUI();
    FMLog(@"bead-summon-changed", @{@"style": @(sender.selectedSegmentIndex)});
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
        if(FMHiddenMode()) FMLog(@"hidden-bead-active", @{@"summon": @(FMSummonStyle())});
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
    FMRemoveAllGestures();
}

static void FMReplacementDrawOrb(id self, SEL _cmd) {
    if(FMOriginalDrawOrb) FMOriginalDrawOrb(self, _cmd);
    FMSyncUI();
}

static void FMReplacementMorphProgress(id self, SEL _cmd, CGFloat progress) {
    if(FMOriginalMorphProgress) FMOriginalMorphProgress(self, _cmd, progress);
    if(!FMHiddenMode()) return;
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
        BOOL next = !FMHiddenMode();
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

@implementation FMSummonCenter

- (void)handlePress:(UILongPressGestureRecognizer *)gesture {
    if(gesture.state != UIGestureRecognizerStateBegan) return;
    FMLog(@"gesture-fired", @{@"type": @"long-press"});
    FMOpenPanel(@"long-press");
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)gesture {
    if(gesture.state != UIGestureRecognizerStateEnded) return;
    FMLog(@"gesture-fired", @{@"type": @"double-tap"});
    FMOpenPanel(@"double-tap");
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldReceiveTouch:(UITouch *)touch {
    BOOL blank = FMTouchIsBlank(touch);
    if(!blank)
        FMLog(@"gesture-not-blank", @{@"path": FMTouchBlockerName(touch) ?: @"unknown"});
    return blank;
}

// 竞争策略核心（参考 LiveContainer-zh TweakLoader）：长按 recognizer 要求
// App 的手势等它失败——用户按住不动 0.4s 我们触发；用户移动（滚动）时长按
// 立即失败，App 的手势接着识别。没有这条，App 的 pan Began 后会"没收"触摸，
// 我们的长按永远不触发（v9 在 Guest 内失效的根因）。
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRequireFailureOfGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return [gestureRecognizer isKindOfClass:UILongPressGestureRecognizer.class];
}

// 双击与 App 手势并行（双击判定快，且只收空白处触摸，不延迟 App 点击）；
// 长按走上面的 failure 要求，不同步。
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return ![gestureRecognizer isKindOfClass:UILongPressGestureRecognizer.class];
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

    // 手势安装兜底：Guest 的主窗口经常在模块启动之后才创建，新窗口出现和
    // 回到前台时都全量刷一次，不漏掉晚到的窗口。
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

    if(!ok) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            FMLog(@"gesture-hook-missing", @{@"LCFloatingMenuModule": @(module != nil),
                                            @"FMManager": @(manager != nil)});
        });
    }
}

@end
