#import "MaxVibeGhost.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdarg.h>
#import <string.h>

/*
 * MaxVibe privacy toggles (default OFF, runtime flag is source of truth).
 *
 * hide-read    — drop single enqueueTask: of OKMReadMarkTask + no-op performWork
 *                (do NOT filter enqueueTasks:withDependencies: — that broke replies)
 * hide-typing  — no-op typing sender start/timer + TypingService userDidType
 * hide-online  — force ping interactive=NO on OKMMessengerClient (Android tgc)
 * hide-vpn     — named VPN classes only (no objc_copyClassList, no delayed walk)
 *
 * Never hook sendData: (ABI / MSG_SEND reply link).
 * Never hook inherited methods (class_copyMethodList / MVOwnMethod only),
 * except OKMBaseTask.performWorkSignal with an explicit class filter.
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

static id MVEmptySignal(void) {
    Class rac = NSClassFromString(@"RACSignal");
    if ([rac respondsToSelector:@selector(empty)]) {
        return ((id (*)(id, SEL))objc_msgSend)(rac, @selector(empty));
    }
    SEL retSel = NSSelectorFromString(@"return:");
    if ([rac respondsToSelector:retSel]) {
        return ((id (*)(id, SEL, id))objc_msgSend)(rac, retSel, nil);
    }
    return nil;
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
static IMP gOrigPerformWork = NULL;
static IMP gOrigBatchPerformWork = NULL;
static IMP gOrigPerform = NULL;
static IMP gOrigEnqueueTask = NULL;
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

#pragma mark - Read

static BOOL MVShouldBlockReadTask(id task) {
    return MaxVibeHideReadEnabled() && MVIsReadTask(task) && !MVReadTaskIsUnreadMark(task);
}

static id mvibe_performWork(id self, SEL _cmd) {
    if (MVShouldBlockReadTask(self)) {
        MVGLog(@"performWorkSignal skip %@", NSStringFromClass([self class]));
        return MVEmptySignal();
    }
    IMP orig = gOrigPerformWork;
    if ([NSStringFromClass([self class]) isEqualToString:@"OKMBatchReadLogTask"] && gOrigBatchPerformWork) {
        orig = gOrigBatchPerformWork;
    }
    if (orig) return ((id (*)(id, SEL))orig)(self, _cmd);
    return nil;
}

static void mvibe_perform(id self, SEL _cmd) {
    if (MVShouldBlockReadTask(self)) {
        MVGLog(@"perform skip %@", NSStringFromClass([self class]));
        return;
    }
    if (gOrigPerform) ((void (*)(id, SEL))gOrigPerform)(self, _cmd);
}

static void mvibe_enqueueTask(id self, SEL _cmd, id task) {
    if (MVShouldBlockReadTask(task)) {
        MVGLog(@"enqueueTask drop %@", NSStringFromClass([task class]));
        return;
    }
    if (gOrigEnqueueTask) ((void (*)(id, SEL, id))gOrigEnqueueTask)(self, _cmd, task);
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

#pragma mark - VPN (named classes only)

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

static unsigned MVHookNamed(const char *const *names, SEL sel, IMP replacement, NSString *tag) {
    unsigned hooked = 0;
    for (const char *const *p = names; p && *p; p++) {
        Class cls = objc_getClass(*p);
        if (!cls) continue;
        Method m = MVOwnMethod(cls, sel);
        if (!m) continue;
        IMP orig = method_getImplementation(m);
        if (orig == replacement) continue;
        MVSaveOrig(cls, sel, orig);
        method_setImplementation(m, replacement);
        hooked++;
        MVGLog(@"%@: OK %@", tag, NSStringFromClass(cls));
    }
    if (!hooked) MVGLog(@"%@: no named class", tag);
    return hooked;
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
    MVHookNamed(kVPNClasses, NSSelectorFromString(@"isVPNDetected"),
                (IMP)mvibe_isVPNDetected, @"isVPNDetected");
    MVHookNamed(kVPNClasses, NSSelectorFromString(@"isVPNEnabled"),
                (IMP)mvibe_isVPNEnabled, @"isVPNEnabled");
    MVHookNamed(kVPNClasses, NSSelectorFromString(@"setIsVPNDetected:"),
                (IMP)mvibe_setVPNDetected, @"setIsVPNDetected");
    MVHookNamed(kVPNClasses, NSSelectorFromString(@"shouldIgnoreVPNRestriction"),
                (IMP)mvibe_ignoreVPN, @"shouldIgnoreVPNRestriction");
    MVHookNamed(kVPNClasses, NSSelectorFromString(@"presentVPNRestrictionWithRestrictedAction:"),
                (IMP)mvibe_presentVPN, @"presentVPNRestriction");
    MVHookNamed(kVPNClasses, NSSelectorFromString(@"presentCallVPNRestrictionIfNeeded"),
                (IMP)mvibe_presentCallVPN, @"presentCallVPN");
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

        Class baseTask = NSClassFromString(@"OKMBaseTask");
        MVHookOwn(baseTask, NSSelectorFromString(@"performWorkSignal"),
                  (IMP)mvibe_performWork, &gOrigPerformWork, @"OKMBaseTask performWorkSignal");
        MVHookOwn(baseTask, NSSelectorFromString(@"perform"),
                  (IMP)mvibe_perform, &gOrigPerform, @"OKMBaseTask perform");
        Class batchRead = NSClassFromString(@"OKMBatchReadLogTask");
        MVHookOwn(batchRead, NSSelectorFromString(@"performWorkSignal"),
                  (IMP)mvibe_performWork, &gOrigBatchPerformWork, @"OKMBatchReadLogTask performWorkSignal");
        Class tasks = NSClassFromString(@"OKMTasksService");
        MVHookOwn(tasks, NSSelectorFromString(@"enqueueTask:"),
                  (IMP)mvibe_enqueueTask, &gOrigEnqueueTask, @"enqueueTask");

        Class client = NSClassFromString(@"OKMMessengerClient");
        MVHookOwn(client, NSSelectorFromString(@"_reschedulePingTimerWithForInteractive:"),
                  (IMP)mvibe_pingInteractive, &gOrigPingInteractive, @"ping interactive");
        MVHookOwn(client, NSSelectorFromString(@"sendPingIfNeeded"),
                  (IMP)mvibe_sendPingIfNeeded, &gOrigSendPingIfNeeded, @"sendPingIfNeeded");
        MVHookOwn(client, NSSelectorFromString(@"setInteractive:"),
                  (IMP)mvibe_setInteractive, &gOrigSetInteractive, @"setInteractive");

        MVInstallVPNHooks();

        MVGLog(@"install done (no sendData, no enqueueTasks batch filter, no class-list VPN)");
    });
}
