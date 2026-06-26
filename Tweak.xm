#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// ========== 配置管理 ==========
static NSString *const kConfigPath = @"/var/mobile/AdInspector_SkipConfig.json";

static NSDictionary* loadSkipConfig() {
    NSData *data = [NSData dataWithContentsOfFile:kConfigPath];
    if (!data) return nil;
    NSError *error = nil;
    NSDictionary *result = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error) return nil;
    return result;
}

static void saveSkipConfig(NSString *targetClass, NSString *selectorName) {
    NSDictionary *config = @{
        @"targetClass": targetClass ?: @"",
        @"selectorName": selectorName ?: @"",
        @"learnedAt": @([[NSDate date] timeIntervalSince1970])
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:config options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:kConfigPath atomically:YES];
}

// ========== ✅ 绝对安全的顶层 Toast（完全复制你的安全实现）==========
static UIWindow *g_toastWindow = nil;
static UILabel *g_toastLabel = nil;
static dispatch_block_t g_hideBlock = nil;

static void showTopLevelToast(NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (!g_toastWindow) {
                // ✅ 关键：userInteractionEnabled = NO，绝不拦截任何触摸
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
            
            if (g_hideBlock) {
                dispatch_block_cancel(g_hideBlock);
                g_hideBlock = nil;
            }
            g_hideBlock = dispatch_block_create(0, ^{
                g_toastWindow.hidden = YES;
                g_hideBlock = nil;
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), g_hideBlock);
        } @catch (NSException *e) {
            NSLog(@"[AdInspector] Toast异常: %@", e);
        }
    });
}

// ========== 安全的手势 Target-Action 解析（保留你的原始实现）==========
static NSArray<NSString *> *extractGestureActions(UIGestureRecognizer *gr) {
    NSMutableArray *results = [NSMutableArray array];
    @try {
        NSArray *targets = [gr valueForKey:@"_targets"];
        for (id targetInfo in targets) {
            id target = [targetInfo valueForKey:@"_target"];
            id actionObj = [targetInfo valueForKey:@"_action"];
            SEL action = NULL;
            if ([actionObj isKindOfClass:[NSValue class]]) {
                action = (SEL)[(NSValue *)actionObj pointerValue];
            } else if ([actionObj isKindOfClass:[NSString class]]) {
                action = NSSelectorFromString((NSString *)actionObj);
            }
            if (target && action) {
                [results addObject:[NSString stringWithFormat:@"[Gesture:%@] %@ -> %@",
                                    NSStringFromClass([gr class]), target, NSStringFromSelector(action)]];
            }
        }
    } @catch (NSException *e) {
        [results addObject:[NSString stringWithFormat:@"[Gesture:%@] (解析异常)", NSStringFromClass([gr class])]];
    }
    return results;
}

// ========== 核心诊断逻辑（三指长按触发，保留你的原始实现）==========
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
    if (!hitView) {
        showTopLevelToast(@"❌ 未命中视图，请对准按钮重试");
        return;
    }
    
    NSMutableArray *chain = [NSMutableArray array];
    UIView *current = hitView;
    while (current) {
        [chain addObject:[NSString stringWithFormat:@"%@ (%@)",
                          NSStringFromClass([current class]), current.accessibilityIdentifier ?: @"nil"]];
        current = current.superview;
    }
    
    NSMutableArray *actions = [NSMutableArray array];
    if ([hitView isKindOfClass:[UIControl class]]) {
        UIControl *control = (UIControl *)hitView;
        for (id target in control.allTargets) {
            NSArray *targetActions = [control actionsForTarget:target forControlEvent:UIControlEventAllEvents];
            for (NSString *action in targetActions) {
                [actions addObject:[NSString stringWithFormat:@"[Control] %@ -> %@", target, action]];
            }
        }
    }
    for (UIGestureRecognizer *gr in hitView.gestureRecognizers) {
        [actions addObjectsFromArray:extractGestureActions(gr)];
    }
    
    NSDictionary *extraInfo = @{
        @"frame": NSStringFromCGRect(hitView.frame),
        @"windowFrame": NSStringFromCGRect([hitView convertRect:hitView.bounds toView:nil]),
        @"isHidden": @(hitView.isHidden),
        @"alpha": @(hitView.alpha),
        @"userInteractionEnabled": @(hitView.userInteractionEnabled)
    };
    
    NSDictionary *result = @{@"hierarchyChain": chain, @"targetActions": actions, @"extraInfo": extraInfo};
    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:&error];
    
    if (jsonData) {
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ad_inspect_result.json"];
        NSString *jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        BOOL ok = [jsonStr writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error];
        showTopLevelToast(ok ? [NSString stringWithFormat:@"✅ 诊断成功\n路径: %@", path]
                             : [NSString stringWithFormat:@"⚠️ 写入失败: %@", error.localizedDescription]);
    } else {
        showTopLevelToast([NSString stringWithFormat:@"❌ JSON序列化失败: %@", error.localizedDescription]);
    }
}

// ========== 三指长按状态机（保留你的原始实现）==========
static BOOL g_isThreeFingerHolding = NO;
static CGPoint g_trackedPoint = CGPointZero;
static dispatch_block_t g_inspectBlock = nil;

// ========== C 函数：查找目标子视图 ==========
static UIView* findTargetSubview(UIView *root, Class targetCls) {
    if (!root) return nil;
    if ([root isKindOfClass:targetCls]) return root;
    for (UIView *sub in root.subviews) {
        UIView *found = findTargetSubview(sub, targetCls);
        if (found) return found;
    }
    return nil;
}

// ========== 自动跳过执行逻辑 ==========
static void performAutoSkip() {
    NSDictionary *config = loadSkipConfig();
    if (!config) return;
    
    NSString *targetClassName = config[@"targetClass"];
    NSString *selectorName = config[@"selectorName"];
    if (!targetClassName.length || !selectorName.length) {
        showTopLevelToast(@"⚠️ 配置文件内容为空");
        return;
    }
    
    Class cls = NSClassFromString(targetClassName);
    SEL sel = NSSelectorFromString(selectorName);
    if (!cls) {
        showTopLevelToast([NSString stringWithFormat:@"⚠️ 类不存在: %@", targetClassName]);
        return;
    }
    if (![cls instancesRespondToSelector:sel]) {
        showTopLevelToast([NSString stringWithFormat:@"⚠️ 方法不存在: %@", selectorName]);
        return;
    }
    
    __block BOOL triggered = NO;
    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
        for (UIWindow *win in scene.windows) {
            if (!win.rootViewController.view) continue;
            UIView *targetView = findTargetSubview(win.rootViewController.view, cls);
            if (targetView && [targetView respondsToSelector:sel]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [targetView performSelector:sel withObject:nil];
                #pragma clang diagnostic pop
                triggered = YES;
                showTopLevelToast([NSString stringWithFormat:@"🚀 自动跳过成功!\n%@.%@", targetClassName, selectorName]);
                break;
            }
        }
        if (triggered) break;
    }
    
    if (!triggered) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            BOOL retryTriggered = NO;
            for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                for (UIWindow *win in scene.windows) {
                    if (!win.rootViewController.view) continue;
                    UIView *targetView = findTargetSubview(win.rootViewController.view, cls);
                    if (targetView && [targetView respondsToSelector:sel]) {
                        #pragma clang diagnostic push
                        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                        [targetView performSelector:sel withObject:nil];
                        #pragma clang diagnostic pop
                        retryTriggered = YES;
                        showTopLevelToast(@"🚀 延迟跳过成功!");
                        break;
                    }
                }
                if (retryTriggered) break;
            }
            if (!retryTriggered) {
                showTopLevelToast(@"ℹ️ 未找到跳过按钮\n可能广告尚未加载");
            }
        });
    }
}

// ========== 全局 Hook：事件分发 + 学习态拦截 ==========
%hook UIApplication
- (void)sendEvent:(UIEvent *)event {
    %orig;
    if (event.type != UIEventTypeTouches) return;
    
    NSSet *touches = [event allTouches];
    BOOL isThreeFingers = (touches.count == 3);
    
    if (isThreeFingers) {
        CGPoint centerPoint = CGPointZero;
        NSInteger validCount = 0;
        for (UITouch *touch in touches) {
            CGPoint p = [touch locationInView:touch.window];
            centerPoint.x += p.x;
            centerPoint.y += p.y;
            validCount++;
        }
        if (validCount > 0) {
            centerPoint.x /= validCount;
            centerPoint.y /= validCount;
        }
        
        UITouch *anyTouch = touches.anyObject;
        if (anyTouch.phase == UITouchPhaseBegan && !g_isThreeFingerHolding) {
            g_isThreeFingerHolding = YES;
            g_trackedPoint = centerPoint;
            g_inspectBlock = dispatch_block_create(0, ^{
                inspectViewAtPoint(g_trackedPoint);
                dispatch_async(dispatch_get_main_queue(), ^{
                    @try {
                        UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
                        [fb prepare]; [fb impactOccurred];
                    } @catch (NSException *e) {}
                });
                g_isThreeFingerHolding = NO;
                g_inspectBlock = nil;
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), g_inspectBlock);
        } else if (g_isThreeFingerHolding) {
            g_trackedPoint = centerPoint;
        }
    } else {
        if (g_isThreeFingerHolding && g_inspectBlock) {
            dispatch_block_cancel(g_inspectBlock);
            g_inspectBlock = nil;
            g_isThreeFingerHolding = NO;
        }
    }
}

// ✅ 学习态：拦截跳过按钮点击
- (BOOL)sendAction:(SEL)action to:(id)target from:(id)sender forEvent:(UIEvent *)event {
    BOOL result = %orig;
    if (!loadSkipConfig() && [sender isKindOfClass:[UIButton class]]) {
        UIButton *btn = (UIButton *)sender;
        NSString *title = [btn titleForState:UIControlStateNormal];
        if ([title containsString:@"跳过"] || [title containsString:@"Skip"]) {
            NSString *targetClassName = NSStringFromClass([target class]);
            NSString *selectorName = NSStringFromSelector(action);
            saveSkipConfig(targetClassName, selectorName);
            
            UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
            [feedback impactOccurred];
            showTopLevelToast([NSString stringWithFormat:@"✅ 已学习:\n%@.%@\n重启生效", targetClassName, selectorName]);
        }
    }
    return result;
}
%end

// ========== 入口 ==========
%ctor {
    NSDictionary *config = loadSkipConfig();
    BOOL isLearningMode = (config == nil);
    
    if (isLearningMode) {
        showTopLevelToast(@"🎓 AdInspector v6.0 已注入\n【学习模式】\n请点击广告跳过按钮\n三指长按0.8s抓取视图");
    } else {
        NSString *tc = config[@"targetClass"];
        NSString *sn = config[@"selectorName"];
        showTopLevelToast([NSString stringWithFormat:@"🚀 AdInspector v6.0 已注入\n【自动模式】%@.%@\n三指长按0.8s抓取视图", tc, sn]);
    }
    
    if (!isLearningMode) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            performAutoSkip();
        });
    }
    
    NSLog(@"[AdInspector] ✅ v6.0 加载成功！三指静止长按0.8s触发诊断。");
}
