#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "MaxVibeAntiDelete.h"

/*
 * MaxVibe: Telegram banner + native Settings row + soft persist fix + anti-delete.
 */

extern void MaxVibeInstallPersistFixes(void);

static NSString * const kConfigURL = @"https://dorofo.github.io/max-vibe-assets/config.json";
static NSString * const kTelegramURL = @"https://t.me/max_vibe";
static NSString * const kKeyFirst = @"mvibe_banner_first_launch";
static NSString * const kKeyLast = @"mvibe_banner_last_show_time";
static NSString * const kKeyBannerEnabled = @"mvibe_banner_enabled";
static const NSTimeInterval kDaySeconds = 86400.0;
static const NSTimeInterval kFetchTimeout = 4.0;
static const NSTimeInterval kInitialDelay = 8.0;

static BOOL gDidSchedule = NO;
static BOOL gShowingBanner = NO;
static BOOL gShowingSettings = NO;
static char kMvibeSettingsRowKey;

@interface MaxVibeModController : NSObject
+ (instancetype)shared;
- (void)start;
- (void)openTelegram;
- (void)showSettings;
- (void)attachSettingsRowToViewController:(UIViewController *)vc;
@end

@interface UINavigationController (MaxVibe)
- (void)mvibe_pushViewController:(UIViewController *)vc animated:(BOOL)animated;
- (void)mvibe_setViewControllers:(NSArray *)vcs animated:(BOOL)animated;
@end

@implementation MaxVibeModController {
    UIView *_bannerOverlay;
    UIView *_settingsOverlay;
}

+ (instancetype)shared {
    static MaxVibeModController *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [MaxVibeModController new]; });
    return s;
}

- (NSUserDefaults *)prefs { return [NSUserDefaults standardUserDefaults]; }

- (BOOL)bannerEnabled {
    NSUserDefaults *p = [self prefs];
    if ([p objectForKey:kKeyBannerEnabled] == nil) return YES;
    return [p boolForKey:kKeyBannerEnabled];
}
- (void)setBannerEnabled:(BOOL)on { [[self prefs] setBool:on forKey:kKeyBannerEnabled]; }

- (BOOL)shouldShowBanner {
    if (![self bannerEnabled]) return NO;
    NSUserDefaults *p = [self prefs];
    BOOL first = YES;
    if ([p objectForKey:kKeyFirst] != nil) first = [p boolForKey:kKeyFirst];
    NSTimeInterval last = [p doubleForKey:kKeyLast];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if ((now - last) < kDaySeconds && !first) return NO;
    return YES;
}

- (void)markBannerShown {
    NSUserDefaults *p = [self prefs];
    [p setBool:NO forKey:kKeyFirst];
    [p setDouble:[[NSDate date] timeIntervalSince1970] forKey:kKeyLast];
}

- (UIColor *)hex:(unsigned int)hex alpha:(CGFloat)a {
    return [UIColor colorWithRed:((hex >> 16) & 0xFF) / 255.0
                           green:((hex >> 8) & 0xFF) / 255.0
                            blue:(hex & 0xFF) / 255.0 alpha:a];
}

- (UIWindow *)keyWindow {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) if (w.isKeyWindow) return w;
            if (ws.windows.count) return ws.windows.firstObject;
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop
}

- (UIImage *)bannerImage {
    NSBundle *main = [NSBundle mainBundle];
    for (NSString *rel in @[@"banner_character.png", @"Frameworks/banner_character.png"]) {
        NSString *path = [main.bundlePath stringByAppendingPathComponent:rel];
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            UIImage *img = [UIImage imageWithContentsOfFile:path];
            if (img) return img;
        }
    }
    return nil;
}

- (void)openTelegram {
    NSURL *url = [NSURL URLWithString:kTelegramURL];
    if (@available(iOS 10.0, *)) {
        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    }
}

- (void)start {
    if (gDidSchedule) return;
    gDidSchedule = YES;
    MaxVibeInstallPersistFixes();
    MaxVibeInstallAntiDelete();
    [self installSettingsHooks];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kInitialDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self tryPresentBanner];
    });
}

#pragma mark - Hook Settings UI (NO Swift viewDidAppear swizzle — that crashed ~1s)

- (BOOL)isMainSettingsViewController:(UIViewController *)vc {
    if (!vc) return NO;
    NSString *cls = NSStringFromClass([vc class]);
    // Exact main settings list only — not Privacy/Devices/PIN/…
    if ([cls isEqualToString:@"_TtC10SettingsUI22SettingsViewController"]) return YES;
    if (![cls containsString:@"SettingsViewController"]) return NO;
    for (NSString *bad in @[@"Privacy", @"Devices", @"Language", @"Messages",
                            @"PIN", @"Appearance", @"Notification", @"Background",
                            @"Locked", @"Onboarding", @"Recover"]) {
        if ([cls containsString:bad]) return NO;
    }
    // SettingsUI module, short mangled name (~main list)
    return [cls containsString:@"SettingsUI"] && cls.length < 55;
}

- (void)walkViewControllers:(UIViewController *)root
                      block:(void (^)(UIViewController *vc))block {
    if (!root || !block) return;
    block(root);
    for (UIViewController *c in root.childViewControllers) {
        [self walkViewControllers:c block:block];
    }
    if ([root isKindOfClass:[UINavigationController class]]) {
        for (UIViewController *c in ((UINavigationController *)root).viewControllers) {
            [self walkViewControllers:c block:block];
        }
    }
    if ([root isKindOfClass:[UITabBarController class]]) {
        for (UIViewController *c in ((UITabBarController *)root).viewControllers) {
            [self walkViewControllers:c block:block];
        }
    }
    if (root.presentedViewController) {
        [self walkViewControllers:root.presentedViewController block:block];
    }
}

- (void)installSettingsHooks {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class nav = [UINavigationController class];
        SEL orig = @selector(pushViewController:animated:);
        SEL swiz = @selector(mvibe_pushViewController:animated:);
        Method mOrig = class_getInstanceMethod(nav, orig);
        Method mDonor = class_getInstanceMethod([MaxVibeModController class], swiz);
        if (mOrig && mDonor) {
            class_addMethod(nav, swiz, method_getImplementation(mDonor), method_getTypeEncoding(mDonor));
            method_exchangeImplementations(class_getInstanceMethod(nav, orig),
                                           class_getInstanceMethod(nav, swiz));
        }

        SEL origSet = @selector(setViewControllers:animated:);
        SEL swizSet = @selector(mvibe_setViewControllers:animated:);
        Method mOrigSet = class_getInstanceMethod(nav, origSet);
        Method mDonorSet = class_getInstanceMethod([MaxVibeModController class], swizSet);
        if (mOrigSet && mDonorSet) {
            class_addMethod(nav, swizSet, method_getImplementation(mDonorSet), method_getTypeEncoding(mDonorSet));
            method_exchangeImplementations(class_getInstanceMethod(nav, origSet),
                                           class_getInstanceMethod(nav, swizSet));
        }

        [NSTimer scheduledTimerWithTimeInterval:0.8
                                         target:self
                                       selector:@selector(pollForSettingsScreen)
                                       userInfo:nil
                                        repeats:YES];
    });
}

- (void)mvibe_pushViewController:(UIViewController *)vc animated:(BOOL)animated {
    [(UINavigationController *)self mvibe_pushViewController:vc animated:animated];
    if ([[MaxVibeModController shared] isMainSettingsViewController:vc]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[MaxVibeModController shared] attachSettingsRowToViewController:vc];
        });
    }
}

- (void)mvibe_setViewControllers:(NSArray *)vcs animated:(BOOL)animated {
    [(UINavigationController *)self mvibe_setViewControllers:vcs animated:animated];
    for (UIViewController *top in vcs) {
        if ([[MaxVibeModController shared] isMainSettingsViewController:top]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [[MaxVibeModController shared] attachSettingsRowToViewController:top];
            });
        }
    }
}

- (void)pollForSettingsScreen {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
        }
    }
    if (!windows.count) {
        UIWindow *kw = [self keyWindow];
        if (kw) [windows addObject:kw];
    }
    __weak MaxVibeModController *weakSelf = self;
    for (UIWindow *w in windows) {
        [self walkViewControllers:w.rootViewController block:^(UIViewController *vc) {
            if ([weakSelf isMainSettingsViewController:vc] && vc.isViewLoaded && vc.view.window) {
                [weakSelf attachSettingsRowToViewController:vc];
            }
        }];
    }
}

/** Native-looking settings row (like О приложении / Помощь / MAX для бизнеса). */
- (UIView *)buildNativeSettingsRow {
    CGFloat side = 16.0;
    CGFloat rowH = 52.0;
    CGFloat topPad = 8.0;
    CGFloat bottomPad = 10.0;
    UIView *wrap = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, topPad + rowH + bottomPad)];
    wrap.backgroundColor = UIColor.clearColor;
    wrap.tag = 0x4D564942; // MVIB

    UIView *cell = [[UIView alloc] initWithFrame:CGRectMake(side, topPad, 288, rowH)];
    cell.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    cell.layer.cornerRadius = 12;
    cell.clipsToBounds = YES;
    if (@available(iOS 13.0, *)) {
        cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    } else {
        cell.backgroundColor = [UIColor whiteColor];
    }

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, 220, rowH)];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    label.text = @"Настройки MaxVibe";
    label.font = [UIFont systemFontOfSize:17];
    if (@available(iOS 13.0, *)) {
        label.textColor = [UIColor labelColor];
    }
    [cell addSubview:label];

    UIImageView *chev = nil;
    if (@available(iOS 13.0, *)) {
        UIImage *img = [UIImage systemImageNamed:@"chevron.right"];
        chev = [[UIImageView alloc] initWithImage:[img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
        chev.tintColor = [UIColor tertiaryLabelColor];
        chev.frame = CGRectMake(288 - 28, (rowH - 14) / 2.0, 10, 14);
        chev.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        [cell addSubview:chev];
    }

    UIButton *hit = [UIButton buttonWithType:UIButtonTypeCustom];
    hit.frame = cell.bounds;
    hit.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [hit addTarget:self action:@selector(showSettings) forControlEvents:UIControlEventTouchUpInside];
    [cell addSubview:hit];

    [wrap addSubview:cell];
    return wrap;
}

- (void)attachSettingsRowToViewController:(UIViewController *)vc {
    if (!vc || !vc.isViewLoaded) return;
    if (![self isMainSettingsViewController:vc]) return;

    UIView *existing = objc_getAssociatedObject(vc, &kMvibeSettingsRowKey);
    if ([existing isKindOfClass:[UIView class]] && existing.superview == vc.view) return;
    if ([existing isKindOfClass:[UIView class]]) [existing removeFromSuperview];

    UIView *row = [self buildNativeSettingsRow];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [vc.view addSubview:row];
    [vc.view bringSubviewToFront:row];

    UILayoutGuide *safe = vc.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [row.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor],
        [row.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor],
        [row.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [row.heightAnchor constraintEqualToConstant:70],
    ]];

    // Keep above tab bar / home indicator; nudge list so last rows aren't fully covered
    UIScrollView *scroll = nil;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:vc.view];
    CGFloat best = 0;
    while (stack.count) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if ([v isKindOfClass:[UITableView class]] || [v isKindOfClass:[UICollectionView class]]) {
            CGFloat area = v.bounds.size.width * MAX(v.bounds.size.height, 1);
            if (area >= best) { best = area; scroll = (UIScrollView *)v; }
        }
        for (UIView *c in v.subviews) {
            if (c.tag == 0x4D564942) continue;
            [stack addObject:c];
        }
    }
    if (scroll) {
        UIEdgeInsets inset = scroll.contentInset;
        inset.bottom = MAX(inset.bottom, 84);
        scroll.contentInset = inset;
        scroll.scrollIndicatorInsets = inset;
    }

    objc_setAssociatedObject(vc, &kMvibeSettingsRowKey, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}


#pragma mark - Settings sheet

- (UIView *)settingsRowTitle:(NSString *)title subtitle:(NSString *)subtitle action:(SEL)action chevron:(BOOL)chevron {
    UIButton *row = [UIButton buttonWithType:UIButtonTypeCustom];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.06];
    row.layer.cornerRadius = 14;
    [row addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];

    UILabel *t = [[UILabel alloc] init];
    t.text = title; t.textColor = UIColor.whiteColor;
    t.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    t.translatesAutoresizingMaskIntoConstraints = NO; t.userInteractionEnabled = NO;
    UILabel *s = [[UILabel alloc] init];
    s.text = subtitle; s.textColor = [self hex:0x8E858A alpha:1];
    s.font = [UIFont systemFontOfSize:12]; s.numberOfLines = 2;
    s.translatesAutoresizingMaskIntoConstraints = NO; s.userInteractionEnabled = NO;
    [row addSubview:t]; [row addSubview:s];
    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintGreaterThanOrEqualToConstant:64],
        [t.topAnchor constraintEqualToAnchor:row.topAnchor constant:12],
        [t.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:14],
        [t.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-36],
        [s.topAnchor constraintEqualToAnchor:t.bottomAnchor constant:4],
        [s.leadingAnchor constraintEqualToAnchor:t.leadingAnchor],
        [s.trailingAnchor constraintEqualToAnchor:t.trailingAnchor],
        [s.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-12],
    ]];
    if (chevron) {
        UILabel *ch = [[UILabel alloc] init];
        ch.text = @"›"; ch.textColor = [self hex:0xE8C4CE alpha:1];
        ch.font = [UIFont systemFontOfSize:28 weight:UIFontWeightLight];
        ch.translatesAutoresizingMaskIntoConstraints = NO; ch.userInteractionEnabled = NO;
        [row addSubview:ch];
        [NSLayoutConstraint activateConstraints:@[
            [ch.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [ch.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-12],
        ]];
    }
    return row;
}

- (void)showSettings {
    if (gShowingSettings) return;
    UIWindow *window = [self keyWindow];
    if (!window) return;
    gShowingSettings = YES;

    UIView *overlay = [[UIView alloc] initWithFrame:window.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];

    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [self hex:0x1A1218 alpha:1];
    card.layer.cornerRadius = 22; card.clipsToBounds = YES;

    UILabel *kicker = [[UILabel alloc] init];
    kicker.text = @"МОД НА MAX"; kicker.textColor = [self hex:0xE85A7A alpha:1];
    kicker.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    kicker.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *title = [[UILabel alloc] init];
    title.text = @"Настройки MaxVibe"; title.textColor = [self hex:0xE8C4CE alpha:1];
    title.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBold];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *sub = [[UILabel alloc] init];
    sub.text = @"как на Android · Telegram, баннер, антиудаление"; sub.textColor = [self hex:0x8E858A alpha:1];
    sub.font = [UIFont systemFontOfSize:12]; sub.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageView *hero = [[UIImageView alloc] initWithImage:[self bannerImage]];
    hero.contentMode = UIViewContentModeScaleAspectFit; hero.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setTitle:@"✕" forState:UIControlStateNormal];
    [close setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    close.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
    close.layer.cornerRadius = 18; close.translatesAutoresizingMaskIntoConstraints = NO;
    [close addTarget:self action:@selector(dismissSettings) forControlEvents:UIControlEventTouchUpInside];

    UIScrollView *scroll = [[UIScrollView alloc] init]; scroll.translatesAutoresizingMaskIntoConstraints = NO;
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 10; stack.translatesAutoresizingMaskIntoConstraints = NO;

    [stack addArrangedSubview:[self settingsRowTitle:@"Telegram канал" subtitle:@"t.me/max_vibe" action:@selector(onSettingsTelegram) chevron:YES]];
    [stack addArrangedSubview:[self settingsRowTitle:[self bannerEnabled] ? @"Баннер: включён" : @"Баннер: выключен" subtitle:@"Стартовый баннер раз в сутки" action:@selector(onSettingsToggleBanner) chevron:NO]];
    [stack addArrangedSubview:[self settingsRowTitle:MaxVibeAntiDeleteEnabled() ? @"Антиудаление: включено" : @"Антиудаление: выключено" subtitle:@"v11: keep+❌ · UI refresh без swizzle" action:@selector(onSettingsToggleAntiDelete) chevron:NO]];
    [stack addArrangedSubview:[self settingsRowTitle:@"Показать баннер сейчас" subtitle:@"Сбросить таймер" action:@selector(onSettingsForceBanner) chevron:YES]];
    [stack addArrangedSubview:[self settingsRowTitle:@"Сменить иконку" subtitle:@"Скоро" action:@selector(onSettingsStub) chevron:YES]];
    [stack addArrangedSubview:[self settingsRowTitle:@"Аккаунты" subtitle:@"Скоро" action:@selector(onSettingsStub) chevron:YES]];

    [scroll addSubview:stack];
    [card addSubview:kicker]; [card addSubview:title]; [card addSubview:sub];
    [card addSubview:hero]; [card addSubview:close]; [card addSubview:scroll];
    [overlay addSubview:card]; [window addSubview:overlay];
    _settingsOverlay = overlay;

    CGFloat width = MIN(window.bounds.size.width - 24, 400);
    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [card.widthAnchor constraintEqualToConstant:width],
        [kicker.topAnchor constraintEqualToAnchor:card.topAnchor constant:18],
        [kicker.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [close.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [close.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [close.widthAnchor constraintEqualToConstant:36], [close.heightAnchor constraintEqualToConstant:36],
        [title.topAnchor constraintEqualToAnchor:kicker.bottomAnchor constant:6],
        [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [title.trailingAnchor constraintEqualToAnchor:close.leadingAnchor constant:-8],
        [sub.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:4],
        [sub.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [hero.topAnchor constraintEqualToAnchor:sub.bottomAnchor constant:4],
        [hero.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-8],
        [hero.widthAnchor constraintEqualToConstant:110], [hero.heightAnchor constraintEqualToConstant:140],
        [scroll.topAnchor constraintEqualToAnchor:sub.bottomAnchor constant:16],
        [scroll.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [scroll.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [scroll.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-18],
        [scroll.heightAnchor constraintEqualToConstant:320],
        [stack.topAnchor constraintEqualToAnchor:scroll.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor],
        [stack.widthAnchor constraintEqualToAnchor:scroll.widthAnchor],
    ]];
    overlay.alpha = 0;
    [UIView animateWithDuration:0.25 animations:^{ overlay.alpha = 1; }];
}

- (void)dismissSettings {
    UIView *overlay = _settingsOverlay;
    if (!overlay) { gShowingSettings = NO; return; }
    [UIView animateWithDuration:0.2 animations:^{ overlay.alpha = 0; } completion:^(BOOL f) {
        [overlay removeFromSuperview];
        self->_settingsOverlay = nil;
        gShowingSettings = NO;
    }];
}

- (void)onSettingsTelegram { [self openTelegram]; }
- (void)onSettingsToggleBanner {
    [self setBannerEnabled:![self bannerEnabled]];
    [self dismissSettings];
}
- (void)onSettingsToggleAntiDelete {
    MaxVibeSetAntiDeleteEnabled(!MaxVibeAntiDeleteEnabled());
    [self dismissSettings];
}
- (void)onSettingsForceBanner {
    [[self prefs] setBool:YES forKey:kKeyFirst];
    [[self prefs] setDouble:0 forKey:kKeyLast];
    [self setBannerEnabled:YES];
    [self dismissSettings];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gShowingBanner = NO;
        [self tryPresentBanner];
    });
}
- (void)onSettingsStub {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"MaxVibe" message:@"Скоро появится" preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    UIViewController *root = [self keyWindow].rootViewController;
    while (root.presentedViewController) root = root.presentedViewController;
    [root presentViewController:ac animated:YES completion:nil];
}

#pragma mark - Banner

- (void)tryPresentBanner {
    if (gShowingBanner || gShowingSettings) return;
    if (![self shouldShowBanner]) return;
    UIWindow *window = [self keyWindow];
    if (!window) return;
    gShowingBanner = YES;

    NSURL *url = [NSURL URLWithString:kConfigURL];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:kFetchTimeout];
    [req setValue:@"MaxVibe/iOS" forHTTPHeaderField:@"User-Agent"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSString *text = nil; BOOL valid = YES;
        if (!err && data.length) {
            id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([obj isKindOfClass:[NSDictionary class]]) {
                NSDictionary *j = obj;
                if ([j[@"valid_launcher"] isKindOfClass:[NSNumber class]]) valid = [j[@"valid_launcher"] boolValue];
                if ([j[@"banner_text"] isKindOfClass:[NSString class]] && [j[@"banner_text"] length]) text = j[@"banner_text"];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!valid) {
                UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Лаунчер отключен" message:@"Обновитесь в телеграм-канале" preferredStyle:UIAlertControllerStyleAlert];
                [ac addAction:[UIAlertAction actionWithTitle:@"Открыть Telegram" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ [self openTelegram]; gShowingBanner=NO; }]];
                UIViewController *root = window.rootViewController;
                while (root.presentedViewController) root = root.presentedViewController;
                [root presentViewController:ac animated:YES completion:nil];
                return;
            }
            [self showBannerOn:window message:text];
        });
    }] resume];
}

- (void)showBannerOn:(UIWindow *)window message:(NSString *)message {
    NSString *text = message.length ? message : @"Подпишись на канал — обновления мода, фичи и вайб без воды";
    CGFloat width = MIN(window.bounds.size.width - 32, 360);
    UIView *overlay = [[UIView alloc] initWithFrame:window.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [self hex:0x1A1218 alpha:1]; card.layer.cornerRadius = 20; card.clipsToBounds = YES;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageView *hero = [[UIImageView alloc] initWithImage:[self bannerImage]];
    hero.contentMode = UIViewContentModeScaleAspectFit; hero.translatesAutoresizingMaskIntoConstraints = NO;
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setTitle:@"✕" forState:UIControlStateNormal]; [close setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    close.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.18]; close.layer.cornerRadius = 20;
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close addTarget:self action:@selector(onBannerClose) forControlEvents:UIControlEventTouchUpInside];
    UILabel *title = [[UILabel alloc] init];
    title.text = @"MaxVibe в Telegram"; title.textColor = [self hex:0xE8C4CE alpha:1];
    title.font = [UIFont boldSystemFontOfSize:20]; title.textAlignment = NSTextAlignmentCenter; title.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *msg = [[UILabel alloc] init];
    msg.text = text; msg.textColor = [self hex:0x8E858A alpha:1]; msg.font = [UIFont systemFontOfSize:14];
    msg.textAlignment = NSTextAlignmentCenter; msg.numberOfLines = 0; msg.translatesAutoresizingMaskIntoConstraints = NO;
    UIButton *join = [UIButton buttonWithType:UIButtonTypeSystem];
    [join setTitle:@"Подписаться в Telegram" forState:UIControlStateNormal];
    [join setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    join.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    join.backgroundColor = [self hex:0xE85A7A alpha:1]; join.layer.cornerRadius = 14;
    join.translatesAutoresizingMaskIntoConstraints = NO;
    [join addTarget:self action:@selector(onBannerJoin) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:hero]; [card addSubview:close]; [card addSubview:title]; [card addSubview:msg]; [card addSubview:join];
    [overlay addSubview:card]; [window addSubview:overlay]; _bannerOverlay = overlay;
    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [card.widthAnchor constraintEqualToConstant:width],
        [hero.topAnchor constraintEqualToAnchor:card.topAnchor constant:8],
        [hero.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [hero.widthAnchor constraintEqualToConstant:220], [hero.heightAnchor constraintEqualToConstant:300],
        [close.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
        [close.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
        [close.widthAnchor constraintEqualToConstant:40], [close.heightAnchor constraintEqualToConstant:40],
        [title.topAnchor constraintEqualToAnchor:hero.bottomAnchor constant:4],
        [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:24],
        [title.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-24],
        [msg.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8],
        [msg.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:28],
        [msg.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-28],
        [join.topAnchor constraintEqualToAnchor:msg.bottomAnchor constant:14],
        [join.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:28],
        [join.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-28],
        [join.heightAnchor constraintEqualToConstant:52],
        [join.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-20],
    ]];
    overlay.alpha = 0;
    [UIView animateWithDuration:0.25 animations:^{ overlay.alpha = 1; }];
}

- (void)dismissBanner {
    UIView *o = _bannerOverlay;
    if (!o) { gShowingBanner = NO; return; }
    [UIView animateWithDuration:0.2 animations:^{ o.alpha = 0; } completion:^(BOOL f) {
        [o removeFromSuperview]; self->_bannerOverlay = nil; gShowingBanner = NO;
    }];
}
- (void)onBannerClose { [self markBannerShown]; [self dismissBanner]; }
- (void)onBannerJoin { [self markBannerShown]; [self openTelegram]; [self dismissBanner]; }

@end

__attribute__((constructor))
static void MaxVibeModInit(void) {
    @autoreleasepool {
        MaxVibeInstallPersistFixes();
        MaxVibeInstallAntiDelete();
        dispatch_async(dispatch_get_main_queue(), ^{
            [[MaxVibeModController shared] start];
        });
    }
}
