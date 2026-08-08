#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

/*
 * MaxVibe startup Telegram banner (injected dylib).
 * Mirrors Android MvibeStartupBannerHelper behaviour.
 */

static NSString * const kConfigURL = @"https://dorofo.github.io/max-vibe-assets/config.json";
static NSString * const kTelegramURL = @"https://t.me/max_vibe";
static NSString * const kPrefsSuite = @"mvibe_banner_prefs";
static NSString * const kKeyFirst = @"first_launch";
static NSString * const kKeyLast = @"last_show_time";
static const NSTimeInterval kDaySeconds = 86400.0;
static const NSTimeInterval kFetchTimeout = 4.0;

static BOOL gDidSchedule = NO;
static BOOL gShowing = NO;

@interface MaxVibeBannerController : NSObject
+ (instancetype)shared;
- (void)start;
@end

@implementation MaxVibeBannerController {
    UIView *_overlay;
    UIView *_card;
    UILabel *_messageLabel;
    BOOL _killMode;
}

+ (instancetype)shared {
    static MaxVibeBannerController *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [MaxVibeBannerController new]; });
    return s;
}

- (NSUserDefaults *)prefs {
    return [[NSUserDefaults alloc] initWithSuiteName:kPrefsSuite] ?: [NSUserDefaults standardUserDefaults];
}

- (BOOL)shouldShow {
    NSUserDefaults *p = [self prefs];
    BOOL first = [p objectForKey:kKeyFirst] == nil ? YES : [p boolForKey:kKeyFirst];
    // Mirror Android: KEY_FIRST defaults to true; after dismiss we set false.
    if ([p objectForKey:kKeyFirst] != nil) {
        first = [p boolForKey:kKeyFirst];
    } else {
        first = YES;
    }
    NSTimeInterval last = [p doubleForKey:kKeyLast];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if ((now - last) < kDaySeconds && !first) {
        return NO;
    }
    return YES;
}

- (void)markShown {
    NSUserDefaults *p = [self prefs];
    [p setBool:NO forKey:kKeyFirst];
    [p setDouble:[[NSDate date] timeIntervalSince1970] forKey:kKeyLast];
    [p synchronize];
}

- (void)start {
    if (gDidSchedule) return;
    gDidSchedule = YES;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];

    // Also try shortly after load in case we missed the first active.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self tryPresent];
    });
}

- (void)onActive:(NSNotification *)note {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self tryPresent];
    });
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

- (void)tryPresent {
    if (gShowing) return;
    if (![self shouldShow]) return;
    UIWindow *window = [self keyWindow];
    if (!window) return;

    gShowing = YES;
    [self fetchConfigThenShowOn:window];
}

- (void)fetchConfigThenShowOn:(UIWindow *)window {
    NSURL *url = [NSURL URLWithString:kConfigURL];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:kFetchTimeout];
    [req setValue:@"MaxVibe/iOS" forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSString *bannerText = nil;
            BOOL validLauncher = YES;

            if (!error && data.length > 0) {
                NSError *jsonErr = nil;
                id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
                if (!jsonErr && [obj isKindOfClass:[NSDictionary class]]) {
                    NSDictionary *json = (NSDictionary *)obj;
                    id vl = json[@"valid_launcher"];
                    if ([vl isKindOfClass:[NSNumber class]]) {
                        validLauncher = [vl boolValue];
                    }
                    id bt = json[@"banner_text"];
                    if ([bt isKindOfClass:[NSString class]] && [(NSString *)bt length] > 0) {
                        bannerText = (NSString *)bt;
                    }
                }
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                if (!validLauncher) {
                    [self showKillSwitchOn:window];
                } else {
                    [self showBannerOn:window message:bannerText];
                }
            });
        }];
    [task resume];
}

- (UIImage *)bannerImage {
    // Prefer image next to dylib / in Frameworks, then app bundle root.
    NSArray<NSString *> *candidates = @[
        @"banner_character.png",
        @"Frameworks/banner_character.png",
        @"Frameworks/MaxVibeBanner.bundle/banner_character.png",
    ];
    NSBundle *main = [NSBundle mainBundle];
    for (NSString *rel in candidates) {
        NSString *path = [main pathForResource:[rel stringByDeletingPathExtension]
                                        ofType:[rel pathExtension]
                                   inDirectory:[rel stringByDeletingLastPathComponent].length
                                               ? [rel stringByDeletingLastPathComponent]
                                               : nil];
        if (!path) {
            path = [[main.bundlePath stringByAppendingPathComponent:rel] copy];
        }
        if (path && [[NSFileManager defaultManager] fileExistsAtPath:path]) {
            UIImage *img = [UIImage imageWithContentsOfFile:path];
            if (img) return img;
        }
    }

    // Absolute path via executable dir
    NSString *exe = main.executablePath;
    NSString *fw = [[[exe stringByDeletingLastPathComponent]
                     stringByAppendingPathComponent:@"Frameworks"]
                    stringByAppendingPathComponent:@"banner_character.png"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:fw]) {
        return [UIImage imageWithContentsOfFile:fw];
    }
    return nil;
}

- (UIColor *)colorFromHex:(unsigned int)hex alpha:(CGFloat)a {
    return [UIColor colorWithRed:((hex >> 16) & 0xFF) / 255.0
                           green:((hex >> 8) & 0xFF) / 255.0
                            blue:(hex & 0xFF) / 255.0
                           alpha:a];
}

- (void)showKillSwitchOn:(UIWindow *)window {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Лаунчер отключен"
                                                                message:@"Лаунчер отключен от работы, обновитесь в телеграм-канале"
                                                         preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *go = [UIAlertAction actionWithTitle:@"Обновиться в телеграм-канале"
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *action) {
        [self openTelegram];
        // Keep blocking — show again shortly
        gShowing = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self showKillSwitchOn:[self keyWindow] ?: window];
        });
    }];
    [ac addAction:go];
    UIViewController *root = window.rootViewController;
    while (root.presentedViewController) root = root.presentedViewController;
    if (root) {
        [root presentViewController:ac animated:YES completion:nil];
    }
}

- (void)showBannerOn:(UIWindow *)window message:(NSString *)message {
    if (_overlay) {
        [_overlay removeFromSuperview];
        _overlay = nil;
    }

    NSString *text = message.length > 0
        ? message
        : @"Подпишись на канал — обновления мода, фичи и вайб без воды";

    CGFloat pad = 16.0;
    CGFloat width = MIN(window.bounds.size.width - pad * 2, 360.0);

    UIView *overlay = [[UIView alloc] initWithFrame:window.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
    overlay.accessibilityIdentifier = @"MaxVibeBannerOverlay";

    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [self colorFromHex:0x1A1218 alpha:1.0];
    card.layer.cornerRadius = 20.0;
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
    close.layer.cornerRadius = 20.0;
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close addTarget:self action:@selector(onClose) forControlEvents:UIControlEventTouchUpInside];

    UILabel *title = [[UILabel alloc] init];
    title.text = @"MaxVibe в Telegram";
    title.textColor = [self colorFromHex:0xE8C4CE alpha:1.0];
    title.font = [UIFont boldSystemFontOfSize:20];
    title.textAlignment = NSTextAlignmentCenter;
    title.numberOfLines = 0;
    title.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *msg = [[UILabel alloc] init];
    msg.text = text;
    msg.textColor = [self colorFromHex:0x8E858A alpha:1.0];
    msg.font = [UIFont systemFontOfSize:14];
    msg.textAlignment = NSTextAlignmentCenter;
    msg.numberOfLines = 0;
    msg.translatesAutoresizingMaskIntoConstraints = NO;
    _messageLabel = msg;

    UIButton *join = [UIButton buttonWithType:UIButtonTypeSystem];
    [join setTitle:@"Подписаться в Telegram" forState:UIControlStateNormal];
    [join setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    join.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    join.backgroundColor = [self colorFromHex:0xE85A7A alpha:1.0];
    join.layer.cornerRadius = 14.0;
    join.translatesAutoresizingMaskIntoConstraints = NO;
    [join addTarget:self action:@selector(onJoin) forControlEvents:UIControlEventTouchUpInside];

    [card addSubview:hero];
    [card addSubview:close];
    [card addSubview:title];
    [card addSubview:msg];
    [card addSubview:join];
    [overlay addSubview:card];
    [window addSubview:overlay];

    _overlay = overlay;
    _card = card;

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

- (void)dismissOverlay {
    if (!_overlay) {
        gShowing = NO;
        return;
    }
    UIView *overlay = _overlay;
    [UIView animateWithDuration:0.2 animations:^{
        overlay.alpha = 0;
    } completion:^(BOOL finished) {
        [overlay removeFromSuperview];
        self->_overlay = nil;
        self->_card = nil;
        gShowing = NO;
    }];
}

- (void)onClose {
    [self markShown];
    [self dismissOverlay];
}

- (void)onJoin {
    [self markShown];
    [self openTelegram];
    [self dismissOverlay];
}

- (void)openTelegram {
    NSURL *url = [NSURL URLWithString:kTelegramURL];
    UIApplication *app = UIApplication.sharedApplication;
    if ([app canOpenURL:url]) {
        if (@available(iOS 10.0, *)) {
            [app openURL:url options:@{} completionHandler:nil];
        } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [app openURL:url];
#pragma clang diagnostic pop
        }
    }
}

@end

__attribute__((constructor))
static void MaxVibeBannerInit(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[MaxVibeBannerController shared] start];
        });
    }
}
