#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#import <QuartzCore/QuartzCore.h>

// ============================================================
#pragma mark - 私有API前置声明 (消除隐式声明警告)
// ============================================================

@interface UIApplication (Private)
- (UIEvent *)_touchesEvent;
@end

// ============================================================
#pragma mark - 常量与宏定义
// ============================================================

static NSString *const kConfigFileName = @"AdInspector_SkipConfig.json";
static NSString *const kCoordinateSkipSelector = @"__coordinate_skip__";
static NSInteger const kMaxSearchDepth = 30;
static CGFloat const kLocalSearchRadius = 50.0;
static NSTimeInterval const kRetryDelay = 1.0;
static NSTimeInterval const kToastDuration = 3.0;
static NSTimeInterval const kAutoSkipInitialDelay = 4.0;

// Toast generation counter (修复O2: 并发Toast覆盖问题)
static NSUInteger sToastGeneration = 0;

// 安全字典取值宏
#define SAFE_STRING(dict, key) ((NSString *)[(dict) objectForKey:(key)])
#define SAFE_NUMBER(dict, key) ((NSNumber *)[(dict) objectForKey:(key)])

// ============================================================
#pragma mark - 配置管理 (Atomic + 容错)
// ============================================================

static NSString* getConfigPath() {
    @try {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        return [paths.firstObject stringByAppendingPathComponent:kConfigFileName];
    } @catch (NSException *e) {
        return [NSTemporaryDirectory() stringByAppendingPathComponent:kConfigFileName];
    }
}

static NSDictionary* loadSkipConfig() {
    @try {
        NSData *data = [NSData dataWithContentsOfFile:getConfigPath()];
        if (!data) return nil;
        NSDictionary *cfg = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        CGFloat rx = [SAFE_NUMBER(cfg, @"relX") floatValue];
        CGFloat ry = [SAFE_NUMBER(cfg, @"relY") floatValue];
        if (rx <= 0.001 || ry <= 0.001 || rx > 1.0 || ry > 1.0) {
            NSLog(@"[AdInspector] Invalid config coords (%f,%f), auto-clearing", rx, ry);
            [[NSFileManager defaultManager] removeItemAtPath:getConfigPath() error:nil];
            return nil;
        }
        return cfg;
    } @catch (NSException *e) {
        NSLog(@"[AdInspector] Config load error: %@", e.reason);
        return nil;
    }
}

static void saveSkipConfig(NSDictionary *config) {
    @try {
        NSString *path = getConfigPath();
        [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        NSData *data = [NSJSONSerialization dataWithJSONObject:config 
                                                       options:NSJSONWritingPrettyPrinted 
                                                         error:nil];
        [data writeToFile:path options:NSDataWritingAtomic error:nil];
    } @catch (NSException *e) {
        NSLog(@"[AdInspector] Config save error: %@", e.reason);
    }
}

static BOOL clearSkipConfig() {
    @try {
        return [[NSFileManager defaultManager] removeItemAtPath:getConfigPath() error:nil];
    } @catch (NSException *e) { return NO; }
}

// ============================================================
#pragma mark - Toast 反馈系统 (含generation防并发)
// ============================================================

static void showToast(NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            static UIWindow *tw = nil;
            static UILabel *tl = nil;
            
            CGRect screenBounds = [UIScreen mainScreen].bounds;
            if (screenBounds.size.width <= 0 || screenBounds.size.height <= 0) return;
            
            if (!tw) {
                tw = [[UIWindow alloc] initWithFrame:screenBounds];
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
            } else {
                tw.frame = screenBounds;
            }
            
            CGFloat mw = screenBounds.size.width - 40;
            if (mw <= 0) mw = 300;
            CGRect r = [msg boundingRectWithSize:CGSizeMake(mw, CGFLOAT_MAX)
                                         options:NSStringDrawingUsesLineFragmentOrigin
                                      attributes:@{NSFontAttributeName: tl.font} 
                                         context:nil];
            tl.frame = CGRectMake(0, 0, r.size.width + 30, r.size.height + 20);
            tl.center = CGPointMake(screenBounds.size.width / 2.0, screenBounds.size.height - 150);
            tl.text = msg;
            tw.hidden = NO;
            
            // ✅ 修复O2: generation counter防止快速连续Toast互相覆盖
            NSUInteger currentGen = ++sToastGeneration;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kToastDuration * NSEC_PER_SEC)), 
                           dispatch_get_main_queue(), ^{
                if (currentGen == sToastGeneration) {
                    tw.hidden = YES;
                }
            });
        } @catch (NSException *e) {
            NSLog(@"[AdInspector] Toast error: %@", e.reason);
        }
    });
}

// ============================================================
#pragma mark - 手势 Action 提取工具
// ============================================================

static NSArray<NSString*>* getGestureActions(UIGestureRecognizer *gr) {
    NSMutableArray *results = [NSMutableArray array];
    @try {
        id targets = [gr valueForKey:@"_targets"];
        if ([targets isKindOfClass:[NSArray class]]) {
            for (id ti in (NSArray *)targets) {
                id tgt = [ti valueForKey:@"_target"];
                id act = [ti valueForKey:@"_action"];
                SEL sel = NULL;
                if ([act isKindOfClass:[NSValue class]]) sel = (SEL)[(NSValue *)act pointerValue];
                else if ([act isKindOfClass:[NSString class]]) sel = NSSelectorFromString((NSString *)act);
                if (tgt && sel) {
                    [results addObject:[NSString stringWithFormat:@"%@ -> %@", 
                                        tgt, NSStringFromSelector(sel)]];
                }
            }
        }
    } @catch (NSException *e) {}
    return results;
}

// ============================================================
#pragma mark - 三层递进式广告抓取引擎
// ============================================================

typedef struct {
    UIView *hitView;
    NSString *selectorName;
    BOOL found;
} AISkipTarget;

// ✅ 修复O1: 局部搜索性能优化 (预转换坐标系)
static UIView* localSubviewSearch(UIView *root, CGPoint screenTouchPoint, CGFloat radius) {
    __block UIView *bestMatch = nil;
    __block CGFloat bestDist = CGFLOAT_MAX;
    
    // 将触摸点预先转换到root坐标系，避免每个subview重复convert
    CGPoint localTouchPoint = [root.superview ? root.superview : root convertPoint:screenTouchPoint fromView:nil];
    
    NSArray *keywords = @[@"skip", @"close", @"dismiss", @"ad", @"跳过", @"关闭"];
    
    void (^search)(UIView *, NSInteger) = nil;
    search = ^(UIView *v, NSInteger depth) {
        if (depth > kMaxSearchDepth || !v || v.isHidden || v.alpha < 0.01) return;
        
        NSString *label = v.accessibilityLabel ?: @"";
        NSString *restId = v.restorationIdentifier ?: @"";
        NSString *clsName = NSStringFromClass([v class]);
        
        BOOL keywordMatch = NO;
        for (NSString *kw in keywords) {
            if ([label localizedCaseInsensitiveContainsString:kw] ||
                [restId localizedCaseInsensitiveContainsString:kw] ||
                [clsName localizedCaseInsensitiveContainsString:kw]) {
                keywordMatch = YES;
                break;
            }
        }
        
        // ✅ 使用frame直接判断，替代昂贵的convertPoint
        CGPoint center = CGPointMake(CGRectGetMidX(v.frame), CGRectGetMidY(v.frame));
        CGFloat dist = hypot(center.x - localTouchPoint.x, center.y - localTouchPoint.y);
        
        if ((dist <= radius || keywordMatch) && dist < bestDist) {
            if ([v isKindOfClass:[UIControl class]] || v.gestureRecognizers.count > 0 || keywordMatch) {
                bestMatch = v;
                bestDist = dist;
            }
        }
        
        for (UIView *sub in v.subviews) search(sub, depth + 1);
    };
    
    search(root, 0);
    return bestMatch;
}

// L3: 全视图树关键词模糊匹配
static UIView* globalKeywordSearch(UIWindow *window) {
    __block UIView *match = nil;
    NSArray *keywords = @[@"skip", @"close", @"dismiss", @"ad", @"跳过", @"关闭"];
    
    void (^search)(UIView *, NSInteger) = nil;
    search = ^(UIView *v, NSInteger depth) {
        if (depth > kMaxSearchDepth || match || !v || v.isHidden || v.alpha < 0.01) return;
        
        NSString *label = v.accessibilityLabel ?: @"";
        NSString *restId = v.restorationIdentifier ?: @"";
        NSString *clsName = NSStringFromClass([v class]);
        
        for (NSString *kw in keywords) {
            if ([label localizedCaseInsensitiveContainsString:kw] ||
                [restId localizedCaseInsensitiveContainsString:kw] ||
                [clsName localizedCaseInsensitiveContainsString:kw]) {
                match = v;
                return;
            }
        }
        for (UIView *sub in v.subviews) search(sub, depth + 1);
    };
    
    search(window.rootViewController.view, 0);
    return match;
}

// 手势深度分析：向上遍历 superview 链查找 tap 手势
static NSString* findTapSelector(UIView *view) {
    UIView *current = view;
    for (NSInteger i = 0; i < 5 && current; i++) {
        for (UIGestureRecognizer *gr in current.gestureRecognizers) {
            if (![gr isKindOfClass:[UITapGestureRecognizer class]]) continue;
            UITapGestureRecognizer *tap = (UITapGestureRecognizer *)gr;
            if (!tap.enabled || tap.numberOfTapsRequired != 1 || tap.numberOfTouchesRequired != 1) continue;
            
            NSArray *acts = getGestureActions(tap);
            for (NSString *info in acts) {
                NSRange ar = [info rangeOfString:@" -> "];
                if (ar.location != NSNotFound) {
                    return [info substringFromIndex:ar.location + 4];
                }
            }
        }
        current = current.superview;
    }
    return nil;
}

// 执行完整的三层分析
static AISkipTarget analyzeSkipTarget(UIWindow *realWindow, CGPoint screenPoint) {
    AISkipTarget result = {nil, kCoordinateSkipSelector, NO};
    CGSize winSize = realWindow.bounds.size;
    if (winSize.width <= 0 || winSize.height <= 0) return result;
    
    CGPoint winPoint = [realWindow convertPoint:screenPoint fromWindow:nil];
    
    // === L1: 标准 hitTest ===
    UIView *hit = [realWindow hitTest:winPoint withEvent:nil];
    if (hit && ![hit isKindOfClass:[UIWindow class]]) {
        result.hitView = hit;
        result.found = YES;
        NSString *sel = findTapSelector(hit);
        if (sel) result.selectorName = sel;
        return result;
    }
    
    // === L2: 局部搜索 (✅ 传入屏幕坐标，内部预转换) ===
    UIView *localHit = localSubviewSearch(realWindow.rootViewController.view, screenPoint, kLocalSearchRadius);
    if (localHit) {
        result.hitView = localHit;
        result.found = YES;
        NSString *sel = findTapSelector(localHit);
        if (sel) result.selectorName = sel;
        return result;
    }
    
    // === L3: 全局关键词搜索 ===
    UIView *globalHit = globalKeywordSearch(realWindow);
    if (globalHit) {
        result.hitView = globalHit;
        result.found = YES;
        NSString *sel = findTapSelector(globalHit);
        if (sel) result.selectorName = sel;
        return result;
    }
    
    return result;
}

// ============================================================
#pragma mark - 自动跳过执行引擎
// ============================================================

static void performAutoSkip() {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
                NSLog(@"[AdInspector] Skip deferred: app not active");
                return;
            }
            
            NSDictionary *cfg = loadSkipConfig();
            if (!cfg) return;
            
// ✅ v8.2: 使用 UIWindowScene.interfaceOrientation 替代废弃API
UIInterfaceOrientation orientation = UIInterfaceOrientationUnknown;
for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
    if (scene.activationState == UISceneActivationStateForegroundActive) {
        orientation = scene.interfaceOrientation;
        break;
    }
}

// 如果无法获取有效场景方向，默认允许执行（避免误拦截）
if (orientation != UIInterfaceOrientationUnknown &&
    orientation != UIInterfaceOrientationPortrait && 
    orientation != UIInterfaceOrientationPortraitUpsideDown) {
    showToast(@"⏸️ 当前非竖屏，跳过已暂停");
    return;
}
            
            CGFloat rx = [SAFE_NUMBER(cfg, @"relX") floatValue];
            CGFloat ry = [SAFE_NUMBER(cfg, @"relY") floatValue];
            NSString *savedSn = SAFE_STRING(cfg, @"selectorName");
            
            CGRect screenBounds = [UIScreen mainScreen].bounds;
            if (screenBounds.size.width <= 0 || screenBounds.size.height <= 0) return;
            
            CGPoint absScreen = CGPointMake(rx * screenBounds.size.width, 
                                            ry * screenBounds.size.height);
            
            UIWindow *realWindow = nil;
            for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (scene.activationState != UISceneActivationStateForegroundActive) continue;
                for (UIWindow *w in scene.windows) {
                    if (w.isKeyWindow && w.bounds.size.width > 0 && w.bounds.size.height > 0) {
                        realWindow = w;
                        break;
                    }
                }
                if (realWindow) break;
            }
            
            if (!realWindow) {
                NSLog(@"[AdInspector] No valid window for auto-skip");
                return;
            }
            
            AISkipTarget target = analyzeSkipTarget(realWindow, absScreen);
            
            if (target.found && target.hitView) {
                // 优先尝试 UIControl
                if ([target.hitView isKindOfClass:[UIControl class]]) {
                    [(UIControl *)target.hitView sendActionsForControlEvents:UIControlEventTouchUpInside];
                    showToast([NSString stringWithFormat:@"🚀 L1/L2 跳过!\n%@", 
                              NSStringFromClass([target.hitView class])]);
                    return;
                }
                
                // 尝试手势触发
                for (UIGestureRecognizer *gr in target.hitView.gestureRecognizers) {
                    if ([gr isKindOfClass:[UITapGestureRecognizer class]] && gr.enabled) {
                        #pragma clang diagnostic push
                        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                        [gr performSelector:NSSelectorFromString(@"_recognizeTap:") withObject:nil];
                        #pragma clang diagnostic pop
                        showToast(@"🚀 手势跳过!");
                        return;
                    }
                }
                
                // 尝试 selector 直接调用
                if (savedSn && ![savedSn isEqualToString:kCoordinateSkipSelector]) {
                    SEL sel = NSSelectorFromString(savedSn);
                    if ([target.hitView respondsToSelector:sel]) {
                        #pragma clang diagnostic push
                        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                        [target.hitView performSelector:sel withObject:nil];
                        #pragma clang diagnostic pop
                        showToast([NSString stringWithFormat:@"🚀 Selector跳过!\n%@", savedSn]);
                        return;
                    }
                }
            }
            
            // ✅ 修复2: 真正的纯坐标兜底点击 (替换原fakeTouch死代码)
            @try {
                CGPoint winPoint = [realWindow convertPoint:absScreen fromWindow:nil];
                
                Class touchClass = NSClassFromString(@"UITouch");
                id t1 = [[touchClass alloc] init];
                ((void (*)(id, SEL, CGPoint))objc_msgSend)(t1, NSSelectorFromString(@"setLocationInWindow:"), winPoint);
                ((void (*)(id, SEL, UIWindow *))objc_msgSend)(t1, NSSelectorFromString(@"setWindow:"), realWindow);
                ((void (*)(id, SEL, NSInteger))objc_msgSend)(t1, NSSelectorFromString(@"setPhase:"), UITouchPhaseBegan);
                ((void (*)(id, SEL, NSTimeInterval))objc_msgSend)(t1, NSSelectorFromString(@"setTimestamp:"), CACurrentMediaTime());
                
                UIEvent *event = [[UIApplication sharedApplication] _touchesEvent];
                if (event) {
                    NSSet *beganSet = [NSSet setWithObject:t1];
                    ((void (*)(id, SEL, NSSet *))objc_msgSend)(event, NSSelectorFromString(@"_setTouches:"), beganSet);
                    [[UIApplication sharedApplication] sendEvent:event];
                    
                    ((void (*)(id, SEL, NSInteger))objc_msgSend)(t1, NSSelectorFromString(@"setPhase:"), UITouchPhaseEnded);
                    ((void (*)(id, SEL, NSTimeInterval))objc_msgSend)(t1, NSSelectorFromString(@"setTimestamp:"), CACurrentMediaTime() + 0.05);
                    [[UIApplication sharedApplication] sendEvent:event];
                    
                    showToast(@"🚀 纯坐标兜底点击");
                } else {
                    showToast(@"⚠️ 跳过失败：无法构造触摸事件\n请重新学习");
                }
            } @catch (NSException *e) {
                showToast(@"⚠️ 跳过失败：目标元素未找到\n请重新学习");
            }
            
        } @catch (NSException *e) {
            NSLog(@"[AdInspector] Auto-skip error: %@", e.reason);
            showToast([NSString stringWithFormat:@"❌ 跳过异常: %@", e.reason]);
        }
    });
}

// ============================================================
#pragma mark - 动态类创建宏 (dispatch_once 保护)
// ============================================================

#define DYNAMIC_CLASS(name, methodSel, typeEncoding, blockImpl) \
    static Class name##Class = nil; \
    static dispatch_once_t name##Once; \
    dispatch_once(&name##Once, ^{ \
        name##Class = objc_allocateClassPair([NSObject class], #name, 0); \
        class_addMethod(name##Class, methodSel, imp_implementationWithBlock(blockImpl), typeEncoding); \
        objc_registerClassPair(name##Class); \
    })

// ============================================================
#pragma mark - 学习面板
// ============================================================

static void showLearnPanel() {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            CGRect screenBounds = [UIScreen mainScreen].bounds;
            CGFloat sw = screenBounds.size.width;
            CGFloat sh = screenBounds.size.height;
            
            if (sw <= 0 || sh <= 0) {
                showToast(@"❌ 屏幕尺寸异常");
                return;
            }
            
            UIWindow *lw = [[UIWindow alloc] initWithFrame:screenBounds];
            lw.windowLevel = UIWindowLevelAlert + 2000;
            lw.backgroundColor = [[UIColor redColor] colorWithAlphaComponent:0.15];
            
// ✅ v8.2: 提示移至底部，避免遮挡顶部广告跳过按钮
CGFloat safeBottom = 0;
if (@available(iOS 11.0, *)) {
    safeBottom = lw.safeAreaInsets.bottom;
}
CGFloat hintHeight = 50;
CGFloat hintY = sh - safeBottom - hintHeight - 20; // 底部安全区上方20pt

UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(20, hintY, sw - 40, hintHeight)];
hint.text = @"🎯 点击广告【跳过】按钮完成学习";
hint.numberOfLines = 1;
hint.textColor = [UIColor whiteColor];
hint.font = [UIFont boldSystemFontOfSize:14];
hint.textAlignment = NSTextAlignmentCenter;
hint.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.5]; // 降低透明度
hint.layer.cornerRadius = 25;
hint.clipsToBounds = YES;
hint.userInteractionEnabled = NO; // ✅ 关键：允许点击穿透到下方真实按钮
[lw addSubview:hint];
            
            UIButton *cancelBtn = [UIButton buttonWithType:UIButtonTypeSystem];
            cancelBtn.frame = CGRectMake(sw / 2 - 60, sh - 100, 120, 44);
            [cancelBtn setTitle:@"❌ 取消学习" forState:UIControlStateNormal];
            [cancelBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            cancelBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
            cancelBtn.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.7];
            cancelBtn.layer.cornerRadius = 22;
            [lw addSubview:cancelBtn];
            
            // --- LearnHandler ---
            DYNAMIC_CLASS(AILearnHandler, @selector(handleTap:), "v@:@", ^(id self, UITapGestureRecognizer *g) {
                UIWindow *window = objc_getAssociatedObject(self, "lw");
                UIButton *cBtn = objc_getAssociatedObject(self, "cancelBtn");
                UIView *hintV = objc_getAssociatedObject(self, "hintView");
                if (!window) return;
                
                CGPoint screenP = [g locationInView:nil];
                CGRect scrB = [UIScreen mainScreen].bounds;
                CGFloat scrW = scrB.size.width;
                CGFloat scrH = scrB.size.height;
                
                if (scrW <= 0 || scrH <= 0) {
                    showToast(@"❌ 屏幕尺寸读取失败");
                    return;
                }
                
                if (cBtn && CGRectContainsPoint(cBtn.frame, screenP)) {
                    window.hidden = YES;
                    showToast(@"❌ 学习已取消");
                    return;
                }
                if (hintV && CGRectContainsPoint(hintV.frame, screenP)) return;
                
                window.hidden = YES;
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    @try {
                        UIWindow *realWindow = nil;
                        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
                            for (UIWindow *w in scene.windows) {
                                if (w != window && w.isKeyWindow && 
                                    w.bounds.size.width > 0 && w.bounds.size.height > 0) {
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
                        
                        AISkipTarget target = analyzeSkipTarget(realWindow, screenP);
                        
                        // ✅ 遮挡自动重试机制
                        if (!target.found) {
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRetryDelay * NSEC_PER_SEC)), 
                                           dispatch_get_main_queue(), ^{
                                @try {
                                    AISkipTarget retry = analyzeSkipTarget(realWindow, screenP);
                                    if (retry.found) {
                                        CGFloat relX = screenP.x / scrW;
                                        CGFloat relY = screenP.y / scrH;
                                        saveSkipConfig(@{
                                            @"targetClass": NSStringFromClass([retry.hitView class]),
                                            @"selectorName": retry.selectorName ?: kCoordinateSkipSelector,
                                            @"relX": @(relX),
                                            @"relY": @(relY),
                                            @"learnedAt": @([[NSDate date] timeIntervalSince1970])
                                        });
                                        // ✅ 修复1: 重试成功后隐藏窗口
                                        window.hidden = YES;
                                        UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
                                        [fb impactOccurred];
                                        showToast([NSString stringWithFormat:@"✅ 重试学习成功!\n类: %@\n坐标: (%.2f%%, %.2f%%)", 
                                                  NSStringFromClass([retry.hitView class]), relX * 100, relY * 100]);
                                    } else {
                                        window.hidden = NO;
                                        showToast(@"❌ 界面被遮挡或无可交互元素\n请手动关闭弹窗后重试");
                                    }
                                } @catch (NSException *e) {
                                    window.hidden = NO;
                                    showToast([NSString stringWithFormat:@"❌ 重试异常: %@", e.reason]);
                                }
                            });
                            return;
                        }
                        
                        CGFloat relX = screenP.x / scrW;
                        CGFloat relY = screenP.y / scrH;
                        
                        if (relX < 0.01 || relY < 0.01 || relX > 0.99 || relY > 0.99) {
                            window.hidden = NO;
                            showToast([NSString stringWithFormat:@"⚠️ 坐标边缘(%.1f%%,%.1f%%)\n请重新点击", relX*100, relY*100]);
                            return;
                        }
                        
                        saveSkipConfig(@{
                            @"targetClass": NSStringFromClass([target.hitView class]),
                            @"selectorName": target.selectorName ?: kCoordinateSkipSelector,
                            @"relX": @(relX),
                            @"relY": @(relY),
                            @"learnedAt": @([[NSDate date] timeIntervalSince1970])
                        });
                        
                        UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
                        [fb impactOccurred];
                        
                        NSString *method = target.found ? 
                            ([target.selectorName isEqualToString:kCoordinateSkipSelector] ? @"纯坐标" : @"类名+手势") : @"兜底";
                        showToast([NSString stringWithFormat:@"✅ 学习成功! [%@]\n类: %@\n坐标: (%.2f%%, %.2f%%)", 
                                  method, NSStringFromClass([target.hitView class]), relX * 100, relY * 100]);
                        
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
            
            // --- CancelHandler ---
            DYNAMIC_CLASS(AICancelHandler, @selector(cancelTapped), "v@:", ^(id self, id sender) {
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

// ============================================================
#pragma mark - 边缘手势安装
// ============================================================

static void installEdgeSwipe() {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            DYNAMIC_CLASS(AIEdgeHandler, @selector(handleEdge:), "v@:@", ^(id self, UIScreenEdgePanGestureRecognizer *g) {
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
                    edge.delaysTouchesBegan = YES;
                    [win addGestureRecognizer:edge];
                    
                    objc_setAssociatedObject(win, "edgeHandler", handler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
            }
            NSLog(@"[AdInspector] ✅ Edge swipe installed");
        } @catch (NSException *e) {
            NSLog(@"[AdInspector] ❌ Edge swipe error: %@", e.reason);
        }
    });
}

// ============================================================
#pragma mark - 三指双击清除 Hook (✅ 修复3: 增强判断逻辑)
// ============================================================

%hook UIApplication
- (void)sendEvent:(UIEvent *)event {
    %orig;
    @try {
        if (event.type != UIEventTypeTouches) return;
        NSSet *touches = [event allTouches];
        if (touches.count < 2) return;
        
        __block NSInteger endedDoubleTapCount = 0;
        [touches enumerateObjectsUsingBlock:^(UITouch *t, BOOL *stop) {
            if (t.phase == UITouchPhaseEnded && t.tapCount >= 2) {
                endedDoubleTapCount++;
            }
        }];
        
        if (endedDoubleTapCount >= 2) {
            BOOL ok = clearSkipConfig();
            showToast(ok ? @"🗑️ 配置已清除" : @"ℹ️ 无配置可清除");
            UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
            [fb impactOccurred];
        }
    } @catch (NSException *e) {}
}
%end

// ============================================================
#pragma mark - 入口
// ============================================================

%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            NSLog(@"[AdInspector] ✅ v8.1 initializing...");
            installEdgeSwipe();
            
            NSDictionary *cfg = loadSkipConfig();
            if (cfg) {
                showToast(@"🚀 AdInspector v8.1\n自动跳过已就绪");
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kAutoSkipInitialDelay * NSEC_PER_SEC)), 
                               dispatch_get_main_queue(), ^{
                    performAutoSkip();
                });
            } else {
                showToast(@"👁️ AdInspector v8.1\n右边缘左滑=学习\n三指双击=清除配置");
            }
        } @catch (NSException *e) {
            NSLog(@"[AdInspector] ❌ v8.1 FATAL: %@", e.reason);
        }
    });
}
