#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <stdint.h>

// ========== 配置管理 ==========
static NSString* getConfigPath() {
    @try {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        return [paths.firstObject stringByAppendingPathComponent:@"AdInspector_SkipConfig.json"];
    } @catch (NSException *e) {
        return [NSTemporaryDirectory() stringByAppendingPathComponent:@"AdInspector_SkipConfig.json"];
    }
}

static NSDictionary* loadSkipConfig() {
    @try {
        NSData *data = [NSData dataWithContentsOfFile:getConfigPath()];
        return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    } @catch (NSException *e) { return nil; }
}

static void saveSkipConfig(NSDictionary *config) {
    @try {
        NSString *path = getConfigPath();
        [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        NSData *data = [NSJSONSerialization dataWithJSONObject:config options:NSJSONWritingPrettyPrinted error:nil];
        [data writeToFile:path options:NSDataWritingAtomic error:nil];
    } @catch (NSException *e) {}
}

static BOOL clearSkipConfig() {
    @try {
        return [[NSFileManager defaultManager] removeItemAtPath:getConfigPath() error:nil];
    } @catch (NSException *e) { return NO; }
}

// ========== Toast ==========
static void showToast(NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            static UIWindow *tw = nil;
            static UILabel *tl = nil;
            if (!tw) {
                tw = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
                tw.windowLevel = UIWindowLevelAlert + 3000;
                tw.backgroundColor = [UIColor clearColor];
                tw.userInteractionEnabled = NO;
                tl = [[UILabel alloc] init];
                tl.numberOfLines = 0;
                tl.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
                tl.textColor = [UIColor whiteColor];
                tl.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
                tl.layer.cornerRadius = 12;
                tl.clipsToBounds = YES;
                tl.textAlignment = NSTextAlignmentCenter;
                [tw addSubview:tl];
            }
            CGFloat mw = tw.bounds.size.width - 40;
            if (mw <= 0) mw = 300;
            CGRect r = [msg boundingRectWithSize:CGSizeMake(mw, CGFLOAT_MAX)
                                         options:NSStringDrawingUsesLineFragmentOrigin
                                      attributes:@{NSFontAttributeName: tl.font} context:nil];
            tl.frame = CGRectMake(0, 0, r.size.width + 30, r.size.height + 20);
            tl.center = CGPointMake(tw.bounds.size.width / 2.0, tw.bounds.size.height - 150);
            tl.text = msg;
            tw.hidden = NO;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                tw.hidden = YES;
            });
        } @catch (NSException *e) {}
    });
}

// ========== 手势动作提取 ==========
static NSArray<NSString*>* getGestureActions(UIGestureRecognizer *gr) {
    NSMutableArray *r = [NSMutableArray array];
    @try {
        for (id ti in [gr valueForKey:@"_targets"]) {
            id tgt = [ti valueForKey:@"_target"];
            id act = [ti valueForKey:@"_action"];
            SEL sel = NULL;
            if ([act isKindOfClass:[NSValue class]]) sel = (SEL)[(NSValue *)act pointerValue];
            else if ([act isKindOfClass:[NSString class]]) sel = NSSelectorFromString(act);
            if (tgt && sel) [r addObject:[NSString stringWithFormat:@"%@ -> %@", tgt, NSStringFromSelector(sel)]];
        }
    } @catch (NSException *e) {}
    return r;
}

// ========== 安全自动跳过（防卡死）==========
static void performAutoSkip() {
    // ✅ 关键：不在主线程同步执行 hitTest，改用异步+超时保护
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            // 检查 App 是否活跃，避免在后台/过渡态触发
            if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
                NSLog(@"[AdInspector] Skip deferred: app not active");
                return;
            }
            
            NSDictionary *cfg = loadSkipConfig();
            if (!cfg) return;
            
            CGFloat rx = [cfg[@"relX"] floatValue];
            CGFloat ry = [cfg[@"relY"] floatValue];
            
            // ✅ 验证坐标有效性（排除 0,0 和 NaN）
            if (rx <= 0.001 || ry <= 0.001 || rx > 1.0 || ry > 1.0) {
                NSLog(@"[AdInspector] Invalid coords: (%f, %f), skipping auto-skip", rx, ry);
                return;
            }
            
            NSString *tc = cfg[@"targetClass"];
            NSString *sn = cfg[@"selectorName"];
            
            for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (scene.activationState != UISceneActivationStateForegroundActive) continue;
                for (UIWindow *win in scene.windows) {
                    if (!win.isKeyWindow) continue;
                    
                    CGSize sz = win.bounds.size;
                    if (sz.width <= 0 || sz.height <= 0) continue;
                    
                    CGPoint abs = CGPointMake(rx * sz.width, ry * sz.height);
                    UIView *hit = [win hitTest:abs withEvent:nil];
                    if (!hit) continue;
                    
                    if ([hit isKindOfClass:[UIControl class]]) {
                        [(UIControl *)hit sendActionsForControlEvents:UIControlEventTouchUpInside];
                        showToast([NSString stringWithFormat:@"🚀 坐标跳过!\n(%@)", NSStringFromClass([hit class])]);
                        return;
                    }
                    
                    for (UIGestureRecognizer *gr in hit.gestureRecognizers) {
                        if ([gr isKindOfClass:[UITapGestureRecognizer class]] && gr.enabled) {
                            #pragma clang diagnostic push
                            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                            [gr performSelector:NSSelectorFromString(@"_recognizeTap:") withObject:nil];
                            #pragma clang diagnostic pop
                            showToast(@"🚀 手势跳过!");
                            return;
                        }
                    }
                }
            }
            
            // 兜底：类名查找
            if (tc.length && sn.length && ![sn isEqualToString:@"__coordinate_skip__"]) {
                Class cls = NSClassFromString(tc);
                SEL sel = NSSelectorFromString(sn);
                if (cls) {
                    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
                        for (UIWindow *win in scene.windows) {
                            if (!win.rootViewController.view) continue;
                            __block UIView *found = nil;
                            void (^search)(UIView *, NSInteger) = nil;
                            search = ^(UIView *v, NSInteger d) {
                                if (d > 30 || found) return;
                                if ([v isKindOfClass:cls] && !v.isHidden && v.alpha > 0.01) found = v;
                                for (UIView *s in v.subviews) search(s, d + 1);
                            };
                            search(win.rootViewController.view, 0);
                            if (found) {
                                if ([found isKindOfClass:[UIControl class]]) {
                                    [(UIControl *)found sendActionsForControlEvents:UIControlEventTouchUpInside];
                                } else if ([found respondsToSelector:sel]) {
                                    #pragma clang diagnostic push
                                    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                                    [found performSelector:sel withObject:nil];
                                    #pragma clang diagnostic pop
                                }
                                showToast([NSString stringWithFormat:@"🚀 类名跳过!\n%@.%@", tc, sn]);
                                return;
                            }
                        }
                    }
                }
            }
        } @catch (NSException *e) {
            NSLog(@"[AdInspector] Auto-skip error: %@", e.reason);
        }
    });
}

// ========== 动态类宏 ==========
#define DYNAMIC_CLASS(name, methodSel, blockImpl) \
    static Class name##Class = nil; \
    static dispatch_once_t name##Once; \
    dispatch_once(&name##Once, ^{ \
        name##Class = objc_allocateClassPair([NSObject class], #name, 0); \
        class_addMethod(name##Class, methodSel, imp_implementationWithBlock(blockImpl), "v@:@"); \
        objc_registerClassPair(name##Class); \
    })

// ========== 学习面板 ==========
static void showLearnPanel() {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            // ✅ 使用 screen bounds 而非 window bounds 计算尺寸
            CGRect screenBounds = [UIScreen mainScreen].bounds;
            if (screenBounds.size.width <= 0 || screenBounds.size.height <= 0) {
                showToast(@"❌ 屏幕尺寸异常");
                return;
            }
            
            UIWindow *lw = [[UIWindow alloc] initWithFrame:screenBounds];
            lw.windowLevel = UIWindowLevelAlert + 2000;
            lw.backgroundColor = [[UIColor redColor] colorWithAlphaComponent:0.15];
            
            UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(20, 60, screenBounds.size.width - 40, 60)];
            hint.text = @"🎯 学习模式\n请点击广告【跳过】按钮";
            hint.numberOfLines = 0;
            hint.textColor = [UIColor whiteColor];
            hint.font = [UIFont boldSystemFontOfSize:16];
            hint.textAlignment = NSTextAlignmentCenter;
            hint.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.7];
            hint.layer.cornerRadius = 12;
            hint.clipsToBounds = YES;
            [lw addSubview:hint];
            
            UIButton *cancelBtn = [UIButton buttonWithType:UIButtonTypeSystem];
            cancelBtn.frame = CGRectMake(screenBounds.size.width / 2 - 60, screenBounds.size.height - 100, 120, 44);
            [cancelBtn setTitle:@"❌ 取消学习" forState:UIControlStateNormal];
            [cancelBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            cancelBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
            cancelBtn.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.7];
            cancelBtn.layer.cornerRadius = 22;
            [lw addSubview:cancelBtn];
            
            // LearnHandler
            DYNAMIC_CLASS(AILearnHandler, @selector(handleTap:), ^(id self, UITapGestureRecognizer *g) {
                UIWindow *window = objc_getAssociatedObject(self, "lw");
                UIButton *cBtn = objc_getAssociatedObject(self, "cancelBtn");
                UIView *hintV = objc_getAssociatedObject(self, "hintView");
                if (!window) return;
                
                CGPoint p = [g locationInView:window];
                
                if (cBtn && CGRectContainsPoint(cBtn.frame, p)) {
                    window.hidden = YES;
                    showToast(@"❌ 学习已取消");
                    return;
                }
                if (hintV && CGRectContainsPoint(hintV.frame, p)) return;
                
                // ✅ 隐藏面板让 hitTest 穿透
                window.hidden = YES;
                
                // ✅ 延迟一帧确保面板完全隐藏后再 hitTest
                dispatch_async(dispatch_get_main_queue(), ^{
                    @try {
                        UIWindow *realWindow = nil;
                        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
                            for (UIWindow *w in scene.windows) {
                                if (w != window && w.isKeyWindow && w.bounds.size.width > 0) {
                                    realWindow = w;
                                    break;
                                }
                            }
                            if (realWindow) break;
                        }
                        
                        if (!realWindow) {
                            window.hidden = NO;
                            showToast(@"❌ 无法获取真实窗口");
                            return;
                        }
                        
                        UIView *hit = [realWindow hitTest:p withEvent:nil];
                        if (!hit) {
                            window.hidden = NO;
                            showToast(@"❌ 未命中视图，请重试");
                            return;
                        }
                        
                        // ✅ 使用真实窗口的尺寸计算相对坐标
                        CGSize realSize = realWindow.bounds.size;
                        CGFloat relX = p.x / realSize.width;
                        CGFloat relY = p.y / realSize.height;
                        
                        // ✅ 安全检查：排除无效坐标
                        if (relX < 0.01 || relY < 0.01 || relX > 0.99 || relY > 0.99) {
                            window.hidden = NO;
                            showToast([NSString stringWithFormat:@"⚠️ 坐标异常(%.1f%%,%.1f%%)\n请重新点击", relX*100, relY*100]);
                            return;
                        }
                        
                        NSString *tc = NSStringFromClass([hit class]);
                        NSString *sn = @"__coordinate_skip__";
                        for (UIGestureRecognizer *gr in hit.gestureRecognizers) {
                            NSArray *acts = getGestureActions(gr);
                            for (NSString *info in acts) {
                                NSRange ar = [info rangeOfString:@" -> "];
                                if (ar.location != NSNotFound) {
                                    sn = [info substringFromIndex:ar.location + 4];
                                    break;
                                }
                            }
                            if (![sn isEqualToString:@"__coordinate_skip__"]) break;
                        }
                        
                        saveSkipConfig(@{
                            @"targetClass": tc,
                            @"selectorName": sn,
                            @"relX": @(relX),
                            @"relY": @(relY),
                            @"learnedAt": @([[NSDate date] timeIntervalSince1970])
                        });
                        
                        UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
                        [fb impactOccurred];
                        showToast([NSString stringWithFormat:@"✅ 学习成功!\n类: %@\n坐标: (%.2f%%, %.2f%%)", 
                                  tc, relX * 100, relY * 100]);
                    } @catch (NSException *e) {
                        window.hidden = NO;
                        showToast([NSString stringWithFormat:@"❌ 学习异常: %@", e.reason]);
                    }
                });
            });
            
            id handler = [[AILearnHandlerClass alloc] init];
            objc_setAssociatedObject(handler, "lw", lw, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(handler, "cancelBtn", cancelBtn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(handler, "hintView", hint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            
            UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:handler action:@selector(handleTap:)];
            tap.cancelsTouchesInView = NO;
            [lw addGestureRecognizer:tap];
            
            // CancelHandler
            DYNAMIC_CLASS(AICancelHandler, @selector(cancelTapped), ^(id self, id sender) {
                UIWindow *window = objc_getAssociatedObject(self, "lw");
                window.hidden = YES;
                showToast(@"❌ 学习已取消");
            });
            id cancelHandler = [[AICancelHandlerClass alloc] init];
            objc_setAssociatedObject(cancelHandler, "lw", lw, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [cancelBtn addTarget:cancelHandler action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];
            objc_setAssociatedObject(lw, "cancelHandler", cancelHandler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(lw, "handler", handler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            
            [lw makeKeyAndVisible];
            UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
            [fb impactOccurred];
        } @catch (NSException *e) {
            showToast([NSString stringWithFormat:@"❌ 学习面板异常: %@", e.reason]);
        }
    });
}

// ========== 边缘手势 ==========
static void installEdgeSwipe() {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            DYNAMIC_CLASS(AIEdgeHandler, @selector(handleEdge:), ^(id self, UIScreenEdgePanGestureRecognizer *g) {
                if (g.state == UIGestureRecognizerStateRecognized) {
                    showLearnPanel();
                }
            });
            
            for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (scene.activationState != UISceneActivationStateForegroundActive) continue;
                for (UIWindow *win in scene.windows) {
                    if (win.tag == 9527) continue;
                    win.tag = 9527;
                    
                    id handler = [[AIEdgeHandlerClass alloc] init];
                    UIScreenEdgePanGestureRecognizer *edge = [[UIScreenEdgePanGestureRecognizer alloc] 
                        initWithTarget:handler action:@selector(handleEdge:)];
                    edge.edges = UIRectEdgeRight;
                    edge.cancelsTouchesInView = NO;
                    [win addGestureRecognizer:edge];
                    
                    objc_setAssociatedObject(win, "edgeHandler", handler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
            }
        } @catch (NSException *e) {
            NSLog(@"[AdInspector] Edge swipe install error: %@", e.reason);
        }
    });
}

// ========== 三指双击清除 ==========
%hook UIApplication
- (void)sendEvent:(UIEvent *)event {
    %orig;
    if (event.type != UIEventTypeTouches) return;
    NSSet *touches = [event allTouches];
    UITouch *t = touches.anyObject;
    if (touches.count == 3 && t.phase == UITouchPhaseEnded && t.tapCount >= 2) {
        BOOL ok = clearSkipConfig();
        showToast(ok ? @"🗑️ 配置已清除" : @"ℹ️ 无配置可清除");
        UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
        [fb impactOccurred];
    }
}
%end

// ========== 入口 ==========
%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            NSLog(@"[AdInspector] ✅ v7.24 init...");
            installEdgeSwipe();
            
            NSDictionary *cfg = loadSkipConfig();
            // ✅ 只有坐标有效时才启用自动跳过
            CGFloat rx = [cfg[@"relX"] floatValue];
            CGFloat ry = [cfg[@"relY"] floatValue];
            BOOL validCoords = (rx > 0.001 && ry > 0.001 && rx <= 1.0 && ry <= 1.0);
            
            if (validCoords || (cfg[@"targetClass"].length && ![cfg[@"selectorName"] isEqualToString:@"__coordinate_skip__"])) {
                showToast(@"🚀 AdInspector v7.24\n自动跳过已就绪");
                // ✅ 延迟更久，等广告 UI 完全渲染
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    performAutoSkip();
                });
            } else {
                if (cfg) {
                    NSLog(@"[AdInspector] Config exists but coords invalid, clearing");
                    clearSkipConfig();
                }
                showToast(@"👁️ AdInspector v7.24\n右边缘左滑=学习\n三指双击=清除配置");
            }
        } @catch (NSException *e) {
            NSLog(@"[AdInspector] ❌ v7.24 FATAL: %@", e.reason);
        }
    });
}
