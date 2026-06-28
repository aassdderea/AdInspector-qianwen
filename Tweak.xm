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
                tw.windowLevel = UIWindowLevelAlert + 3000; // ⬆️ 提高到最高层级
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
            CGRect r = [msg boundingRectWithSize:CGSizeMake(mw, CGFLOAT_MAX)
                                         options:NSStringDrawingUsesLineFragmentOrigin
                                      attributes:@{NSFontAttributeName: tl.font} context:nil];
            tl.frame = CGRectMake(0, 0, r.size.width + 30, r.size.height + 20);
            tl.center = CGPointMake(tw.center.x, tw.bounds.size.height - 150);
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

// ========== 自动跳过执行 ==========
static void performAutoSkip() {
    @try {
        NSDictionary *cfg = loadSkipConfig();
        if (!cfg) return;
        NSString *tc = cfg[@"targetClass"];
        NSString *sn = cfg[@"selectorName"];
        CGFloat rx = [cfg[@"relX"] floatValue];
        CGFloat ry = [cfg[@"relY"] floatValue];
        
        if (rx > 0 && ry > 0) {
            for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                for (UIWindow *win in scene.windows) {
                    if (!win.isKeyWindow) continue;
                    CGPoint abs = CGPointMake(rx * win.bounds.size.width, ry * win.bounds.size.height);
                    UIView *hit = [win hitTest:abs withEvent:nil];
                    if (hit) {
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
            }
        }
        
        if (tc.length && sn.length) {
            Class cls = NSClassFromString(tc);
            SEL sel = NSSelectorFromString(sn);
            if (cls) {
                for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
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
}

// ========== 动态类创建辅助宏 ==========
#define DYNAMIC_CLASS(name, methodSel, blockImpl) \
    static Class name##Class = nil; \
    static dispatch_once_t name##Once; \
    dispatch_once(&name##Once, ^{ \
        name##Class = objc_allocateClassPair([NSObject class], #name, 0); \
        class_addMethod(name##Class, methodSel, imp_implementationWithBlock(blockImpl), "v@:@"); \
        objc_registerClassPair(name##Class); \
    })

// ========== 显示学习面板 ==========
static void showLearnPanel() {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIWindow *lw = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
            lw.windowLevel = UIWindowLevelAlert + 2000;
            lw.backgroundColor = [[UIColor redColor] colorWithAlphaComponent:0.15];
            
            // 提示标签
            UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(20, 60, lw.bounds.size.width - 40, 60)];
            hint.text = @"🎯 学习模式\n请点击广告【跳过】按钮";
            hint.numberOfLines = 0;
            hint.textColor = [UIColor whiteColor];
            hint.font = [UIFont boldSystemFontOfSize:16];
            hint.textAlignment = NSTextAlignmentCenter;
            hint.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.7];
            hint.layer.cornerRadius = 12;
            hint.clipsToBounds = YES;
            [lw addSubview:hint];
            
            // ✅ 明确的取消按钮（不再用坐标判断）
            UIButton *cancelBtn = [UIButton buttonWithType:UIButtonTypeSystem];
            cancelBtn.frame = CGRectMake(lw.bounds.size.width / 2 - 60, lw.bounds.size.height - 100, 120, 44);
            [cancelBtn setTitle:@"❌ 取消学习" forState:UIControlStateNormal];
            [cancelBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            cancelBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
            cancelBtn.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.7];
            cancelBtn.layer.cornerRadius = 22;
            [lw addSubview:cancelBtn];
            
            // 动态创建 LearnHandler
            DYNAMIC_CLASS(AILearnHandler, @selector(handleTap:), ^(id self, UITapGestureRecognizer *g) {
                UIWindow *window = objc_getAssociatedObject(self, "lw");
                UIButton *cBtn = objc_getAssociatedObject(self, "cancelBtn");
                if (!window) return;
                
                CGPoint p = [g locationInView:window];
                
                // ✅ 只有点击取消按钮才取消
                if (CGRectContainsPoint(cBtn.frame, p)) {
                    window.hidden = YES;
                    showToast(@"❌ 学习已取消");
                    return;
                }
                
                // 点击提示标签区域忽略
                UIView *hintView = objc_getAssociatedObject(self, "hintView");
                if (hintView && CGRectContainsPoint(hintView.frame, p)) {
                    return;
                }
                
                // ✅ 关键：暂时隐藏学习面板，让 hitTest 穿透到真实广告视图
                window.hidden = YES;
                
                UIWindow *realWindow = nil;
                for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                    for (UIWindow *w in scene.windows) {
                        if (w != window && w.isKeyWindow) { realWindow = w; break; }
                    }
                }
                
                UIView *hit = [realWindow hitTest:p withEvent:nil];
                
                if (!hit) {
                    window.hidden = NO; // 恢复面板
                    showToast(@"❌ 未命中视图，请重试");
                    return;
                }
                
                CGFloat relX = p.x / window.bounds.size.width;
                CGFloat relY = p.y / window.bounds.size.height;
                
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
                
                // 学习成功，不再恢复面板
                UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
                [fb impactOccurred];
                showToast([NSString stringWithFormat:@"✅ 学习成功!\n类: %@\n坐标: (%.2f%%, %.2f%%)", 
                          tc, relX * 100, relY * 100]);
            });
            
            id handler = [[AILearnHandlerClass alloc] init];
            objc_setAssociatedObject(handler, "lw", lw, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(handler, "cancelBtn", cancelBtn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(handler, "hintView", hint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            
            UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:handler action:@selector(handleTap:)];
            tap.cancelsTouchesInView = NO;
            [lw addGestureRecognizer:tap];
            
            // 取消按钮事件
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

// ========== 安装边缘手势 ==========
static void installEdgeSwipe() {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            DYNAMIC_CLASS(AIEdgeHandler, @selector(handleEdge:), ^(id self, UIScreenEdgePanGestureRecognizer *g) {
                if (g.state == UIGestureRecognizerStateRecognized) {
                    showLearnPanel();
                }
            });
            
            for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
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
            NSLog(@"[AdInspector] ✅ v7.23 init...");
            installEdgeSwipe();
            
            NSDictionary *cfg = loadSkipConfig();
            if (cfg && (cfg[@"relX"] || cfg[@"targetClass"])) {
                showToast(@"🚀 AdInspector v7.23\n自动跳过已就绪");
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    performAutoSkip();
                });
            } else {
                showToast(@"👁️ AdInspector v7.23\n右边缘左滑=学习\n三指双击=清除配置");
            }
        } @catch (NSException *e) {
            NSLog(@"[AdInspector] ❌ v7.23 FATAL: %@", e.reason);
        }
    });
}
