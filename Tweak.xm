// ========== ✅ v7.11 手势轮询器（独立于 sendEvent）==========
static void startGesturePolling() {
    // ✅ 已移除错误的 __weak typeof(nil) weakSelf = nil;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 0.05 * NSEC_PER_SEC, 0.01 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{
        @autoreleasepool {
            // 获取当前屏幕上的活跃触摸
            NSSet *activeTouches = nil;
            for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                for (UIWindow *win in scene.windows) {
                    // 尝试通过私有 API 获取当前触摸（仅用于手势检测，不注入事件）
                    @try {
                        activeTouches = [win valueForKey:@"_touchData"];
                        if (activeTouches) break;
                    } @catch (NSException *e) {}
                }
                if (activeTouches) break;
            }
            
            // 双指长按计时
            if (g_twoFingerStartTime > 0 && !g_twoFingerArmed) {
                NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceReferenceDate] - g_twoFingerStartTime;
                if (elapsed >= 0.8) {
                    g_twoFingerArmed = YES;
                    g_currentMode = AI_Mode_LearnArmed;
                    showTopLevelToast(@"🎯 学习捕获已激活!\n请点击广告【跳过】按钮");
                    UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
                    [fb impactOccurred];
                }
            }
            
            // 三指长按计时
            if (g_threeFingerStartTime > 0 && !g_threeFingerArmed) {
                NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceReferenceDate] - g_threeFingerStartTime;
                if (elapsed >= 0.8) {
                    g_threeFingerArmed = YES;
                    inspectViewAtPoint(g_trackedPoint);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        @try { 
                            UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium]; 
                            [fb prepare]; 
                            [fb impactOccurred]; 
                        } @catch (NSException *e) {}
                    });
                }
            }
        }
    });
    dispatch_resume(timer);
}
