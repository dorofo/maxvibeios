#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import "fishhook.h"

/*
 * Persist fixes for decrypted / TrollStore IPA:
 * 1) Strip keychain access-group so items bind to the app container
 * 2) Redirect App Group UserDefaults suite to a local suite
 *
 * These are the usual causes of "login every launch" on dumped messengers.
 */

static OSStatus (*orig_SecItemCopyMatching)(CFDictionaryRef query, CFTypeRef *result) = NULL;
static OSStatus (*orig_SecItemAdd)(CFDictionaryRef attributes, CFTypeRef *result) = NULL;
static OSStatus (*orig_SecItemUpdate)(CFDictionaryRef query, CFDictionaryRef attrsToUpdate) = NULL;
static OSStatus (*orig_SecItemDelete)(CFDictionaryRef query) = NULL;

static CFMutableDictionaryRef MVCopyQueryWithoutAccessGroup(CFDictionaryRef query) {
    if (!query) return NULL;
    CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, query);
    if (!m) return NULL;
    CFDictionaryRemoveValue(m, kSecAttrAccessGroup);
    return m;
}

static OSStatus mv_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    CFMutableDictionaryRef stripped = MVCopyQueryWithoutAccessGroup(query);
    OSStatus st = errSecParam;
    if (stripped && orig_SecItemCopyMatching) {
        st = orig_SecItemCopyMatching(stripped, result);
        CFRelease(stripped);
        if (st == errSecSuccess) return st;
    } else if (stripped) {
        CFRelease(stripped);
    }
    if (orig_SecItemCopyMatching) return orig_SecItemCopyMatching(query, result);
    return st;
}

static OSStatus mv_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    CFMutableDictionaryRef stripped = MVCopyQueryWithoutAccessGroup(attributes);
    OSStatus st = errSecParam;
    if (stripped && orig_SecItemAdd) {
        st = orig_SecItemAdd(stripped, result);
        CFRelease(stripped);
        if (st == errSecSuccess || st == errSecDuplicateItem) return st;
    } else if (stripped) {
        CFRelease(stripped);
    }
    if (orig_SecItemAdd) return orig_SecItemAdd(attributes, result);
    return st;
}

static OSStatus mv_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attrsToUpdate) {
    CFMutableDictionaryRef q = MVCopyQueryWithoutAccessGroup(query);
    CFMutableDictionaryRef a = MVCopyQueryWithoutAccessGroup(attrsToUpdate);
    OSStatus st = errSecParam;
    if (q && a && orig_SecItemUpdate) {
        st = orig_SecItemUpdate(q, a);
    }
    if (q) CFRelease(q);
    if (a) CFRelease(a);
    if (st == errSecSuccess) return st;
    if (orig_SecItemUpdate) return orig_SecItemUpdate(query, attrsToUpdate);
    return st;
}

static OSStatus mv_SecItemDelete(CFDictionaryRef query) {
    CFMutableDictionaryRef stripped = MVCopyQueryWithoutAccessGroup(query);
    OSStatus st = errSecParam;
    if (stripped && orig_SecItemDelete) {
        st = orig_SecItemDelete(stripped);
        CFRelease(stripped);
        if (st == errSecSuccess || st == errSecItemNotFound) return st;
    } else if (stripped) {
        CFRelease(stripped);
    }
    if (orig_SecItemDelete) return orig_SecItemDelete(query);
    return st;
}

static NSString *MVRedirectSuiteName(NSString *suiteName) {
    if (!suiteName) return suiteName;
    if ([suiteName isEqualToString:@"group.ru.oneme.app"] ||
        [suiteName hasPrefix:@"group.ru.oneme."] ||
        [suiteName containsString:@"group.ru.oneme.app"]) {
        return @"mvibe.local.group.ru.oneme.app";
    }
    return suiteName;
}

@implementation NSUserDefaults (MaxVibePersist)

+ (void)mvibeInstallSuiteRedirect {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = [NSUserDefaults class];
        SEL origSel = @selector(initWithSuiteName:);
        SEL swizSel = @selector(mvibe_initWithSuiteName:);
        Method orig = class_getInstanceMethod(cls, origSel);
        Method swiz = class_getInstanceMethod(cls, swizSel);
        if (orig && swiz) {
            method_exchangeImplementations(orig, swiz);
        }
    });
}

- (instancetype)mvibe_initWithSuiteName:(NSString *)suitename {
    return [self mvibe_initWithSuiteName:MVRedirectSuiteName(suitename)];
}

@end

void MaxVibeInstallPersistFixes(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        struct rebinding rebs[] = {
            {"SecItemCopyMatching", (void *)mv_SecItemCopyMatching, (void **)&orig_SecItemCopyMatching},
            {"SecItemAdd", (void *)mv_SecItemAdd, (void **)&orig_SecItemAdd},
            {"SecItemUpdate", (void *)mv_SecItemUpdate, (void **)&orig_SecItemUpdate},
            {"SecItemDelete", (void *)mv_SecItemDelete, (void **)&orig_SecItemDelete},
        };
        rebind_symbols(rebs, sizeof(rebs) / sizeof(rebs[0]));
        [NSUserDefaults mvibeInstallSuiteRedirect];
    });
}
