// FMHiddenBeadModule — LCFloatingMenu 的「隐藏微珠」形态
//
// 选中该形态后：
//   * 不绘制吸附在屏幕边缘的微珠（把手），也不响应触摸；
//   * 展开方式改为「单指长按任意空白页面」。
//
// 设计前提：不修改上游 8300 行主文件里的业务逻辑，全部通过运行时接入。
// 上游改了下列符号名，本模块会安静失效（不崩溃），并记一条 gesture-hook-missing。
//
// 接入点（五个 swizzle，都是"先调原实现，再补一句"）：
//   -[LCFloatingMenuModule orbitDidStartWithContext:]              模块启动 → 装长按
//   -[LCFloatingMenuModule orbitDidReceiveLifecycleEvent:scene:]   前后台/场景切换 → 重装
//   -[LCFloatingMenuModule orbitWillStop]                          模块停止 → 拆干净
//   -[FMManager drawOrb]                                           画完把手 → 隐藏
//   -[FMManager applyMorphProgress:]                               形变每帧 → 低进度淡出面板
//
// 形态编码沿用上游 orbHandleStyle：0 胶囊 / 1 水滴（orbDropletPull 表示拉动水滴）
// / 2 隐藏微珠。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>
#import "../../Core/LCOrbitStorage.h"
#import "../../Core/LCOrbitHost.h"
#import "../../Core/LCOrbitLog.h"

static NSString *const kFMModuleName = @"LCFloatingMenu";

// 单指长按的判定。按压时间短了会和 App 自己的长按打架，长了手感拖沓。
static const CGFloat kFMPressDuration = 0.45;
static const CGFloat kFMPressMovement = 12.0;
static const CGFloat kFMFadeFloor = 0.02;
static const CGFloat kFMFadeSpan = 0.16;

static char kFMPressGestureKey;
static BOOL FMAnyGestureInstalled = NO;

static CGFloat FMGClamp(CGFloat value, CGFloat low, CGFloat high) {
    return value < low ? low : (value > high ? high : value);
}

static void FMLog(NSString *event, id details) {
    [LCOrbitLog appendEvent:event details:details kind:@"runtime"];
}

// 隐藏微珠形态：orbHandleStyle >= 1.5。
static BOOL FMHiddenMode(void) {
    id value = [LCOrbitStorage objectForKey:@"orbHandleStyle" module:kFMModuleName];
    return value && [value doubleValue] >= 1.5;
}

// 震动开关沿用上游的 haptic 偏好（默认开）。
static BOOL FMHapticEnabled(void) {
    id value = [LCOrbitStorage objectForKey:@"haptic" module:kFMModuleName];
    return value ? [value boolValue] : YES;
}

// 摇一摇呼出，默认关：这个动作容易误触，交给自己在设置里开。
static BOOL FMShakeEnabled(void) {
    id value = [LCOrbitStorage objectForKey:@"shakeToOpen" module:kFMModuleName];
    return value ? [value boolValue] : NO;
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

#pragma mark - 空白判定

// “空白页面”的判定标准：触摸点不能落在任何可交互控件、文本输入、
// 列表单元格或网页视图上。命中这些就交给 App 自己处理，我们不抢。
static BOOL FMTouchIsBlank(UITouch *touch) {
    UIView *view = touch.view;
    if(!view) return NO;
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

#pragma mark - 手势

@interface FMPressCenter : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)handlePress:(UILongPressGestureRecognizer *)gesture;
@end

static void FMRemoveAllGestures(void);

static BOOL FMIsOwnOverlayWindow(UIWindow *window) {
    // Overlay 是 LCOrbitPassThroughWindow，挂在 Normal+75；它的触摸不会到这里。
    return [NSStringFromClass(window.class) isEqualToString:@"LCOrbitPassThroughWindow"];
}

static void FMInstallInScene(UIWindowScene *scene) {
    if(!scene) return;
    if(!FMHiddenMode()) {
        if(FMAnyGestureInstalled) FMRemoveAllGestures();
        return;
    }
    FMPressCenter *center = [FMPressCenter shared];
    for(UIWindow *window in scene.windows) {
        if(window.hidden) continue;
        if(window.windowLevel >= UIWindowLevelAlert) continue;
        if(FMIsOwnOverlayWindow(window)) continue;
        if(objc_getAssociatedObject(window, &kFMPressGestureKey)) continue;

        UILongPressGestureRecognizer *press =
            [[UILongPressGestureRecognizer alloc] initWithTarget:center
                                                          action:@selector(handlePress:)];
        press.minimumPressDuration = kFMPressDuration;
        press.allowableMovement = kFMPressMovement;
        press.numberOfTouchesRequired = 1;
        // 不吞触摸：App 自己的点击、滚动、长按都照常工作。
        press.cancelsTouchesInView = NO;
        press.delaysTouchesEnded = NO;
        press.delegate = center;
        [window addGestureRecognizer:press];
        objc_setAssociatedObject(window, &kFMPressGestureKey, press, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        FMAnyGestureInstalled = YES;
    }
}

static void FMRemoveAllGestures(void) {
    FMAnyGestureInstalled = NO;
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if(![scene isKindOfClass:UIWindowScene.class]) continue;
        for(UIWindow *window in ((UIWindowScene *)scene).windows) {
            UIGestureRecognizer *gesture = objc_getAssociatedObject(window, &kFMPressGestureKey);
            if(!gesture) continue;
            [window removeGestureRecognizer:gesture];
            objc_setAssociatedObject(window, &kFMPressGestureKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

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
        UIWindowScene *scene = [LCOrbitHost activeScene];
        if(!scene) return;
        FMInstallInScene(scene);
        if(FMHiddenMode()) FMLog(@"hidden-bead-active", @{@"open": @"long-press-blank"});
    });
}

static void FMReplacementLifecycle(id self, SEL _cmd, NSString *event, UIWindowScene *scene) {
    if(FMOriginalLifecycle) FMOriginalLifecycle(self, _cmd, event, scene);
    UIWindowScene *target = scene ?: [LCOrbitHost activeScene];
    if(target) FMInstallInScene(target);
}

static void FMReplacementStop(id self, SEL _cmd) {
    if(FMOriginalStop) FMOriginalStop(self, _cmd);
    FMRemoveAllGestures();
}

static void FMReplacementDrawOrb(id self, SEL _cmd) {
    if(FMOriginalDrawOrb) FMOriginalDrawOrb(self, _cmd);

    BOOL hidden = FMHiddenMode();
    UIView *orb = FMIvar(self, "_orb");
    if([orb isKindOfClass:UIView.class]) {
        // 上游点亮把手的地方写的都是 alpha，没有人碰 hidden，
        // 所以这里压一次 hidden 就够，不必逐个 swizzle 那些 alpha 写入点。
        orb.hidden = hidden;
        orb.userInteractionEnabled = hidden ? NO : !FMBool(self, @"isOpen");
    }

    UIWindow *window = FMObject(self, @"window");
    if(window.windowScene) FMInstallInScene(window.windowScene);
}

static void FMReplacementMorphProgress(id self, SEL _cmd, CGFloat progress) {
    if(FMOriginalMorphProgress) FMOriginalMorphProgress(self, _cmd, progress);
    if(!FMHiddenMode()) return;
    UIView *panel = FMObject(self, @"panel");
    if(![panel isKindOfClass:UIView.class]) return;
    // 形变在进度接近 0 时会把面板插值成把手的轮廓；把手不可见时那一帧只剩一团
    // “微珠形状”。按进度淡出面板，收合时就在成形之前透明掉。
    panel.alpha = FMGClamp((progress - kFMFadeFloor) / kFMFadeSpan, 0, 1);
}

// 摇一摇：motionEnded 是 UIResponder 的方法，直接改 UIWindow 会污染整个继承链，
// 所以先用 class_addMethod 给 UIWindow 装一份自己的实现。
static void FMReplacementMotion(id self, SEL _cmd, UIEventSubtype motion, UIEvent *event) {
    if(motion == UIEventSubtypeMotionShake && FMHiddenMode() && FMShakeEnabled()) {
        id manager = FMSharedManager();
        if(manager && !FMBool(manager, @"isOpen") && !FMObject(manager, @"settingsWindow") &&
           !FMBoolIvar(manager, "_morphActive")) {
            SEL toggle = NSSelectorFromString(@"toggle");
            if([manager respondsToSelector:toggle]) {
                ((void (*)(id, SEL))objc_msgSend)(manager, toggle);
                if(FMHapticEnabled()) {
                    UIImpactFeedbackGenerator *feedback =
                        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
                    [feedback impactOccurred];
                }
                FMLog(@"hidden-bead-open", @{@"trigger": @"shake"});
                return;   // 摇一摇已被我们消费，不往下传，避免连带触发系统的撤销提示
            }
        }
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

@implementation FMPressCenter {
    BOOL _hooksInstalled;
}

+ (instancetype)shared {
    static FMPressCenter *center;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ center = [FMPressCenter new]; });
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
    [FMPressCenter shared]->_hooksInstalled = ok;

    // 兜底：swizzle 全失败时，回到前台仍然尝试装一次。
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                 usingBlock:^(NSNotification *note) {
        UIWindowScene *scene = [LCOrbitHost activeScene];
        if(scene) FMInstallInScene(scene);
    }];

    if(!ok) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if(![FMPressCenter shared]->_hooksInstalled)
                FMLog(@"gesture-hook-missing", @{@"LCFloatingMenuModule": @(module != nil),
                                                @"FMManager": @(manager != nil)});
        });
    }
}

- (void)handlePress:(UILongPressGestureRecognizer *)gesture {
    if(gesture.state != UIGestureRecognizerStateBegan) return;

    id manager = FMSharedManager();
    if(!manager) return;
    if(FMBool(manager, @"isOpen")) return;              // 已展开
    if(FMObject(manager, @"settingsWindow")) return;    // 设置页开着
    if(FMBoolIvar(manager, "_morphActive")) return;     // 正在开合

    SEL toggle = NSSelectorFromString(@"toggle");
    if(![manager respondsToSelector:toggle]) return;
    ((void (*)(id, SEL))objc_msgSend)(manager, toggle);

    if(FMHapticEnabled()) {
        UIImpactFeedbackGenerator *feedback =
            [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [feedback impactOccurred];
    }
    FMLog(@"hidden-bead-open", nil);
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
