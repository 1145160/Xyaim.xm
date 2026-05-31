// Xyaim - 完整版（自瞄 + 绘制 + 悬浮面板）
#import <UIKit/UIKit.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <AudioToolbox/AudioToolbox.h>

#define SWITCH_DISTANCE 80.0
#define SCREEN_WIDTH [UIScreen mainScreen].bounds.size.width
#define SCREEN_HEIGHT [UIScreen mainScreen].bounds.size.height

// ==================== 配置结构 ====================
typedef struct {
    float bulletSpeed;
    float gravity;
    float predictionStrength;
    UIColor *color;
    NSString *name;
} ModeConfig;

static ModeConfig shotgunMode = {450, 14.0, 0.85, [UIColor orangeColor], @"霰弹"};
static ModeConfig sniperMode = {1200, 5.0, 0.98, [UIColor cyanColor], @"狙击"};
static ModeConfig currentConfig;

// ==================== 全局变量 ====================
static id localPlayer = nil;
static int localTeamId = -1;
static float currentYaw = 0, currentPitch = 0;
static id currentTarget = nil;
static float currentTargetDistance = 0;
static CGPoint currentTargetScreen = {0};
static float currentTargetHealth = 0;

static Class playerClass = nil;
static Ivar posIvar = nil;
static Ivar teamIvar = nil;
static Ivar healthIvar = nil;
static Ivar nameIvar = nil;
static SEL localPlayerSel = nil;

static void (*orig_Update)(id self, SEL _cmd);
static NSMutableDictionary *velCache = nil;

static BOOL killFlash = NO;
static NSTimeInterval killFlashEnd = 0;
static BOOL killText = NO;
static NSTimeInterval killTextEnd = 0;
static int lastKillCount = 0;
static NSString *lastKillName = @"";

static int totalAlive = 0;
static int visibleEnemies = 0;

static UIWindow *overlayWindow = nil;
static UIView *drawView = nil;

// 悬浮面板相关
static UIWindow *floatWindow = nil;
static UIButton *floatButton = nil;
static UIView *settingsPanel = nil;
static UISwitch *aimSwitchControl = nil;
static UISlider *fovSliderControl = nil;
static UISlider *predSliderControl = nil;
static BOOL aimEnabled = YES;
static float userFov = 220;
static float userPred = 0.92;

typedef struct { float x, y, z; } Vector3;

// ==================== 工具函数 ====================
static Vector3 getPosition(id obj) {
    if (!obj || !posIvar) return (Vector3){0};
    id val = object_getIvar(obj, posIvar);
    if (val) {
        Vector3 pos;
        [val getValue:&pos];
        return pos;
    }
    return (Vector3){0};
}

static int getTeamId(id obj) {
    if (!obj || !teamIvar) return -1;
    return [object_getIvar(obj, teamIvar) intValue];
}

static float getHealth(id obj) {
    if (!obj || !healthIvar) return 100;
    return [object_getIvar(obj, healthIvar) floatValue];
}

static NSString* getName(id obj) {
    if (!obj || !nameIvar) return @"?";
    id val = object_getIvar(obj, nameIvar);
    if (val && [val respondsToSelector:@selector(UTF8String)]) {
        return [NSString stringWithUTF8String:[val UTF8String]];
    }
    return @"Enemy";
}

static float getDistance(Vector3 a, Vector3 b) {
    float dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z;
    return sqrt(dx*dx + dy*dy + dz*dz);
}

static Vector3 worldToScreen(Vector3 world) {
    Class cameraClass = objc_getClass("Camera");
    if (!cameraClass) return (Vector3){0};
    SEL mainSel = sel_registerName("main");
    if (![cameraClass respondsToSelector:mainSel]) return (Vector3){0};
    id camera = [cameraClass performSelector:mainSel];
    if (!camera) return (Vector3){0};
    SEL w2sSel = sel_registerName("WorldToScreenPoint:");
    if (![camera respondsToSelector:w2sSel]) return (Vector3){0};
    NSValue *val = [NSValue valueWithBytes:&world objCType:@encode(Vector3)];
    NSValue *res = [camera performSelector:w2sSel withObject:val];
    if (res) {
        Vector3 screen;
        [res getValue:&screen];
        screen.y = SCREEN_HEIGHT - screen.y;
        return screen;
    }
    return (Vector3){0};
}

static NSArray *getAllPlayers() {
    if (!playerClass) return @[];
    NSMutableArray *arr = [NSMutableArray array];
    Ivar listIvar = class_getClassVariable(playerClass, "players");
    if (listIvar) {
        id list = object_getIvar((id)playerClass, listIvar);
        if (list && [list respondsToSelector:@selector(count)]) {
            for (int i = 0; i < [list count]; i++) {
                id p = [list objectAtIndex:i];
                if (p) [arr addObject:p];
            }
        }
    }
    return arr;
}

static Vector3 getVelocity(id obj, Vector3 cur) {
    if (!velCache) velCache = [NSMutableDictionary new];
    NSString *key = [NSString stringWithFormat:@"%p", obj];
    NSDictionary *last = velCache[key];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (!last) {
        velCache[key] = @{@"pos": [NSValue valueWithBytes:&cur objCType:@encode(Vector3)], @"time": @(now)};
        return (Vector3){0};
    }
    Vector3 lastPos;
    [[last objectForKey:@"pos"] getValue:&lastPos];
    double dt = now - [[last objectForKey:@"time"] doubleValue];
    if (dt < 0.01 || dt > 0.5) {
        velCache[key] = @{@"pos": [NSValue valueWithBytes:&cur objCType:@encode(Vector3)], @"time": @(now)};
        return (Vector3){0};
    }
    Vector3 vel = {
        (cur.x - lastPos.x) / dt,
        (cur.y - lastPos.y) / dt,
        (cur.z - lastPos.z) / dt
    };
    velCache[key] = @{@"pos": [NSValue valueWithBytes:&cur objCType:@encode(Vector3)], @"time": @(now)};
    return vel;
}

static id selectTarget(Vector3 localPos, int localTeam, float *outDist, CGPoint *outScreen) {
    if (!aimEnabled) return nil;
    id best = nil;
    float bestDist = 9999;
    CGPoint center = CGPointMake(SCREEN_WIDTH/2, SCREEN_HEIGHT/2);
    float bestScreenDist = userFov;
    
    for (id p in getAllPlayers()) {
        if (p == localPlayer) continue;
        int team = getTeamId(p);
        if (team == localTeam || team == -1) continue;
        if (getHealth(p) <= 0) continue;
        
        Vector3 pos = getPosition(p);
        float dist = getDistance(localPos, pos);
        if (dist > 300) continue;
        
        Vector3 screen = worldToScreen(pos);
        if (screen.z <= 0) continue;
        
        float dx = screen.x - center.x;
        float dy = screen.y - center.y;
        float screenDist = sqrt(dx*dx + dy*dy);
        
        if (screenDist < bestScreenDist && dist < bestDist) {
            bestScreenDist = screenDist;
            bestDist = dist;
            best = p;
            if (outScreen) *outScreen = CGPointMake(screen.x, screen.y);
        }
    }
    if (outDist) *outDist = bestDist;
    return best;
}

static CGPoint calcAngle(Vector3 shooter, Vector3 target, Vector3 vel, float dist) {
    float flightTime = dist / currentConfig.bulletSpeed;
    if (flightTime > 0.6) flightTime = 0.6;
    float predX = target.x + vel.x * flightTime * userPred;
    float predY = target.y + vel.y * flightTime * userPred;
    float predZ = target.z + vel.z * flightTime * userPred;
    predY -= 0.5 * currentConfig.gravity * flightTime * flightTime;
    float dx = predX - shooter.x, dy = predY - shooter.y, dz = predZ - shooter.z;
    float hor = sqrt(dx*dx + dz*dz);
    return CGPointMake(atan2(dx, dz) * 180/M_PI, atan2(dy, hor) * 180/M_PI);
}

static void setViewAngle(float yaw, float pitch) {
    Class cameraClass = objc_getClass("Camera");
    if (!cameraClass) return;
    SEL mainSel = sel_registerName("main");
    if (![cameraClass respondsToSelector:mainSel]) return;
    id camera = [cameraClass performSelector:mainSel];
    if (!camera) return;
    SEL transSel = sel_registerName("transform");
    id trans = [camera performSelector:transSel];
    if (!trans) return;
    SEL setEulerSel = sel_registerName("set_eulerAngles:");
    if (![trans respondsToSelector:setEulerSel]) return;
    static float curYaw = 0, curPitch = 0;
    float step = 0.15;
    curYaw = curYaw * (1-step) + yaw * step;
    curPitch = curPitch * (1-step) + pitch * step;
    Vector3 euler = {curPitch, curYaw, 0};
    NSValue *val = [NSValue valueWithBytes:&euler objCType:@encode(Vector3)];
    [trans performSelector:setEulerSel withObject:val];
}

static void updateMode(float dist) {
    currentConfig = (dist <= SWITCH_DISTANCE) ? shotgunMode : sniperMode;
}

static void new_Update(id self, SEL _cmd) {
    if (orig_Update) orig_Update(self, _cmd);
    if (!localPlayer) {
        if (localPlayerSel && [playerClass respondsToSelector:localPlayerSel]) {
            localPlayer = [playerClass performSelector:localPlayerSel];
        }
        return;
    }
    Vector3 localPos = getPosition(localPlayer);
    (void)localPos;
    if (localPos.x == 0 && localPos.y == 0) return;
    int localTeam = getTeamId(localPlayer);
    float dist = 0;
    CGPoint screen = {0};
    id target = selectTarget(localPos, localTeam, &dist, &screen);
    if (target) {
        currentTarget = target;
        currentTargetDistance = dist;
        currentTargetHealth = getHealth(target);
        currentTargetScreen = screen;
        updateMode(dist);
        Vector3 targetPos = getPosition(target);
        Vector3 targetVel = getVelocity(target, targetPos);
        CGPoint angle = calcAngle(localPos, targetPos, targetVel, dist);
        setViewAngle(angle.x, angle.y);
    }
}

static void scanClasses() {
    int num = objc_getClassList(NULL, 0);
    Class *classes = (Class *)malloc(sizeof(Class) * num);
    num = objc_getClassList(classes, num);
    for (int i = 0; i < num; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        if ([name containsString:@"Player"] || [name containsString:@"Hero"]) {
            playerClass = classes[i];
            unsigned int count;
            Ivar *ivars = class_copyIvarList(playerClass, &count);
            for (int j = 0; j < count; j++) {
                NSString *iname = [NSString stringWithUTF8String:ivar_getName(ivars[j])];
                if ([iname containsString:@"position"]) posIvar = ivars[j];
                if ([iname containsString:@"team"]) teamIvar = ivars[j];
                if ([iname containsString:@"health"]) healthIvar = ivars[j];
                if ([iname containsString:@"name"]) nameIvar = ivars[j];
            }
            free(ivars);
            objc_property_t *props = class_copyPropertyList(playerClass, &count);
            for (int j = 0; j < count; j++) {
                NSString *pname = [NSString stringWithUTF8String:property_getName(props[j])];
                if ([pname isEqualToString:@"LocalPlayer"]) localPlayerSel = sel_registerName("LocalPlayer");
            }
            free(props);
            break;
        }
    }
    free(classes);
}

static void checkKill() {
    int alive = 0;
    int visible = 0;
    if (!localPlayer) return;
    Vector3 localPos = getPosition(localPlayer);
    (void)localPos;
    int localTeam = getTeamId(localPlayer);
    for (id p in getAllPlayers()) {
        if (p == localPlayer) continue;
        int team = getTeamId(p);
        if (team == -1) continue;
        float hp = getHealth(p);
        if (hp > 0) {
            alive++;
            if (team != localTeam) {
                Vector3 pos = getPosition(p);
                Vector3 screen = worldToScreen(pos);
                if (screen.z > 0) visible++;
            }
        }
    }
    totalAlive = alive;
    visibleEnemies = visible;
    
    int currentKill = 16 - totalAlive;
    if (currentKill > lastKillCount && lastKillCount != 0) {
        killFlash = YES;
        killFlashEnd = [[NSDate date] timeIntervalSince1970] + 0.15;
        killText = YES;
        killTextEnd = [[NSDate date] timeIntervalSince1970] + 1.5;
        AudioServicesPlaySystemSound(1519);
    }
    lastKillCount = currentKill;
}

// ==================== 悬浮面板 ====================
void closePanel() {
    if (settingsPanel) settingsPanel.hidden = YES;
}

void toggleAim(UISwitch *sw) {
    aimEnabled = sw.on;
    NSLog(@"[面板] 自瞄开关: %@", aimEnabled ? @"开" : @"关");
}

void fovChanged(UISlider *slider) {
    userFov = slider.value;
    NSLog(@"[面板] FOV: %.0f", userFov);
}

void predChanged(UISlider *slider) {
    userPred = slider.value / 100.0;
    NSLog(@"[面板] 预判力度: %.0f%%", userPred * 100);
}

void showSettingsPanel() {
    if (!settingsPanel) {
        settingsPanel = [[UIView alloc] initWithFrame:CGRectMake(30, 120, SCREEN_WIDTH - 60, 280)];
        settingsPanel.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.92];
        settingsPanel.layer.cornerRadius = 24;
        settingsPanel.layer.borderWidth = 0.5;
        settingsPanel.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:1].CGColor;
        
        UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        closeBtn.frame = CGRectMake(settingsPanel.bounds.size.width - 50, 12, 40, 40);
        [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
        [closeBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:20];
        [closeBtn addTarget:self action:@selector(closePanel) forControlEvents:UIControlEventTouchUpInside];
        [settingsPanel addSubview:closeBtn];
        
        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, 20, 200, 30)];
        title.text = @"XyAim 设置";
        title.textColor = [UIColor whiteColor];
        title.font = [UIFont boldSystemFontOfSize:18];
        [settingsPanel addSubview:title];
        
        // 自瞄开关
        UILabel *aimLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 70, 100, 30)];
        aimLabel.text = @"自瞄开关";
        aimLabel.textColor = [UIColor whiteColor];
        [settingsPanel addSubview:aimLabel];
        
        aimSwitchControl = [[UISwitch alloc] initWithFrame:CGRectMake(settingsPanel.bounds.size.width - 80, 65, 50, 30)];
        aimSwitchControl.on = aimEnabled;
        [aimSwitchControl addTarget:self action:@selector(toggleAim:) forControlEvents:UIControlEventValueChanged];
        [settingsPanel addSubview:aimSwitchControl];
        
        // FOV 滑块
        UILabel *fovLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 120, 150, 30)];
        fovLabel.text = @"自瞄范围 (FOV)";
        fovLabel.textColor = [UIColor whiteColor];
        [settingsPanel addSubview:fovLabel];
        
        fovSliderControl = [[UISlider alloc] initWithFrame:CGRectMake(20, 150, settingsPanel.bounds.size.width - 40, 30)];
        fovSliderControl.minimumValue = 120;
        fovSliderControl.maximumValue = 320;
        fovSliderControl.value = userFov;
        [fovSliderControl addTarget:self action:@selector(fovChanged:) forControlEvents:UIControlEventValueChanged];
        [settingsPanel addSubview:fovSliderControl];
        
        // 预判力度滑块
        UILabel *predLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 190, 150, 30)];
        predLabel.text = @"预判力度 (%)";
        predLabel.textColor = [UIColor whiteColor];
        [settingsPanel addSubview:predLabel];
        
        predSliderControl = [[UISlider alloc] initWithFrame:CGRectMake(20, 220, settingsPanel.bounds.size.width - 40, 30)];
        predSliderControl.minimumValue = 70;
        predSliderControl.maximumValue = 100;
        predSliderControl.value = userPred * 100;
        [predSliderControl addTarget:self action:@selector(predChanged:) forControlEvents:UIControlEventValueChanged];
        [settingsPanel addSubview:predSliderControl];
        
        [[UIApplication sharedApplication].keyWindow addSubview:settingsPanel];
    } else {
        settingsPanel.hidden = NO;
    }
}

void floatButtonTapped() {
    if (settingsPanel && !settingsPanel.hidden) {
        closePanel();
    } else {
        showSettingsPanel();
    }
}

void handlePan(UIPanGestureRecognizer *gesture) {
    UIButton *btn = (UIButton *)gesture.view;
    CGPoint translation = [gesture translationInView:btn.superview];
    CGPoint newCenter = CGPointMake(btn.center.x + translation.x, btn.center.y + translation.y);
    newCenter.x = MAX(25, MIN(SCREEN_WIDTH - 25, newCenter.x));
    newCenter.y = MAX(25, MIN(SCREEN_HEIGHT - 25, newCenter.y));
    btn.center = newCenter;
    [gesture setTranslation:CGPointZero inView:btn.superview];
}

void setupFloatButton() {
    dispatch_async(dispatch_get_main_queue(), ^{
        floatWindow = [[UIWindow alloc] initWithFrame:CGRectMake(SCREEN_WIDTH - 70, 150, 50, 50)];
        floatWindow.windowLevel = UIWindowLevelAlert + 2;
        floatWindow.backgroundColor = [UIColor clearColor];
        floatWindow.hidden = NO;
        
        floatButton = [UIButton buttonWithType:UIButtonTypeCustom];
        floatButton.frame = CGRectMake(0, 0, 50, 50);
        floatButton.backgroundColor = [UIColor colorWithRed:0.2 green:0.5 blue:0.8 alpha:0.85];
        floatButton.layer.cornerRadius = 25;
        floatButton.layer.shadowColor = [UIColor blackColor].CGColor;
        floatButton.layer.shadowOffset = CGSizeMake(0, 2);
        floatButton.layer.shadowRadius = 4;
        [floatButton setTitle:@"⚙" forState:UIControlStateNormal];
        [floatButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        floatButton.titleLabel.font = [UIFont systemFontOfSize:24];
        [floatButton addTarget:self action:@selector(floatButtonTapped) forControlEvents:UIControlEventTouchUpInside];
        
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [floatButton addGestureRecognizer:pan];
        
        [floatWindow addSubview:floatButton];
    });
}

// ==================== 游戏内绘制 ====================
@interface DrawView : UIView @end
@implementation DrawView

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetTextMatrix(ctx, CGAffineTransformIdentity);
    
    if (killFlash && [[NSDate date] timeIntervalSince1970] < killFlashEnd) {
        CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.7].CGColor);
        CGContextFillRect(ctx, rect);
    }
    
    CGFloat cx = SCREEN_WIDTH/2, cy = SCREEN_HEIGHT/2;
    CGContextSetStrokeColorWithColor(ctx, [UIColor whiteColor].CGColor);
    CGContextSetLineWidth(ctx, 1.5);
    CGContextMoveToPoint(ctx, cx-12, cy); CGContextAddLineToPoint(ctx, cx-4, cy);
    CGContextMoveToPoint(ctx, cx+4, cy); CGContextAddLineToPoint(ctx, cx+12, cy);
    CGContextMoveToPoint(ctx, cx, cy-12); CGContextAddLineToPoint(ctx, cx, cy-4);
    CGContextMoveToPoint(ctx, cx, cy+4); CGContextAddLineToPoint(ctx, cx, cy+12);
    CGContextStrokePath(ctx);
    
    CGContextAddEllipseInRect(ctx, CGRectMake(cx-120, cy-120, 240, 240));
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:1 green:0.3 blue:0 alpha:0.35].CGColor);
    CGContextSetLineWidth(ctx, 1.2);
    CGContextStrokePath(ctx);
    
    if (killText && [[NSDate date] timeIntervalSince1970] < killTextEnd) {
        NSString *text = [NSString stringWithFormat:@"💀 %@ 💀", lastKillName];
        UIFont *font = [UIFont boldSystemFontOfSize:26];
        NSDictionary *attrs = @{NSFontAttributeName: font, NSForegroundColorAttributeName: [UIColor redColor]};
        CGSize size = [text sizeWithAttributes:attrs];
        [text drawAtPoint:CGPointMake(cx - size.width/2, cy - 120) withAttributes:attrs];
    }
    
    NSString *modeText = [NSString stringWithFormat:@"[%@]", currentConfig.name];
    [modeText drawAtPoint:CGPointMake(SCREEN_WIDTH - 85, 12) withAttributes:@{NSFontAttributeName: [UIFont boldSystemFontOfSize:11], NSForegroundColorAttributeName: currentConfig.color}];
    
    if (currentTarget && currentTargetScreen.x > 0 && currentTargetScreen.y > 0) {
        float healthPercent = currentTargetHealth / 100.0;
        CGFloat ex = currentTargetScreen.x;
        CGFloat ey = currentTargetScreen.y;
        
        NSString *classIcon = @"🎯";
        if (currentTargetDistance <= 30) classIcon = @"🔫";
        else if (currentTargetDistance <= 80) classIcon = @"📦";
        
        NSString *name = getName(currentTarget);
        NSString *topText = [NSString stringWithFormat:@"%@ %@", classIcon, name];
        UIFont *nameFont = [UIFont boldSystemFontOfSize:12];
        CGSize nameSize = [topText sizeWithAttributes:@{NSFontAttributeName: nameFont}];
        [topText drawAtPoint:CGPointMake(ex - nameSize.width/2, ey - 48) withAttributes:@{NSFontAttributeName: nameFont, NSForegroundColorAttributeName: [UIColor whiteColor]}];
        
        CGRect bgRect = CGRectMake(ex - 45, ey - 38, 90, 6);
        CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.2 alpha:0.6].CGColor);
        CGContextFillRect(ctx, bgRect);
        CGRect hpRect = CGRectMake(ex - 45, ey - 38, 90 * healthPercent, 6);
        CGContextSetFillColorWithColor(ctx, [UIColor colorWithRed:0.2 green:0.8 blue:0.2 alpha:1].CGColor);
        CGContextFillRect(ctx, hpRect);
        
        NSString *distText = [NSString stringWithFormat:@"%.0fm", currentTargetDistance];
        UIFont *distFont = [UIFont systemFontOfSize:11];
        CGSize distSize = [distText sizeWithAttributes:@{NSFontAttributeName: distFont}];
        [distText drawAtPoint:CGPointMake(ex - distSize.width/2, ey - 28) withAttributes:@{NSFontAttributeName: distFont, NSForegroundColorAttributeName: [UIColor yellowColor]}];
        
        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:1 green:0.2 blue:0.2 alpha:0.45].CGColor);
        CGContextSetLineWidth(ctx, 1.2);
        CGContextMoveToPoint(ctx, cx, cy);
        CGContextAddLineToPoint(ctx, ex, ey - 38);
        CGContextStrokePath(ctx);
    }
    
    // 左上角统计
    UIGraphicsBeginImageContext(CGSizeMake(130, 70));
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0 alpha:0.5].CGColor);
    CGContextFillRect(ctx, CGRectMake(0, 0, 130, 70));
    [[NSString stringWithFormat:@"👥 %d/16", totalAlive] drawAtPoint:CGPointMake(8, 8) withAttributes:@{NSFontAttributeName: [UIFont boldSystemFontOfSize:13], NSForegroundColorAttributeName: [UIColor whiteColor]}];
    [[NSString stringWithFormat:@"👁 %d", visibleEnemies] drawAtPoint:CGPointMake(8, 28) withAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:12], NSForegroundColorAttributeName: [UIColor yellowColor]}];
    [[NSString stringWithFormat:@"🎯 %d", currentTarget ? 1 : 0] drawAtPoint:CGPointMake(8, 48) withAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:12], NSForegroundColorAttributeName: [UIColor cyanColor]}];
    UIGraphicsEndImageContext();
}

@end

static void setupUI() {
    dispatch_async(dispatch_get_main_queue(), ^{
        overlayWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        overlayWindow.windowLevel = UIWindowLevelAlert + 1;
        overlayWindow.backgroundColor = [UIColor clearColor];
        overlayWindow.userInteractionEnabled = NO;
        drawView = [[DrawView alloc] initWithFrame:overlayWindow.bounds];
        drawView.backgroundColor = [UIColor clearColor];
        [overlayWindow addSubview:drawView];
        overlayWindow.hidden = NO;
        
        [NSTimer scheduledTimerWithTimeInterval:0.033 repeats:YES block:^(NSTimer *timer) {
            checkKill();
            [drawView setNeedsDisplay];
        }];
    });
}

// ==================== 入口 ====================
%ctor {
    currentConfig = shotgunMode;
    NSLog(@"[Xyaim] 完整版加载成功");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        scanClasses();
        setupUI();
        setupFloatButton();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (playerClass) {
            SEL sel = sel_registerName("Update");
            if (class_getInstanceMethod(playerClass, sel)) {
                MSHookMessageEx(playerClass, sel, (IMP)&new_Update, (IMP*)&orig_Update);
            }
        }
    });
}
