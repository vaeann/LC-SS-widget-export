// FMHiddenBeadModule — 微珠显隐：隐藏微珠 + 三种呼出方式 + 摇一摇显隐
//
// 功能（全部通过运行时接入，不改上游业务逻辑）：
//   * beadHidden        隐藏吸附在屏幕边缘的微珠（把手）；
//   * beadSummonGesture 微珠隐藏后的呼出方式：
//                         0 长按空白 / 1 双击空白 / 2 左胶囊按钮；
//   * shakeToggleBead   摇一摇在「显示微珠」和「隐藏微珠」之间切换。
//
// 设置入口：设置页 → 显示方式 → 微珠显隐（入口行由本模块导出的
// FMBeadVisibilityRow() 生成，子页是本模块自己的 ViewController）。
//
// 接入点（六个 swizzle + 两个通知，都是"先调原实现，再补一句"）：
//   -[LCFloatingMenuModule orbitDidStartWithContext:]              模块启动 → 同步 UI
//   -[LCFloatingMenuModule orbitDidReceiveLifecycleEvent:scene:]   前后台/场景切换 → 同步
//   -[LCFloatingMenuModule orbitWillStop]                          模块停止 → 拆干净
//   -[FMManager drawOrb]                                           画完把手 → 按开关隐藏
//   -[FMManager applyMorphProgress:]                               形变每帧 → 低进度淡出面板
//   -[UIWindow motionEnded:withEvent:]                             摇一摇
//   UIApplicationDidBecomeActiveNotification                       回到前台兜底
//   UIWindowDidBecomeVisibleNotification                           新窗口出现兜底（Guest App
//                                                                  的主窗口经常晚于模块启动）
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
//   beadSummonGesture   0 长按空白（默认）/ 1 双击空白 / 2 左胶囊按钮
//   shakeToggleBead     摇一摇显隐微珠，默认关
static NSString *const kKeyHidden = @"beadHidden";
static NSString *const kKeySummon = @"beadSummonGesture";
static NSString *const kKeyShake = @"shakeToggleBead";

// 长按判定。按压时间短了会和 App 自己的长按打架，长了手感拖沓；
// allowableMovement 给到手抖余量——12pt 在真实握持下太容易超，超了手势直接失败。
static const CGFloat kFMPressDuration = 0.45;
static const CGFloat kFMPressMovement = 24.0;
static const CGFloat kFMFadeFloor = 0.02;
static const CGFloat kFMFadeSpan = 0.16;

static char kFMPressGestureKey;
static char kFMDoubleGestureKey;
static char kFMCapsuleKey;

static CGFloat FMGClamp(CGFloat value, CGFloat low, CGFloat high) {    return value < low ? low : (value > high ? high : value);
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

// 呼出方式：0 长按空白 / 1 双击空白 / 2 左胶囊按钮。
static NSInteger FMSummonStyle(void) {
    id value = FMPref(kKeySummon);
    NSInteger style = value ? [value integerValue] : 0;
    if(style < 0 || style > 2) style = 0;
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

// 面板收合时呼出。
static void FMOpenPanel(NSString *trigger) {
    id manager = FMSharedManager();
    if(!manager) return;
    if(FMBool(manager, @"isOpen")) return;
    if(FMObject(manager, @"settingsWindow")) return;
    if(FMBoolIvar(manager, "_morphActive")) return;

    SEL toggle = NSSelectorFromString(@"toggle");
    if(![manager respondsToSelector:toggle]) return;
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

#pragma mark - 手势中心

@interface FMSummonCenter : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)handlePress:(UILongPressGestureRecognizer *)gesture;
- (void)handleDoubleTap:(UITapGestureRecognizer *)gesture;
@end

static void FMSyncUI(void);

static BOOL FMIsOwnOverlayWindow(UIWindow *window) {
    // Overlay 是 LCOrbitPassThroughWindow，挂在 Normal+75；它的触摸不会到这里。
    return [NSStringFromClass(window.class) isEqualToString:@"LCOrbitPassThroughWindow"];
}

// 手势挂在 level < Alert 的普通 window 上（LC 宿主窗口和 Guest App 的
// 主窗口都在这个集合里）。每个 window 按当前呼出方式装/拆，切换方式时
// 旧手势会被拆掉，不重复、不残留。
static void FMInstallInScene(UIWindowScene *scene) {
    if(!scene) return;
    FMSummonCenter *center = FMHiddenMode() ? [FMSummonCenter shared] : nil;
    (void)center;
    NSInteger style = FMSummonStyle();
    BOOL wantPress = FMHiddenMode() && style == 0;
    BOOL wantDouble = FMHiddenMode() && style == 1;

    for(UIWindow *window in scene.windows) {
        if(window.hidden) continue;
        if(window.windowLevel >= UIWindowLevelAlert) continue;
        if(FMIsOwnOverlayWindow(window)) continue;

        UILongPressGestureRecognizer *press =
            objc_getAssociatedObject(window, &kFMPressGestureKey);
        if(wantPress && !press) {
            press = [[UILongPressGestureRecognizer alloc] initWithTarget:center
                                                                  action:@selector(handlePress:)];
            press.minimumPressDuration = kFMPressDuration;
            press.allowableMovement = kFMPressMovement;
            press.numberOfTouchesRequired = 1;
            // 不吞触摸：App 自己的点击、滚动、长按都照常工作。
            press.cancelsTouchesInView = NO;
            press.delaysTouchesEnded = NO;
            press.delegate = center;
            [window addGestureRecognizer:press];
            objc_setAssociatedObject(window, &kFMPressGestureKey, press,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else if(!wantPress && press) {
            [window removeGestureRecognizer:press];
            objc_setAssociatedObject(window, &kFMPressGestureKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }

        UITapGestureRecognizer *doubleTap =
            objc_getAssociatedObject(window, &kFMDoubleGestureKey);
        if(wantDouble && !doubleTap) {
            doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:center
                                                                action:@selector(handleDoubleTap:)];
            doubleTap.numberOfTapsRequired = 2;
            doubleTap.numberOfTouchesRequired = 1;
            doubleTap.cancelsTouchesInView = NO;
            doubleTap.delaysTouchesEnded = NO;
            doubleTap.delegate = center;
            [window addGestureRecognizer:doubleTap];
            objc_setAssociatedObject(window, &kFMDoubleGestureKey, doubleTap,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else if(!wantDouble && doubleTap) {
            [window removeGestureRecognizer:doubleTap];
            objc_setAssociatedObject(window, &kFMDoubleGestureKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

// 遍历所有前台场景安装。不再依赖某个特定 scene：Guest App 的主窗口
// 创建得晚，任何一个触发点都可能只看到部分窗口，所以每个触发点都全量刷。
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
            UIControl *capsule = objc_getAssociatedObject(window, &kFMCapsuleKey);
            if(capsule) {
                [capsule removeFromSuperview];
                objc_setAssociatedObject(window, &kFMCapsuleKey, nil,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    }
}

#pragma mark - 左胶囊按钮

// 左侧边缘的竖向胶囊把手：宽 7pt、高 64pt，贴安全区左侧垂直居中。
// 是"微珠隐藏"时代的可见把手，点它呼出面板。
@interface FMSummonCapsule : UIControl
@end

@implementation FMSummonCapsule
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:CGRectMake(0, 0, 7, 64)];
    if(self) {
        self.layer.cornerRadius = 3.5;
        self.layer.masksToBounds = YES;
        self.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithWhite:1.0 alpha:0.28]
                : [UIColor colorWithWhite:0.0 alpha:0.22];
        }];
        self.alpha = 0.9;
        self.accessibilityLabel = @"呼出侧栏";
        [self addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
}
- (void)tapped {
    FMOpenPanel(@"capsule");
}
@end

static void FMSyncCapsule(void) {
    BOOL want = FMHiddenMode() && FMSummonStyle() == 2 && !FMManagerBusy();
    UIWindowScene *activeScene = nil;
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if([scene isKindOfClass:UIWindowScene.class] &&
           scene.activationState == UISceneActivationStateForegroundActive) {
            activeScene = (UIWindowScene *)scene;
            break;
        }
    }
    if(!activeScene) return;

    UIWindow *host = nil;
    for(UIWindow *window in activeScene.windows) {
        if(window.hidden || window.windowLevel >= UIWindowLevelAlert) continue;
        if(FMIsOwnOverlayWindow(window)) continue;
        host = window;
        break;
    }
    if(!host) return;

    FMSummonCapsule *capsule = objc_getAssociatedObject(host, &kFMCapsuleKey);
    if(want && !capsule) {
        capsule = [[FMSummonCapsule alloc] initWithFrame:CGRectZero];
        capsule.translatesAutoresizingMaskIntoConstraints = NO;
        [host addSubview:capsule];
        [NSLayoutConstraint activateConstraints:@[
            [capsule.leadingAnchor constraintEqualToAnchor:host.leadingAnchor constant:4],
            [capsule.centerYAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.centerYAnchor],
        ]];
        objc_setAssociatedObject(host, &kFMCapsuleKey, capsule, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if(!want && capsule) {
        // 面板展开或呼出方式切换时收起；胶囊所在的 window 如果已被销毁，
        // associated object 也会随之释放，这里只处理还挂着的情况。
        [capsule removeFromSuperview];
        objc_setAssociatedObject(host, &kFMCapsuleKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// 统一同步：微珠显隐、手势装拆、胶囊显隐。任何偏好变化或上游重绘后都走这里。
static void FMSyncUI(void) {
    BOOL hidden = FMHiddenMode();
    id manager = FMSharedManager();
    UIView *orb = FMIvar(manager, "_orb");
    if([orb isKindOfClass:UIView.class]) {
        // 上游点亮把手的地方写的都是 alpha，没有人碰 hidden，
        // 所以这里压一次 hidden 就够，不必逐个 swizzle 那些 alpha 写入点。
        orb.hidden = hidden;
        orb.userInteractionEnabled = hidden ? NO : !FMBool(manager, @"isOpen");
    }
    FMInstallEverywhere();
    FMSyncCapsule();
}

#pragma mark - 设置子页

// 子页：三行设置。
//   隐藏微珠        开关（ON = 隐藏）
//   呼出侧栏        长按空白 / 双击空白 / 左胶囊按钮
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
        self.backgroundColor = [UIColor secondarySystemGroupedBackground];
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
    self.view.backgroundColor = [UIColor systemGroupedBackground];
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
    if(section == 1) return @"微珠隐藏时生效：长按或双击空白页面，或点击屏幕左侧的胶囊按钮。";
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
    cell.backgroundColor = [UIColor secondarySystemGroupedBackground];

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
            _summonSegment = [[UISegmentedControl alloc] initWithItems:@[@"长按空白", @"双击空白", @"左胶囊按钮"]];
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

#pragma mark -

@implementation FMSummonCenter {
    BOOL _hooksInstalled;
}

+ (instancetype)shared {
    static FMSummonCenter *center;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ center = [FMSummonCenter new]; });
    return center;
}

+ (void)load {
    Class module = NSClassFromString(@"LCFloatingMenuModule");
    Class manager = NSClassFromString(@"FMManager");

    BOOL ok = YES;
    ok &= FMSwizzleInstance(module, @"orbitDidStartWithContext:", (IMP)FMReplacementStart, (IMP *)&FMOriginalStart);
    ok &= FMSwizzleInstance(module, @"orbitDidReceiveLifecycleEvent:scene:", (IMP)FMReplacementLifecycle, (IMP *)&FMOriginalLifecycle);
    ok &= FMSwizzleInstance(module, @"orbitWillStop", (IMP)FMReplacementStop, (IMP *)&FMOriginalStop);
    ok &= FMSwizzleInstance(manager, @"drawOrb", (IMP)FMReplacementDrawOrb, (IMP *)&FMOriginalDrawOrb);
    ok &= FMSwizzleInstance(manager, @"applyMorphProgress:", (IMP)FMReplacementMorphProgress, (IMP *)&FMOriginalMorphProgress);
    ok &= FMSwizzleOverride(UIWindow.class, @"motionEnded:withEvent:", (IMP)FMReplacementMotion, (IMP *)&FMOriginalMotion);
    [FMSummonCenter shared]->_hooksInstalled = ok;

    // 回到前台兜底：场景窗口集合可能变化。
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                 usingBlock:^(NSNotification *note) {
        FMSyncUI();
    }];

    // 新窗口出现兜底：Guest App 的主窗口经常在模块启动之后才创建，
    // 只依赖启动时机安装，手势就会一直缺席。
    [NSNotificationCenter.defaultCenter addObserverForName:UIWindowDidBecomeVisibleNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                 usingBlock:^(NSNotification *note) {
        FMSyncUI();
    }];

    if(!ok) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if(![FMSummonCenter shared]->_hooksInstalled)
                FMLog(@"gesture-hook-missing", @{@"LCFloatingMenuModule": @(module != nil),
                                                @"FMManager": @(manager != nil)});
        });
    }
}

- (void)handlePress:(UILongPressGestureRecognizer *)gesture {
    if(gesture.state != UIGestureRecognizerStateBegan) return;
    if(!FMHiddenMode() || FMSummonStyle() != 0) return;
    FMOpenPanel(nil);
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)gesture {
    if(gesture.state != UIGestureRecognizerStateEnded) return;
    if(!FMHiddenMode() || FMSummonStyle() != 1) return;
    FMOpenPanel(@"double-tap");
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    return FMHiddenMode();
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldReceiveTouch:(UITouch *)touch {
    return FMTouchIsBlank(touch);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

@end
