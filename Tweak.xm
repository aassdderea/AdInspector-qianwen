#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

// ========== 配置管理 ==========
static NSString *const kConfigPath = @"/var/mobile/AdInspector_SkipConfig.json";

static NSDictionary* loadSkipConfig() {
    NSData *data = [NSData dataWithContentsOfFile:kConfigPath];
    if (!data) return nil;
    NSError *error = nil;
    NSDictionary *result = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error) {
        NSLog(@"[AdInspector] ⚠️ Config parse error: %@", error);
        return nil;
    }
    return result;
}

static void saveSkipConfig(NSString *targetClass, NSString *selectorName) {
    // ✅ 不再保存 windowTag，改用类名+方法名作为唯一标识
    NSDictionary *config = @{
        @"targetClass": targetClass ?: @"",
        @"selectorName": selectorName ?: @"",
        @"learnedAt": @([[NSDate date] timeIntervalSince1970])
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:config options:NSJSONWritingPrettyPrinted error:nil];
    BOOL ok = [data writeToFile:kConfigPath atomically:YES];
    NSLog(@"[AdInspector] ✅ Skip config saved: %@.%@ (write:%d)", targetClass, selectorName, ok);
}

// ========== Toast 提示工具 ==========
static void showToast(NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UILabel *toast = [[UILabel alloc] init];
        toast.text = message;
        toast.textColor = [UIColor whiteColor];
        toast.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
        toast.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        toast.textAlignment = NSTextAlignmentCenter;
        toast.layer.cornerRadius = 8;
        toast.clipsToBounds = YES;
        [toast sizeToFit];
        CGRect frame = toast.frame;
        frame.size.width += 32;
        frame.size.height += 16;
        toast.frame = frame;
        
        UIWindow *keyWindow = nil;
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in scene.windows) {
                    if (w.isKeyWindow) { keyWindow = w; break; }
                }
            }
            if (keyWindow) break;
        }
        if (!keyWindow) return;
        toast.center = CGPointMake(keyWindow.bounds.size.width / 2, keyWindow.bounds.size.height - 120);
        [keyWindow addSubview:toast];
        [UIView animateWithDuration:0.3 delay:2.5 options:UIViewAnimationOptionCurveEaseOut animations:^{
            toast.alpha = 0;
        } completion:^(BOOL finished) {
            [toast removeFromSuperview];
        }];
    });
}

// ========== ✅ 独立最高层级 Window + 悬浮面板 ==========
static UIWindow *g_overlayWindow = nil;
static UIView *g_infoPanel = nil;
static UILabel *g_infoLabel = nil;
static BOOL g_panelVisible = YES;
static CGPoint g_panStartCenter = CGPointZero;

@interface AdInspectorPanelDelegate : NSObject
@end

@implementation AdInspectorPanelDelegate
- (void)panGesture:(UIPanGestureRecognizer *)recognizer {
    if (!g_infoPanel || !g_overlayWindow) return;
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        g_panStartCenter = g_infoPanel.center;
    }
    CGPoint translation = [recognizer translationInView:g_overlayWindow];
    g_infoPanel.center = CGPointMake(g_panStartCenter.x + translation.x, g_panStartCenter.y + translation.y);
}
- (void)closeButtonTapped {
    g_panelVisible = !g_panelVisible;
    g_infoPanel.hidden = !g_panelVisible;
}
@end

static AdInspectorPanelDelegate *g_panelDelegate = nil;

static void updateInfoPanel(NSString *text) {
    if (!g_panelVisible || !g_infoLabel) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        g_infoLabel.text = text;
        [g_infoLabel sizeToFit];
        CGRect f = g_infoLabel.frame;
        f.size.width = MIN(f.size.width + 20, 260);
        f.size.height += 16;
        g_infoLabel.frame = f;
        g_infoPanel.frame = CGRectMake(g_infoPanel.frame.origin.x, g_infoPanel.frame.origin.y, f.size.width, f.size.height);
    });
}

static void createOverlayWindowAndPanel() {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_overlayWindow) return;
        
        // ✅ 创建独立 Window，设置最高层级，永远不会被广告遮挡
        UIWindowScene *activeScene = nil;
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                activeScene = scene;
                break;
            }
        }
        if (!activeScene) {
            showToast(@"⚠️ 未找到活跃Scene，面板创建失败");
            return;
        }
        
        g_overlayWindow = [[UIWindow alloc] initWithWindowScene:activeScene];
        g_overlayWindow.windowLevel = UIWindowLevelAlert + 100; // ✅ 高于所有广告和弹窗
        g_overlayWindow.backgroundColor = [UIColor clearColor];
        g_overlayWindow.userInteractionEnabled = YES;
        g_overlayWindow.hidden = NO;
        
        g_panelDelegate = [[AdInspectorPanelDelegate alloc] init];
        
        // 面板容器
        CGFloat panelW = 200, panelH = 120;
        CGFloat screenW = activeScene.coordinateSpace.bounds.size.width;
        g_infoPanel = [[UIView alloc] initWithFrame:CGRectMake(screenW - panelW - 10, 80, panelW, panelH)];
        g_infoPanel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.88];
        g_infoPanel.layer.cornerRadius = 10;
        g_infoPanel.layer.borderWidth = 1.5;
        g_infoPanel.layer.borderColor = [UIColor systemGreenColor].CGColor;
        g_infoPanel.userInteractionEnabled = YES;
        
        // 信息标签
        g_infoLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 8, 180, 100)];
        g_infoLabel.textColor = [UIColor systemGreenColor];
        g_infoLabel.font = [UIFont fontWithName:@"Menlo" size:11];
        g_infoLabel.numberOfLines = 0;
        g_infoLabel.text = @"🔍 AdInspector\n等待触摸...";
        [g_infoPanel addSubview:g_infoLabel];
        
        // 关闭按钮
        UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        closeBtn.frame = CGRectMake(g_infoPanel.bounds.size.width - 28, 2, 26, 26);
        [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
        [closeBtn setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
        closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        [closeBtn addTarget:g_panelDelegate action:@selector(closeButtonTapped) forControlEvents:UIControlEventTouchUpInside];
        [g_infoPanel addSubview:closeBtn];
        
        // 拖拽手势
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:g_panelDelegate action:@selector(panGesture:)];
        [g_infoPanel addGestureRecognizer:pan];
        
        [g_overlayWindow addSubview:g_infoPanel];
        
        // ✅ 让 overlay window 不拦截非面板区域的触摸事件
        // 通过重写 hitTest 实现（此处用简化方案：面板外区域 userInteractionEnabled=NO 由透明背景自然穿透）
        NSLog(@"[AdInspector] ✅ Overlay window created at level %.0f", g_overlayWindow.windowLevel);
    });
}

// 重写 overlay window 的 hitTest 使面板外区域可穿透
@interface AdInspectorOverlayWindow : UIWindow
@end
@implementation AdInspectorOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    // 只有点到面板时才拦截事件，否则穿透到下层
    if (hitView == g_infoPanel || [g_infoPanel isDescendantOfView:hitView]) {
        return hitView;
    }
    // 检查是否点到了面板的子视图
    CGPoint panelPoint = [g_infoPanel convertPoint:point fromView:self];
    if ([g_infoPanel pointInside:panelPoint withEvent:event]) {
        return hitView;
    }
    return nil; // ✅ 穿透
}
@end

// ========== 学习态：全局拦截按钮点击 ==========
%hook UIApplication
- (BOOL)sendAction:(SEL)action to:(id)target from:(id)sender forEvent:(UIEvent *)event {
    BOOL result = %orig;
    
    // ✅ 更新悬浮面板信息
    if (sender && [sender isKindOfClass:[UIView class]]) {
        UIView *v = (UIView *)sender;
        NSString *info = [NSString stringWithFormat:@"🎯 %@\nSel: %@\nTag: %ld\nWin: %ld\nFrame: %@",
                          NSStringFromClass([target class]),
                          NSStringFromSelector(action),
                          (long)v.tag,
                          (long)v.window.tag,
                          NSStringFromCGRect(v.frame)];
        updateInfoPanel(info);
    }
    
    // ✅ 学习态：仅在学习模式下拦截
    if (!loadSkipConfig() && [sender isKindOfClass:[UIButton class]]) {
        UIButton *btn = (UIButton *)sender;
        NSString *title = [btn titleForState:UIControlStateNormal];
        if ([title containsString:@"跳过"] || [title containsString:@"Skip"]) {
            NSString *targetClassName = NSStringFromClass([target class]);
            NSString *selectorName = NSStringFromSelector(action);
            
            // ✅ 不再保存 windowTag
            saveSkipConfig(targetClassName, selectorName);
            
            UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
            [feedback impactOccurred];
            
            NSString *msg = [NSString stringWithFormat:@"✅ 已学习:\n%@.%@", targetClassName, selectorName];
            showToast(msg);
            updateInfoPanel([NSString stringWithFormat:@"✅ LEARNED\n%@.%@\n重启生效", targetClassName, selectorName]);
        }
    }
    return result;
}
%end

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

// ========== ✅ 执行态：遍历所有 Window 查找并触发跳过 ==========
static void performAutoSkip() {
    NSDictionary *config = loadSkipConfig();
    if (!config) return;
    
    NSString *targetClassName = config[@"targetClass"];
    NSString *selectorName = config[@"selectorName"];
    
    if (!targetClassName.length || !selectorName.length) {
        showToast(@"⚠️ 配置文件内容为空");
        return;
    }
    
    Class cls = NSClassFromString(targetClassName);
    SEL sel = NSSelectorFromString(selectorName);
    
    if (!cls) {
        showToast([NSString stringWithFormat:@"⚠️ 类不存在: %@", targetClassName]);
        NSLog(@"[AdInspector] ⚠️ Class not found: %@", targetClassName);
        return;
    }
    if (![cls instancesRespondToSelector:sel]) {
        showToast([NSString stringWithFormat:@"⚠️ 方法不存在: %@", selectorName]);
        NSLog(@"[AdInspector] ⚠️ Selector not found: %@", selectorName);
        return;
    }
    
    // ✅ 遍历所有 Scene 的所有 Window，不再依赖固定 tag
    BOOL triggered = NO;
    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
        for (UIWindow *win in scene.windows) {
            if (win == g_overlayWindow) continue; // 跳过自己的 overlay
            if (!win.rootViewController.view) continue;
            
            UIView *targetView = findTargetSubview(win.rootViewController.view, cls);
            if (targetView && [targetView respondsToSelector:sel]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [targetView performSelector:sel withObject:nil];
                #pragma clang diagnostic pop
                
                triggered = YES;
                NSString *msg = [NSString stringWithFormat:@"🚀 自动跳过成功!\n%@.%@\nWin:%ld", 
                                 targetClassName, selectorName, (long)win.tag];
                showToast(msg);
                NSLog(@"[AdInspector] ✅ Auto-skip triggered on window tag:%ld", (long)win.tag);
                break;
            }
        }
        if (triggered) break;
    }
    
    if (!triggered) {
        // 可能广告还没加载出来，延迟重试一次
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            BOOL retryTriggered = NO;
            for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                for (UIWindow *win in scene.windows) {
                    if (win == g_overlayWindow) continue;
                    if (!win.rootViewController.view) continue;
                    UIView *targetView = findTargetSubview(win.rootViewController.view, cls);
                    if (targetView && [targetView respondsToSelector:sel]) {
                        #pragma clang diagnostic push
                        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                        [targetView performSelector:sel withObject:nil];
                        #pragma clang diagnostic pop
                        retryTriggered = YES;
                        showToast([NSString stringWithFormat:@"🚀 延迟跳过成功!"]);
                        NSLog(@"[AdInspector] ✅ Delayed auto-skip triggered on window tag:%ld", (long)win.tag);
                        break;
                    }
                }
                if (retryTriggered) break;
            }
            if (!retryTriggered) {
                showToast(@"ℹ️ 未找到跳过按钮\n可能广告尚未加载");
                NSLog(@"[AdInspector] ℹ️ No skip button found after retry.");
            }
        });
    }
}

// ========== 入口 ==========
%ctor {
    NSDictionary *config = loadSkipConfig();
    BOOL isLearningMode = (config == nil);
    
    if (isLearningMode) {
        showToast(@"🎓 AdInspector 已注入\n【学习模式】\n请点击广告跳过按钮");
        NSLog(@"[AdInspector] 🎓 Learning mode active.");
    } else {
        NSString *tc = config[@"targetClass"];
        NSString *sn = config[@"selectorName"];
        showToast([NSString stringWithFormat:@"🚀 AdInspector 已注入\n【自动模式】\n%@.%@", tc, sn]);
        NSLog(@"[AdInspector] 🚀 Auto mode: %@.%@", tc, sn);
    }
    
    // ✅ 创建独立最高层级面板
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        createOverlayWindowAndPanel();
    });
    
    // ✅ 自动跳过（带延迟重试）
    if (!isLearningMode) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            performAutoSkip();
        });
    }
    
    // 控制台层级抓取备份
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSLog(@"[AdInspector] ===== View Hierarchy Dump =====");
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            for (UIWindow *win in scene.windows) {
                NSLog(@"[AdInspector] Window tag:%ld | class:%@ | level:%.0f", 
                      (long)win.tag, NSStringFromClass([win class]), win.windowLevel);
            }
        }
        NSLog(@"[AdInspector] ===== End Dump =====");
    });
}
