// ========== 新增：学习模式超时自动退出 ==========
static dispatch_block_t g_learnTimeoutBlock = nil;

static void armLearnMode() {
    g_currentMode = AI_Mode_LearnArmed;
    showTopLevelToast(@"🎯 学习模式已激活!\n请点击【跳过】按钮\n(10秒后自动退出)");
    UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [fb impactOccurred];
    
    // ✅ 10秒超时自动退回观察模式
    if (g_learnTimeoutBlock) dispatch_block_cancel(g_learnTimeoutBlock);
    g_learnTimeoutBlock = dispatch_block_create((dispatch_block_flags_t)0, ^{
        if (g_currentMode == AI_Mode_LearnArmed) {
            g_currentMode = AI_Mode_Observe;
            showTopLevelToast(@"⏰ 学习模式已超时退出");
            g_learnTimeoutBlock = nil;
        }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), g_learnTimeoutBlock);
}

static void disarmLearnMode(BOOL success) {
    if (g_learnTimeoutBlock) { dispatch_block_cancel(g_learnTimeoutBlock); g_learnTimeoutBlock = nil; }
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
    disarmLearnMode(YES); // ✅ 成功后取消超时
    
    UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [fb impactOccurred];
    
    NSString *text = extractAllTextRecursive(hitView, 5);
    showTopLevelToast([NSString stringWithFormat:@"✅ 盲录成功!\n类: %@\n方法: %@\n来源: %@\n文本: %@", 
                      targetClass, selName, captureMethod, 
                      text.length > 0 ? text : @"(无文本)"]);
}

// ========== v7.18 重写 sendEvent: 状态机 ==========
%hook UIApplication
- (void)sendEvent:(UIEvent *)event {
    %orig;
    if (event.type != UIEventTypeTouches) return;

    NSSet *touches = [event allTouches];
    NSUInteger count = touches.count;
    UITouch *anyTouch = touches.anyObject;
    if (!anyTouch) return;

    // ✅ 学习模式下的触摸捕获（不再要求 count==1，改为检测 Began 阶段）
    // 使用 Began 而非 Ended，避免被广告SDK手势消费掉 Ended 事件
    if (g_currentMode == AI_Mode_LearnArmed && anyTouch.phase == UITouchPhaseBegan) {
        CGPoint point = [anyTouch locationInView:anyTouch.window];
        // ✅ 延迟到下一个 RunLoop 执行 hitTest，确保视图层级已更新
        dispatch_async(dispatch_get_main_queue(), ^{
            tryLearnFromTouchEndPoint(point, anyTouch.window);
        });
    }

    // 双指长按检测（仅控制计时器，不直接控制学习模式）
    if (count == 2 && anyTouch.phase == UITouchPhaseBegan && g_twoFingerStartTime == 0) {
        g_twoFingerStartTime = [[NSDate date] timeIntervalSinceReferenceDate];
        g_twoFingerArmed = NO;
        showTopLevelToast(@"⏳ 双指按住中...");
    } else if (count < 2 && g_twoFingerStartTime > 0 && !g_twoFingerArmed) {
        // ✅ 双指松开但未达到0.8s，取消计时
        g_twoFingerStartTime = 0;
    }
    // ✅ 关键修复：双指松开后，即使已达到0.8s，也不再重置 g_currentMode
    // 学习模式的退出只由 tryLearnFromTouchEndPoint 或超时块控制

    // 三指诊断 & 清除配置（逻辑不变，省略以节省篇幅）
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
            disarmLearnMode(NO); // ✅ 清除配置时也退出学习模式
            BOOL ok = clearSkipConfig();
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
    // ✅ 学习模式下也尝试从 sendAction 捕获（作为补充通道）
    if (g_currentMode == AI_Mode_LearnArmed) {
        if ([sender isKindOfClass:[UIControl class]]) {
            BOOL learned = tryLearnFromSender(sender, target, action);
            if (learned) disarmLearnMode(YES);
        }
    }
    return result;
}
%end

// ========== 轮询器（v7.18 修正）==========
static void startPolling() {
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 0.05 * NSEC_PER_SEC, 0.01 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{
        @autoreleasepool {
            // ✅ 双指达到0.8s → 调用 armLearnMode() 而非直接赋值
            if (g_twoFingerStartTime > 0 && !g_twoFingerArmed) {
                if ([[NSDate date] timeIntervalSinceReferenceDate] - g_twoFingerStartTime >= 0.8) {
                    g_twoFingerArmed = YES;
                    armLearnMode(); // ✅ 统一入口，带超时保护
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
