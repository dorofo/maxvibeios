#import "MaxVibeGhost.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdarg.h>
#import <string.h>

/*
 * MaxVibe privacy toggles (default OFF, runtime flag is source of truth).
 *
 * hide-read    — drop OKMReadMarkTask / OKMBatchReadLogTask + CHAT_MARK (50)
 * hide-typing  — no-op OKMChatTypingSender start + drop MSG_TYPING (65)
 * hide-online  — PING (1) goes out with interactive=false (Android ping active=false)
 * hide-vpn     — isVPNDetected/isVPNEnabled → NO, do not present VPN restriction UI
 *
 * Do NOT hook inherited methods (class_copyMethodList only).
 * sendData: only integer-command variants on OKMMessengerClient.
 * Never hook serializeBlock (sticker panel) or inherited _timerFired:.
 */

static NSString * const kPrefOnline = @"mvibe_hide_online_enabled";
static NSString * const kPrefRead = @"mvibe_hide_read_enabled";
static NSString * const kPrefTyping = @"mvibe_hide_typing_enabled";
static NSString * const kPrefVpn = @"mvibe_hide_vpn_enabled";

static const NSInteger kOpcodePing = 1;
static const NSInteger kOpcodePresence = 35;
static const NSInteger kOpcodeChatMark = 50;
static const NSInteger kOpcodeTyping = 65;

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

static NSDictionary *MVAsDict(id data) {
    if ([data isKindOfClass:[NSDictionary class]]) return data;
    @try {
        id payload = [data valueForKey:@"payload"];
        if ([payload isKindOfClass:[NSDictionary class]]) return payload;
    } @catch (__unused NSException *ex) {}
    return nil;
}

static NSMutableDictionary *MVMutablePayload(id data) {
    NSDictionary *d = MVAsDict(data);
    if (!d) return nil;
    return [d mutableCopy];
}

static BOOL MVChatMarkIsUnread(NSDictionary *payload) {
    if (!payload) return NO;
    id type = payload[@"type"] ?: payload[@"markType"] ?: payload[@"action"];
    NSString *s = [type isKindOfClass:[NSString class]] ? [(NSString *)type uppercaseString] : nil;
    if (!s.length) return NO;
    return [s containsString:@"UNREAD"] && ![s containsString:@"READ_MESSAGE"];
}

static BOOL MVPresenceLooksLikeRequest(NSDictionary *payload) {
    if (!payload) return NO;
    for (NSString *key in @[@"contactIds", @"userIds", @"ids", @"contacts"]) {
        id v = payload[key];
        if ([v isKindOfClass:[NSArray class]] && [(NSArray *)v count] > 0) return YES;
    }
    return NO;
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
    return [cls isEqualToString:@"OKMReadMarkTask"] || [cls isEqualToString:@"OKMBatchReadLogTask"];
}

#pragma mark - Orig IMPs

static IMP gOrigStartTyping = NULL;
static IMP gOrigEnqueueTasks = NULL;
static IMP gOrigEnqueueTask = NULL;
static IMP gOrigPingInteractive = NULL;
static IMP gOrigSendRetryCb = NULL;
static IMP gOrigSendRetryMap = NULL;
static IMP gOrigIsVPNDetected = NULL;
static IMP gOrigIsVPNEnabled = NULL;
static IMP gOrigSetVPNDetected = NULL;
static IMP gOrigIgnoreVPN = NULL;
static IMP gOrigPresentVPN = NULL;
static IMP gOrigPresentCallVPN = NULL;
static IMP gOrigVPNEnabledCompletion = NULL;
static NSMutableDictionary *gOrigByKey = nil;
static BOOL gSendRetryCbRetId = NO;
static BOOL gSendRetryMapRetId = NO;

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

#pragma mark - Read tasks

static void mvibe_enqueueTasks(id self, SEL _cmd, id tasks, id deps) {
    id filtered = tasks;
    if (MaxVibeHideReadEnabled() && [tasks isKindOfClass:[NSArray class]]) {
        NSMutableArray *keep = [NSMutableArray array];
        NSUInteger dropped = 0;
        for (id t in (NSArray *)tasks) {
            if (MVIsReadTask(t)) { dropped++; continue; }
            [keep addObject:t];
        }
        if (dropped) {
            MVGLog(@"enqueueTasks drop read-tasks=%lu keep=%lu",
                   (unsigned long)dropped, (unsigned long)keep.count);
            filtered = keep;
            if (keep.count == 0) return;
        }
    }
    if (gOrigEnqueueTasks) ((void (*)(id, SEL, id, id))gOrigEnqueueTasks)(self, _cmd, filtered, deps);
}

static void mvibe_enqueueTask(id self, SEL _cmd, id task) {
    if (MaxVibeHideReadEnabled() && MVIsReadTask(task)) {
        MVGLog(@"enqueueTask drop %@", NSStringFromClass([task class]));
        return;
    }
    if (gOrigEnqueueTask) ((void (*)(id, SEL, id))gOrigEnqueueTask)(self, _cmd, task);
}

#pragma mark - Ping timer

static void mvibe_pingInteractive(id self, SEL _cmd, BOOL interactive) {
    if (MaxVibeHideOnlineEnabled()) interactive = NO;
    if (gOrigPingInteractive) ((void (*)(id, SEL, BOOL))gOrigPingInteractive)(self, _cmd, interactive);
}

#pragma mark - sendData (integer command only)

static id MVRewriteOrDrop(id data, long long command, BOOL returnsId, IMP orig, id self, SEL sel, BOOL retry, id extra, BOOL hasRetry) {
    NSDictionary *payload = MVAsDict(data);
    id sendData = data;

    if (command == kOpcodePing) {
        if (MaxVibeHideOnlineEnabled()) {
            NSMutableDictionary *m = MVMutablePayload(data);
            if (m) {
                m[@"interactive"] = @NO;
                sendData = m;
                MVGLog(@"PING interactive=false");
            }
        }
    } else if (command == kOpcodeTyping) {
        if (MaxVibeHideTypingEnabled()) {
            MVGLog(@"block MSG_TYPING");
            return returnsId ? MVEmptySignal() : nil;
        }
    } else if (command == kOpcodeChatMark) {
        if (MaxVibeHideReadEnabled() && !MVChatMarkIsUnread(payload)) {
            MVGLog(@"block CHAT_MARK type=%@", payload[@"type"] ?: @"?");
            return returnsId ? MVEmptySignal() : nil;
        }
    } else if (command == kOpcodePresence) {
        if (MaxVibeHideOnlineEnabled() && !MVPresenceLooksLikeRequest(payload)) {
            MVGLog(@"block CONTACT_PRESENCE");
            return returnsId ? MVEmptySignal() : nil;
        }
    }

    if (!orig) return nil;
    if (hasRetry) {
        return ((id (*)(id, SEL, id, long long, BOOL, id))orig)(self, sel, sendData, command, retry, extra);
    }
    return ((id (*)(id, SEL, id, long long, id))orig)(self, sel, sendData, command, extra);
}

static id mvibe_sendRetryCb_int(id self, SEL _cmd, id data, long long command, BOOL retry, id cb) {
    return MVRewriteOrDrop(data, command, gSendRetryCbRetId, gOrigSendRetryCb, self, _cmd, retry, cb, YES);
}
static id mvibe_sendRetryMap_int(id self, SEL _cmd, id data, long long command, BOOL retry, id map) {
    return MVRewriteOrDrop(data, command, gSendRetryMapRetId, gOrigSendRetryMap, self, _cmd, retry, map, YES);
}

static BOOL MVHookSendInt(Class cls, SEL sel, IMP *origOut, IMP impInt, BOOL *retIdOut, NSString *tag) {
    Method m = MVOwnMethod(cls, sel);
    if (!m) {
        MVGLog(@"%@: no own method", tag);
        return NO;
    }
    char *t = method_copyArgumentType(m, 3);
    char c = t ? t[0] : 0;
    if (t) free(t);
    if (!strchr("qQiIlL", c)) {
        MVGLog(@"%@: command encoding '%c' not int — skip (keep original)", tag, c ? c : '?');
        return NO;
    }
    const char *enc = method_getTypeEncoding(m);
    BOOL retId = enc && enc[0] == '@';
    if (retIdOut) *retIdOut = retId;
    if (origOut) *origOut = method_getImplementation(m);
    method_setImplementation(m, impInt);
    MVGLog(@"%@: OK int-cmd ret=%@", tag, retId ? @"id" : @"void");
    return YES;
}

#pragma mark - VPN

static BOOL mvibe_isVPNDetected(id self, SEL _cmd) {
    if (MaxVibeHideVpnEnabled()) return NO;
    IMP orig = MVLoadOrig(self, _cmd) ?: gOrigIsVPNDetected;
    if (orig) return ((BOOL (*)(id, SEL))orig)(self, _cmd);
    return NO;
}
static BOOL mvibe_isVPNEnabled(id self, SEL _cmd) {
    if (MaxVibeHideVpnEnabled()) return NO;
    IMP orig = MVLoadOrig(self, _cmd) ?: gOrigIsVPNEnabled;
    if (orig) return ((BOOL (*)(id, SEL))orig)(self, _cmd);
    return NO;
}
static void mvibe_setVPNDetected(id self, SEL _cmd, BOOL on) {
    if (MaxVibeHideVpnEnabled()) on = NO;
    IMP orig = MVLoadOrig(self, _cmd) ?: gOrigSetVPNDetected;
    if (orig) ((void (*)(id, SEL, BOOL))orig)(self, _cmd, on);
}
static BOOL mvibe_ignoreVPN(id self, SEL _cmd) {
    if (MaxVibeHideVpnEnabled()) return YES;
    IMP orig = MVLoadOrig(self, _cmd) ?: gOrigIgnoreVPN;
    if (orig) return ((BOOL (*)(id, SEL))orig)(self, _cmd);
    return NO;
}
static void mvibe_presentVPN(id self, SEL _cmd, id action) {
    if (MaxVibeHideVpnEnabled()) {
        MVGLog(@"suppress presentVPNRestriction");
        return;
    }
    IMP orig = MVLoadOrig(self, _cmd) ?: gOrigPresentVPN;
    if (orig) ((void (*)(id, SEL, id))orig)(self, _cmd, action);
}
static void mvibe_presentCallVPN(id self, SEL _cmd) {
    if (MaxVibeHideVpnEnabled()) {
        MVGLog(@"suppress presentCallVPNRestriction");
        return;
    }
    IMP orig = MVLoadOrig(self, _cmd) ?: gOrigPresentCallVPN;
    if (orig) ((void (*)(id, SEL))orig)(self, _cmd);
}
static void mvibe_vpnEnabledCompletion(id self, SEL _cmd, id completion) {
    if (MaxVibeHideVpnEnabled()) {
        if (completion) {
            @try { ((void (^)(BOOL))completion)(NO); } @catch (__unused NSException *ex) {}
        }
        return;
    }
    IMP orig = MVLoadOrig(self, _cmd) ?: gOrigVPNEnabledCompletion;
    if (orig) ((void (*)(id, SEL, id))orig)(self, _cmd, completion);
}

static unsigned MVHookOwnEverywhere(SEL sel, IMP replacement, IMP *firstOrigOut, NSString *tag) {
    unsigned hooked = 0;
    unsigned n = 0;
    Class *list = objc_copyClassList(&n);
    for (unsigned i = 0; i < n; i++) {
        Method m = MVOwnMethod(list[i], sel);
        if (!m) continue;
        IMP orig = method_getImplementation(m);
        if (orig == replacement) continue;
        MVSaveOrig(list[i], sel, orig);
        if (firstOrigOut && !*firstOrigOut) *firstOrigOut = orig;
        method_setImplementation(m, replacement);
        hooked++;
        if (hooked <= 8) MVGLog(@"%@: OK %@", tag, NSStringFromClass(list[i]));
    }
    if (list) free(list);
    MVGLog(@"%@: hooked %u classes", tag, hooked);
    return hooked;
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

        Class tasks = NSClassFromString(@"OKMTasksService");
        MVHookOwn(tasks, NSSelectorFromString(@"enqueueTasks:withDependencies:"),
                  (IMP)mvibe_enqueueTasks, &gOrigEnqueueTasks, @"enqueueTasks");
        MVHookOwn(tasks, NSSelectorFromString(@"enqueueTask:"),
                  (IMP)mvibe_enqueueTask, &gOrigEnqueueTask, @"enqueueTask");

        Class client = NSClassFromString(@"OKMMessengerClient");
        MVHookOwn(client, NSSelectorFromString(@"_reschedulePingTimerWithForInteractive:"),
                  (IMP)mvibe_pingInteractive, &gOrigPingInteractive, @"ping interactive");
        MVHookSendInt(client, NSSelectorFromString(@"sendData:withCommand:retry:callback:"),
                      &gOrigSendRetryCb, (IMP)mvibe_sendRetryCb_int, &gSendRetryCbRetId,
                      @"sendData retry:callback");
        MVHookSendInt(client, NSSelectorFromString(@"sendData:withCommand:retry:mapResultTo:"),
                      &gOrigSendRetryMap, (IMP)mvibe_sendRetryMap_int, &gSendRetryMapRetId,
                      @"sendData retry:mapResultTo");

        void (^vpnPass)(void) = ^{
            MVHookOwnEverywhere(NSSelectorFromString(@"isVPNDetected"),
                                (IMP)mvibe_isVPNDetected, &gOrigIsVPNDetected, @"isVPNDetected");
            MVHookOwnEverywhere(NSSelectorFromString(@"isVPNEnabled"),
                                (IMP)mvibe_isVPNEnabled, &gOrigIsVPNEnabled, @"isVPNEnabled");
            MVHookOwnEverywhere(NSSelectorFromString(@"setIsVPNDetected:"),
                                (IMP)mvibe_setVPNDetected, &gOrigSetVPNDetected, @"setIsVPNDetected");
            MVHookOwnEverywhere(NSSelectorFromString(@"shouldIgnoreVPNRestriction"),
                                (IMP)mvibe_ignoreVPN, &gOrigIgnoreVPN, @"shouldIgnoreVPNRestriction");
            MVHookOwnEverywhere(NSSelectorFromString(@"presentVPNRestrictionWithRestrictedAction:"),
                                (IMP)mvibe_presentVPN, &gOrigPresentVPN, @"presentVPNRestriction");
            MVHookOwnEverywhere(NSSelectorFromString(@"presentCallVPNRestrictionIfNeeded"),
                                (IMP)mvibe_presentCallVPN, &gOrigPresentCallVPN, @"presentCallVPN");
            MVHookOwnEverywhere(NSSelectorFromString(@"isVPNEnabledWithCompletion:"),
                                (IMP)mvibe_vpnEnabledCompletion, &gOrigVPNEnabledCompletion, @"isVPNEnabledWithCompletion");
        };
        vpnPass();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), vpnPass);

        MVGLog(@"install done");
    });
}
