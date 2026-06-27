#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// ========== 顶层 Toast ==========
static UIWindow *g_toastWindow = nil;
static UILabel *g_toastLabel = nil;
static dispatch_block_t g_hideBlock = nil;

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
            if (g_hideBlock) { dispatch_block_cancel(g_hideBlock); g_hideBlock = nil; }
            g_hideBlock = dispatch_block_create((dispatch_block_flags_t)0, ^{
                g_toastWindow.hidden = YES;
                g_hideBlock = nil;
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), g_hideBlock);
        } @catch (NSException *e) {}
    });
}

// ========== 配置管理（全安全包裹）==========
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
    } @catch (NSException *e) {
        NSLog(@"[AdInspector] ⚠️ loadSkipConfig exception: %@", e.reason);
        return nil;
    }
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
    } @catch (NSException *e) {
        NSLog(@"[AdInspector] ⚠️ saveSkipConfig exception: %@", e.reason);
    }
}

static BOOL clearSkipConfig() {
    @try {
        NSString *path = getConfigPath();
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            NSError *error = nil;
            return [[NSFileManager defaultManager] removeItemAtPath:path error:&error];
        }
        return NO;
    } @catch (NSException *e) {
        return NO;
    }
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
           [lower containsString:@"dismiss"];
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

// ========== 核心状态机 ==========
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

// ========== 安全查找（带深度限制）==========
static UIView* findBestTargetSubview(UIView *root, Class targetCls) {
    if (!root) return nil;
    NSMutableArray<UIView *> *candidates = [NSMutableArray array];
    __block NSInteger nodeCount = 0;
    void (^collect)(UIView *, NSInteger) = nil;
    collect = ^(UIView *v, NSInteger depth) {
        if (depth > 30 || nodeCount > 500) return; // ✅ 防止无限递归/过大视图树
        nodeCount++;
        if ([v isKindOfClass:targetCls] && !v.isHidden && v.alpha > 0.01 &&
            v.bounds.size.width > 1 && v.bounds.size.height > 1 && v.window != nil) {
            [candidates addObject:v];
        }
        for (UIView *sub in v.subviews) collect(sub, depth + 1);
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

// ========== 安全自动跳过 ==========
static void performAutoSkip() {
    @try {
        NSDictionary *config = loadSkipConfig();
        if (!config) { NSLog(@"[AdInspector] No config found"); return; }
        NSString *tc = config[@"targetClass"];
        NSString *sn = config[@"selectorName"];
        if (!tc.length || !sn.length) { NSLog(@"[AdInspector] Empty config"); return; }
        Class cls = NSClassFromString(tc);
        SEL sel = NSSelectorFromString(sn);
        if (!cls) { NSLog(@"[AdInspector] Class not found: %@", tc); return; }

        NSLog(@"[AdInspector] Attempting auto-skip: %@.%@", tc, sn);

        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            for (UIWindow *win in scene.windows) {
                if (!win.rootViewController.view) continue;
                UIView *tv = findBestTargetSubview(win.rootViewController.view, cls);
                if (!tv) continue;

                NSLog(@"[AdInspector] Found target: %@ in %@", NSStringFromClass([tv class]), win);

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
                    NSInteger depth = 0;
                    while (parent && depth < 5) {
                        if ([parent isKindOfClass:[UIControl class]]) {
                            [(UIControl *)parent sendActionsForControlEvents:UIControlEventTouchUpInside];
                            showTopLevelToast([NSString stringWithFormat:@"🚀 父级Control触发!\n%@", NSStringFromClass([parent class])]);
                            return;
                        }
                        parent = parent.superview;
                        depth++;
                    }
                } @catch (NSException *e) {
                    NSLog(@"[AdInspector] Auto-skip exception: %@", e.reason);
                }
            }
        }
        NSLog(@"[AdInspector] No actionable target found");
        showTopLevelToast(@"ℹ️ 未找到可触发的目标");
    } @catch (NSException *e) {
        NSLog(@"[AdInspector] ⚠️ performAutoSkip fatal exception: %@", e.reason);
    }
}

// ========== 学习通道 ==========
static void tryLearnFromTouchEndPoint(CGPoint point, UIWindow *window) {
    if (g_currentMode != AI_Mode_LearnArmed || !window) return;
    UIView *hitView = [window hitTest:point withEvent:nil];
    if (!hitView) return;
    UIView *current = hitView;
    NSInteger depth = 0;
    while (current && depth < 8) {
        NSString *text = extractAllTextRecursive(current, 10);
        if (isSkipRelatedText(text)) {
            NSString *selName = @"__adinspector_control_skip__";
            if (![current isKindOfClass:[UIControl class]]) {
                BOOL foundRealSel = NO;
                for (UIGestureRecognizer *gr in current.gestureRecognizers) {
                    NSArray *gas = extractGestureActions(gr);
                    for (NSString *info in gas) {
                        NSRange ar = [info rangeOfString:@" -> "];
                        if (ar.location != NSNotFound) {
                            selName = [info substringFromIndex:ar.location + 4];
                            foundRealSel = YES;
                            break;
                        }
                    }
                    if (foundRealSel) break;
                }
                if (!foundRealSel && current.superview) {
                    for (UIGestureRecognizer *gr in current.superview.gestureRecognizers) {
                        NSArray *gas = extractGestureActions(gr);
                        for (NSString *info in gas) {
                            NSRange ar = [info rangeOfString:@" -> "];
                            if (ar.location != NSNotFound) {
                                selName = [info substringFromIndex:ar.location + 4];
                                foundRealSel = YES;
                                break;
                            }
                        }
                        if (foundRealSel) break;
                    }
                }
            }
            saveSkipConfig(NSStringFromClass([current class]), selName);
            g_currentMode = AI_Mode_Observe;
            UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
            [fb impactOccurred];
            showTopLevelToast([NSString stringWithFormat:@"✅ 学习成功!\n%@.%@", NSStringFromClass([current class]), selName]);
            return;
        }
        current = current.superview;
        depth++;
    }
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
        g_currentMode = AI_Mode_Observe;
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
                    g_currentMode = AI_Mode_LearnArmed;
                    showTopLevelToast(@"🎯 学习模式已激活!\n请点击【跳过】按钮");
                    UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
                    [fb impactOccurred];
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

    if (g_currentMode == AI_Mode_LearnArmed && count == 1 && anyTouch.phase == UITouchPhaseEnded) {
        tryLearnFromTouchEndPoint([anyTouch locationInView:anyTouch.window], anyTouch.window);
    }

    if (count == 2 && anyTouch.phase == UITouchPhaseBegan && g_twoFingerStartTime == 0) {
        g_twoFingerStartTime = [[NSDate date] timeIntervalSinceReferenceDate];
        g_twoFingerArmed = NO;
        showTopLevelToast(@"⏳ 双指按住中...");
    } else if (count != 2 && g_twoFingerStartTime > 0 && !g_twoFingerArmed) {
        g_twoFingerStartTime = 0;
    }

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
    if ([sender isKindOfClass:[UIControl class]]) tryLearnFromSender(sender, target, action);
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
                g_currentMode = AI_Mode_Observe;
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
                                g_currentMode = AI_Mode_Observe;
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

// ========== ✅ v7.15 入口（零同步操作，全延迟）==========
%ctor {
    // ✅ 不在 %ctor 中执行任何逻辑，仅注册一个延迟初始化块
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            NSLog(@"[AdInspector] ✅ v7.15 deferred init starting...");
            
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
                
                NSLog(@"[AdInspector] Auto-skip mode: %@.%@", tc, sn);
                showTopLevelToast([NSString stringWithFormat:@"🚀 AdInspector v7.15\n自动模式: %@.%@", tc, sn]);
                
                // ✅ 再延迟 2 秒执行跳过，确保广告 SDK 完全就绪
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    @try {
                        performAutoSkip();
                    } @catch (NSException *e) {
                        NSLog(@"[AdInspector] ⚠️ Deferred auto-skip exception: %@", e.reason);
                    }
                });
            } else {
                g_currentMode = AI_Mode_Observe;
                NSLog(@"[AdInspector] Observe mode, no config");
                showTopLevelToast(@"👁️ AdInspector v7.15\n观察模式\n\n双指长按=学习\n三指长按=诊断\n三指双击=清除");
            }
            NSLog(@"[AdInspector] ✅ v7.15 deferred init complete. Mode: %ld", (long)g_currentMode);
        } @catch (NSException *e) {
            NSLog(@"[AdInspector] ❌ v7.15 deferred init FATAL: %@", e.reason);
        }
    });
    
    // ✅ %ctor 立即返回，不阻塞 App 启动
    NSLog(@"[AdInspector] %ctor registered (deferred 3s)");
}
