#import <Foundation/Foundation.h>
#import <objc/runtime.h>

/*
 * Persist fix without fishhook (SecItem rebinding was crashing ~2s after launch).
 * Redirect App Group UserDefaults to a local suite so session prefs survive
 * when group.ru.oneme.app container is unavailable under TrollStore.
 */

static NSString *MVRedirectSuiteName(NSString *suiteName) {
    if (![suiteName isKindOfClass:[NSString class]] || suiteName.length == 0) {
        return suiteName;
    }
    if ([suiteName isEqualToString:@"group.ru.oneme.app"] ||
        [suiteName hasPrefix:@"group.ru.oneme."]) {
        return @"mvibe.local.group.ru.oneme.app";
    }
    return suiteName;
}

@implementation NSUserDefaults (MaxVibePersist)

- (instancetype)mvibe_initWithSuiteName:(NSString *)suitename {
    @try {
        return [self mvibe_initWithSuiteName:MVRedirectSuiteName(suitename)];
    } @catch (__unused NSException *ex) {
        return [self mvibe_initWithSuiteName:suitename];
    }
}

+ (void)mvibeInstallSuiteRedirect {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = [NSUserDefaults class];
        Method orig = class_getInstanceMethod(cls, @selector(initWithSuiteName:));
        Method swiz = class_getInstanceMethod(cls, @selector(mvibe_initWithSuiteName:));
        if (orig && swiz) {
            method_exchangeImplementations(orig, swiz);
        }
    });
}

@end

void MaxVibeInstallPersistFixes(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [NSUserDefaults mvibeInstallSuiteRedirect];
    });
}
