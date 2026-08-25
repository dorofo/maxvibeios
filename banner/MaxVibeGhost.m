#import "MaxVibeGhost.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdarg.h>
#import <string.h>

/*
 * MaxVibe privacy toggles (default OFF, runtime flag is source of truth).
 *
 * hide-read    — subclass-only override of OKMReadMarkTask perform (do NOT enqueue-drop)
 * hide-typing  — no-op typing sender start/timer + TypingService userDidType
 * hide-online  — force ping interactive=NO on OKMMessengerClient (Android tgc)
 * hide-vpn     — isRestricted=NO + shouldIgnore + do not present restriction UI
 *
 * Never hook sendData: / OKMBaseTask perform (reply crash + lost reply link).
 * Never hook serializeBlock (sticker panel).
 */

static NSString * const kPrefOnline = @"mvibe_hide_online_enabled";
static NSString * const kPrefRead = @"mvibe_hide_read_enabled";
static NSString * const kPrefTyping = @"mvibe_hide_typing_enabled";
static NSString * const kPrefVpn = @"mvibe_hide_vpn_enabled";

static BOOL gRtOnline = NO;
static BOOL gRtRead = NO;
static BOOL gRtTyping = NO;
static BOOL gRtVpn = NO;
static BOOL gRtLoaded = NO;

#pragma mark - Prefs + runtime

static void MVLoadRuntime(void) {
    if (gRtLoaded) return;
    NSUserDefaults *p = [NSUserDefaults standardUserDefaults];
    gRtOnline = [p objectForKey:kPrefOnline] ? [p boolForKey:kPrefOnline] : NO;
    gRtRead = [p objectForKey:kPrefRead] ? [p boolForKey:kPrefRead] : NO;
    gRtTyping = [p objectForKey:kPrefTyping] ? [p boolForKey:kPrefTyping] : NO;
    gRtVpn = [p objectForKey:kPrefVpn] ? [p boolForKey:kPrefVpn] : NO;
    gRtLoaded = YES;
}

BOOL MaxVibeHideOnlineEnabled(void) { MVLoadRuntime(); return gRtOnline; }
BOOL MaxVibeHideReadEnabled(void) { MVLoadRuntime(); return gRtRead; }
BOOL MaxVibeHideTypingEnabled(void) { MVLoadRuntime(); return gRtTyping; }
BOOL MaxVibeHideVpnEnabled(void) { MVLoadRuntime(); return gRtVpn; }

void MaxVibeSetHideOnlineEnabled(BOOL enabled) {
    gRtLoaded = YES; gRtOnline = enabled;
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kPrefOnline];
}
void MaxVibeSetHideReadEnabled(BOOL enabled) {
    gRtLoaded = YES; gRtRead = enabled;
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kPrefRead];
}
void MaxVibeSetHideTypingEnabled(BOOL enabled) {
    gRtLoaded = YES; gRtTyping = enabled;
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kPrefTyping];
}
void MaxVibeSetHideVpnEnabled(BOOL enabled) {
    gRtLoaded = YES; gRtVpn = enabled;
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kPrefVpn];
}

#pragma mark - Log

static void MVGLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void MVGLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[MaxVibeGhost] %@", line);
    @try {
        NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        if (!doc.length) return;
        NSString *path = [doc stringByAppendingPathComponent:@"mvibe_ghost.log"];
        NSString *stamp = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                         dateStyle:NSDateFormatterNoStyle
                                                         timeStyle:NSDateFormatterMediumStyle];
        NSString *row = [NSString stringWithFormat:@"%@ %@\n", stamp, line];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [row writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:[row dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (__unused NSException *ex) {}
}

static Method MVOwnMethod(Class cls, SEL sel) {
    if (!cls || !sel) return NULL;
    unsigned count = 0;
    Method *list = class_copyMethodList(cls, &count);
    Method found = NULL;
    for (unsigned i = 0; i < count; i++) {
        if (method_getName(list[i]) == sel) { found = list[i]; break; }
    }
    if (list) free(list);
    return found;
}

static BOOL MVHookOwn(Class cls, SEL sel, IMP replacement, IMP *origOut, NSString *tag) {
    Method m = MVOwnMethod(cls, sel);
    if (!m) {
        MVGLog(@"%@: no own method", tag);
        return NO;
    }
    if (origOut) *origOut = method_getImplementation(m);
    method_setImplementation(m, replacement);
    MVGLog(@"%@: OK (%@)", tag, NSStringFromClass(cls));
    return YES;
}

static BOOL MVIsReadTask(id task) {
    if (!task) return NO;
    NSString *cls = NSStringFromClass([task class]);
    return [cls hasSuffix:@"ReadMarkTask"] || [cls isEqualToString:@"OKMBatchReadLogTask"];
}

/** Android allows SET_AS_UNREAD through ghost. Do NOT treat an unread-count as that flag. */
static BOOL MVReadTaskIsUnreadMark(id task) {
    if (!task) return NO;
    @try {
        for (NSString *key in @[@"markedAsUnread", @"setAsUnread"]) {
            id flagged = [task valueForKey:key];
            if ([flagged respondsToSelector:@selector(boolValue)] && [flagged boolValue]) return YES;
        }
        id mt = [task valueForKey:@"markType"];
        if (!mt) return NO;
        NSString *s = [[mt description] uppercaseString];
        if ([s containsString:@"SET_AS_UNREAD"]) return YES;
        if ([s isEqualToString:@"UNREAD"] || [s isEqualToString:@"MARK_AS_UNREAD"]) return YES;
    } @catch (__unused NSException *ex) {}
    return NO;
}

#pragma mark - Orig IMPs

static IMP gOrigStartTyping = NULL;
static IMP gOrigTimerFired = NULL;
static IMP gOrigUserDidType = NULL;
static IMP gOrigSendTypingNotif = NULL;
static IMP gOrigPingInteractive = NULL;
static IMP gOrigSendPingIfNeeded = NULL;
static IMP gOrigSetInteractive = NULL;
static IMP gOrigRMPerform = NULL;
static IMP gOrigRMWork = NULL;
static IMP gOrigBRPerform = NULL;
static IMP gOrigBRWork = NULL;
static IMP gOrigPresentVC = NULL;
static IMP gOrigShowVC = NULL;
static NSMutableDictionary *gOrigByKey = nil;

static NSString *MVOrigKey(Class cls, SEL sel) {
    return [NSString stringWithFormat:@"%s|%s", class_getName(cls), sel_getName(sel)];
}
static void MVSaveOrig(Class cls, SEL sel, IMP imp) {
    if (!gOrigByKey) gOrigByKey = [[NSMutableDictionary alloc] init];
    if (imp) gOrigByKey[MVOrigKey(cls, sel)] = [NSValue valueWithPointer:(void *)imp];
}
static IMP MVLoadOrig(id self, SEL sel) {
    Class cls = object_getClass(self);
    while (cls) {
        NSValue *v = gOrigByKey[MVOrigKey(cls, sel)];
        if (v) return (IMP)v.pointerValue;
        cls = class_getSuperclass(cls);
    }
    return NULL;
}

#pragma mark - Typing

static void mvibe_startTyping(id self, SEL _cmd, id type, id chat, id key) {
    if (MaxVibeHideTypingEnabled()) return;
    if (gOrigStartTyping) ((void (*)(id, SEL, id, id, id))gOrigStartTyping)(self, _cmd, type, chat, key);
}

static void mvibe_timerFired(id self, SEL _cmd, id timer) {
    if (MaxVibeHideTypingEnabled()) return;
    if (gOrigTimerFired) ((void (*)(id, SEL, id))gOrigTimerFired)(self, _cmd, timer);
}

static void mvibe_userDidType(id self, SEL _cmd, id chat, long long type) {
    if (MaxVibeHideTypingEnabled()) return;
    if (gOrigUserDidType) ((void (*)(id, SEL, id, long long))gOrigUserDidType)(self, _cmd, chat, type);
}

static void mvibe_sendTypingNotif(id self, SEL _cmd, id arg) {
    if (MaxVibeHideTypingEnabled()) return;
    if (gOrigSendTypingNotif) ((void (*)(id, SEL, id))gOrigSendTypingNotif)(self, _cmd, arg);
}

#pragma mark - Read (subclass override only — never touch enqueue or BaseTask)

static BOOL MVShouldBlockReadTask(id task) {
    return MaxVibeHideReadEnabled() && MVIsReadTask(task) && !MVReadTaskIsUnreadMark(task);
}

static BOOL MVAddSubclassHook(Class cls, SEL sel, IMP imp, IMP *origOut, NSString *tag) {
    if (!cls || !sel) return NO;
    Method own = MVOwnMethod(cls, sel);
    if (own) {
        if (origOut) *origOut = method_getImplementation(own);
        method_setImplementation(own, imp);
        MVGLog(@"%@: own %@", tag, NSStringFromClass(cls));
        return YES;
    }
    Method inherited = class_getInstanceMethod(cls, sel);
    if (!inherited) {
        MVGLog(@"%@: no method %@", tag, NSStringFromClass(cls));
        return NO;
    }
    if (origOut) *origOut = method_getImplementation(inherited);
    const char *enc = method_getTypeEncoding(inherited);
    if (class_addMethod(cls, sel, imp, enc ? enc : "v@:")) {
        MVGLog(@"%@: subclass override %@", tag, NSStringFromClass(cls));
        return YES;
    }
    MVGLog(@"%@: addMethod failed %@", tag, NSStringFromClass(cls));
    return NO;
}

static void mvibe_rmPerform(id self, SEL _cmd) {
    if (MVShouldBlockReadTask(self)) return;
    if (gOrigRMPerform) ((void (*)(id, SEL))gOrigRMPerform)(self, _cmd);
}
static id mvibe_rmWork(id self, SEL _cmd) {
    if (MVShouldBlockReadTask(self)) return nil;
    if (gOrigRMWork) return ((id (*)(id, SEL))gOrigRMWork)(self, _cmd);
    return nil;
}
static void mvibe_brPerform(id self, SEL _cmd) {
    if (MVShouldBlockReadTask(self)) return;
    if (gOrigBRPerform) ((void (*)(id, SEL))gOrigBRPerform)(self, _cmd);
}
static id mvibe_brWork(id self, SEL _cmd) {
    if (MVShouldBlockReadTask(self)) return nil;
    if (gOrigBRWork) return ((id (*)(id, SEL))gOrigBRWork)(self, _cmd);
    return nil;
}

#pragma mark - Online / ping

static void MVForceClientNonInteractive(id self) {
    @try { [self setValue:@NO forKey:@"interactive"]; } @catch (__unused NSException *ex) {}
}

static void mvibe_pingInteractive(id self, SEL _cmd, BOOL interactive) {
    if (MaxVibeHideOnlineEnabled()) interactive = NO;
    if (gOrigPingInteractive) ((void (*)(id, SEL, BOOL))gOrigPingInteractive)(self, _cmd, interactive);
}

static void mvibe_sendPingIfNeeded(id self, SEL _cmd) {
    if (MaxVibeHideOnlineEnabled()) MVForceClientNonInteractive(self);
    if (gOrigSendPingIfNeeded) ((void (*)(id, SEL))gOrigSendPingIfNeeded)(self, _cmd);
}

static void mvibe_setInteractive(id self, SEL _cmd, BOOL interactive) {
    if (MaxVibeHideOnlineEnabled()) interactive = NO;
    if (gOrigSetInteractive) ((void (*)(id, SEL, BOOL))gOrigSetInteractive)(self, _cmd, interactive);
}

#pragma mark - VPN

static BOOL mvibe_isVPNDetected(id self, SEL _cmd) {
    if (MaxVibeHideVpnEnabled()) return NO;
    IMP orig = MVLoadOrig(self, _cmd);
    if (orig) return ((BOOL (*)(id, SEL))orig)(self, _cmd);
    return NO;
}
static BOOL mvibe_isVPNEnabled(id self, SEL _cmd) {
    if (MaxVibeHideVpnEnabled()) return NO;
    IMP orig = MVLoadOrig(self, _cmd);
    if (orig) return ((BOOL (*)(id, SEL))orig)(self, _cmd);
    return NO;
}
static void mvibe_setVPNDetected(id self, SEL _cmd, BOOL on) {
    if (MaxVibeHideVpnEnabled()) on = NO;
    IMP orig = MVLoadOrig(self, _cmd);
    if (orig) ((void (*)(id, SEL, BOOL))orig)(self, _cmd, on);
}
static BOOL mvibe_isRestricted(id self, SEL _cmd) {
    if (MaxVibeHideVpnEnabled()) return NO;
    IMP orig = MVLoadOrig(self, _cmd);
    if (orig) return ((BOOL (*)(id, SEL))orig)(self, _cmd);
    return NO;
}
static BOOL mvibe_isRestricted1(id self, SEL _cmd, long long action) {
    if (MaxVibeHideVpnEnabled()) return NO;
    IMP orig = MVLoadOrig(self, _cmd);
    if (orig) return ((BOOL (*)(id, SEL, long long))orig)(self, _cmd, action);
    return NO;
}
static void mvibe_setRestricted(id self, SEL _cmd, BOOL on) {
    if (MaxVibeHideVpnEnabled()) on = NO;
    IMP orig = MVLoadOrig(self, _cmd);
    if (orig) ((void (*)(id, SEL, BOOL))orig)(self, _cmd, on);
}
static BOOL mvibe_ignoreVPN(id self, SEL _cmd) {
    if (MaxVibeHideVpnEnabled()) return YES;
    IMP orig = MVLoadOrig(self, _cmd);
    if (orig) return ((BOOL (*)(id, SEL))orig)(self, _cmd);
    return NO;
}
static void mvibe_presentVPN(id self, SEL _cmd, id action) {
    if (MaxVibeHideVpnEnabled()) {
        MVGLog(@"suppress presentVPNRestriction");
        return;
    }
    IMP orig = MVLoadOrig(self, _cmd);
    if (orig) ((void (*)(id, SEL, id))orig)(self, _cmd, action);
}
static void mvibe_presentCallVPN(id self, SEL _cmd) {
    if (MaxVibeHideVpnEnabled()) {
        MVGLog(@"suppress presentCallVPNRestriction");
        return;
    }
    IMP orig = MVLoadOrig(self, _cmd);
    if (orig) ((void (*)(id, SEL))orig)(self, _cmd);
}
static void mvibe_vpnEnabledCompletion(id self, SEL _cmd, id completion) {
    if (MaxVibeHideVpnEnabled()) {
        if (completion) {
            @try { ((void (^)(BOOL))completion)(NO); } @catch (__unused NSException *ex) {}
        }
        return;
    }
    IMP orig = MVLoadOrig(self, _cmd);
    if (orig) ((void (*)(id, SEL, id))orig)(self, _cmd, completion);
}

static BOOL MVClassLooksLikeAppVPN(Class cls) {
    if (!cls) return NO;
    const char *n = class_getName(cls);
    if (!n) return NO;
    if (strstr(n, "NEVPN") || strstr(n, "NWTLS") || strstr(n, "NetworkExtension")) return NO;
    return strstr(n, "VPNRestriction") || strstr(n, "OMVPN") || strstr(n, "VPNWarning");
}

static unsigned MVHookSelOnClass(Class cls, SEL sel, IMP replacement, NSString *tag) {
    Method m = MVOwnMethod(cls, sel);
    if (!m) return 0;
    IMP orig = method_getImplementation(m);
    if (orig == replacement) return 0;
    MVSaveOrig(cls, sel, orig);
    method_setImplementation(m, replacement);
    MVGLog(@"%@: OK %@", tag, NSStringFromClass(cls));
    return 1;
}

static void MVHookVPNSelsOnClass(Class cls) {
    MVHookSelOnClass(cls, NSSelectorFromString(@"isVPNDetected"), (IMP)mvibe_isVPNDetected, @"isVPNDetected");
    MVHookSelOnClass(cls, NSSelectorFromString(@"isVPNEnabled"), (IMP)mvibe_isVPNEnabled, @"isVPNEnabled");
    MVHookSelOnClass(cls, NSSelectorFromString(@"setIsVPNDetected:"), (IMP)mvibe_setVPNDetected, @"setIsVPNDetected");
    MVHookSelOnClass(cls, NSSelectorFromString(@"shouldIgnoreVPNRestriction"), (IMP)mvibe_ignoreVPN, @"shouldIgnoreVPNRestriction");
    MVHookSelOnClass(cls, NSSelectorFromString(@"presentVPNRestrictionWithRestrictedAction:"), (IMP)mvibe_presentVPN, @"presentVPNRestriction");
    MVHookSelOnClass(cls, NSSelectorFromString(@"presentCallVPNRestrictionIfNeeded"), (IMP)mvibe_presentCallVPN, @"presentCallVPN");
    MVHookSelOnClass(cls, NSSelectorFromString(@"isVPNEnabledWithCompletion:"), (IMP)mvibe_vpnEnabledCompletion, @"isVPNEnabledWithCompletion");
    Method rest = MVOwnMethod(cls, NSSelectorFromString(@"isRestricted"));
    if (rest && method_getNumberOfArguments(rest) == 2) {
        MVHookSelOnClass(cls, NSSelectorFromString(@"isRestricted"), (IMP)mvibe_isRestricted, @"isRestricted");
    } else {
        Method inh = class_getInstanceMethod(cls, NSSelectorFromString(@"isRestricted"));
        if (inh && method_getNumberOfArguments(inh) == 2 && !MVOwnMethod(cls, NSSelectorFromString(@"isRestricted"))) {
            MVSaveOrig(cls, NSSelectorFromString(@"isRestricted"), method_getImplementation(inh));
            const char *enc = method_getTypeEncoding(inh);
            if (class_addMethod(cls, NSSelectorFromString(@"isRestricted"), (IMP)mvibe_isRestricted, enc ? enc : "B@:")) {
                MVGLog(@"isRestricted: subclass override %@", NSStringFromClass(cls));
            }
        }
    }
    Method rest1 = MVOwnMethod(cls, NSSelectorFromString(@"isRestricted:"));
    if (rest1) {
        MVHookSelOnClass(cls, NSSelectorFromString(@"isRestricted:"), (IMP)mvibe_isRestricted1, @"isRestricted:");
    }
    MVHookSelOnClass(cls, NSSelectorFromString(@"setIsRestricted:"), (IMP)mvibe_setRestricted, @"setIsRestricted");
    MVHookSelOnClass(cls, NSSelectorFromString(@"setRestricted:"), (IMP)mvibe_setRestricted, @"setRestricted");
}

static BOOL MVIsVPNRestrictionController(id vc) {
    if (!vc) return NO;
    NSString *n = NSStringFromClass([vc class]);
    return [n containsString:@"VPNRestriction"];
}

static void mvibe_presentVC(id self, SEL _cmd, id vc, BOOL animated, id completion) {
    if (MaxVibeHideVpnEnabled() && MVIsVPNRestrictionController(vc)) {
        MVGLog(@"suppress presentViewController %@", NSStringFromClass([vc class]));
        if (completion) {
            @try { ((void (^)(void))completion)(); } @catch (__unused NSException *ex) {}
        }
        return;
    }
    if (gOrigPresentVC) ((void (*)(id, SEL, id, BOOL, id))gOrigPresentVC)(self, _cmd, vc, animated, completion);
}

static void mvibe_showVC(id self, SEL _cmd, id vc, id sender) {
    if (MaxVibeHideVpnEnabled() && MVIsVPNRestrictionController(vc)) {
        MVGLog(@"suppress showViewController %@", NSStringFromClass([vc class]));
        return;
    }
    if (gOrigShowVC) ((void (*)(id, SEL, id, id))gOrigShowVC)(self, _cmd, vc, sender);
}

static void MVInstallVPNPresentHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class vc = [UIViewController class];
        MVHookOwn(vc, @selector(presentViewController:animated:completion:),
                  (IMP)mvibe_presentVC, &gOrigPresentVC, @"presentViewController");
        MVHookOwn(vc, @selector(showViewController:sender:),
                  (IMP)mvibe_showVC, &gOrigShowVC, @"showViewController");
    });
}

static void MVInstallVPNHooks(void) {
    static const char *const kVPNClasses[] = {
        "OMVPNRestrictionStatusProvider",
        "_TtC13MessengerCore30OMVPNRestrictionStatusProvider",
        "VPNRestrictionViewController",
        "_TtC14AppIntegration28VPNRestrictionViewController",
        "_TtC23OKMAppMessengerProtocol23OMVPNRestrictionsStatus",
        "OMVPNRestrictionsStatus",
        "OMVPNRestrictionBuilder",
        "VPNRestrictionBuilder",
        NULL
    };
    for (const char *const *p = kVPNClasses; p && *p; p++) {
        Class cls = objc_getClass(*p);
        if (cls) MVHookVPNSelsOnClass(cls);
    }
    unsigned n = 0;
    Class *list = objc_copyClassList(&n);
    unsigned extra = 0;
    for (unsigned i = 0; i < n; i++) {
        if (!MVClassLooksLikeAppVPN(list[i])) continue;
        MVHookVPNSelsOnClass(list[i]);
        extra++;
    }
    if (list) free(list);
    MVGLog(@"VPN class-filter matched %u", extra);
    MVInstallVPNPresentHooks();
}

void MaxVibeRefreshVPNHooks(void) {
    MVInstallVPNHooks();
}

void MaxVibeStripVPNRestrictionUI(void) {
}

#pragma mark - Install

void MaxVibeInstallGhost(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        MVLoadRuntime();
        MVGLog(@"install begin online=%d read=%d typing=%d vpn=%d",
               gRtOnline, gRtRead, gRtTyping, gRtVpn);

        Class typingSender = NSClassFromString(@"OKMChatTypingSender");
        MVHookOwn(typingSender, NSSelectorFromString(@"startSendingTypingWithType:inChat:key:"),
                  (IMP)mvibe_startTyping, &gOrigStartTyping, @"startSendingTyping");
        MVHookOwn(typingSender, NSSelectorFromString(@"_timerFired:"),
                  (IMP)mvibe_timerFired, &gOrigTimerFired, @"typing _timerFired");

        Class typingSvc = NSClassFromString(@"OKMTypingService");
        MVHookOwn(typingSvc, NSSelectorFromString(@"userDidTypeInChat:type:"),
                  (IMP)mvibe_userDidType, &gOrigUserDidType, @"userDidTypeInChat");
        MVHookOwn(typingSvc, NSSelectorFromString(@"sendTypingNotificationIfNeeded:"),
                  (IMP)mvibe_sendTypingNotif, &gOrigSendTypingNotif, @"sendTypingNotificationIfNeeded");

        Class readMark = NSClassFromString(@"OKMReadMarkTask");
        MVAddSubclassHook(readMark, NSSelectorFromString(@"perform"),
                          (IMP)mvibe_rmPerform, &gOrigRMPerform, @"ReadMark perform");
        MVAddSubclassHook(readMark, NSSelectorFromString(@"performWorkSignal"),
                          (IMP)mvibe_rmWork, &gOrigRMWork, @"ReadMark performWorkSignal");
        Class batchRead = NSClassFromString(@"OKMBatchReadLogTask");
        MVAddSubclassHook(batchRead, NSSelectorFromString(@"perform"),
                          (IMP)mvibe_brPerform, &gOrigBRPerform, @"BatchRead perform");
        MVAddSubclassHook(batchRead, NSSelectorFromString(@"performWorkSignal"),
                          (IMP)mvibe_brWork, &gOrigBRWork, @"BatchRead performWorkSignal");

        Class client = NSClassFromString(@"OKMMessengerClient");
        MVHookOwn(client, NSSelectorFromString(@"_reschedulePingTimerWithForInteractive:"),
                  (IMP)mvibe_pingInteractive, &gOrigPingInteractive, @"ping interactive");
        MVHookOwn(client, NSSelectorFromString(@"sendPingIfNeeded"),
                  (IMP)mvibe_sendPingIfNeeded, &gOrigSendPingIfNeeded, @"sendPingIfNeeded");
        MVHookOwn(client, NSSelectorFromString(@"setInteractive:"),
                  (IMP)mvibe_setInteractive, &gOrigSetInteractive, @"setInteractive");

        MVInstallVPNHooks();

        MVGLog(@"install done (no BaseTask perform, no sendData)");
    });
}
