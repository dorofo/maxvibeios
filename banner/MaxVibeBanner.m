#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>

/*
 * MaxVibe injected mod: Telegram banner + Settings sheet + persist hooks.
 */

extern void MaxVibeInstallPersistFixes(void);

static NSString * const kConfigURL = @"https://dorofo.github.io/max-vibe-assets/config.json";
static NSString * const kTelegramURL = @"https://t.me/max_vibe";
static NSString * const kKeyFirst = @"mvibe_banner_first_launch";
static NSString * const kKeyLast = @"mvibe_banner_last_show_time";
static NSString * const kKeyBannerEnabled = @"mvibe_banner_enabled";
static NSString * const kKeyFabVisible = @"mvibe_fab_visible";
static const NSTimeInterval kDaySeconds = 86400.0;
static const NSTimeInterval kFetchTimeout = 4.0;
static const NSTimeInterval kInitialDelay = 5.0;
static const NSTimeInterval kActiveDelay = 3.0;

static BOOL gDidSchedule = NO;
static BOOL gShowingBanner = NO;
static BOOL gShowingSettings = NO;

@interface MaxVibeModController : NSObject
+ (instancetype)shared;
- (void)start;
- (void)openTelegram;
- (void)showSettings;
- (BOOL)bannerEnabled;
@end

@implementation MaxVibeModController {
    UIView *_bannerOverlay;
    UIView *_settingsOverlay;
    UIButton *_fab;
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

- (void)setBannerEnabled:(BOOL)on {
    [[self prefs] setBool:on forKey:kKeyBannerEnabled];
}

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

- (UIColor *)colorFromHex:(unsigned int)hex alpha:(CGFloat)a {
    return [UIColor colorWithRed:((hex >> 16) & 0xFF) / 255.0
                           green:((hex >> 8) & 0xFF) / 255.0
                            blue:(hex & 0xFF) / 255.0
                           alpha:a];
}

- (UIWindow *)keyWindow {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) return w;
            }
            if (ws.windows.count > 0) return ws.windows.firstObject;
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop
}

- (UIImage *)bannerImage {
    NSBundle *main = [NSBundle mainBundle];
    NSArray<NSString *> *rels = @[
        @"banner_character.png",
        @"Frameworks/banner_character.png",
    ];
    for (NSString *rel in rels) {
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
    UIApplication *app = UIApplication.sharedApplication;
    if (@available(iOS 10.0, *)) {
        [app openURL:url options:@{} completionHandler:nil];
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [app openURL:url];
#pragma clang diagnostic pop
    }
}

- (void)start {
    if (gDidSchedule) return;
    gDidSchedule = YES;

    MaxVibeInstallPersistFixes();

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kInitialDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self ensureFab];
        [self tryPresentBanner];
    });
}

- (void)onActive:(NSNotification *)note {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kActiveDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self ensureFab];
        [self tryPresentBanner];
    });
}

#pragma mark - FAB (open settings)

- (void)ensureFab {
    UIWindow *window = [self keyWindow];
    if (!window) return;
    if (_fab && _fab.superview) return;

    UIButton *fab = [UIButton buttonWithType:UIButtonTypeSystem];
    fab.frame = CGRectMake(window.bounds.size.width - 58, window.bounds.size.height * 0.62, 46, 46);
    fab.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    fab.backgroundColor = [self colorFromHex:0xE85A7A alpha:0.92];
    fab.layer.cornerRadius = 23;
    fab.layer.shadowColor = [UIColor blackColor].CGColor;
    fab.layer.shadowOpacity = 0.35;
    fab.layer.shadowRadius = 8;
    fab.layer.shadowOffset = CGSizeMake(0, 3);
    [fab setTitle:@"MV" forState:UIControlStateNormal];
    [fab setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    fab.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [fab addTarget:self action:@selector(showSettings) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onFabPan:)];
    [fab addGestureRecognizer:pan];

    [window addSubview:fab];
    _fab = fab;
}

- (void)onFabPan:(UIPanGestureRecognizer *)gr {
    UIView *v = gr.view;
    UIView *parent = v.superview;
    if (!parent) return;
    CGPoint t = [gr translationInView:parent];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [gr setTranslation:CGPointZero inView:parent];
    if (gr.state == UIGestureRecognizerStateEnded) {
        CGFloat x = v.center.x < parent.bounds.size.width * 0.5 ? 28 : parent.bounds.size.width - 28;
        [UIView animateWithDuration:0.2 animations:^{
            v.center = CGPointMake(x, MIN(MAX(v.center.y, 80), parent.bounds.size.height - 80));
        }];
    }
}

#pragma mark - Settings MaxVibe

- (UIView *)settingsRowTitle:(NSString *)title
                    subtitle:(NSString *)subtitle
                      action:(SEL)action
                    showChevron:(BOOL)chevron {
    UIButton *row = [UIButton buttonWithType:UIButtonTypeCustom];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.06];
    row.layer.cornerRadius = 14;
    [row addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];

    UILabel *t = [[UILabel alloc] init];
    t.text = title;
    t.textColor = [UIColor whiteColor];
    t.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    t.translatesAutoresizingMaskIntoConstraints = NO;
    t.userInteractionEnabled = NO;

    UILabel *s = [[UILabel alloc] init];
    s.text = subtitle;
    s.textColor = [self colorFromHex:0x8E858A alpha:1];
    s.font = [UIFont systemFontOfSize:12];
    s.numberOfLines = 2;
    s.translatesAutoresizingMaskIntoConstraints = NO;
    s.userInteractionEnabled = NO;

    [row addSubview:t];
    [row addSubview:s];

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
        ch.text = @"›";
        ch.textColor = [self colorFromHex:0xE8C4CE alpha:1];
        ch.font = [UIFont systemFontOfSize:28 weight:UIFontWeightLight];
        ch.translatesAutoresizingMaskIntoConstraints = NO;
        ch.userInteractionEnabled = NO;
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
    AudioServicesPlaySystemSound(1519);

    UIView *overlay = [[UIView alloc] initWithFrame:window.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];

    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [self colorFromHex:0x1A1218 alpha:1];
    card.layer.cornerRadius = 22;
    card.clipsToBounds = YES;

    UILabel *kicker = [[UILabel alloc] init];
    kicker.text = @"МОД НА MAX";
    kicker.textColor = [self colorFromHex:0xE85A7A alpha:1];
    kicker.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    kicker.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *title = [[UILabel alloc] init];
    title.text = @"Настройки MaxVibe";
    title.textColor = [self colorFromHex:0xE8C4CE alpha:1];
    title.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBold];
    title.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *sub = [[UILabel alloc] init];
    sub.text = @"листайте ниже · persist fix активен";
    sub.textColor = [self colorFromHex:0x8E858A alpha:1];
    sub.font = [UIFont systemFontOfSize:12];
    sub.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageView *hero = [[UIImageView alloc] initWithImage:[self bannerImage]];
    hero.contentMode = UIViewContentModeScaleAspectFit;
    hero.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setTitle:@"✕" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    close.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
    close.layer.cornerRadius = 18;
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close addTarget:self action:@selector(dismissSettings) forControlEvents:UIControlEventTouchUpInside];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *tg = [self settingsRowTitle:@"Telegram канал"
                               subtitle:@"Подписаться · t.me/max_vibe"
                                 action:@selector(onSettingsTelegram)
                             showChevron:YES];
    UIView *ban = [self settingsRowTitle:[self bannerEnabled] ? @"Баннер: включён" : @"Баннер: выключен"
                                subtitle:@"Показ стартового баннера раз в сутки"
                                  action:@selector(onSettingsToggleBanner)
                              showChevron:NO];
    ban.tag = 9001;
    UIView *force = [self settingsRowTitle:@"Показать баннер сейчас"
                                  subtitle:@"Сбросить таймер и открыть"
                                    action:@selector(onSettingsForceBanner)
                                showChevron:YES];
    UIView *icon = [self settingsRowTitle:@"Сменить иконку"
                                 subtitle:@"Скоро · пока только визуал"
                                   action:@selector(onSettingsStubIcon)
                               showChevron:YES];
    UIView *acc = [self settingsRowTitle:@"Аккаунты"
                                subtitle:@"Скоро · сменить / добавить"
                                  action:@selector(onSettingsStubAccounts)
                              showChevron:YES];

    [stack addArrangedSubview:tg];
    [stack addArrangedSubview:ban];
    [stack addArrangedSubview:force];
    [stack addArrangedSubview:icon];
    [stack addArrangedSubview:acc];

    [scroll addSubview:stack];
    [card addSubview:kicker];
    [card addSubview:title];
    [card addSubview:sub];
    [card addSubview:hero];
    [card addSubview:close];
    [card addSubview:scroll];
    [overlay addSubview:card];
    [window addSubview:overlay];
    _settingsOverlay = overlay;

    CGFloat width = MIN(window.bounds.size.width - 24, 400);
    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [card.widthAnchor constraintEqualToConstant:width],
        [card.heightAnchor constraintLessThanOrEqualToAnchor:overlay.heightAnchor multiplier:0.88],

        [kicker.topAnchor constraintEqualToAnchor:card.topAnchor constant:18],
        [kicker.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],

        [close.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [close.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [close.widthAnchor constraintEqualToConstant:36],
        [close.heightAnchor constraintEqualToConstant:36],

        [title.topAnchor constraintEqualToAnchor:kicker.bottomAnchor constant:6],
        [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [title.trailingAnchor constraintEqualToAnchor:close.leadingAnchor constant:-8],

        [sub.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:4],
        [sub.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],

        [hero.topAnchor constraintEqualToAnchor:sub.bottomAnchor constant:4],
        [hero.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-8],
        [hero.widthAnchor constraintEqualToConstant:110],
        [hero.heightAnchor constraintEqualToConstant:140],

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
    card.transform = CGAffineTransformMakeScale(0.94, 0.94);
    [UIView animateWithDuration:0.28 animations:^{
        overlay.alpha = 1;
        card.transform = CGAffineTransformIdentity;
    }];
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

- (void)onSettingsTelegram {
    [self openTelegram];
}

- (void)onSettingsToggleBanner {
    BOOL next = ![self bannerEnabled];
    [self setBannerEnabled:next];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"MaxVibe"
                                                                message:next ? @"Баннер включён" : @"Баннер выключен"
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    UIViewController *root = [self keyWindow].rootViewController;
    while (root.presentedViewController) root = root.presentedViewController;
    [root presentViewController:ac animated:YES completion:nil];
    [self dismissSettings];
}

- (void)onSettingsForceBanner {
    NSUserDefaults *p = [self prefs];
    [p setBool:YES forKey:kKeyFirst];
    [p setDouble:0 forKey:kKeyLast];
    [self setBannerEnabled:YES];
    [self dismissSettings];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gShowingBanner = NO;
        [self tryPresentBanner];
    });
}

- (void)onSettingsStubIcon {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Сменить иконку"
                                                                message:@"Пока недоступно на iOS. На Android уже есть."
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    UIViewController *root = [self keyWindow].rootViewController;
    while (root.presentedViewController) root = root.presentedViewController;
    [root presentViewController:ac animated:YES completion:nil];
}

- (void)onSettingsStubAccounts {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Аккаунты"
                                                                message:@"Скоро. Пока используй системный переключатель аккаунтов MAX."
                                                         preferredStyle:UIAlertControllerStyleAlert];
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
    [self fetchConfigThenShowOn:window];
}

- (void)fetchConfigThenShowOn:(UIWindow *)window {
    NSURL *url = [NSURL URLWithString:kConfigURL];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:kFetchTimeout];
    [req setValue:@"MaxVibe/iOS" forHTTPHeaderField:@"User-Agent"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSString *bannerText = nil;
        BOOL validLauncher = YES;
        if (!error && data.length > 0) {
            id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([obj isKindOfClass:[NSDictionary class]]) {
                NSDictionary *json = obj;
                id vl = json[@"valid_launcher"];
                if ([vl isKindOfClass:[NSNumber class]]) validLauncher = [vl boolValue];
                id bt = json[@"banner_text"];
                if ([bt isKindOfClass:[NSString class]] && [(NSString *)bt length] > 0) bannerText = bt;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!validLauncher) [self showKillSwitchOn:window];
            else [self showBannerOn:window message:bannerText];
        });
    }] resume];
}

- (void)showKillSwitchOn:(UIWindow *)window {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Лаунчер отключен"
                                                                message:@"Лаунчер отключен от работы, обновитесь в телеграм-канале"
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Обновиться в телеграм-канале"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) {
        [self openTelegram];
        gShowingBanner = NO;
    }]];
    UIViewController *root = window.rootViewController;
    while (root.presentedViewController) root = root.presentedViewController;
    [root presentViewController:ac animated:YES completion:nil];
}

- (void)showBannerOn:(UIWindow *)window message:(NSString *)message {
    if (_bannerOverlay) { [_bannerOverlay removeFromSuperview]; _bannerOverlay = nil; }
    NSString *text = message.length > 0 ? message : @"Подпишись на канал — обновления мода, фичи и вайб без воды";
    CGFloat width = MIN(window.bounds.size.width - 32, 360);

    UIView *overlay = [[UIView alloc] initWithFrame:window.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];

    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [self colorFromHex:0x1A1218 alpha:1];
    card.layer.cornerRadius = 20;
    card.clipsToBounds = YES;
    card.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageView *hero = [[UIImageView alloc] initWithImage:[self bannerImage]];
    hero.contentMode = UIViewContentModeScaleAspectFit;
    hero.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setTitle:@"✕" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    close.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.18];
    close.layer.cornerRadius = 20;
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close addTarget:self action:@selector(onBannerClose) forControlEvents:UIControlEventTouchUpInside];

    UILabel *title = [[UILabel alloc] init];
    title.text = @"MaxVibe в Telegram";
    title.textColor = [self colorFromHex:0xE8C4CE alpha:1];
    title.font = [UIFont boldSystemFontOfSize:20];
    title.textAlignment = NSTextAlignmentCenter;
    title.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *msg = [[UILabel alloc] init];
    msg.text = text;
    msg.textColor = [self colorFromHex:0x8E858A alpha:1];
    msg.font = [UIFont systemFontOfSize:14];
    msg.textAlignment = NSTextAlignmentCenter;
    msg.numberOfLines = 0;
    msg.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *join = [UIButton buttonWithType:UIButtonTypeSystem];
    [join setTitle:@"Подписаться в Telegram" forState:UIControlStateNormal];
    [join setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    join.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    join.backgroundColor = [self colorFromHex:0xE85A7A alpha:1];
    join.layer.cornerRadius = 14;
    join.translatesAutoresizingMaskIntoConstraints = NO;
    [join addTarget:self action:@selector(onBannerJoin) forControlEvents:UIControlEventTouchUpInside];

    [card addSubview:hero];
    [card addSubview:close];
    [card addSubview:title];
    [card addSubview:msg];
    [card addSubview:join];
    [overlay addSubview:card];
    [window addSubview:overlay];
    _bannerOverlay = overlay;

    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [card.widthAnchor constraintEqualToConstant:width],
        [hero.topAnchor constraintEqualToAnchor:card.topAnchor constant:8],
        [hero.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [hero.widthAnchor constraintEqualToConstant:220],
        [hero.heightAnchor constraintEqualToConstant:300],
        [close.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
        [close.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
        [close.widthAnchor constraintEqualToConstant:40],
        [close.heightAnchor constraintEqualToConstant:40],
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
    card.transform = CGAffineTransformMakeScale(0.92, 0.92);
    [UIView animateWithDuration:0.28 animations:^{
        overlay.alpha = 1;
        card.transform = CGAffineTransformIdentity;
    }];
}

- (void)dismissBanner {
    UIView *overlay = _bannerOverlay;
    if (!overlay) { gShowingBanner = NO; return; }
    [UIView animateWithDuration:0.2 animations:^{ overlay.alpha = 0; } completion:^(BOOL f) {
        [overlay removeFromSuperview];
        self->_bannerOverlay = nil;
        gShowingBanner = NO;
    }];
}

- (void)onBannerClose {
    [self markBannerShown];
    [self dismissBanner];
}

- (void)onBannerJoin {
    [self markBannerShown];
    [self openTelegram];
    [self dismissBanner];
}

@end

__attribute__((constructor))
static void MaxVibeModInit(void) {
    @autoreleasepool {
        // Persist hooks ASAP (before app touches keychain / app-group defaults)
        MaxVibeInstallPersistFixes();
        dispatch_async(dispatch_get_main_queue(), ^{
            [[MaxVibeModController shared] start];
        });
    }
}
