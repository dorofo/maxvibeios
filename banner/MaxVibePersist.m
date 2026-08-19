#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import "fishhook.h"

/*
 * Persist for TrollStore / decrypted MAX:
 * 1) App Group container → Library/mvibe_group (fixes nil/broken group URL)
 * 2) Soft-catch contentsOfDirectory exceptions (SIGABRT safety net)
 * 3) UserDefaults suite redirect for group.ru.oneme.app
 * 4) SecItem CopyMatching+Add rebound ONLY in main image (session tokens)
 */

#pragma mark - App Group container

static NSURL *MVLocalGroupContainer(NSString *groupIdentifier) {
    NSString *lib = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
    if (!lib) lib = NSTemporaryDirectory();
    NSString *gid = groupIdentifier.length ? groupIdentifier : @"group.unknown";
    NSString *safe = [gid stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    NSString *path = [[lib stringByAppendingPathComponent:@"mvibe_group"]
                      stringByAppendingPathComponent:safe];
    [[NSFileManager defaultManager] createDirectoryAtPath:path
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
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
        return MVLocalGroupContainer(groupIdentifier);
    }
    return url;
}

- (NSArray<NSURL *> *)mvibe_contentsOfDirectoryAtURL:(NSURL *)url
                         includingPropertiesForKeys:(NSArray<NSURLResourceKey> *)keys
                                            options:(NSDirectoryEnumerationOptions)mask
                                              error:(NSError **)error {
    if (!url) {
        if (error) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:NSFileReadNoSuchFileError
                                     userInfo:nil];
        }
        return @[];
    }
    @try {
        NSArray *result = [self mvibe_contentsOfDirectoryAtURL:url
                                   includingPropertiesForKeys:keys
                                                      options:mask
                                                        error:error];
        return result ?: @[];
    } @catch (NSException *ex) {
        if (error) {
            *error = [NSError errorWithDomain:@"MaxVibe"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: ex.reason ?: @"contentsOfDirectory failed"}];
        }
        return @[];
    }
}

- (NSArray<NSString *> *)mvibe_contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)error {
    if (!path.length) {
        if (error) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:NSFileReadNoSuchFileError
                                     userInfo:nil];
        }
        return @[];
    }
    @try {
        NSArray *result = [self mvibe_contentsOfDirectoryAtPath:path error:error];
        return result ?: @[];
    } @catch (NSException *ex) {
        if (error) {
            *error = [NSError errorWithDomain:@"MaxVibe"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: ex.reason ?: @"contentsOfDirectory failed"}];
        }
        return @[];
    }
}

+ (void)mvibeInstallContainerRedirect {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = [NSFileManager class];
        Method m1 = class_getInstanceMethod(cls, @selector(containerURLForSecurityApplicationGroupIdentifier:));
        Method s1 = class_getInstanceMethod(cls, @selector(mvibe_containerURLForSecurityApplicationGroupIdentifier:));
        if (m1 && s1) method_exchangeImplementations(m1, s1);

        Method m2 = class_getInstanceMethod(cls, @selector(contentsOfDirectoryAtURL:includingPropertiesForKeys:options:error:));
        Method s2 = class_getInstanceMethod(cls, @selector(mvibe_contentsOfDirectoryAtURL:includingPropertiesForKeys:options:error:));
        if (m2 && s2) method_exchangeImplementations(m2, s2);

        Method m3 = class_getInstanceMethod(cls, @selector(contentsOfDirectoryAtPath:error:));
        Method s3 = class_getInstanceMethod(cls, @selector(mvibe_contentsOfDirectoryAtPath:error:));
        if (m3 && s3) method_exchangeImplementations(m3, s3);
    });
}

@end

#pragma mark - UserDefaults suite

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

#pragma mark - Keychain (main image only)

static OSStatus (*orig_SecItemCopyMatching)(CFDictionaryRef, CFTypeRef *) = NULL;
static OSStatus (*orig_SecItemAdd)(CFDictionaryRef, CFTypeRef *) = NULL;
static OSStatus (*orig_SecItemUpdate)(CFDictionaryRef, CFDictionaryRef) = NULL;
static OSStatus (*orig_SecItemDelete)(CFDictionaryRef) = NULL;

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

static OSStatus mv_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    if (!orig_SecItemUpdate) return errSecParam;
    CFMutableDictionaryRef strippedQuery = MVStripAccessGroup(query);
    CFMutableDictionaryRef strippedAttrs = MVStripAccessGroup(attributesToUpdate);
    if (strippedQuery || strippedAttrs) {
        OSStatus st = orig_SecItemUpdate(strippedQuery ?: query, strippedAttrs ?: attributesToUpdate);
        if (strippedQuery) CFRelease(strippedQuery);
        if (strippedAttrs) CFRelease(strippedAttrs);
        if (st == errSecSuccess || st == errSecItemNotFound) return st;
    }
    return orig_SecItemUpdate(query, attributesToUpdate);
}

static OSStatus mv_SecItemDelete(CFDictionaryRef query) {
    if (!orig_SecItemDelete) return errSecParam;
    CFMutableDictionaryRef stripped = MVStripAccessGroup(query);
    if (stripped) {
        OSStatus st = orig_SecItemDelete(stripped);
        CFRelease(stripped);
        if (st == errSecSuccess || st == errSecItemNotFound) return st;
    }
    return orig_SecItemDelete(query);
}

static void MVRebindMainImageOnly(void) {
    if (_dyld_image_count() == 0) return;
    const struct mach_header *hdr = _dyld_get_image_header(0);
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    if (!hdr) return;
    struct rebinding rebs[] = {
        {"SecItemCopyMatching", (void *)mv_SecItemCopyMatching, (void **)&orig_SecItemCopyMatching},
        {"SecItemAdd", (void *)mv_SecItemAdd, (void **)&orig_SecItemAdd},
        {"SecItemUpdate", (void *)mv_SecItemUpdate, (void **)&orig_SecItemUpdate},
        {"SecItemDelete", (void *)mv_SecItemDelete, (void **)&orig_SecItemDelete},
    };
    rebind_symbols_image((void *)hdr, slide, rebs, sizeof(rebs) / sizeof(rebs[0]));
}

void MaxVibeInstallPersistFixes(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [NSFileManager mvibeInstallContainerRedirect];
        [NSUserDefaults mvibeInstallSuiteRedirect];
        MVRebindMainImageOnly();
    });
}
