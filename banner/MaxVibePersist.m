#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import "fishhook.h"

/*
 * Session persist: rebind SecItem ONLY in main image.
 * Only CopyMatching + Add (Update/Delete hooks were extra crash surface).
 */

static OSStatus (*orig_SecItemCopyMatching)(CFDictionaryRef, CFTypeRef *) = NULL;
static OSStatus (*orig_SecItemAdd)(CFDictionaryRef, CFTypeRef *) = NULL;

static CFMutableDictionaryRef MVStripAccessGroup(CFDictionaryRef dict) {
    if (!dict) return NULL;
    if (CFGetTypeID(dict) != CFDictionaryGetTypeID()) return NULL;
    CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, dict);
    if (!m) return NULL;
    CFDictionaryRemoveValue(m, kSecAttrAccessGroup);
    return m;
}

static OSStatus mv_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    if (!orig_SecItemCopyMatching) return errSecParam;
    OSStatus st = orig_SecItemCopyMatching(query, result);
    if (st == errSecSuccess) return st;
    CFMutableDictionaryRef stripped = MVStripAccessGroup(query);
    if (!stripped) return st;
    OSStatus st2 = orig_SecItemCopyMatching(stripped, result);
    CFRelease(stripped);
    return st2;
}

static OSStatus mv_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    if (!orig_SecItemAdd) return errSecParam;
    CFMutableDictionaryRef stripped = MVStripAccessGroup(attributes);
    if (stripped) {
        OSStatus st = orig_SecItemAdd(stripped, result);
        CFRelease(stripped);
        if (st == errSecSuccess || st == errSecDuplicateItem) return st;
    }
    return orig_SecItemAdd(attributes, result);
}

static NSString *MVRedirectSuiteName(NSString *suiteName) {
    if (![suiteName isKindOfClass:[NSString class]] || suiteName.length == 0) return suiteName;
    if ([suiteName isEqualToString:@"group.ru.oneme.app"] ||
        [suiteName hasPrefix:@"group.ru.oneme."]) {
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

static void MVRebindMainImageOnly(void) {
    if (_dyld_image_count() == 0) return;
    const struct mach_header *hdr = _dyld_get_image_header(0);
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    if (!hdr) return;
    struct rebinding rebs[] = {
        {"SecItemCopyMatching", (void *)mv_SecItemCopyMatching, (void **)&orig_SecItemCopyMatching},
        {"SecItemAdd", (void *)mv_SecItemAdd, (void **)&orig_SecItemAdd},
    };
    rebind_symbols_image((void *)hdr, slide, rebs, sizeof(rebs) / sizeof(rebs[0]));
}

void MaxVibeInstallPersistFixes(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [NSUserDefaults mvibeInstallSuiteRedirect];
        MVRebindMainImageOnly();
    });
}
