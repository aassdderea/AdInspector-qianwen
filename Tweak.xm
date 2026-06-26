// ✅ v7.8 修复：广点通/百度联盟 Touch 模拟跳过
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
            UIView *tv = findTargetSubview(win.rootViewController.view, cls);
            if (tv && tv.window) {
                CGPoint center = [tv convertPoint:CGPointMake(tv.bounds.size.width / 2.0, tv.bounds.size.height / 2.0)
                                           toView:nil];
                @try {
                    UITouch *touch = [[UITouch alloc] init];
                    
                    // ✅ 关键修复1：必须设置 _window、_view、_senderView
                    [touch setValue:tv.window forKey:@"_window"];
                    [touch setValue:tv forKey:@"_view"];
                    [touch setValue:tv forKey:@"_senderView"]; 
                    
                    // ✅ 关键修复2：补全触摸类型与基础属性
                    [touch setValue:@(0) forKey:@"_touchType"]; // 0 = Direct touch
                    [touch setValue:@(YES) forKey:@"_isFirstTouchForView"];
                    [touch setValue:@(1) forKey:@"_tapCount"];
                    
                    NSValue *locValue = [NSValue valueWithCGPoint:center];
                    [touch setValue:locValue forKey:@"_locationInWindow"];
                    [touch setValue:locValue forKey:@"_previousLocationInWindow"];

                    // --- Phase 1: Began ---
                    [touch setValue:@([[NSDate date] timeIntervalSinceReferenceDate]) forKey:@"_timestamp"];
                    [touch setValue:@(UITouchPhaseBegan) forKey:@"_phase"];
                    
                    UIEvent *beganEvent = [[UIEvent alloc] init];
                    [beganEvent setValue:[NSSet setWithObject:touch] forKey:@"_touches"];
                    [beganEvent setValue:@(UIEventTypeTouches) forKey:@"_type"];
                    [[UIApplication sharedApplication] sendEvent:beganEvent];

                    // --- Phase 2: Stationary (延迟30ms，部分SDK需要此相位确认非滑动) ---
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        @try {
                            [touch setValue:@([[NSDate date] timeIntervalSinceReferenceDate]) forKey:@"_timestamp"];
                            [touch setValue:@(UITouchPhaseStationary) forKey:@"_phase"];
                            
                            UIEvent *stationaryEvent = [[UIEvent alloc] init];
                            [stationaryEvent setValue:[NSSet setWithObject:touch] forKey:@"_touches"];
                            [stationaryEvent setValue:@(UIEventTypeTouches) forKey:@"_type"];
                            [[UIApplication sharedApplication] sendEvent:stationaryEvent];
                        } @catch (NSException *e) {}
                        
                        // --- Phase 3: Ended (再延迟30ms) ---
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            @try {
                                [touch setValue:@([[NSDate date] timeIntervalSinceReferenceDate]) forKey:@"_timestamp"];
                                [touch setValue:@(UITouchPhaseEnded) forKey:@"_phase"];
                                
                                UIEvent *endedEvent = [[UIEvent alloc] init];
                                [endedEvent setValue:[NSSet setWithObject:touch] forKey:@"_touches"];
                                [endedEvent setValue:@(UIEventTypeTouches) forKey:@"_type"];
                                [[UIApplication sharedApplication] sendEvent:endedEvent];
                                
                                showTopLevelToast([NSString stringWithFormat:@"🚀 Touch模拟已发送!\n目标: %@", targetClassName]);
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
