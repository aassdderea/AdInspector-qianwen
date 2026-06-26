#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// ========== ✅ 绝对安全的顶层 Toast（必须放在最前面）==========
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

// ========== 配置管理 ==========
static NSString *const kConfigPath = @"/var/mobile/AdInspector_SkipConfig.json";

static NSDictionary* loadSkipConfig() {
    NSData *data = [NSData dataWithContentsOfFile:kConfigPath];
    if (!data) return nil;
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}

static void saveSkipConfig(NSString *targetClass, NSString *selectorName) {
    NSDictionary *config = @{
        @"targetClass": targetClass ?: @"",
        @"selectorName": selectorName ?: @"",
        @"learnedAt": @([[NSDate date] timeIntervalSince1970])
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:config options:NSJSONWritingPrettyPrinted error:nil];
    BOOL ok = [data writeToFile:kConfigPath atomically:YES];
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:kConfigPath];
    showTopLevelToast([NSString stringWithFormat:@"%@\n路径: %@\n文件存在: %@", 
        ok && exists ? @"✅ 配置已保存!" : @"❌ 保存失败!", 
        kConfigPath, exists ? @"YES" : @"NO"]);
}

static BOOL clearSkipConfig() {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:kConfigPath]) {
        NSError *error = nil;
        return [fm removeItemAtPath:kConfigPath error:&error];
    }
    return NO;
}

// ========== 手势解析 & 视图诊断 ==========
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
            if (target && action) {
                [results addObject:[NSString stringWithFormat:@"[Gesture:%@] %@ -> %@", NSStringFromClass([gr class]), target, NSStringFromSelector(action)]];
            }
        }
    } @catch (NSException *e) {
        [results addObject:[NSString stringWithFormat:@"[Gesture:%@] (解析异常)", NSStringFromClass([gr class])]];
    }
    return results;
}

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
    
    NSDictionary *result = @{@"hierarchyChain": chain, @"targetActions": actions, @"extraInfo": @{
        @"frame": NSStringFromCGRect(hitView.frame),
        @"windowFrame": NSStringFromCGRect([hitView convertRect:hitView.bounds toView:nil]),
        @"isHidden": @(hitView.isHidden), @"alpha": @(hitView.alpha), @"userInteractionEnabled": @(hitView.userInteractionEnabled)
    }};
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

static BOOL isSkipRelatedText(NSString *text) {
    if (!text || text.length == 0) return NO;
    NSString *lower = [text lowercaseString];
    return [lower containsString:@"跳过"] || 
           [lower containsString:@"skip"] || 
           [lower containsString:@"close"] || 
           [lower containsString:@"关闭"] || 
           [lower containsString:@"dismiss"];
}

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

static UIView* findTargetSubview(UIView *root, Class targetCls) {
    if (!root) return nil;
    if ([root isKindOfClass:targetCls]) return root;
    for (UIView *sub in root.subviews) {
        UIView *found = findTargetSubview(sub, targetCls);
        if (found) return found;
    }
    return nil;
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
        showTopLevelToast([NSString stringWithFormat:@"⚠️ %@.%@ 无效", tc, sn]);
        return;
    }
    
    __block BOOL triggered = NO;
    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
        for (UIWindow *win in scene.windows) {
            if (!win.rootViewController.view) continue;
            UIView *tv = findTargetSubview(win.rootViewController.view, cls);
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
                    UIView *tv = findTargetSubview(win.rootViewController.view, cls);
                    if (tv && [tv respondsToSelector:sel]) {
                        #pragma clang diagnostic push
                        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                        [tv performSelector:sel withObject:nil];
                        #pragma clang diagnostic pop
                        retry = YES;
                        showTopLevelToast(@"🚀 延迟跳过成功!");
                        break;
                    }
                }
                if (retry) break;
            }
            if (!retry) showTopLevelToast(@"ℹ️ 未找到跳过按钮\n广告可能尚未加载");
        });
    }
}

static BOOL tryLearnFromSender(id sender, id target, SEL action) {
    if (g_currentMode != AI_Mode_LearnArmed) return NO;
    
    BOOL matched = NO;
    NSString *matchedText = nil;
    
    if ([sender isKindOfClass:[UIView class]]) {
        NSString *text = extractAllTextFromView((UIView *)sender);
        if (isSkipRelatedText(text)) {
            matched = YES;
            matchedText = text;
        }
        if (!matched) {
            UIView *senderView = (UIView *)sender;
            for (UIView *sub in senderView.subviews) {
                NSString *subText = extractAllTextFromView(sub);
                if (isSkipRelatedText(subText)) {
                    matched = YES;
                    matchedText = subText;
                    break;
                }
            }
        }
    }
    
    if (!matched && [target isKindOfClass:[UIViewController class]]) {
        UIViewController *vc = (UIViewController *)target;
        for (UIView *sub in vc.view.subviews) {
            NSString *subText = extractAllTextFromView(sub);
            if (isSkipRelatedText(subText)) {
                matched = YES;
                matchedText = subText;
                break;
            }
        }
    }
    
    if (matched) {
        NSString *tc = NSStringFromClass([target class]);
        NSString *sn = NSStringFromSelector(action);
        saveSkipConfig(tc, sn);
        g_currentMode = AI_Mode_Observe;
        
        UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [fb impactOccurred];
        NSLog(@"[AdInspector] ✅ Learned: %@.%@ (matched text: %@)", tc, sn, matchedText);
        return YES;
    }
    
    NSString *senderClass = NSStringFromClass([sender class]);
    NSString *targetClass = NSStringFromClass([target class]);
    NSString *selName = NSStringFromSelector(action);
    showTopLevelToast([NSString stringWithFormat:@"⚠️ 学习模式已激活\n但未匹配到跳过文本\n\nsender: %@\ntarget: %@\naction: %@\n\n请用三指长按诊断此按钮", senderClass, targetClass, selName]);
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
                            UIView *grView = self.view;
                            NSString *viewText = extractAllTextFromView(grView);
                            BOOL matched = isSkipRelatedText(viewText);
                            if (!matched && grView.superview) {
                                viewText = extractAllTextFromView(grView.superview);
                                matched = isSkipRelatedText(viewText);
                            }
                            if (matched) {
                                NSString *tc = NSStringFromClass([target class]);
                                NSString *sn = NSStringFromSelector(sel);
                                saveSkipConfig(tc, sn);
                                g_currentMode = AI_Mode_Observe;
                                UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
                                [fb impactOccurred];
                                NSLog(@"[AdInspector] ✅ Learned via gesture: %@.%@", tc, sn);
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
        g_currentMode = AI_Mode_AutoSkip;
        NSString *tc = config[@"targetClass"];
        NSString *sn = config[@"selectorName"];
        showTopLevelToast([NSString stringWithFormat:@"🚀 AdInspector v7.3\n【自动模式】\n%@.%@\n\n双指长按=学习\n三指长按=诊断\n三指双击=清除", tc, sn]);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            performAutoSkip();
        });
    } else {
        g_currentMode = AI_Mode_Observe;
        showTopLevelToast(@"👁️ AdInspector v7.3\n【观察模式】不干预任何操作\n\n双指长按0.8s=激活学习\n三指长按0.8s=诊断视图\n三指双击=清除配置");
    }
    NSLog(@"[AdInspector] ✅ v7.3 loaded. Mode: %ld", (long)g_currentMode);
}
