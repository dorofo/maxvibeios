#import <Foundation/Foundation.h>
#import <objc/runtime.h>

/*
 * SAFE persist (no fishhook):
 * Crash logs showed SIGABRT from NSFileManager contentsOfDirectoryAtURL —
 * typical when group.ru.oneme.app container URL is nil/unusable under TrollStore.
 * Redirect App Group container + UserDefaults suite into Library/mvibe_group/.
 */

static NSURL *MVLocalGroupContainer(NSString *groupIdentifier) {
    NSString *lib = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
    if (!lib) lib = NSTemporaryDirectory();
    NSString *gid = groupIdentifier.length ? groupIdentifier : @"group.unknown";
    NSString *safe = [gid stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    NSString *path = [[lib stringByAppendingPathComponent:@"mvibe_group"]
                      stringByAppendingPathComponent:safe];
    NSError *err = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:path
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&err];
    return [NSURL fileURLWithPath:path isDirectory:YES];
}

static BOOL MVIsOnemeGroup(NSString *groupIdentifier) {
    if (![groupIdentifier isKindOfClass:[NSString class]]) return NO;
    return [groupIdentifier isEqualToString:@"group.ru.oneme.app"] ||
           [groupIdentifier hasPrefix:@"group.ru.oneme."];
}

@implementation NSFileManager (MaxVibePersist)

- (NSURL *)mvibe_containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
    if (MVIsOnemeGroup(groupIdentifier)) {
        return MVLocalGroupContainer(groupIdentifier);
    }
    NSURL *url = [self mvibe_containerURLForSecurityApplicationGroupIdentifier:groupIdentifier];
    if (!url && groupIdentifier.length) {
        // Any missing group container → local fallback (prevents contentsOfDirectory crash)
        return MVLocalGroupContainer(groupIdentifier);
    }
    return url;
}

+ (void)mvibeInstallContainerRedirect {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = [NSFileManager class];
        SEL orig = @selector(containerURLForSecurityApplicationGroupIdentifier:);
        SEL swiz = @selector(mvibe_containerURLForSecurityApplicationGroupIdentifier:);
        Method mOrig = class_getInstanceMethod(cls, orig);
        Method mSwiz = class_getInstanceMethod(cls, swiz);
        if (mOrig && mSwiz) method_exchangeImplementations(mOrig, mSwiz);
    });
}

@end

static NSString *MVRedirectSuiteName(NSString *suiteName) {
    if (![suiteName isKindOfClass:[NSString class]] || suiteName.length == 0) return suiteName;
    if (MVIsOnemeGroup(suiteName)) {
        return @"mvibe.local.group.ru.oneme.app";
    }
    return suiteName;
}

@implementation NSUserDefaults (MaxVibePersist)

- (instancetype)mvibe_initWithSuiteName:(NSString *)suitename {
    return [self mvibe_initWithSuiteName:MVRedirectSuiteName(suitename)];
}

+ (void)mvibeInstallSuiteRedirect {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Method orig = class_getInstanceMethod([NSUserDefaults class], @selector(initWithSuiteName:));
        Method swiz = class_getInstanceMethod([NSUserDefaults class], @selector(mvibe_initWithSuiteName:));
        if (orig && swiz) method_exchangeImplementations(orig, swiz);
    });
}

@end

void MaxVibeInstallPersistFixes(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [NSFileManager mvibeInstallContainerRedirect];
        [NSUserDefaults mvibeInstallSuiteRedirect];
    });
}
