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

// ========== 视图层级抓取（调试用）==========
static void dumpViewHierarchy(UIView *view, int indent) {
    NSMutableString *prefix = [NSMutableString string];
    for (int i = 0; i < indent; i++) [prefix appendString:@"  "];
    
    NSString *className = NSStringFromClass([view class]);
    CGRect f = view.frame;
    NSLog(@"[AdInspector] %@%@ | tag:%ld | (%.0f,%.0f,%.0f,%.0f)", 
          prefix, className, (long)view.tag, f.origin.x, f.origin.y, f.size.width, f.size.height);
    
    for (UIView *sub in view.subviews) {
        dumpViewHierarchy(sub, indent + 1);
    }
}

// ========== 学习态：全局拦截按钮点击 ==========
%hook UIApplication
- (BOOL)sendAction:(SEL)action to:(id)target from:(id)sender forEvent:(UIEvent *)event {
    BOOL result = %orig;
    
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
            
            // ✅ 学习成功 Toast 反馈
            NSString *msg = [NSString stringWithFormat:@"✅ 已学习: %@\ntag:%ld", targetClassName, (long)windowTag];
            showToast(msg);
        }
    }
    return result;
}
%end

// ========== 执行态：自动跳过 ==========
%ctor {
    // ✅ 注入即显示状态 Toast
    NSDictionary *config = loadSkipConfig();
    if (!config) {
        showToast(@"🎓 AdInspector 已注入\n学习模式激活");
        NSLog(@"[AdInspector] 🎓 No config found. Learning mode active.");
    } else {
        NSString *tc = config[@"targetClass"];
        NSInteger wt = [config[@"windowTag"] integerValue];
        NSString *msg = [NSString stringWithFormat:@"🚀 AdInspector 已注入\n自动跳过: %@ (tag:%ld)", tc, (long)wt];
        showToast(msg);
        NSLog(@"[AdInspector] 🚀 Auto-skip loaded: %@ (tag:%ld)", tc, (long)wt);
    }
    
    // ✅ 延迟抓取并打印完整视图层级到控制台
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSLog(@"[AdInspector] ===== View Hierarchy Dump Start =====");
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            for (UIWindow *win in scene.windows) {
                NSLog(@"[AdInspector] Window tag:%ld | class:%@", (long)win.tag, NSStringFromClass([win class]));
                if (win.rootViewController.view) {
                    dumpViewHierarchy(win.rootViewController.view, 1);
                }
            }
        }
        NSLog(@"[AdInspector] ===== View Hierarchy Dump End =====");
    });
    
    // 自动跳过逻辑
    if (!config) return;
    
    NSString *targetClass = config[@"targetClass"];
    NSString *selectorName = config[@"selectorName"];
    NSInteger windowTag = [config[@"windowTag"] integerValue];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        Class cls = NSClassFromString(targetClass);
        SEL sel = NSSelectorFromString(selectorName);
        
        if (!cls || ![cls instancesRespondToSelector:sel]) {
            showToast(@"⚠️ 配置失效，请删除配置文件重新学习");
            NSLog(@"[AdInspector] ⚠️ Learned config invalid. Delete %@ to relearn.", kConfigPath);
            return;
        }
        
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            for (UIWindow *win in scene.windows) {
                if (win.tag == windowTag) {
                    __block UIView *targetView = nil;
                    // 使用 C 函数查找，避免 Block 递归编译问题
                    extern UIView* findTargetSubview(UIView *, Class);
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

// ✅ C 函数定义放在 %ctor 外部，确保全局可见
static UIView* findTargetSubview(UIView *root, Class targetCls) {
    if ([root isKindOfClass:targetCls]) return root;
    for (UIView *sub in root.subviews) {
        UIView *found = findTargetSubview(sub, targetCls);
        if (found) return found;
    }
    return nil;
}
