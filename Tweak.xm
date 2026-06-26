#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// ========== ✅ 绝对安全的顶层 Toast ==========
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
        } @catch (NSException *e) {
            NSLog(@"[AdInspector] Toast异常: %@", e);
        }
    });
}

// ========== ✅ 配置管理 ==========
static NSString* getConfigPath() {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docDir = paths.firstObject;
    if (docDir) return [docDir stringByAppendingPathComponent:@"AdInspector_SkipConfig.json"];
    NSArray *cachePaths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *cacheDir = cachePaths.firstObject;
    if (cacheDir) return [cacheDir stringByAppendingPathComponent:@"AdInspector_SkipConfig.json"];
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"AdInspector_SkipConfig.json"];
}

static NSDictionary* loadSkipConfig() {
    NSData *data = [NSData dataWithContentsOfFile:getConfigPath()];
    if (!data) return nil;
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}

static void saveSkipConfig(NSString *targetClass, NSString *selectorName) {
    NSString *path = getConfigPath();
    NSString *dir = [path stringByDeletingLastPathComponent];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:dir]) {
        NSError *err = nil;
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&err];
        if (err) { showTopLevelToast([NSString stringWithFormat:@"❌ 创建目录失败:\n%@", err.localizedDescription]); return; }
    }
    NSDictionary *config = @{
        @"targetClass": targetClass ?: @"",
        @"selectorName": selectorName ?: @"",
        @"learnedAt": @([[NSDate date] timeIntervalSince1970])
    };
    NSError *jsonErr = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:config options:NSJSONWritingPrettyPrinted error:&jsonErr];
    if (!data) { showTopLevelToast([NSString stringWithFormat:@"❌ JSON序列化失败:\n%@", jsonErr.localizedDescription]); return; }
    NSError *writeErr = nil;
    BOOL ok = [data writeToFile:path options:NSDataWritingAtomic error:&writeErr];
    if (ok && [fm fileExistsAtPath:path]) {
        showTopLevelToast([NSString stringWithFormat:@"✅ 配置已保存!\n路径: %@", path]);
    } else {
        showTopLevelToast([NSString stringWithFormat:@"❌ 保存失败\n路径: %@\n错误: %@", path, writeErr ? writeErr.localizedDescription : @"未知"]);
    }
}

static BOOL clearSkipConfig() {
    NSString *path = getConfigPath();
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSError *error = nil;
        return [[NSFileManager defaultManager] removeItemAtPath:path error:&error];
    }
    return NO;
}

// ========== 文本提取 & 手势解析 ==========
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

static NSString* extractAllTextRecursive(UIView *view) {
    NSMutableString *result = [NSMutableString string];
    NSString *selfText = extractAllTextFromView(view);
    if (selfText.length > 0) [result appendString:selfText];
    for (UIView *sub in view.subviews) {
        NSString *subText = extractAllTextRecursive(sub);
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
                [results addObject:[NSString stringWithFormat:@"[Gesture:%@] %@ -> %@", NSStringFromClass([gr class]), target, NSStringFromSelector(action)]];
        }
    } @catch (NSException *e) {
        [results addObject:[NSString stringWithFormat:@"[Gesture:%@] (解析异常)", NSStringFromClass([gr class])]];
    }
    return results;
}

// ========== 三指诊断（增强版）==========
static void inspectViewAtPoint(CGPoint point) {
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
    while (current) {
        [chain addObject:[NSString stringWithFormat:@"%@ (%@)", NSStringFromClass([current class]), current.accessibilityIdentifier ?: @"nil"]];
        current = current.superview;
    }
    NSMutableArray *actions = [NSMutableArray array];
    if ([hitView isKindOfClass:[UIControl class]]) {
        UIControl *control = (UIControl *)hitView;
        for (id target in control.allTargets) {
            NSArray *ta = [control actionsForTarget:target forControlEvent:UIControlEventAllEvents];
            for (NSString *a in ta) [actions addObject:[NSString stringWithFormat:@"[Control] %@ -> %@", target, a]];
        }
    }
    for (UIGestureRecognizer *gr in hitView.gestureRecognizers) [actions addObjectsFromArray:extractGestureActions(gr)];

    NSMutableArray *cellInfos = nil;
    if ([hitView isKindOfClass:[UICollectionView class]]) {
        UICollectionView *cv = (UICollectionView *)hitView;
        cellInfos = [NSMutableArray array];
        for (UICollectionViewCell *cell in cv.visibleCells) {
            NSString *cellText = extractAllTextRecursive(cell);
            BOOL hasGesture = (cell.gestureRecognizers.count > 0 || cell.contentView.gestureRecognizers.count > 0);
            NSIndexPath *ip = [cv indexPathForCell:cell];
            [cellInfos addObject:@{
                @"class": NSStringFromClass([cell class]),
                @"indexPath": ip ? [NSString stringWithFormat:@"%ld-%ld", (long)ip.section, (long)ip.item] : @"unknown",
                @"text": cellText.length > 0 ? cellText : @"(empty)",
                @"frame": NSStringFromCGRect(cell.frame),
                @"hasGesture": @(hasGesture)
            }];
        }
    }

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"hierarchyChain"] = chain;
    result[@"targetActions"] = actions;
    result[@"extraInfo"] = @{
        @"frame": NSStringFromCGRect(hitView.frame),
        @"windowFrame": NSStringFromCGRect([hitView convertRect:hitView.bounds toView:nil]),
        @"isHidden": @(hitView.isHidden), @"alpha": @(hitView.alpha),
        @"userInteractionEnabled": @(hitView.userInteractionEnabled)
    };
    if (cellInfos) result[@"visibleCells"] = cellInfos;

    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:&error];
    if (jsonData) {
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ad_inspect_result.json"];
        BOOL ok = [[[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error];
        showTopLevelToast(ok ? [NSString stringWithFormat:@"✅ 诊断成功\n%@", path] : [NSString stringWithFormat:@"⚠️ 写入失败: %@", error.localizedDescription]);
    } else {
        showTopLevelToast([NSString stringWithFormat:@"❌ JSON序列化失败: %@", error.localizedDescription]);
    }
}

// ========== 核心状态机 ==========
typedef NS_ENUM(NSInteger, AI_Mode) {
    AI_Mode_Observe = 0,
    AI_Mode_LearnArmed,
    AI_Mode_AutoSkip
};

static AI_Mode g_currentMode = AI_Mode_Observe;
static BOOL g_isTwoFingerHolding = NO;
static dispatch_block_t g_learnArmBlock = nil;
static BOOL g_isThreeFingerHolding = NO;
static CGPoint g_trackedPoint = CGPointZero;
static dispatch_block_t g_inspectBlock = nil;

// ✅ v7.9 新增：智能查找目标视图
// 当找到多个同类实例时，优先选择文本包含"跳过"且面积最小的那个
static UIView* findBestTargetSubview(UIView *root, Class targetCls) {
    if (!root) return nil;
    
    NSMutableArray<UIView *> *candidates = [NSMutableArray array];
    void (^collect)(UIView *) = nil;
    collect = ^(UIView *v) {
        if ([v isKindOfClass:targetCls]) [candidates addObject:v];
        for (UIView *sub in v.subviews) collect(sub);
    };
    collect(root);
    
    if (candidates.count == 0) return nil;
    if (candidates.count == 1) return candidates.firstObject;
    
    // 多个候选：优先选文本含"跳过"的，再按面积升序取最小
    UIView *best = nil;
    CGFloat bestArea = CGFLOAT_MAX;
    BOOL bestHasSkipText = NO;
    
    for (UIView *c in candidates) {
        NSString *text = extractAllTextRecursive(c);
        BOOL hasSkip = isSkipRelatedText(text);
        CGFloat area = c.bounds.size.width * c.bounds.size.height;
        
        if (!best) {
            best = c; bestArea = area; bestHasSkipText = hasSkip;
        } else if (hasSkip && !bestHasSkipText) {
            best = c; bestArea = area; bestHasSkipText = YES;
        } else if (hasSkip == bestHasSkipText && area < bestArea) {
            best = c; bestArea = area; bestHasSkipText = hasSkip;
        }
    }
    
    NSLog(@"[AdInspector] findBestTarget: %lu candidates, selected %@ (area=%.0f, skipText=%d)",
          (unsigned long)candidates.count, NSStringFromClass([best class]), bestArea, bestHasSkipText);
    return best;
}

static void performAutoSkip() {
    NSDictionary *config = loadSkipConfig();
    if (!config) return;
    NSString *tc = config[@"targetClass"];
    NSString *sn = config[@"selectorName"];
    if (!tc.length || !sn.length) { showTopLevelToast(@"⚠️ 配置内容为空"); return; }
    Class cls = NSClassFromString(tc);
    SEL sel = NSSelectorFromString(sn);
    if (!cls || ![cls instancesRespondToSelector:sel]) {
        showTopLevelToast([NSString stringWithFormat:@"⚠️ %@.%@ 无效", tc, sn]); return;
    }
    __block BOOL triggered = NO;
    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
        for (UIWindow *win in scene.windows) {
            if (!win.rootViewController.view) continue;
            UIView *tv = findBestTargetSubview(win.rootViewController.view, cls);
            if (tv && [tv respondsToSelector:sel]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [tv performSelector:sel withObject:nil];
                #pragma clang diagnostic pop
                triggered = YES;
                showTopLevelToast([NSString stringWithFormat:@"🚀 自动跳过成功!\n%@.%@", tc, sn]);
                break;
            }
        }
        if (triggered) break;
    }
    if (!triggered) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            BOOL retry = NO;
            for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                for (UIWindow *win in scene.windows) {
                    if (!win.rootViewController.view) continue;
                    UIView *tv = findBestTargetSubview(win.rootViewController.view, cls);
                    if (tv && [tv respondsToSelector:sel]) {
                        #pragma clang diagnostic push
                        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                        [tv performSelector:sel withObject:nil];
                        #pragma clang diagnostic pop
                        retry = YES; showTopLevelToast(@"🚀 延迟跳过成功!"); break;
                    }
                }
                if (retry) break;
            }
            if (!retry) showTopLevelToast(@"ℹ️ 未找到跳过按钮\n广告可能尚未加载");
        });
    }
}

// ✅ v7.9 Touch 模拟跳过（使用 findBestTargetSubview）
static void performTouchAutoSkip(NSString *targetClassName) {
    Class cls = NSClassFromString(targetClassName);
    if (!cls) {
        showTopLevelToast([NSString stringWithFormat:@"⚠️ 类不存在: %@", targetClassName]);
        return;
    }

    __block BOOL triggered = NO;
    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
        for (UIWindow *win in scene.windows) {
            if (!win.rootViewController.view) continue;
            // ✅ v7.9 关键改动：使用智能查找替代简单查找
            UIView *tv = findBestTargetSubview(win.rootViewController.view, cls);
            if (tv && tv.window) {
                CGPoint center = [tv convertPoint:CGPointMake(tv.bounds.size.width / 2.0, tv.bounds.size.height / 2.0)
                                           toView:nil];
                NSLog(@"[AdInspector] Touch skip target: %@ frame=%@ center=%@", 
                      NSStringFromClass([tv class]), NSStringFromCGRect(tv.frame), NSStringFromCGPoint(center));
                
                @try {
                    UITouch *touch = [[UITouch alloc] init];
                    
                    [touch setValue:tv.window forKey:@"_window"];
                    [touch setValue:tv forKey:@"_view"];
                    [touch setValue:tv forKey:@"_senderView"];
                    [touch setValue:@(0) forKey:@"_touchType"];
                    [touch setValue:@(YES) forKey:@"_isFirstTouchForView"];
                    [touch setValue:@(1) forKey:@"_tapCount"];
                    
                    NSValue *locValue = [NSValue valueWithCGPoint:center];
                    [touch setValue:locValue forKey:@"_locationInWindow"];
                    [touch setValue:locValue forKey:@"_previousLocationInWindow"];

                    // Phase 1: Began
                    [touch setValue:@([[NSDate date] timeIntervalSinceReferenceDate]) forKey:@"_timestamp"];
                    [touch setValue:@(UITouchPhaseBegan) forKey:@"_phase"];
                    UIEvent *beganEvent = [[UIEvent alloc] init];
                    [beganEvent setValue:[NSSet setWithObject:touch] forKey:@"_touches"];
                    [beganEvent setValue:@(UIEventTypeTouches) forKey:@"_type"];
                    [[UIApplication sharedApplication] sendEvent:beganEvent];

                    // Phase 2: Stationary (30ms)
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        @try {
                            [touch setValue:@([[NSDate date] timeIntervalSinceReferenceDate]) forKey:@"_timestamp"];
                            [touch setValue:@(UITouchPhaseStationary) forKey:@"_phase"];
                            UIEvent *stationaryEvent = [[UIEvent alloc] init];
                            [stationaryEvent setValue:[NSSet setWithObject:touch] forKey:@"_touches"];
                            [stationaryEvent setValue:@(UIEventTypeTouches) forKey:@"_type"];
                            [[UIApplication sharedApplication] sendEvent:stationaryEvent];
                        } @catch (NSException *e) {}
                        
                        // Phase 3: Ended (再30ms)
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            @try {
                                [touch setValue:@([[NSDate date] timeIntervalSinceReferenceDate]) forKey:@"_timestamp"];
                                [touch setValue:@(UITouchPhaseEnded) forKey:@"_phase"];
                                UIEvent *endedEvent = [[UIEvent alloc] init];
                                [endedEvent setValue:[NSSet setWithObject:touch] forKey:@"_touches"];
                                [endedEvent setValue:@(UIEventTypeTouches) forKey:@"_type"];
                                [[UIApplication sharedApplication] sendEvent:endedEvent];
                                
                                showTopLevelToast([NSString stringWithFormat:@"🚀 Touch模拟已发送!\n目标: %@\n坐标: (%.0f,%.0f)", 
                                                   targetClassName, center.x, center.y]);
                            } @catch (NSException *e) {
                                showTopLevelToast([NSString stringWithFormat:@"❌ Ended阶段异常:\n%@", e.reason]);
                            }
                        });
                    });

                    triggered = YES;
                } @catch (NSException *e) {
                    showTopLevelToast([NSString stringWithFormat:@"❌ Touch模拟失败:\n%@", e.reason]);
                }
                break;
            }
        }
        if (triggered) break;
    }

    if (!triggered) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            performTouchAutoSkip(targetClassName);
        });
    }
}

// ✅ Touch 级别兜底学习
static void tryLearnFromTouchEndPoint(CGPoint point, UIWindow *window) {
    if (g_currentMode != AI_Mode_LearnArmed) return;
    if (!window) return;

    UIView *hitView = [window hitTest:point withEvent:nil];
    if (!hitView) return;

    UIView *current = hitView;
    NSInteger depth = 0;
    while (current && depth < 8) {
        NSString *text = extractAllTextRecursive(current);
        if (isSkipRelatedText(text)) {
            NSString *tc = NSStringFromClass([current class]);
            saveSkipConfig(tc, @"__adinspector_touch_skip__");
            g_currentMode = AI_Mode_Observe;

            UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
            [fb impactOccurred];
            showTopLevelToast([NSString stringWithFormat:@"✅ Touch级学习成功!\nclass: %@\ntext: %@", tc, text]);
            NSLog(@"[AdInspector] ✅ Learned via touch: %@ (text: %@)", tc, text);
            return;
        }
        current = current.superview;
        depth++;
    }
}

// ========== 标准学习通道 ==========
static BOOL tryLearnFromCollectionView(UICollectionView *cv, id target, SEL action) {
    if (g_currentMode != AI_Mode_LearnArmed) return NO;
    for (UICollectionViewCell *cell in cv.visibleCells) {
        NSString *cellText = extractAllTextRecursive(cell);
        if (isSkipRelatedText(cellText)) {
            saveSkipConfig(NSStringFromClass([target class]), NSStringFromSelector(action));
            g_currentMode = AI_Mode_Observe;
            UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
            [fb impactOccurred];
            showTopLevelToast([NSString stringWithFormat:@"✅ CV Cell匹配!\n%@.%@", NSStringFromClass([target class]), NSStringFromSelector(action)]);
            return YES;
        }
    }
    return NO;
}

static BOOL tryLearnFromSender(id sender, id target, SEL action) {
    if (g_currentMode != AI_Mode_LearnArmed) return NO;
    BOOL matched = NO;
    NSString *matchedText = nil;
    if ([sender isKindOfClass:[UIView class]]) {
        NSString *text = extractAllTextFromView((UIView *)sender);
        if (isSkipRelatedText(text)) { matched = YES; matchedText = text; }
        if (!matched) {
            for (UIView *sub in ((UIView *)sender).subviews) {
                NSString *subText = extractAllTextFromView(sub);
                if (isSkipRelatedText(subText)) { matched = YES; matchedText = subText; break; }
            }
        }
    }
    if (!matched && [target isKindOfClass:[UIViewController class]]) {
        for (UIView *sub in ((UIViewController *)target).view.subviews) {
            NSString *subText = extractAllTextFromView(sub);
            if (isSkipRelatedText(subText)) { matched = YES; matchedText = subText; break; }
        }
    }
    if (matched) {
        saveSkipConfig(NSStringFromClass([target class]), NSStringFromSelector(action));
        g_currentMode = AI_Mode_Observe;
        UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [fb impactOccurred];
        NSLog(@"[AdInspector] ✅ Learned: %@.%@ (text: %@)", NSStringFromClass([target class]), NSStringFromSelector(action), matchedText);
        return YES;
    }
    return NO;
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
        CGPoint endPoint = [anyTouch locationInView:anyTouch.window];
        tryLearnFromTouchEndPoint(endPoint, anyTouch.window);
    }

    // 双指长按 → 激活学习
    if (count == 2) {
        if (anyTouch.phase == UITouchPhaseBegan && !g_isTwoFingerHolding) {
            g_isTwoFingerHolding = YES;
            showTopLevelToast(@"⏳ 双指按住中...\n保持0.8s激活学习");
            if (g_learnArmBlock) { dispatch_block_cancel(g_learnArmBlock); g_learnArmBlock = nil; }
            g_learnArmBlock = dispatch_block_create((dispatch_block_flags_t)0, ^{
                g_currentMode = AI_Mode_LearnArmed;
                showTopLevelToast(@"🎯 学习捕获已激活!\n请点击广告【跳过】按钮");
                UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
                [fb impactOccurred];
                g_isTwoFingerHolding = NO;
                g_learnArmBlock = nil;
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), g_learnArmBlock);
        }
    } else {
        if (g_isTwoFingerHolding) {
            if (g_learnArmBlock) { dispatch_block_cancel(g_learnArmBlock); g_learnArmBlock = nil; }
            g_isTwoFingerHolding = NO;
        }
    }

    // 三指长按 → 诊断
    if (count == 3) {
        CGPoint centerPoint = CGPointZero;
        NSInteger validCount = 0;
        for (UITouch *touch in touches) {
            CGPoint p = [touch locationInView:touch.window];
            centerPoint.x += p.x; centerPoint.y += p.y; validCount++;
        }
        if (validCount > 0) { centerPoint.x /= validCount; centerPoint.y /= validCount; }
        if (anyTouch.phase == UITouchPhaseBegan && !g_isThreeFingerHolding) {
            g_isThreeFingerHolding = YES;
            g_trackedPoint = centerPoint;
            showTopLevelToast(@"⏳ 三指按住中...\n保持0.8s诊断视图");
            if (g_inspectBlock) { dispatch_block_cancel(g_inspectBlock); g_inspectBlock = nil; }
            g_inspectBlock = dispatch_block_create((dispatch_block_flags_t)0, ^{
                inspectViewAtPoint(g_trackedPoint);
                dispatch_async(dispatch_get_main_queue(), ^{
                    @try { UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium]; [fb prepare]; [fb impactOccurred]; } @catch (NSException *e) {}
                });
                g_isThreeFingerHolding = NO;
                g_inspectBlock = nil;
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), g_inspectBlock);
        } else if (g_isThreeFingerHolding) {
            g_trackedPoint = centerPoint;
        }
    } else {
        if (g_isThreeFingerHolding) {
            if (g_inspectBlock) { dispatch_block_cancel(g_inspectBlock); g_inspectBlock = nil; }
            g_isThreeFingerHolding = NO;
        }
    }

    // 三指双击 → 清除配置
    if (count == 3 && anyTouch.phase == UITouchPhaseEnded && anyTouch.tapCount >= 2) {
        if (g_learnArmBlock) { dispatch_block_cancel(g_learnArmBlock); g_learnArmBlock = nil; g_isTwoFingerHolding = NO; }
        if (g_inspectBlock) { dispatch_block_cancel(g_inspectBlock); g_inspectBlock = nil; g_isThreeFingerHolding = NO; }
        BOOL ok = clearSkipConfig();
        g_currentMode = AI_Mode_Observe;
        showTopLevelToast(ok ? @"🗑️ 配置已清除\n已切回观察模式" : @"ℹ️ 无配置文件可清除");
        UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
        [fb impactOccurred];
    }
}

- (BOOL)sendAction:(SEL)action to:(id)target from:(id)sender forEvent:(UIEvent *)event {
    BOOL result = %orig;
    if ([sender isKindOfClass:[UIControl class]]) {
        tryLearnFromSender(sender, target, action);
    }
    return result;
}
%end

%hook NSObject
- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)ip {
    %orig;
    if (g_currentMode == AI_Mode_LearnArmed && [cv isKindOfClass:[UICollectionView class]]) {
        tryLearnFromCollectionView(cv, self, _cmd);
    }
}
%end

%hook UIGestureRecognizer
- (void)setState:(UIGestureRecognizerState)state {
    %orig;
    if (state == UIGestureRecognizerStateRecognized && g_currentMode == AI_Mode_LearnArmed) {
        NSArray<NSString *> *gestureActions = extractGestureActions(self);
        for (NSString *info in gestureActions) {
            NSRange arrowRange = [info rangeOfString:@" -> "];
            if (arrowRange.location != NSNotFound) {
                NSString *selPart = [info substringFromIndex:arrowRange.location + 4];
                @try {
                    NSArray *targets = [self valueForKey:@"_targets"];
                    for (id targetInfo in targets) {
                        id target = [targetInfo valueForKey:@"_target"];
                        SEL sel = NSSelectorFromString(selPart);
                        if (target && [target respondsToSelector:sel]) {
                            NSString *viewText = extractAllTextRecursive(self.view);
                            if (!isSkipRelatedText(viewText) && self.view.superview)
                                viewText = extractAllTextRecursive(self.view.superview);
                            if (isSkipRelatedText(viewText)) {
                                saveSkipConfig(NSStringFromClass([target class]), NSStringFromSelector(sel));
                                g_currentMode = AI_Mode_Observe;
                                UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
                                [fb impactOccurred];
                                NSLog(@"[AdInspector] ✅ Learned via gesture: %@.%@", NSStringFromClass([target class]), NSStringFromSelector(sel));
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
    NSDictionary *config = loadSkipConfig();
    if (config && config[@"targetClass"] && config[@"selectorName"]) {
        NSString *tc = config[@"targetClass"];
        NSString *sn = config[@"selectorName"];
        if ([sn isEqualToString:@"__adinspector_touch_skip__"]) {
            g_currentMode = AI_Mode_AutoSkip;
            showTopLevelToast([NSString stringWithFormat:@"🚀 AdInspector v7.9\n【Touch自动模式】\n%@\n\n双指长按=学习\n三指长按=诊断\n三指双击=清除", tc]);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                performTouchAutoSkip(tc);
            });
        } else {
            g_currentMode = AI_Mode_AutoSkip;
            showTopLevelToast([NSString stringWithFormat:@"🚀 AdInspector v7.9\n【自动模式】\n%@.%@\n\n双指长按=学习\n三指长按=诊断\n三指双击=清除", tc, sn]);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                performAutoSkip();
            });
        }
    } else {
        g_currentMode = AI_Mode_Observe;
        showTopLevelToast(@"👁️ AdInspector v7.9\n【观察模式】不干预任何操作\n\n双指长按0.8s=激活学习\n三指长按0.8s=诊断视图\n三指双击=清除配置");
    }
    NSLog(@"[AdInspector] ✅ v7.9 loaded. Mode: %ld, ConfigPath: %@", (long)g_currentMode, getConfigPath());
}
