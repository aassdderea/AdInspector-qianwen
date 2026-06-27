#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <stdint.h>

// ========== 枚举 & 全局变量（必须放在最前面）==========
typedef NS_ENUM(NSInteger, AI_Mode) {
    AI_Mode_Observe = 0,
    AI_Mode_LearnArmed,
    AI_Mode_AutoSkip
};

static AI_Mode g_currentMode = AI_Mode_Observe;
static NSTimeInterval g_twoFingerStartTime = 0;
static BOOL g_twoFingerArmed = NO;
static NSTimeInterval g_threeFingerStartTime = 0;
static BOOL g_threeFingerArmed = NO;
static CGPoint g_trackedPoint = CGPointZero;
static dispatch_source_t g_learnTimeoutTimer = nil;

// ========== 顶层 Toast ==========
static UIWindow *g_toastWindow = nil;
static UILabel *g_toastLabel = nil;
static dispatch_source_t g_hideTimer = nil;

static void showTopLevelToast(NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (!g_toastWindow) {
                g_toastWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
                g_toastWindow.windowLevel = UIWindowLevelAlert + 999.f;
                g_toastWindow.backgroundColor = [UIColor clearColor];
                g_toastWindow.userInteractionEnabled = NO;
                g_toastLabel = [[UILabel alloc] init];
                g_toastLabel.numberOfLines = 0;
                g_toastLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
                g_toastLabel.textColor = [UIColor whiteColor];
                g_toastLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
                g_toastLabel.layer.cornerRadius = 12;
                g_toastLabel.clipsToBounds = YES;
                g_toastLabel.textAlignment = NSTextAlignmentCenter;
                [g_toastWindow addSubview:g_toastLabel];
            }
            CGFloat maxWidth = g_toastWindow.bounds.size.width - 40;
            CGRect textRect = [message boundingRectWithSize:CGSizeMake(maxWidth, CGFLOAT_MAX)
                                                    options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                                 attributes:@{NSFontAttributeName: g_toastLabel.font}
                                                    context:nil];
            g_toastLabel.frame = CGRectMake(0, 0, textRect.size.width + 30, textRect.size.height + 20);
            g_toastLabel.center = CGPointMake(g_toastWindow.center.x, g_toastWindow.bounds.size.height - 150);
            g_toastLabel.text = message;
            g_toastWindow.hidden = NO;
            
            if (g_hideTimer) { dispatch_source_cancel(g_hideTimer); g_hideTimer = nil; }
            g_hideTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            dispatch_source_set_timer(g_hideTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), DISPATCH_TIME_FOREVER, 0);
            dispatch_source_set_event_handler(g_hideTimer, ^{
                g_toastWindow.hidden = YES;
                dispatch_source_cancel(g_hideTimer);
                g_hideTimer = nil;
            });
            dispatch_resume(g_hideTimer);
        } @catch (NSException *e) {}
    });
}

// ========== 配置管理 ==========
static NSString* getConfigPath() {
    @try {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docDir = paths.firstObject;
        if (docDir) return [docDir stringByAppendingPathComponent:@"AdInspector_SkipConfig.json"];
        NSArray *cachePaths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        NSString *cacheDir = cachePaths.firstObject;
        if (cacheDir) return [cacheDir stringByAppendingPathComponent:@"AdInspector_SkipConfig.json"];
        return [NSTemporaryDirectory() stringByAppendingPathComponent:@"AdInspector_SkipConfig.json"];
    } @catch (NSException *e) {
        return [NSTemporaryDirectory() stringByAppendingPathComponent:@"AdInspector_SkipConfig.json"];
    }
}

static NSDictionary* loadSkipConfig() {
    @try {
        NSString *path = getConfigPath();
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data) return nil;
        return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    } @catch (NSException *e) { return nil; }
}

static void saveSkipConfig(NSString *targetClass, NSString *selectorName) {
    @try {
        NSString *path = getConfigPath();
        NSString *dir = [path stringByDeletingLastPathComponent];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:dir]) {
            NSError *err = nil;
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&err];
            if (err) return;
        }
        NSDictionary *config = @{
            @"targetClass": targetClass ?: @"",
            @"selectorName": selectorName ?: @"",
            @"learnedAt": @([[NSDate date] timeIntervalSince1970])
        };
        NSError *jsonErr = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:config options:NSJSONWritingPrettyPrinted error:&jsonErr];
        if (!data) return;
        NSError *writeErr = nil;
        BOOL ok = [data writeToFile:path options:NSDataWritingAtomic error:&writeErr];
        if (ok) {
            showTopLevelToast([NSString stringWithFormat:@"✅ 配置已保存!\n%@", path]);
        } else {
            showTopLevelToast([NSString stringWithFormat:@"❌ 保存失败: %@", writeErr.localizedDescription]);
        }
    } @catch (NSException *e) {}
}

static BOOL clearSkipConfig() {
    @try {
        NSString *path = getConfigPath();
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            NSError *error = nil;
            return [[NSFileManager defaultManager] removeItemAtPath:path error:&error];
        }
        return NO;
    } @catch (NSException *e) { return NO; }
}

// ========== 文本提取 ==========
static NSString* extractAllTextFromView(UIView *view) {
    NSMutableString *allText = [NSMutableString string];
    if ([view isKindOfClass:[UIButton class]]) {
        UIButton *btn = (UIButton *)view;
        for (NSNumber *stateNum in @[@(UIControlStateNormal), @(UIControlStateHighlighted), @(UIControlStateSelected)]) {
            NSString *t = [btn titleForState:[stateNum unsignedIntegerValue]];
            if (t) [allText appendString:t];
            NSAttributedString *at = [btn attributedTitleForState:[stateNum unsignedIntegerValue]];
            if (at) [allText appendString:at.string];
        }
    } else if ([view isKindOfClass:[UILabel class]]) {
        UILabel *lbl = (UILabel *)view;
        if (lbl.text) [allText appendString:lbl.text];
        if (lbl.attributedText) [allText appendString:lbl.attributedText.string];
    }
    return allText;
}

static NSString* extractAllTextRecursive(UIView *view, NSInteger maxDepth) {
    if (maxDepth <= 0 || !view) return @"";
    NSMutableString *result = [NSMutableString string];
    NSString *selfText = extractAllTextFromView(view);
    if (selfText.length > 0) [result appendString:selfText];
    for (UIView *sub in view.subviews) {
        NSString *subText = extractAllTextRecursive(sub, maxDepth - 1);
        if (subText.length > 0) [result appendString:subText];
    }
    return result;
}

static BOOL isSkipRelatedText(NSString *text) {
    if (!text || text.length == 0) return NO;
    NSString *lower = [text lowercaseString];
    return [lower containsString:@"跳过"] || [lower containsString:@"skip"] ||
           [lower containsString:@"close"] || [lower containsString:@"关闭"] ||
           [lower containsString:@"dismiss"] || [lower containsString:@"✕"] ||
           [lower containsString:@"×"] || [lower containsString:@"x"] ||
           [lower containsString:@">"] || [lower containsString:@"广告"];
}

static NSArray<NSString *> *extractGestureActions(UIGestureRecognizer *gr) {
    NSMutableArray *results = [NSMutableArray array];
    @try {
        NSArray *targets = [gr valueForKey:@"_targets"];
        for (id targetInfo in targets) {
            id target = [targetInfo valueForKey:@"_target"];
            id actionObj = [targetInfo valueForKey:@"_action"];
            SEL action = NULL;
            if ([actionObj isKindOfClass:[NSValue class]]) action = (SEL)[(NSValue *)actionObj pointerValue];
            else if ([actionObj isKindOfClass:[NSString class]]) action = NSSelectorFromString((NSString *)actionObj);
            if (target && action)
                [results addObject:[NSString stringWithFormat:@"%@ -> %@", target, NSStringFromSelector(action)]];
        }
    } @catch (NSException *e) {}
    return results;
}

// ========== 三指诊断 ==========
static void inspectViewAtPoint(CGPoint point) {
    @try {
        UIWindow *keyWindow = nil;
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *window in scene.windows) {
                    if (window.isKeyWindow) { keyWindow = window; break; }
                }
            }
        }
        UIView *hitView = [keyWindow hitTest:point withEvent:nil];
        if (!hitView) { showTopLevelToast(@"❌ 未命中视图"); return; }

        NSMutableArray *chain = [NSMutableArray array];
        UIView *current = hitView;
        NSInteger depth = 0;
        while (current && depth < 20) {
            [chain addObject:[NSString stringWithFormat:@"%@ (%@)", NSStringFromClass([current class]), current.accessibilityIdentifier ?: @"nil"]];
            current = current.superview;
            depth++;
        }
        NSMutableArray *actions = [NSMutableArray array];
        if ([hitView isKindOfClass:[UIControl class]]) {
            UIControl *control = (UIControl *)hitView;
            for (id target in control.allTargets) {
                NSArray *ta = [control actionsForTarget:target forControlEvent:UIControlEventAllEvents];
                for (NSString *a in ta) [actions addObject:[NSString stringWithFormat:@"%@ -> %@", target, a]];
            }
        }
        for (UIGestureRecognizer *gr in hitView.gestureRecognizers) [actions addObjectsFromArray:extractGestureActions(gr)];

        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        result[@"chain"] = chain;
        result[@"actions"] = actions;
        result[@"info"] = @{
            @"frame": NSStringFromCGRect(hitView.frame),
            @"hidden": @(hitView.isHidden), @"alpha": @(hitView.alpha)
        };

        NSError *error = nil;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:&error];
        if (jsonData) {
            NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ad_inspect_result.json"];
            BOOL ok = [[[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error];
            showTopLevelToast(ok ? [NSString stringWithFormat:@"✅ 诊断成功\n%@", path] : @"⚠️ 写入失败");
        }
    } @catch (NSException *e) {
        showTopLevelToast([NSString stringWithFormat:@"❌ 诊断异常: %@", e.reason]);
    }
}

// ========== 安全查找 ==========
static UIView* findBestTargetSubview(UIView *root, Class targetCls) {
    if (!root) return nil;
    NSMutableArray<UIView *> *candidates = [NSMutableArray array];
    __block NSInteger nodeCount = 0;
    void (^collect)(UIView *, NSInteger) = nil;
    collect = ^(UIView *v, NSInteger d) {
        if (d > 30 || nodeCount > 500) return;
        nodeCount++;
        if ([v isKindOfClass:targetCls] && !v.isHidden && v.alpha > 0.01 &&
            v.bounds.size.width > 1 && v.bounds.size.height > 1 && v.window != nil) {
            [candidates addObject:v];
        }
        for (UIView *sub in v.subviews) collect(sub, d + 1);
    };
    collect(root, 0);
    if (candidates.count == 0) return nil;
    if (candidates.count == 1) return candidates.firstObject;

    UIView *bestControl = nil;
    for (UIView *c in candidates) {
        if ([c isKindOfClass:[UIControl class]]) { bestControl = c; break; }
    }
    if (bestControl) return bestControl;

    UIView *best = nil;
    CGFloat bestArea = CGFLOAT_MAX;
    BOOL bestHasSkipText = NO;
    for (UIView *c in candidates) {
        NSString *text = extractAllTextRecursive(c, 10);
        BOOL hasSkip = isSkipRelatedText(text);
        CGFloat area = c.bounds.size.width * c.bounds.size.height;
        if (!best) { best = c; bestArea = area; bestHasSkipText = hasSkip; }
        else if (hasSkip && !bestHasSkipText) { best = c; bestArea = area; bestHasSkipText = YES; }
        else if (hasSkip == bestHasSkipText && area < bestArea) { best = c; bestArea = area; }
    }
    return best;
}

// ========== 自动跳过 ==========
static void performAutoSkip() {
    @try {
        NSDictionary *config = loadSkipConfig();
        if (!config) return;
        NSString *tc = config[@"targetClass"];
        NSString *sn = config[@"selectorName"];
        if (!tc.length || !sn.length) return;
        Class cls = NSClassFromString(tc);
        SEL sel = NSSelectorFromString(sn);
        if (!cls) return;

        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            for (UIWindow *win in scene.windows) {
                if (!win.rootViewController.view) continue;
                UIView *tv = findBestTargetSubview(win.rootViewController.view, cls);
                if (!tv) continue;

                @try {
                    if ([tv isKindOfClass:[UIControl class]]) {
                        [(UIControl *)tv sendActionsForControlEvents:UIControlEventTouchUpInside];
                        showTopLevelToast([NSString stringWithFormat:@"🚀 自动跳过(Control)!\n%@.%@", tc, sn]);
                        return;
                    }
                    if ([tv respondsToSelector:sel]) {
                        #pragma clang diagnostic push
                        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                        [tv performSelector:sel withObject:nil];
                        #pragma clang diagnostic pop
                        showTopLevelToast([NSString stringWithFormat:@"🚀 自动跳过!\n%@.%@", tc, sn]);
                        return;
                    }
                    UIView *parent = tv.superview;
                    NSInteger d = 0;
                    while (parent && d < 5) {
                        if ([parent isKindOfClass:[UIControl class]]) {
                            [(UIControl *)parent sendActionsForControlEvents:UIControlEventTouchUpInside];
                            showTopLevelToast([NSString stringWithFormat:@"🚀 父级Control触发!\n%@", NSStringFromClass([parent class])]);
                            return;
                        }
                        parent = parent.superview;
                        d++;
                    }
                } @catch (NSException *e) {}
            }
        }
        showTopLevelToast(@"ℹ️ 未找到可触发的目标");
    } @catch (NSException *e) {}
}

// ========== v7.18 学习模式管理 ==========
static void armLearnMode() {
    g_currentMode = AI_Mode_LearnArmed;
    showTopLevelToast(@"🎯 学习模式已激活!\n请点击【跳过】按钮\n(10秒后自动退出)");
    UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [fb impactOccurred];
    
    // ✅ 使用 dispatch_source 替代 dispatch_block_create，避免 Theos 编译问题
    if (g_learnTimeoutTimer) { dispatch_source_cancel(g_learnTimeoutTimer); g_learnTimeoutTimer = nil; }
    g_learnTimeoutTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(g_learnTimeoutTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)), DISPATCH_TIME_FOREVER, 0);
    dispatch_source_set_event_handler(g_learnTimeoutTimer, ^{
        if (g_currentMode == AI_Mode_LearnArmed) {
            g_currentMode = AI_Mode_Observe;
            showTopLevelToast(@"⏰ 学习模式已超时退出");
        }
        dispatch_source_cancel(g_learnTimeoutTimer);
        g_learnTimeoutTimer = nil;
    });
    dispatch_resume(g_learnTimeoutTimer);
}

static void disarmLearnMode(BOOL success) {
    if (g_learnTimeoutTimer) { dispatch_source_cancel(g_learnTimeoutTimer); g_learnTimeoutTimer = nil; }
    if (!success) g_currentMode = AI_Mode_Observe;
}

// ========== v7.18 盲录学习通道 ==========
static void tryLearnFromTouchEndPoint(CGPoint point, UIWindow *window) {
    if (g_currentMode != AI_Mode_LearnArmed || !window) return;
    
    UIView *hitView = [window hitTest:point withEvent:nil];
    if (!hitView) {
        showTopLevelToast(@"❌ 未命中任何视图");
        return;
    }
    
    NSString *targetClass = NSStringFromClass([hitView class]);
    NSString *selName = nil;
    NSString *captureMethod = @"未知";
    
    for (UIGestureRecognizer *gr in hitView.gestureRecognizers) {
        NSArray *gas = extractGestureActions(gr);
        for (NSString *info in gas) {
            NSRange ar = [info rangeOfString:@" -> "];
            if (ar.location != NSNotFound) {
                selName = [info substringFromIndex:ar.location + 4];
                captureMethod = @"本视图手势";
                break;
            }
        }
        if (selName) break;
    }
    
    if (!selName && [hitView isKindOfClass:[UIControl class]]) {
        selName = @"__adinspector_control_skip__";
        captureMethod = @"UIControl";
    }
    
    if (!selName) {
        UIView *current = hitView.superview;
        NSInteger depth = 0;
        while (current && depth < 8) {
            for (UIGestureRecognizer *gr in current.gestureRecognizers) {
                NSArray *gas = extractGestureActions(gr);
                for (NSString *info in gas) {
                    NSRange ar = [info rangeOfString:@" -> "];
                    if (ar.location != NSNotFound) {
                        selName = [info substringFromIndex:ar.location + 4];
                        targetClass = NSStringFromClass([current class]);
                        captureMethod = [NSString stringWithFormat:@"父级第%ld层手势", (long)(depth + 1)];
                        break;
                    }
                }
                if (selName) break;
            }
            if (selName) break;
            current = current.superview;
            depth++;
        }
    }
    
    if (!selName) {
        selName = @"__adinspector_hittest_fallback__";
        captureMethod = @"HitTest兜底";
    }
    
    saveSkipConfig(targetClass, selName);
    disarmLearnMode(YES);
    
    UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [fb impactOccurred];
    
    NSString *text = extractAllTextRecursive(hitView, 5);
    showTopLevelToast([NSString stringWithFormat:@"✅ 盲录成功!\n类: %@\n方法: %@\n来源: %@\n文本: %@", 
                      targetClass, selName, captureMethod, 
                      text.length > 0 ? text : @"(无文本)"]);
}

static BOOL tryLearnFromSender(id sender, id target, SEL action) {
    if (g_currentMode != AI_Mode_LearnArmed) return NO;
    BOOL matched = NO;
    if ([sender isKindOfClass:[UIView class]]) {
        NSString *text = extractAllTextFromView((UIView *)sender);
        if (isSkipRelatedText(text)) matched = YES;
        if (!matched) {
            for (UIView *sub in ((UIView *)sender).subviews) {
                if (isSkipRelatedText(extractAllTextFromView(sub))) { matched = YES; break; }
            }
        }
    }
    if (!matched && [target isKindOfClass:[UIViewController class]]) {
        for (UIView *sub in ((UIViewController *)target).view.subviews) {
            if (isSkipRelatedText(extractAllTextFromView(sub))) { matched = YES; break; }
        }
    }
    if (matched) {
        saveSkipConfig(NSStringFromClass([target class]), NSStringFromSelector(action));
        disarmLearnMode(YES);
        UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [fb impactOccurred];
        return YES;
    }
    return NO;
}

// ========== 轮询器 ==========
static void startPolling() {
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 0.05 * NSEC_PER_SEC, 0.01 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{
        @autoreleasepool {
            if (g_twoFingerStartTime > 0 && !g_twoFingerArmed) {
                if ([[NSDate date] timeIntervalSinceReferenceDate] - g_twoFingerStartTime >= 0.8) {
                    g_twoFingerArmed = YES;
                    armLearnMode();
                }
            }
            if (g_threeFingerStartTime > 0 && !g_threeFingerArmed) {
                if ([[NSDate date] timeIntervalSinceReferenceDate] - g_threeFingerStartTime >= 0.8) {
                    g_threeFingerArmed = YES;
                    inspectViewAtPoint(g_trackedPoint);
                    UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
                    [fb prepare]; [fb impactOccurred];
                }
            }
        }
    });
    dispatch_resume(timer);
}

// ========== 全局 Hook ==========
%hook UIApplication

- (void)sendEvent:(UIEvent *)event {
    %orig;
    if (event.type != UIEventTypeTouches) return;

    NSSet *touches = [event allTouches];
    NSUInteger count = touches.count;
    UITouch *anyTouch = touches.anyObject;
    if (!anyTouch) return;

    // ✅ v7.18: 学习模式下用 Began 捕获，避免 Ended 被广告SDK吞掉
    if (g_currentMode == AI_Mode_LearnArmed && anyTouch.phase == UITouchPhaseBegan) {
        CGPoint point = [anyTouch locationInView:anyTouch.window];
        UIWindow *win = anyTouch.window;
        dispatch_async(dispatch_get_main_queue(), ^{
            tryLearnFromTouchEndPoint(point, win);
        });
    }

    // 双指长按检测
    if (count == 2 && anyTouch.phase == UITouchPhaseBegan && g_twoFingerStartTime == 0) {
        g_twoFingerStartTime = [[NSDate date] timeIntervalSinceReferenceDate];
        g_twoFingerArmed = NO;
        showTopLevelToast(@"⏳ 双指按住中...");
    } else if (count < 2 && g_twoFingerStartTime > 0 && !g_twoFingerArmed) {
        g_twoFingerStartTime = 0;
    }

    // 三指诊断 & 清除
    if (count == 3) {
        CGPoint cp = CGPointZero; NSInteger vc = 0;
        for (UITouch *t in touches) {
            CGPoint p = [t locationInView:t.window];
            cp.x += p.x; cp.y += p.y; vc++;
        }
        if (vc > 0) { cp.x /= vc; cp.y /= vc; }

        if (anyTouch.phase == UITouchPhaseBegan && g_threeFingerStartTime == 0) {
            g_threeFingerStartTime = [[NSDate date] timeIntervalSinceReferenceDate];
            g_threeFingerArmed = NO;
            g_trackedPoint = cp;
            showTopLevelToast(@"⏳ 三指按住中...");
        } else if (g_threeFingerStartTime > 0) {
            g_trackedPoint = cp;
        }

        if (anyTouch.phase == UITouchPhaseEnded && anyTouch.tapCount >= 2) {
            g_twoFingerStartTime = 0; g_twoFingerArmed = NO;
            g_threeFingerStartTime = 0; g_threeFingerArmed = NO;
            disarmLearnMode(NO);
            BOOL ok = clearSkipConfig();
            g_currentMode = AI_Mode_Observe;
            showTopLevelToast(ok ? @"🗑️ 配置已清除" : @"ℹ️ 无配置");
            UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
            [fb impactOccurred];
        }
    } else if (count != 3 && g_threeFingerStartTime > 0 && !g_threeFingerArmed) {
        g_threeFingerStartTime = 0;
    }
}

- (BOOL)sendAction:(SEL)action to:(id)target from:(id)sender forEvent:(UIEvent *)event {
    BOOL result = %orig;
    if (g_currentMode == AI_Mode_LearnArmed && [sender isKindOfClass:[UIControl class]]) {
        tryLearnFromSender(sender, target, action);
    }
    return result;
}
%end

%hook NSObject
- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)ip {
    %orig;
    if (g_currentMode == AI_Mode_LearnArmed && [cv isKindOfClass:[UICollectionView class]]) {
        for (UICollectionViewCell *cell in cv.visibleCells) {
            if (isSkipRelatedText(extractAllTextRecursive(cell, 10))) {
                saveSkipConfig(NSStringFromClass([self class]), NSStringFromSelector(_cmd));
                disarmLearnMode(YES);
                UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
                [fb impactOccurred];
                return;
            }
        }
    }
}
%end

%hook UIGestureRecognizer
- (void)setState:(UIGestureRecognizerState)state {
    %orig;
    if (state == UIGestureRecognizerStateRecognized && g_currentMode == AI_Mode_LearnArmed) {
        NSArray<NSString *> *gas = extractGestureActions(self);
        for (NSString *info in gas) {
            NSRange ar = [info rangeOfString:@" -> "];
            if (ar.location != NSNotFound) {
                NSString *sp = [info substringFromIndex:ar.location + 4];
                @try {
                    NSArray *ts = [self valueForKey:@"_targets"];
                    for (id ti in ts) {
                        id tgt = [ti valueForKey:@"_target"];
                        SEL sel = NSSelectorFromString(sp);
                        if (tgt && [tgt respondsToSelector:sel]) {
                            NSString *vt = extractAllTextRecursive(self.view, 10);
                            if (!isSkipRelatedText(vt) && self.view.superview) vt = extractAllTextRecursive(self.view.superview, 10);
                            if (isSkipRelatedText(vt)) {
                                saveSkipConfig(NSStringFromClass([tgt class]), NSStringFromSelector(sel));
                                disarmLearnMode(YES);
                                UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
                                [fb impactOccurred];
                                return;
                            }
                        }
                    }
                } @catch (NSException *e) {}
            }
        }
    }
}
%end

// ========== 入口 ==========
%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            NSLog(@"[AdInspector] ✅ v7.18 deferred init starting...");
            startPolling();
            
            NSDictionary *config = loadSkipConfig();
            if (config && config[@"targetClass"] && config[@"selectorName"]) {
                NSString *tc = config[@"targetClass"];
                NSString *sn = config[@"selectorName"];
                g_currentMode = AI_Mode_AutoSkip;
                
                if ([sn isEqualToString:@"__adinspector_touch_skip__"]) {
                    sn = @"__adinspector_control_skip__";
                    saveSkipConfig(tc, sn);
                }
                
                showTopLevelToast([NSString stringWithFormat:@"🚀 AdInspector v7.18\n自动模式: %@.%@", tc, sn]);
                
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    @try { performAutoSkip(); } @catch (NSException *e) {}
                });
            } else {
                g_currentMode = AI_Mode_Observe;
                showTopLevelToast(@"👁️ AdInspector v7.18\n观察模式\n\n双指长按=学习\n三指长按=诊断\n三指双击=清除");
            }
            NSLog(@"[AdInspector] ✅ v7.18 init complete. Mode: %ld", (long)g_currentMode);
        } @catch (NSException *e) {
            NSLog(@"[AdInspector] ❌ v7.18 init FATAL: %@", e.reason);
        }
    });
    NSLog(@"[AdInspector] %%ctor registered (deferred 3s)");
}
