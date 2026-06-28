#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ==================== 配置与常量 ====================
static NSString *const kConfigKey = @"AdInspector_Config_v86";
static NSString *const kLearnModeKey = @"AdInspector_LearnMode";
static NSTimeInterval const kConfigExpireInterval = 24 * 60 * 60;

typedef struct {
    BOOL found;
    CGPoint point;
    UIView *targetView;
} AISkipTarget;

// ==================== 全局工具方法声明 ====================
static void showToast(NSString *msg);
static NSDictionary *loadConfig(void);
static void saveConfig(NSDictionary *config);
static AISkipTarget searchByClassAndText(UIWindow *window, NSDictionary *features);
static AISkipTarget searchByIndexPath(UIWindow *window, NSDictionary *features);
static AISkipTarget searchByRelativeCoordinate(UIWindow *window, CGFloat xR, CGFloat yR);
static UIView *findRealInteractiveTarget(UIView *hitView, UIWindow *window);
static NSDictionary *extractFeatures(UIView *target, UIWindow *window);
static UIWindow *getActiveNormalWindow(void);
static void showLearnPanel(void);
static void performAutoSkip(void);
static void bindGesturesToWindow(UIWindow *w);

// ==================== ✅ 核心修复: 支持手势并发的 EventHandler ====================
@interface AIPEventHandler : NSObject <UIGestureRecognizerDelegate>
- (void)handleEdgePan:(UIScreenEdgePanGestureRecognizer *)gesture;
- (void)handleLearnTap:(UITapGestureRecognizer *)gesture;
- (void)handleCancelLearn:(UIButton *)btn;
- (void)handleTripleTap:(UITapGestureRecognizer *)gesture;
- (void)handleShake;
@end

@implementation AIPEventHandler

// ✅ 关键修复: 允许与 App 自身的手势同时识别
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (void)handleEdgePan:(UIScreenEdgePanGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded) return;
    BOOL isLearnMode = [NSUserDefaults.standardUserDefaults boolForKey:kLearnModeKey];
    [NSUserDefaults.standardUserDefaults setBool:!isLearnMode forKey:kLearnModeKey];
    showToast(isLearnMode ? @"📖 学习模式已关闭" : @"🎯 学习模式已开启\n请点击广告跳过按钮");
    if (!isLearnMode) {
        showLearnPanel();
    }
}

// ✅ 新增: 摇一摇触发学习模式（备用入口）
- (void)handleShake {
    BOOL isLearnMode = [NSUserDefaults.standardUserDefaults boolForKey:kLearnModeKey];
    [NSUserDefaults.standardUserDefaults setBool:!isLearnMode forKey:kLearnModeKey];
    showToast(isLearnMode ? @"📖 学习模式已关闭" : @"🎯 学习模式已开启(摇一摇)\n请点击广告跳过按钮");
    if (!isLearnMode) {
        showLearnPanel();
    }
}

- (void)handleLearnTap:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded) return;
    
    UIWindow *lw = objc_getAssociatedObject(gesture, "learnWindow");
    CGPoint screenPoint = [gesture locationInView:lw];
    
    UIWindow *realWindow = getActiveNormalWindow();
    if (!realWindow) { showToast(@"⚠️ 未找到活跃窗口"); return; }
    
    lw.hidden = YES;
    UIView *hitView = [realWindow hitTest:screenPoint withEvent:nil];
    lw.hidden = NO;
    
    if (!hitView) { showToast(@"⚠️ 未命中任何视图，请重试"); return; }
    
    UIView *realTarget = findRealInteractiveTarget(hitView, realWindow);
    NSDictionary *features = extractFeatures(realTarget, realWindow);
    
    NSMutableDictionary *config = [NSMutableDictionary dictionaryWithDictionary:loadConfig() ?: @{}];
    config[@"features"] = features;
    config[@"timestamp"] = @([[NSDate date] timeIntervalSince1970]);
    config[@"targetClassName"] = NSStringFromClass([realTarget class]);
    saveConfig(config);
    
    NSString *className = NSStringFromClass([realTarget class]);
    CGFloat xR = [features[@"xRatio"] floatValue] * 100;
    CGFloat yR = [features[@"yRatio"] floatValue] * 100;
    NSString *textPreview = features[@"textContent"] ?: @"无";
    if (textPreview.length > 30) textPreview = [[textPreview substringToIndex:30] stringByAppendingString:@"..."];
    
    showToast([NSString stringWithFormat:@"✅ 学习成功！\n类：%@\n坐标：(%.1f%%, %.1f%%)\n文本：%@", className, xR, yR, textPreview]);
    
    [lw setHidden:YES];
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:kLearnModeKey];
}

- (void)handleCancelLearn:(UIButton *)btn {
    UIWindow *lw = objc_getAssociatedObject(btn, "learnWindow");
    [lw setHidden:YES];
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:kLearnModeKey];
    showToast(@"❌ 学习已取消");
}

- (void)handleTripleTap:(UITapGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateEnded) {
        performAutoSkip();
    }
}

@end

static AIPEventHandler *g_handler = nil;
static AIPEventHandler *getHandler(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_handler = [[AIPEventHandler alloc] init];
    });
    return g_handler;
}

// ==================== 窗口手势绑定工具 ====================
static void bindGesturesToWindow(UIWindow *w) {
    if (!w) return;
    AIPEventHandler *handler = getHandler();
    
    // 检查是否已绑定，避免重复
    for (UIGestureRecognizer *g in w.gestureRecognizers) {
        if ([g isKindOfClass:[UIScreenEdgePanGestureRecognizer class]] && g.target == handler) return;
    }
    
    UIScreenEdgePanGestureRecognizer *edgePan = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:handler action:@selector(handleEdgePan:)];
    edgePan.edges = UIRectEdgeLeft;
    edgePan.delegate = handler; // ✅ 设置代理以支持并发识别
    [w addGestureRecognizer:edgePan];
    
    NSLog(@"[AdInspector] ✅ 手势已绑定到窗口: %@", w);
}

// ==================== ✅ 注入验证 + Scene 通知监听 ====================
%ctor {
    NSLog(@"[AdInspector] ✅ Tweak 已成功加载到进程: %@", [[NSBundle mainBundle] bundleIdentifier]);
    
    // 注入验证 Alert
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"AdInspector v8.6"
                                                                       message:[NSString stringWithFormat:@"✅ 注入成功！\nBundleID: %@\n\n触发方式：\n• 左边缘右滑\n• 摇一摇手机\n• 三指双击(跳过)", [[NSBundle mainBundle] bundleIdentifier]]
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
        
        UIViewController *topVC = nil;
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in scene.windows) {
                    if (w.rootViewController && !w.isHidden) {
                        topVC = w.rootViewController;
                        while (topVC.presentedViewController) topVC = topVC.presentedViewController;
                        break;
                    }
                }
            }
        }
        if (topVC) [topVC presentViewController:alert animated:YES completion:nil];
        else showToast(@"✅ AdInspector v8.6 已注入");
    });
    
    // ✅ 关键修复: 使用 Scene 通知实时监听窗口创建，替代 didFinishLaunching 延迟
    [[NSNotificationCenter defaultCenter] addObserverForName:UISceneDidActivateNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        if ([note.object isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *scene = (UIWindowScene *)note.object;
            for (UIWindow *w in scene.windows) {
                bindGesturesToWindow(w);
            }
        }
    }];
}

// ==================== Hook UIApplication ====================
%hook UIApplication

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    BOOL result = %orig;
    // 兜底：对已存在的窗口也绑定一次
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        for (UIWindowScene *scene in application.connectedScenes) {
            for (UIWindow *w in scene.windows) {
                bindGesturesToWindow(w);
            }
        }
    });
    return result;
}

// ✅ 新增: 拦截摇一摇事件
- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    if (motion == UIEventSubtypeMotionShake) {
        [getHandler() handleShake];
    }
    %orig;
}

%end

// ==================== 三指双击 Hook ====================
%hook UIWindow

- (instancetype)initWithFrame:(CGRect)frame {
    UIWindow *w = %orig;
    if (w) {
        UITapGestureRecognizer *tripleTap = [[UITapGestureRecognizer alloc] initWithTarget:getHandler() action:@selector(handleTripleTap:)];
        tripleTap.numberOfTapsRequired = 3;
        tripleTap.numberOfTouchesRequired = 3;
        tripleTap.cancelsTouchesInView = NO;
        [w addGestureRecognizer:tripleTap];
    }
    return w;
}

%end

// ==================== 学习面板 ====================
static void showLearnPanel(void) {
    UIWindow *realWindow = getActiveNormalWindow();
    if (!realWindow) { showToast(@"❌ 未找到活跃窗口"); return; }
    
    CGFloat sw = realWindow.bounds.size.width;
    CGFloat sh = realWindow.bounds.size.height;
    
    UIWindow *lw = [[UIWindow alloc] initWithFrame:realWindow.bounds];
    lw.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.3];
    lw.windowLevel = UIWindowLevelAlert + 100;
    lw.hidden = NO;
    lw.userInteractionEnabled = YES;
    
    CGFloat safeBottom = 0;
    if (@available(iOS 11.0, *)) safeBottom = lw.safeAreaInsets.bottom;
    CGFloat hintHeight = 50;
    CGFloat hintY = sh - safeBottom - hintHeight - 20;
    
    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(20, hintY, sw - 40, hintHeight)];
    hint.text = @"🎯 点击广告【跳过】按钮完成学习";
    hint.numberOfLines = 1;
    hint.textColor = [UIColor whiteColor];
    hint.font = [UIFont boldSystemFontOfSize:14];
    hint.textAlignment = NSTextAlignmentCenter;
    hint.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.5];
    hint.layer.cornerRadius = 25;
    hint.clipsToBounds = YES;
    hint.userInteractionEnabled = NO;
    [lw addSubview:hint];
    
    UIButton *cancelBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    cancelBtn.frame = CGRectMake(sw / 2 - 60, hintY - 54, 120, 44);
    [cancelBtn setTitle:@"取消学习" forState:UIControlStateNormal];
    [cancelBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    cancelBtn.backgroundColor = [[UIColor redColor] colorWithAlphaComponent:0.8];
    cancelBtn.layer.cornerRadius = 22;
    [cancelBtn addTarget:getHandler() action:@selector(handleCancelLearn:) forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(cancelBtn, "learnWindow", lw, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [lw addSubview:cancelBtn];
    
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:getHandler() action:@selector(handleLearnTap:)];
    tap.cancelsTouchesInView = NO;
    objc_setAssociatedObject(tap, "learnWindow", lw, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [lw addGestureRecognizer:tap];
}

// ==================== 自动跳过执行 ====================
static void performAutoSkip(void) {
    UIInterfaceOrientation orientation = UIInterfaceOrientationUnknown;
    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            orientation = scene.interfaceOrientation;
            break;
        }
    }
    if (orientation != UIInterfaceOrientationUnknown &&
        orientation != UIInterfaceOrientationPortrait && 
        orientation != UIInterfaceOrientationPortraitUpsideDown) return;
    
    NSDictionary *config = loadConfig();
    if (!config || !config[@"features"]) { showToast(@"⚠️ 跳过失败：请先学习"); return; }
    
    NSTimeInterval ts = [config[@"timestamp"] doubleValue];
    if ([[NSDate date] timeIntervalSince1970] - ts > kConfigExpireInterval) {
        showToast(@"⏰ 配置已过期，请重新学习"); return;
    }
    
    NSDictionary *features = config[@"features"];
    UIWindow *realWindow = getActiveNormalWindow();
    if (!realWindow) return;
    
    AISkipTarget target = searchByClassAndText(realWindow, features);
    if (!target.found) target = searchByIndexPath(realWindow, features);
    if (!target.found) {
        target = searchByRelativeCoordinate(realWindow, [features[@"xRatio"] floatValue], [features[@"yRatio"] floatValue]);
    }
    
    if (target.found && target.targetView) {
        if ([target.targetView isKindOfClass:[UIControl class]]) {
            [(UIControl *)target.targetView sendActionsForControlEvents:UIControlEventTouchUpInside];
        } else {
            for (UIGestureRecognizer *g in target.targetView.gestureRecognizers) {
                if ([g isKindOfClass:[UITapGestureRecognizer class]] && g.enabled) {
                    [g setValue:@(UIGestureRecognizerStateEnded) forKey:@"state"];
                    break;
                }
            }
        }
        showToast(@"✅ 自动跳过成功");
    } else {
        showToast(@"❌ 跳过失败：目标未找到\n请重新学习");
    }
}

// ==================== 核心算法实现 ====================
static UIWindow *getActiveNormalWindow(void) {
    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *w in scene.windows) {
                if (w.windowLevel == UIWindowLevelNormal && !w.isHidden) return w;
            }
        }
    }
    return nil;
}

static UIView *findRealInteractiveTarget(UIView *hitView, UIWindow *window) {
    UIView *realTarget = hitView;
    while (realTarget && realTarget != window.rootViewController.view && realTarget != window) {
        if ([realTarget isKindOfClass:[UIControl class]]) return realTarget;
        if (realTarget.gestureRecognizers.count > 0) {
            for (UIGestureRecognizer *g in realTarget.gestureRecognizers) {
                if ([g isKindOfClass:[UITapGestureRecognizer class]] && g.enabled) return realTarget;
            }
        }
        if (realTarget.isAccessibilityElement && (realTarget.accessibilityTraits & UIAccessibilityTraitButton)) return realTarget;
        if ([realTarget respondsToSelector:@selector(touchesEnded:withEvent:)] && 
            ![realTarget isKindOfClass:[UILabel class]] && 
            ![realTarget isKindOfClass:[UIImageView class]]) return realTarget;
        realTarget = realTarget.superview;
    }
    return hitView;
}

static NSDictionary *extractFeatures(UIView *target, UIWindow *window) {
    NSMutableDictionary *features = [NSMutableDictionary dictionary];
    features[@"className"] = NSStringFromClass([target class]);
    CGRect f = [target convertRect:target.bounds toView:window];
    features[@"xRatio"] = @((f.origin.x + f.size.width / 2.0) / window.bounds.size.width);
    features[@"yRatio"] = @((f.origin.y + f.size.height / 2.0) / window.bounds.size.height);
    
    NSMutableString *textContext = [NSMutableString string];
    NSMutableArray *subs = [NSMutableArray arrayWithObject:target];
    NSInteger idx = 0;
    while (idx < (NSInteger)subs.count) {
        UIView *v = subs[idx++];
        [subs addObjectsFromArray:v.subviews];
        NSString *txt = nil;
        if ([v isKindOfClass:[UILabel class]]) txt = ((UILabel *)v).text;
        else if ([v isKindOfClass:[UIButton class]]) txt = ((UIButton *)v).currentTitle;
        else txt = v.accessibilityLabel;
        if (txt.length > 0 && txt.length < 30) [textContext appendFormat:@"%@|", txt];
    }
    if (textContext.length > 0) features[@"textContent"] = textContext;
    
    NSMutableArray *indexPath = [NSMutableArray array];
    UIView *v = target;
    while (v.superview && v != window) {
        [indexPath insertObject:@([v.superview.subviews indexOfObject:v]) atIndex:0];
        v = v.superview;
    }
    features[@"indexPath"] = indexPath;
    return [features copy];
}

static AISkipTarget searchByClassAndText(UIWindow *window, NSDictionary *features) {
    AISkipTarget result = {0};
    NSString *clsName = features[@"className"];
    NSString *savedText = features[@"textContent"];
    if (!clsName || !savedText) return result;
    Class tc = NSClassFromString(clsName);
    if (!tc) return result;
    
    __block UIView *matched = nil;
    void (^search)(UIView *) = nil;
    search = ^(UIView *view) {
        if (matched) return;
        if ([view isKindOfClass:tc]) {
            NSString *ct = @"";
            if ([view isKindOfClass:[UILabel class]]) ct = ((UILabel *)view).text ?: @"";
            else if ([view isKindOfClass:[UIButton class]]) ct = ((UIButton *)view).currentTitle ?: @"";
            else ct = view.accessibilityLabel ?: @"";
            for (NSString *kw in [savedText componentsSeparatedByString:@"|"]) {
                if (kw.length > 0 && [ct containsString:kw]) { matched = view; return; }
            }
        }
        for (UIView *sub in view.subviews) search(sub);
    };
    search(window);
    if (matched) {
        result.found = YES; result.targetView = matched;
        result.point = [matched convertPoint:CGPointMake(matched.bounds.size.width/2, matched.bounds.size.height/2) toView:window];
    }
    return result;
}

static AISkipTarget searchByIndexPath(UIWindow *window, NSDictionary *features) {
    AISkipTarget result = {0};
    NSArray *ip = features[@"indexPath"];
    if (!ip.count) return result;
    UIView *cur = window;
    for (NSNumber *n in ip) {
        NSInteger i = n.integerValue;
        if (i >= (NSInteger)cur.subviews.count) return result;
        cur = cur.subviews[i];
    }
    NSString *sc = features[@"className"];
    if (sc && ![NSStringFromClass(cur.class) isEqualToString:sc]) return result;
    result.found = YES; result.targetView = cur;
    result.point = [cur convertPoint:CGPointMake(cur.bounds.size.width/2, cur.bounds.size.height/2) toView:window];
    return result;
}

static AISkipTarget searchByRelativeCoordinate(UIWindow *window, CGFloat xR, CGFloat yR) {
    AISkipTarget result = {0};
    CGPoint p = CGPointMake(xR * window.bounds.size.width, yR * window.bounds.size.height);
    UIView *hit = [window hitTest:p withEvent:nil];
    if (hit) { result.found = YES; result.targetView = hit; result.point = p; }
    return result;
}

// ==================== 配置持久化 ====================
static NSDictionary *loadConfig(void) {
    NSData *d = [NSUserDefaults.standardUserDefaults dataForKey:kConfigKey];
    return d ? [NSKeyedUnarchiver unarchivedObjectOfClass:[NSDictionary class] fromData:d error:nil] : nil;
}
static void saveConfig(NSDictionary *config) {
    NSData *d = [NSKeyedArchiver archivedDataWithRootObject:config requiringSecureCoding:NO error:nil];
    [NSUserDefaults.standardUserDefaults setObject:d forKey:kConfigKey];
    [NSUserDefaults.standardUserDefaults synchronize];
}

// ==================== Toast ====================
static void showToast(NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *tw = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        tw.windowLevel = UIWindowLevelAlert + 200;
        tw.backgroundColor = [UIColor clearColor];
        tw.userInteractionEnabled = NO;
        tw.hidden = NO;
        
        UILabel *t = [[UILabel alloc] init];
        t.text = msg; t.numberOfLines = 0;
        t.textColor = [UIColor whiteColor];
        t.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        t.textAlignment = NSTextAlignmentCenter;
        t.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
        t.layer.cornerRadius = 10; t.clipsToBounds = YES;
        
        CGFloat mw = tw.bounds.size.width - 60;
        CGSize sz = [msg boundingRectWithSize:CGSizeMake(mw, CGFLOAT_MAX)
                                      options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                   attributes:@{NSFontAttributeName: t.font} context:nil].size;
        t.frame = CGRectMake(0, 0, MIN(sz.width + 30, mw), sz.height + 20);
        t.center = CGPointMake(tw.center.x, tw.bounds.size.height - 120);
        [tw addSubview:t];
        
        [UIView animateWithDuration:0.3 delay:2.5 options:UIViewAnimationOptionCurveEaseOut animations:^{
            t.alpha = 0;
        } completion:^(BOOL finished) {
            [t removeFromSuperview]; tw.hidden = YES;
        }];
    });
}
