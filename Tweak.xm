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

// ========== 学习态：全局拦截按钮点击 ==========
%hook UIApplication
- (BOOL)sendAction:(SEL)action to:(id)target from:(id)sender forEvent:(UIEvent *)event {
    BOOL result = %orig;
    
    // 仅在未学习时激活监听
    if (!loadSkipConfig() && [sender isKindOfClass:[UIButton class]]) {
        UIButton *btn = (UIButton *)sender;
        NSString *title = [btn titleForState:UIControlStateNormal];
        
        // 通过标题关键词识别跳过按钮（兼容"跳过 4"/"跳过"/"Skip"等）
        if ([title containsString:@"跳过"] || [title containsString:@"Skip"]) {
            NSString *targetClassName = NSStringFromClass([target class]);
            NSString *selectorName = NSStringFromSelector(action);
            
            // 向上查找广告 Window 的 tag
            NSInteger windowTag = 0;
            UIWindow *win = btn.window;
            while (win && ![win isKindOfClass:%c(BDNCSplashAdvertiseBaseWindow)]) {
                win = win.parentWindow; // iOS 15+ 可用，低版本需遍历 superview
            }
            if (win) windowTag = win.tag;
            
            saveSkipConfig(targetClassName, selectorName, windowTag);
            
            // 震动反馈提示学习成功
            UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
            [feedback impactOccurred];
        }
    }
    return result;
}
%end

// ========== 执行态：自动跳过 ==========
%ctor {
    NSDictionary *config = loadSkipConfig();
    if (!config) {
        NSLog(@"[AdInspector] 🎓 No config found. Learning mode active.");
        return;
    }
    
    NSString *targetClass = config[@"targetClass"];
    NSString *selectorName = config[@"selectorName"];
    NSInteger windowTag = [config[@"windowTag"] integerValue];
    
    NSLog(@"[AdInspector] 🚀 Auto-skip loaded: %@.%@ (tag:%ld)", targetClass, selectorName, (long)windowTag);
    
    // 延迟执行，等待广告 Window 创建
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        Class cls = NSClassFromString(targetClass);
        SEL sel = NSSelectorFromString(selectorName);
        
        if (!cls || ![cls instancesRespondToSelector:sel]) {
            NSLog(@"[AdInspector] ⚠️ Learned config invalid. Delete %@ to relearn.", kConfigPath);
            return;
        }
        
        // 通过 Window tag 精确定位广告实例
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            for (UIWindow *win in scene.windows) {
                if (win.tag == windowTag) {
                    // 递归查找目标 view 并触发
                    __block UIView *targetView = nil;
                    void (^findSubview)(UIView *) = ^(UIView *v) {
                        if ([v isKindOfClass:cls]) targetView = v;
                        for (UIView *sub in v.subviews) findSubview(sub);
                    };
                    findSubview(win.rootViewController.view);
                    
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
