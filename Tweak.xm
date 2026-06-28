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
                tw.windowLevel = UIWindowLevelAlert + 1000;
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
            [NSObject cancelPreviousPerformRequestsWithTarget:tw selector:@selector(setHidden:) object:@YES];
            [tw performSelector:@selector(setHidden:) withObject:@YES afterDelay:3.0];
        } @catch (NSException *e) {}
    });
}

// ========== 文本提取 ==========
static NSString* extractTextRecursive(UIView *v, NSInteger depth) {
    if (depth <= 0 || !v) return @"";
    NSMutableString *s = [NSMutableString string];
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)v;
        if (l.text) [s appendString:l.text];
    } else if ([v isKindOfClass:[UIButton class]]) {
        UIButton *b = (UIButton *)v;
        NSString *t = [b titleForState:UIControlStateNormal];
        if (t) [s appendString:t];
    }
    for (UIView *sub in v.subviews) {
        NSString *st = extractTextRecursive(sub, depth - 1);
        if (st.length > 0) [s appendString:st];
    }
    return s;
}

static BOOL isSkipText(NSString *text) {
    if (!text.length) return NO;
    NSString *l = [text lowercaseString];
    return [l containsString:@"跳过"] || [l containsString:@"skip"] ||
           [l containsString:@"close"] || [l containsString:@"关闭"] ||
           [l containsString:@"✕"] || [l containsString:@"×"];
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
        
        // 优先使用坐标点击
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
        
        // 兜底：类名+选择器
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

// ========== 学习面板 ==========
static void showLearnPanel() {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIWindow *lw = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
            lw.windowLevel = UIWindowLevelAlert + 2000;
            lw.backgroundColor = [[UIColor redColor] colorWithAlphaComponent:0.15];
            
            UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(20, 60, lw.bounds.size.width - 40, 60)];
            hint.text = @"🎯 学习模式\n请点击广告上的【跳过】按钮\n点击空白处取消";
            hint.numberOfLines = 0;
            hint.textColor = [UIColor whiteColor];
            hint.font = [UIFont boldSystemFontOfSize:16];
            hint.textAlignment = NSTextAlignmentCenter;
            hint.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.7];
            hint.layer.cornerRadius = 12;
            hint.clipsToBounds = YES;
            [lw addSubview:hint];
            
            UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithActionBlock:^(UITapGestureRecognizer *g) {
                CGPoint p = [g locationInView:lw];
                // 点击提示区域或顶部120pt内视为取消
                if (p.y < 130) {
                    lw.hidden = YES;
                    showToast(@"❌ 学习已取消");
                    return;
                }
                
                // 获取真实窗口中的 hitView
                UIWindow *realWindow = nil;
                for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                    for (UIWindow *w in scene.windows) {
                        if (w != lw && w.isKeyWindow) { realWindow = w; break; }
                    }
                }
                
                UIView *hit = [realWindow hitTest:p withEvent:nil];
                if (!hit) {
                    showToast(@"❌ 未命中视图，请重试");
                    return;
                }
                
                // 记录相对坐标
                CGFloat relX = p.x / lw.bounds.size.width;
                CGFloat relY = p.y / lw.bounds.size.height;
                
                // 尝试提取类名和手势
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
                
                lw.hidden = YES;
                UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
                [fb impactOccurred];
                showToast([NSString stringWithFormat:@"✅ 学习成功!\n类: %@\n坐标: (%.2f%%, %.2f%%)", 
                          tc, relX * 100, relY * 100]);
            }];
            [lw addGestureRecognizer:tap];
            
            [lw makeKeyAndVisible];
            UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
            [fb impactOccurred];
        } @catch (NSException *e) {
            showToast([NSString stringWithFormat:@"❌ 学习面板异常: %@", e.reason]);
        }
    });
}

// ========== 边缘滑动手势 ==========
static void installEdgeSwipe() {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                for (UIWindow *win in scene.windows) {
                    if (win.tag == 9527) continue; // 避免重复安装
                    win.tag = 9527;
                    
                    UIScreenEdgePanGestureRecognizer *edge = [[UIScreenEdgePanGestureRecognizer alloc]
                        initWithActionBlock:^(UIScreenEdgePanGestureRecognizer *g) {
                            if (g.state == UIGestureRecognizerStateRecognized) {
                                showLearnPanel();
                            }
                        }];
                    edge.edges = UIRectEdgeRight;
                    edge.cancelsTouchesInView = NO;
                    [win addGestureRecognizer:edge];
                }
            }
        } @catch (NSException *e) {}
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
            NSLog(@"[AdInspector] ✅ v7.19 init...");
            installEdgeSwipe();
            
            NSDictionary *cfg = loadSkipConfig();
            if (cfg && (cfg[@"relX"] || cfg[@"targetClass"])) {
                showToast(@"🚀 AdInspector v7.19\n自动跳过已就绪");
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    performAutoSkip();
                });
            } else {
                showToast(@"👁️ AdInspector v7.19\n右边缘左滑=学习\n三指双击=清除配置");
            }
        } @catch (NSException *e) {
            NSLog(@"[AdInspector] ❌ v7.19 FATAL: %@", e.reason);
        }
    });
}
