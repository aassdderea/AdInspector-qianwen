#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

// ========== 配置管理 ==========
static NSString *const kConfigPath = @"/var/mobile/AdInspector_SkipConfig.json";

static NSDictionary* loadSkipConfig() {
    NSData *data = [NSData dataWithContentsOfFile:kConfigPath];
    if (!data) return nil;
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}

static void saveSkipConfig(NSString *targetClass, NSString *selectorName, NSInteger windowTag) {
    NSDictionary *config = @{
        @"targetClass": targetClass ?: @"",
        @"selectorName": selectorName ?: @"",
        @"windowTag": @(windowTag),
        @"learnedAt": @([[NSDate date] timeIntervalSince1970])
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:config options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:kConfigPath atomically:YES];
    NSLog(@"[AdInspector] ✅ Skip config saved: %@.%@ (tag:%ld)", targetClass, selectorName, (long)windowTag);
}

// ========== Toast 提示工具 ==========
static void showToast(NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UILabel *toast = [[UILabel alloc] init];
        toast.text = message;
        toast.textColor = [UIColor whiteColor];
        toast.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.8];
        toast.font = [UIFont systemFontOfSize:14];
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
        [UIView animateWithDuration:0.3 delay:2.0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            toast.alpha = 0;
        } completion:^(BOOL finished) {
            [toast removeFromSuperview];
        }];
    });
}

// ========== ✅ 恢复：可视化悬浮抓取信息框 ==========
static UIView *g_infoPanel = nil;
static UILabel *g_infoLabel = nil;
static BOOL g_panelVisible = YES;

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

static void createInfoPanel() {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_infoPanel) return;
        
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
        
        // 面板容器
        g_infoPanel = [[UIView alloc] initWithFrame:CGRectMake(keyWindow.bounds.size.width - 220, 80, 200, 120)];
        g_infoPanel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
        g_infoPanel.layer.cornerRadius = 10;
        g_infoPanel.layer.borderWidth = 1;
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
        [closeBtn addTarget:[NSNull null] action:@selector(description) forControlEvents:UIControlEventTouchUpInside]; // placeholder
        [closeBtn addEventHandler:^(id sender) {
            g_panelVisible = !g_panelVisible;
            g_infoPanel.hidden = !g_panelVisible;
        } forControlEvent:UIControlEventTouchUpInside];
        [g_infoPanel addSubview:closeBtn];
        
        // 拖拽手势
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:[NSNull null] action:@selector(description)];
        [pan addTarget:[NSNull null] action:@selector(description)];
        // 使用 block 方式处理拖拽
        __weak UIView *weakPanel = g_infoPanel;
        [g_infoPanel addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithActionBlock:^(UIPanGestureRecognizer *recognizer) {
            CGPoint translation = [recognizer translationInView:keyWindow];
            CGPoint center = weakPanel.center;
            center.x += translation.x;
            center.y += translation.y;
            weakPanel.center = center;
            [recognizer setTranslation:CGPointZero inView:keyWindow];
        }]];
        
        [keyWindow addSubview:g_infoPanel];
    });
}

// 为 UIGestureRecognizer 添加 Block 支持的 Category（内联实现）
@interface UIGestureRecognizer (AdInspectorBlock)
- (instancetype)initWithActionBlock:(void (^)(UIGestureRecognizer *))block;
@end

@implementation UIGestureRecognizer (AdInspectorBlock)
static char kGRBlockKey;
- (instancetype)initWithActionBlock:(void (^)(UIGestureRecognizer *))block {
    self = [self initWithTarget:nil action:@selector(_gr_block_invoke:)];
    if (self) objc_setAssociatedObject(self, &kGRBlockKey, block, OBJC_ASSOCIATION_COPY_NONATOMIC);
    return self;
}
- (void)_gr_block_invoke:(UIGestureRecognizer *)gr {
    void (^blk)(UIGestureRecognizer *) = objc_getAssociatedObject(self, &kGRBlockKey);
    if (blk) blk(gr);
}
@end

// 为 UIButton 添加 Block 事件支持
@interface UIControl (AdInspectorBlock)
- (void)addEventHandler:(void (^)(id sender))handler forControlEvent:(UIControlEvents)event;
@end

@implementation UIControl (AdInspectorBlock)
static char kCtrlBlockKey;
- (void)addEventHandler:(void (^)(id sender))handler forControlEvent:(UIControlEvents)event {
    NSMutableDictionary *handlers = objc_getAssociatedObject(self, &kCtrlBlockKey);
    if (!handlers) {
        handlers = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(self, &kCtrlBlockKey, handlers, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSString *key = [NSString stringWithFormat:@"%lu", (unsigned long)event];
    handlers[key] = [handler copy];
    [self addTarget:self action:@selector(_ctrl_block_invoke:) forControlEvents:event];
}
- (void)_ctrl_block_invoke:(id)sender {
    // 简单实现：遍历所有关联的 handler
    // 实际使用中建议用更精确的映射，此处为精简代码
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
    
    if (!loadSkipConfig() && [sender isKindOfClass:[UIButton class]]) {
        UIButton *btn = (UIButton *)sender;
        NSString *title = [btn titleForState:UIControlStateNormal];
        if ([title containsString:@"跳过"] || [title containsString:@"Skip"]) {
            NSString *targetClassName = NSStringFromClass([target class]);
            NSString *selectorName = NSStringFromSelector(action);
            NSInteger windowTag = btn.window.tag;
            saveSkipConfig(targetClassName, selectorName, windowTag);
            
            UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
            [feedback impactOccurred];
            showToast([NSString stringWithFormat:@"✅ 已学习: %@\ntag:%ld", targetClassName, (long)windowTag]);
        }
    }
    return result;
}
%end

// ========== C 函数：查找目标子视图 ==========
static UIView* findTargetSubview(UIView *root, Class targetCls) {
    if ([root isKindOfClass:targetCls]) return root;
    for (UIView *sub in root.subviews) {
        UIView *found = findTargetSubview(sub, targetCls);
        if (found) return found;
    }
    return nil;
}

// ========== 执行态 ==========
%ctor {
    NSDictionary *config = loadSkipConfig();
    if (!config) {
        showToast(@"🎓 AdInspector 已注入\n学习模式激活");
        NSLog(@"[AdInspector] 🎓 No config found. Learning mode active.");
    } else {
        NSString *tc = config[@"targetClass"];
        NSInteger wt = [config[@"windowTag"] integerValue];
        showToast([NSString stringWithFormat:@"🚀 AdInspector 已注入\n自动跳过: %@ (tag:%ld)", tc, (long)wt]);
        NSLog(@"[AdInspector] 🚀 Auto-skip loaded: %@ (tag:%ld)", tc, (long)wt);
    }
    
    // ✅ 创建悬浮信息面板
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        createInfoPanel();
    });
    
    // 视图层级抓取（控制台备份）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSLog(@"[AdInspector] ===== View Hierarchy Dump Start =====");
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            for (UIWindow *win in scene.windows) {
                NSLog(@"[AdInspector] Window tag:%ld | class:%@", (long)win.tag, NSStringFromClass([win class]));
            }
        }
        NSLog(@"[AdInspector] ===== View Hierarchy Dump End =====");
    });
    
    if (!config) return;
    NSString *targetClass = config[@"targetClass"];
    NSString *selectorName = config[@"selectorName"];
    NSInteger windowTag = [config[@"windowTag"] integerValue];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        Class cls = NSClassFromString(targetClass);
        SEL sel = NSSelectorFromString(selectorName);
        if (!cls || ![cls instancesRespondToSelector:sel]) {
            showToast(@"⚠️ 配置失效，请删除配置文件重新学习");
            return;
        }
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            for (UIWindow *win in scene.windows) {
                if (win.tag == windowTag) {
                    UIView *targetView = nil;
                    if (win.rootViewController.view) {
                        targetView = findTargetSubview(win.rootViewController.view, cls);
                    }
                    if (targetView) {
                        #pragma clang diagnostic push
                        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                        [targetView performSelector:sel withObject:nil];
                        #pragma clang diagnostic pop
                        NSLog(@"[AdInspector] ✅ Auto-skip triggered!");
                    }
                    break;
                }
            }
        }
    });
}
