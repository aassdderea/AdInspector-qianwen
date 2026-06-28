#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ==================== 配置与常量 ====================
static NSString *const kConfigKey = @"AdInspector_Config_v84";
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
static AISkipTarget searchByRelativeCoordinate(UIWindow *window, CGFloat xR, CGFloat yR, CGFloat tolerance);
static UIView *findRealInteractiveTarget(UIView *hitView, UIWindow *window);
static NSDictionary *extractFeatures(UIView *target, UIWindow *window);
static UIWindow *getActiveNormalWindow(void);
static void showLearnPanel(void);
static void performAutoSkip(void);

// ✅ 修复核心: 专用事件处理器，避免 %new 跨作用域和 UIApplication target 问题
@interface AIPEventHandler : NSObject
- (void)handleEdgePan:(UIScreenEdgePanGestureRecognizer *)gesture;
- (void)handleLearnTap:(UITapGestureRecognizer *)gesture;
- (void)handleCancelLearn:(UIButton *)btn;
- (void)handleTripleTap:(UITapGestureRecognizer *)gesture;
@end

@implementation AIPEventHandler

- (void)handleEdgePan:(UIScreenEdgePanGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded) return;
    BOOL isLearnMode = [NSUserDefaults.standardUserDefaults boolForKey:kLearnModeKey];
    [NSUserDefaults.standardUserDefaults setBool:!isLearnMode forKey:kLearnModeKey];
    showToast(isLearnMode ? @"📖 学习模式已关闭" : @"🎯 学习模式已开启\n请点击广告跳过按钮");
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
    
    UIView *hitView = [realWindow hitTest:screenPoint withEvent:nil];
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

// 全局单例 Handler
static AIPEventHandler *g_handler = nil;
static AIPEventHandler *getHandler(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_handler = [[AIPEventHandler alloc] init];
    });
    return g_handler;
}

// ==================== Hook 入口 (✅ 合并为单一 %hook 块) ====================
%hook UIApplication

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    BOOL result = %orig;
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        AIPEventHandler *handler = getHandler();
        UIScreenEdgePanGestureRecognizer *edgePan = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:handler action:@selector(handleEdgePan:)];
        edgePan.edges = UIRectEdgeLeft;
        
        for (UIWindowScene *scene in application.connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in scene.windows) {
                    [w addGestureRecognizer:edgePan];
                }
            }
        }
    });
    
    return result;
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
    
    // 让学习窗口能接收事件但不阻挡底层穿透
    lw.userInteractionEnabled = YES;
    
    CGFloat safeBottom = 0;
    if (@available(iOS 11.0, *)) {
        safeBottom = lw.safeAreaInsets.bottom;
    }
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
    CGFloat cancelY = hintY - 54;
    cancelBtn.frame = CGRectMake(sw / 2 - 60, cancelY, 120, 44);
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
        orientation != UIInterfaceOrientationPortraitUpsideDown) {
        return;
    }
    
    NSDictionary *config = loadConfig();
    if (!config || !config[@"features"]) {
        showToast(@"⚠️ 跳过失败：请先左滑学习");
        return;
    }
    
    NSTimeInterval ts = [config[@"timestamp"] doubleValue];
    if ([[NSDate date] timeIntervalSince1970] - ts > kConfigExpireInterval) {
        showToast(@"⏰ 配置已过期，请重新学习");
        return;
    }
    
    NSDictionary *features = config[@"features"];
    UIWindow *realWindow = getActiveNormalWindow();
    if (!realWindow) return;
    
    AISkipTarget target = searchByClassAndText(realWindow, features);
    if (!target.found) target = searchByIndexPath(realWindow, features);
    if (!target.found) {
        CGFloat xR = [features[@"xRatio"] floatValue];
        CGFloat yR = [features[@"yRatio"] floatValue];
        target = searchByRelativeCoordinate(realWindow, xR, yR, 0.08);
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
        showToast(@"❌ 跳过失败：目标元素未找到\n请重新学习");
    }
}

// ==================== 核心算法实现 ====================

static UIWindow *getActiveNormalWindow(void) {
    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *w in scene.windows) {
                if (w.windowLevel == UIWindowLevelNormal && !w.isHidden) {
                    return w;
                }
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
        SEL touchSel = @selector(touchesEnded:withEvent:);
        if ([realTarget respondsToSelector:touchSel] && 
            ![realTarget isKindOfClass:[UILabel class]] && 
            ![realTarget isKindOfClass:[UIImageView class]]) return realTarget;
        realTarget = realTarget.superview;
    }
    return hitView;
}

static NSDictionary *extractFeatures(UIView *target, UIWindow *window) {
    NSMutableDictionary *features = [NSMutableDictionary dictionary];
    features[@"className"] = NSStringFromClass([target class]);
    
    CGRect frameInWindow = [target convertRect:target.bounds toView:window];
    CGFloat wW = window.bounds.size.width;
    CGFloat wH = window.bounds.size.height;
    features[@"xRatio"] = @((frameInWindow.origin.x + frameInWindow.size.width / 2.0) / wW);
    features[@"yRatio"] = @((frameInWindow.origin.y + frameInWindow.size.height / 2.0) / wH);
    
    NSMutableString *textContext = [NSMutableString string];
    NSMutableArray *subviews = [NSMutableArray arrayWithObject:target];
    NSInteger idx = 0;
    while (idx < (NSInteger)subviews.count) {
        UIView *v = subviews[idx++];
        [subviews addObjectsFromArray:v.subviews];
        NSString *txt = nil;
        if ([v isKindOfClass:[UILabel class]]) txt = ((UILabel *)v).text;
        else if ([v isKindOfClass:[UIButton class]]) txt = ((UIButton *)v).currentTitle;
        else txt = v.accessibilityLabel;
        if (txt.length > 0 && txt.length < 30) {
            [textContext appendFormat:@"%@|", txt];
        }
    }
    if (textContext.length > 0) features[@"textContent"] = textContext;
    
    NSMutableArray *indexPath = [NSMutableArray array];
    UIView *v = target;
    while (v.superview && v != window) {
        NSInteger i = [v.superview.subviews indexOfObject:v];
        [indexPath insertObject:@(i) atIndex:0];
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
    
    Class targetClass = NSClassFromString(clsName);
    if (!targetClass) return result;
    
    __block UIView *matchedView = nil;
    void (^recursiveSearch)(UIView *) = nil;
    recursiveSearch = ^(UIView *view) {
        if (matchedView) return;
        if ([view isKindOfClass:targetClass]) {
            NSString *currentText = @"";
            if ([view isKindOfClass:[UILabel class]]) currentText = ((UILabel *)view).text ?: @"";
            else if ([view isKindOfClass:[UIButton class]]) currentText = ((UIButton *)view).currentTitle ?: @"";
            else currentText = view.accessibilityLabel ?: @"";
            
            NSArray *keywords = [savedText componentsSeparatedByString:@"|"];
            for (NSString *kw in keywords) {
                if (kw.length > 0 && [currentText containsString:kw]) {
                    matchedView = view;
                    return;
                }
            }
        }
        for (UIView *sub in view.subviews) {
            recursiveSearch(sub);
        }
    };
    recursiveSearch(window);
    
    if (matchedView) {
        result.found = YES;
        result.targetView = matchedView;
        result.point = [matchedView convertPoint:CGPointMake(matchedView.bounds.size.width/2, matchedView.bounds.size.height/2) toView:window];
    }
    return result;
}

static AISkipTarget searchByIndexPath(UIWindow *window, NSDictionary *features) {
    AISkipTarget result = {0};
    NSArray *indexPath = features[@"indexPath"];
    if (!indexPath || indexPath.count == 0) return result;
    
    UIView *current = window;
    for (NSNumber *idxNum in indexPath) {
        NSInteger i = [idxNum integerValue];
        if (i >= (NSInteger)current.subviews.count) return result;
        current = current.subviews[i];
    }
    
    NSString *savedClass = features[@"className"];
    if (savedClass && ![NSStringFromClass([current class]) isEqualToString:savedClass]) return result;
    
    result.found = YES;
    result.targetView = current;
    result.point = [current convertPoint:CGPointMake(current.bounds.size.width/2, current.bounds.size.height/2) toView:window];
    return result;
}

static AISkipTarget searchByRelativeCoordinate(UIWindow *window, CGFloat xR, CGFloat yR, CGFloat tolerance) {
    AISkipTarget result = {0};
    CGFloat wW = window.bounds.size.width;
    CGFloat wH = window.bounds.size.height;
    CGPoint targetPoint = CGPointMake(xR * wW, yR * wH);
    UIView *hit = [window hitTest:targetPoint withEvent:nil];
    if (hit) {
        result.found = YES;
        result.targetView = hit;
        result.point = targetPoint;
    }
    return result;
}

// ==================== 配置持久化 ====================
static NSDictionary *loadConfig(void) {
    NSData *data = [NSUserDefaults.standardUserDefaults dataForKey:kConfigKey];
    if (!data) return nil;
    return [NSKeyedUnarchiver unarchivedObjectOfClass:[NSDictionary class] fromData:data error:nil];
}

static void saveConfig(NSDictionary *config) {
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:config requiringSecureCoding:NO error:nil];
    [NSUserDefaults.standardUserDefaults setObject:data forKey:kConfigKey];
    [NSUserDefaults.standardUserDefaults synchronize];
}

// ==================== ✅ Toast 修复: 使用独立高层级 UIWindow ====================
static void showToast(NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 创建独立的 Toast 窗口，确保不被学习面板遮挡
        UIWindow *toastWin = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        toastWin.windowLevel = UIWindowLevelAlert + 200;
        toastWin.backgroundColor = [UIColor clearColor];
        toastWin.userInteractionEnabled = NO; // 不拦截任何触摸
        toastWin.hidden = NO;
        
        UILabel *toast = [[UILabel alloc] init];
        toast.text = msg;
        toast.numberOfLines = 0;
        toast.textColor = [UIColor whiteColor];
        toast.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        toast.textAlignment = NSTextAlignmentCenter;
        toast.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
        toast.layer.cornerRadius = 10;
        toast.clipsToBounds = YES;
        
        CGFloat maxWidth = toastWin.bounds.size.width - 60;
        CGSize textSize = [msg boundingRectWithSize:CGSizeMake(maxWidth, CGFLOAT_MAX)
                                           options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                        attributes:@{NSFontAttributeName: toast.font}
                                           context:nil].size;
        toast.frame = CGRectMake(0, 0, MIN(textSize.width + 30, maxWidth), textSize.height + 20);
        toast.center = CGPointMake(toastWin.center.x, toastWin.bounds.size.height - 120);
        
        [toastWin addSubview:toast];
        
        [UIView animateWithDuration:0.3 delay:2.5 options:UIViewAnimationOptionCurveEaseOut animations:^{
            toast.alpha = 0;
        } completion:^(BOOL finished) {
            [toast removeFromSuperview];
            toastWin.hidden = YES;
        }];
    });
}
