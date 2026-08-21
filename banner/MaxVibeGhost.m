#import "MaxVibeGhost.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdarg.h>
#import <string.h>

/*
 * MaxVibe ghost — Android ghost mode split into 3 independent switches.
 *
 *   hide-online  → ping not interactive + drop own CONTACT_PRESENCE (opcode 35)
 *   hide-read    → drop CHAT_MARK READ_MESSAGE/READ_REACTION (opcode 50); allow unread
 *   hide-typing  → drop MSG_TYPING (opcode 65) + no-op typing sender
 *
 * Launch-safe: C trampolines + method_setImplementation on known OKM classes.
 * sendData hook inspects method encoding at install time and is skipped if unknown.
 */

static NSString * const kPrefOnline = @"mvibe_hide_online_enabled";
static NSString * const kPrefRead = @"mvibe_hide_read_enabled";
static NSString * const kPrefTyping = @"mvibe_hide_typing_enabled";

static const NSInteger kOpcodePresence = 35; /* CONTACT_PRESENCE */
static const NSInteger kOpcodeChatMark = 50; /* CHAT_MARK */
static const NSInteger kOpcodeTyping = 65;   /* MSG_TYPING */

typedef NS_ENUM(NSInteger, MVGhostKind) {
    MVGhostKindNone = 0,
    MVGhostKindOnline,
    MVGhostKindRead,
    MVGhostKindTyping,
};

#pragma mark - Prefs

BOOL MaxVibeHideOnlineEnabled(void) {
    NSUserDefaults *p = [NSUserDefaults standardUserDefaults];
    if ([p objectForKey:kPrefOnline] == nil) return NO;
    return [p boolForKey:kPrefOnline];
}
void MaxVibeSetHideOnlineEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kPrefOnline];
}

BOOL MaxVibeHideReadEnabled(void) {
    NSUserDefaults *p = [NSUserDefaults standardUserDefaults];
    if ([p objectForKey:kPrefRead] == nil) return NO;
    return [p boolForKey:kPrefRead];
}
void MaxVibeSetHideReadEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kPrefRead];
}

BOOL MaxVibeHideTypingEnabled(void) {
    NSUserDefaults *p = [NSUserDefaults standardUserDefaults];
    if ([p objectForKey:kPrefTyping] == nil) return NO;
    return [p boolForKey:kPrefTyping];
}
void MaxVibeSetHideTypingEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kPrefTyping];
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

static BOOL MVHook(Class cls, SEL sel, IMP replacement, IMP *origOut, NSString *tag) {
    if (!cls) {
        MVGLog(@"%@: no class", tag);
        return NO;
    }
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        MVGLog(@"%@: no method %@", tag, NSStringFromSelector(sel));
        return NO;
    }
    if (origOut) *origOut = method_getImplementation(m);
    method_setImplementation(m, replacement);
    MVGLog(@"%@: OK", tag);
    return YES;
}

#pragma mark - Command / payload

static NSDictionary *MVAsDict(id data) {
    if ([data isKindOfClass:[NSDictionary class]]) return data;
    if ([data isKindOfClass:[NSString class]]) {
        NSData *raw = [(NSString *)data dataUsingEncoding:NSUTF8StringEncoding];
        if (!raw.length) return nil;
        id obj = [NSJSONSerialization JSONObjectWithData:raw options:0 error:nil];
        return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
    }
    if ([data isKindOfClass:[NSData class]]) {
        id obj = [NSJSONSerialization JSONObjectWithData:(NSData *)data options:0 error:nil];
        return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
    }
    @try {
        id payload = [data valueForKey:@"payload"];
        if ([payload isKindOfClass:[NSDictionary class]]) return payload;
    } @catch (__unused NSException *ex) {}
    return nil;
}

static NSString *MVNorm(id v) {
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v uppercaseString];
    if ([v respondsToSelector:@selector(stringValue)]) return [[v stringValue] uppercaseString];
    if ([v respondsToSelector:@selector(description)]) return [[v description] uppercaseString];
    return nil;
}

static MVGhostKind MVKindFromNumber(long long n) {
    if (n == kOpcodePresence) return MVGhostKindOnline;
    if (n == kOpcodeChatMark) return MVGhostKindRead;
    if (n == kOpcodeTyping) return MVGhostKindTyping;
    return MVGhostKindNone;
}

static MVGhostKind MVKindFromString(NSString *s) {
    if (!s.length) return MVGhostKindNone;
    NSString *u = s.uppercaseString;
    if ([u containsString:@"CONTACT_PRESENCE"] || [u isEqualToString:@"35"]) return MVGhostKindOnline;
    if ([u containsString:@"CHAT_MARK"] || [u isEqualToString:@"50"]) return MVGhostKindRead;
    if ([u containsString:@"MSG_TYPING"] || [u isEqualToString:@"65"]) return MVGhostKindTyping;
    /* do not match NOTIF_* incoming names if they ever appear on send */
    return MVGhostKindNone;
}

static MVGhostKind MVKindFromCommand(id command) {
    if (!command) return MVGhostKindNone;
    if ([command isKindOfClass:[NSNumber class]]) {
        return MVKindFromNumber([(NSNumber *)command longLongValue]);
    }
    if ([command isKindOfClass:[NSString class]]) {
        return MVKindFromString((NSString *)command);
    }
    @try {
        for (NSString *key in @[@"opcode", @"code", @"rawValue", @"type", @"name", @"command"]) {
            id v = nil;
            @try { v = [command valueForKey:key]; } @catch (__unused NSException *ex) { v = nil; }
            if ([v isKindOfClass:[NSNumber class]]) {
                MVGhostKind k = MVKindFromNumber([(NSNumber *)v longLongValue]);
                if (k != MVGhostKindNone) return k;
            }
            if ([v isKindOfClass:[NSString class]]) {
                MVGhostKind k = MVKindFromString((NSString *)v);
                if (k != MVGhostKindNone) return k;
            }
        }
    } @catch (__unused NSException *ex) {}
    return MVKindFromString([command description]);
}

static BOOL MVChatMarkIsUnread(NSDictionary *payload) {
    if (!payload) return NO;
    NSString *type = MVNorm(payload[@"type"] ?: payload[@"markType"] ?: payload[@"action"]);
    if (!type.length) return NO;
    if ([type containsString:@"UNREAD"] && ![type containsString:@"READ_MESSAGE"] && ![type containsString:@"READ_REACTION"]) {
        return YES;
    }
    return NO;
}

static BOOL MVPresenceLooksLikeRequest(NSDictionary *payload) {
    if (!payload) return NO;
    for (NSString *key in @[@"contactIds", @"userIds", @"ids", @"contactIds", @"contacts"]) {
        id v = payload[key];
        if ([v isKindOfClass:[NSArray class]] && [(NSArray *)v count] > 0) return YES;
    }
    return NO;
}

static BOOL MVPresenceLooksLikeSelfReport(NSDictionary *payload) {
    if (!payload) return NO;
    if (MVPresenceLooksLikeRequest(payload)) return NO;
    id status = payload[@"status"] ?: payload[@"presence"] ?: payload[@"on"];
    NSString *s = MVNorm(status);
    if (s.length && ([s containsString:@"ONLINE"] || [s containsString:@"OFFLINE"]
                     || [s containsString:@"UNKNOWN"] || [s containsString:@"AWAY"]
                     || [s isEqualToString:@"ON"] || [s isEqualToString:@"1"]
                     || [s isEqualToString:@"TRUE"])) {
        return YES;
    }
    id interactive = payload[@"interactive"];
    if ([interactive respondsToSelector:@selector(boolValue)] && [interactive boolValue]
        && !MVPresenceLooksLikeRequest(payload)) {
        return YES;
    }
    /* own presence updates are usually small dicts without contact id lists */
    if (payload[@"status"] || payload[@"presence"]) return YES;
    return NO;
}

static CFTimeInterval gLastTypingLog = 0;

static BOOL MVShouldBlockKind(MVGhostKind kind, id data) {
    if (kind == MVGhostKindNone) return NO;
    NSDictionary *payload = MVAsDict(data);
    if (kind == MVGhostKindTyping) {
        if (!MaxVibeHideTypingEnabled()) return NO;
        CFTimeInterval now = CFAbsoluteTimeGetCurrent();
        if (now - gLastTypingLog > 2.0) {
            gLastTypingLog = now;
            MVGLog(@"block MSG_TYPING");
        }
        return YES;
    }
    if (kind == MVGhostKindRead) {
        if (!MaxVibeHideReadEnabled()) return NO;
        if (MVChatMarkIsUnread(payload)) return NO;
        MVGLog(@"block CHAT_MARK type=%@", payload[@"type"] ?: @"?");
        return YES;
    }
    if (kind == MVGhostKindOnline) {
        if (!MaxVibeHideOnlineEnabled()) return NO;
        if (MVPresenceLooksLikeRequest(payload)) return NO;
        if (payload && !MVPresenceLooksLikeSelfReport(payload)) return NO;
        MVGLog(@"block CONTACT_PRESENCE self-report");
        return YES;
    }
    return NO;
}

static BOOL MVShouldBlockCommandObj(id command, id data) {
    return MVShouldBlockKind(MVKindFromCommand(command), data);
}

static BOOL MVShouldBlockCommandInt(long long command, id data) {
    return MVShouldBlockKind(MVKindFromNumber(command), data);
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
    if ([cls containsString:@"ReadMark"] || [cls containsString:@"BatchRead"]) return YES;
    return NO;
}

#pragma mark - Orig IMPs

static IMP gOrigStartTyping = NULL;
static IMP gOrigTimerFired = NULL;
static IMP gOrigUserDidType = NULL;
static IMP gOrigSendTypingIfNeeded = NULL;
static IMP gOrigStopTyping = NULL;
static IMP gOrigEnqueueTasks = NULL;
static IMP gOrigEnqueueTask = NULL;
static IMP gOrigPingInteractive = NULL;
static IMP gOrigSendRetryCb = NULL;
static IMP gOrigSendRetryMap = NULL;
static IMP gOrigSendCb = NULL;
static IMP gOrigSendMap = NULL;
static IMP gOrigSendSerialize = NULL;
static BOOL gSendRetryCbReturnsId = NO;
static BOOL gSendRetryMapReturnsId = NO;
static BOOL gSendCbReturnsId = NO;
static BOOL gSendMapReturnsId = NO;
static BOOL gSendSerializeReturnsId = NO;
static BOOL gSendRetryCbCmdIsObj = NO;
static BOOL gSendRetryMapCmdIsObj = NO;
static BOOL gSendCbCmdIsObj = NO;
static BOOL gSendMapCmdIsObj = NO;
static BOOL gSendSerializeCmdIsObj = NO;

#pragma mark - Typing trampolines

static void mvibe_startTyping(id self, SEL _cmd, id type, id chat, id key) {
    if (MaxVibeHideTypingEnabled()) return;
    if (gOrigStartTyping) ((void (*)(id, SEL, id, id, id))gOrigStartTyping)(self, _cmd, type, chat, key);
}

static void mvibe_timerFired(id self, SEL _cmd, id timer) {
    if (MaxVibeHideTypingEnabled()) return;
    if (gOrigTimerFired) ((void (*)(id, SEL, id))gOrigTimerFired)(self, _cmd, timer);
}

static void mvibe_userDidType(id self, SEL _cmd, id chat, id type) {
    if (MaxVibeHideTypingEnabled()) return;
    if (gOrigUserDidType) ((void (*)(id, SEL, id, id))gOrigUserDidType)(self, _cmd, chat, type);
}

static void mvibe_sendTypingIfNeeded(id self, SEL _cmd, id arg) {
    if (MaxVibeHideTypingEnabled()) return;
    if (gOrigSendTypingIfNeeded) ((void (*)(id, SEL, id))gOrigSendTypingIfNeeded)(self, _cmd, arg);
}

static void mvibe_stopTyping(id self, SEL _cmd, id key) {
    /* always allow stop so a leftover "typing" can clear if toggle flipped mid-type */
    if (gOrigStopTyping) ((void (*)(id, SEL, id))gOrigStopTyping)(self, _cmd, key);
}

#pragma mark - Read: drop ReadMark tasks (local UI still updates)

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
            MVGLog(@"enqueueTasks drop read-tasks=%lu keep=%lu", (unsigned long)dropped, (unsigned long)keep.count);
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

#pragma mark - Online / ping

static void mvibe_pingInteractive(id self, SEL _cmd, BOOL interactive) {
    if (MaxVibeHideOnlineEnabled()) interactive = NO;
    if (gOrigPingInteractive) ((void (*)(id, SEL, BOOL))gOrigPingInteractive)(self, _cmd, interactive);
}

#pragma mark - sendData trampolines

static id MVPassthroughOrNil(BOOL returnsId, IMP orig, id self, SEL sel, id data, id cmdObj, long long cmdInt, BOOL cmdIsObj, BOOL retry, id extra, int nExtra) {
    if (cmdIsObj) {
        if (MVShouldBlockCommandObj(cmdObj, data)) return returnsId ? MVEmptySignal() : nil;
    } else {
        if (MVShouldBlockCommandInt(cmdInt, data)) return returnsId ? MVEmptySignal() : nil;
    }
    if (!orig) return nil;
    if (nExtra == 2) {
        /* retry + block */
        if (cmdIsObj) {
            return ((id (*)(id, SEL, id, id, BOOL, id))orig)(self, sel, data, cmdObj, retry, extra);
        }
        return ((id (*)(id, SEL, id, long long, BOOL, id))orig)(self, sel, data, cmdInt, retry, extra);
    }
    /* command + one extra (callback / mapResultTo) */
    if (cmdIsObj) {
        return ((id (*)(id, SEL, id, id, id))orig)(self, sel, data, cmdObj, extra);
    }
    return ((id (*)(id, SEL, id, long long, id))orig)(self, sel, data, cmdInt, extra);
}

static id mvibe_sendRetryCb_obj(id self, SEL _cmd, id data, id command, BOOL retry, id cb) {
    return MVPassthroughOrNil(gSendRetryCbReturnsId, gOrigSendRetryCb, self, _cmd, data, command, 0, YES, retry, cb, 2);
}
static id mvibe_sendRetryCb_int(id self, SEL _cmd, id data, long long command, BOOL retry, id cb) {
    return MVPassthroughOrNil(gSendRetryCbReturnsId, gOrigSendRetryCb, self, _cmd, data, nil, command, NO, retry, cb, 2);
}
static id mvibe_sendRetryMap_obj(id self, SEL _cmd, id data, id command, BOOL retry, id map) {
    return MVPassthroughOrNil(gSendRetryMapReturnsId, gOrigSendRetryMap, self, _cmd, data, command, 0, YES, retry, map, 2);
}
static id mvibe_sendRetryMap_int(id self, SEL _cmd, id data, long long command, BOOL retry, id map) {
    return MVPassthroughOrNil(gSendRetryMapReturnsId, gOrigSendRetryMap, self, _cmd, data, nil, command, NO, retry, map, 2);
}
static id mvibe_sendCb_obj(id self, SEL _cmd, id data, id command, id cb) {
    return MVPassthroughOrNil(gSendCbReturnsId, gOrigSendCb, self, _cmd, data, command, 0, YES, NO, cb, 1);
}
static id mvibe_sendCb_int(id self, SEL _cmd, id data, long long command, id cb) {
    return MVPassthroughOrNil(gSendCbReturnsId, gOrigSendCb, self, _cmd, data, nil, command, NO, NO, cb, 1);
}
static id mvibe_sendMap_obj(id self, SEL _cmd, id data, id command, id map) {
    return MVPassthroughOrNil(gSendMapReturnsId, gOrigSendMap, self, _cmd, data, command, 0, YES, NO, map, 1);
}
static id mvibe_sendMap_int(id self, SEL _cmd, id data, long long command, id map) {
    return MVPassthroughOrNil(gSendMapReturnsId, gOrigSendMap, self, _cmd, data, nil, command, NO, NO, map, 1);
}

static id mvibe_sendSerialize_obj(id self, SEL _cmd, id data, id command, id ser, id res) {
    if (MVShouldBlockCommandObj(command, data)) return gSendSerializeReturnsId ? MVEmptySignal() : nil;
    if (!gOrigSendSerialize) return nil;
    return ((id (*)(id, SEL, id, id, id, id))gOrigSendSerialize)(self, _cmd, data, command, ser, res);
}
static id mvibe_sendSerialize_int(id self, SEL _cmd, id data, long long command, id ser, id res) {
    if (MVShouldBlockCommandInt(command, data)) return gSendSerializeReturnsId ? MVEmptySignal() : nil;
    if (!gOrigSendSerialize) return nil;
    return ((id (*)(id, SEL, id, long long, id, id))gOrigSendSerialize)(self, _cmd, data, command, ser, res);
}

static int MVCommandEnc(Method m) {
    /* 1 = object, 2 = integer, 0 = skip hook */
    char *t = method_copyArgumentType(m, 3);
    if (!t) return 0;
    char c = t[0];
    MVGLog(@"command encoding=%s", t);
    free(t);
    if (c == '@') return 1;
    if (strchr("qQiIlL", c)) return 2;
    return 0;
}

static BOOL MVReturnIsId(Method m) {
    const char *enc = method_getTypeEncoding(m);
    return enc && enc[0] == '@';
}

static BOOL MVHookSend(Class cls, SEL sel, IMP *origOut, IMP impObj, IMP impInt, BOOL *cmdIsObjOut, BOOL *retIdOut, NSString *tag) {
    if (!cls) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        MVGLog(@"%@: no method", tag);
        return NO;
    }
    unsigned nargs = method_getNumberOfArguments(m);
    if (nargs < 4) {
        MVGLog(@"%@: nargs=%u skip", tag, nargs);
        return NO;
    }
    int enc = MVCommandEnc(m);
    if (enc == 0) {
        MVGLog(@"%@: unknown command encoding, skip (keep original)", tag);
        return NO;
    }
    BOOL cmdIsObj = (enc == 1);
    BOOL retId = MVReturnIsId(m);
    if (cmdIsObjOut) *cmdIsObjOut = cmdIsObj;
    if (retIdOut) *retIdOut = retId;
    if (origOut) *origOut = method_getImplementation(m);
    method_setImplementation(m, cmdIsObj ? impObj : impInt);
    MVGLog(@"%@: OK cmd=%@ ret=%@", tag, cmdIsObj ? @"obj" : @"int", retId ? @"id" : @"void");
    return YES;
}

#pragma mark - Install

void MaxVibeInstallGhost(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        MVGLog(@"install begin online=%d read=%d typing=%d",
               MaxVibeHideOnlineEnabled(), MaxVibeHideReadEnabled(), MaxVibeHideTypingEnabled());

        Class typingSender = NSClassFromString(@"OKMChatTypingSender");
        MVHook(typingSender, NSSelectorFromString(@"startSendingTypingWithType:inChat:key:"),
               (IMP)mvibe_startTyping, &gOrigStartTyping, @"startSendingTyping");
        MVHook(typingSender, NSSelectorFromString(@"_timerFired:"),
               (IMP)mvibe_timerFired, &gOrigTimerFired, @"_timerFired");
        MVHook(typingSender, NSSelectorFromString(@"stopSendingTypingWithKey:"),
               (IMP)mvibe_stopTyping, &gOrigStopTyping, @"stopSendingTyping");
        MVHook(typingSender, NSSelectorFromString(@"sendTypingNotificationIfNeeded:"),
               (IMP)mvibe_sendTypingIfNeeded, &gOrigSendTypingIfNeeded, @"sendTypingIfNeeded sender");

        Class typingSvc = NSClassFromString(@"OKMTypingService");
        MVHook(typingSvc, NSSelectorFromString(@"userDidTypeInChat:type:"),
               (IMP)mvibe_userDidType, &gOrigUserDidType, @"userDidTypeInChat");
        if (!gOrigSendTypingIfNeeded) {
            MVHook(typingSvc, NSSelectorFromString(@"sendTypingNotificationIfNeeded:"),
                   (IMP)mvibe_sendTypingIfNeeded, &gOrigSendTypingIfNeeded, @"sendTypingIfNeeded svc");
        }

        Class tasks = NSClassFromString(@"OKMTasksService");
        MVHook(tasks, NSSelectorFromString(@"enqueueTasks:withDependencies:"),
               (IMP)mvibe_enqueueTasks, &gOrigEnqueueTasks, @"enqueueTasks");
        MVHook(tasks, NSSelectorFromString(@"enqueueTask:"),
               (IMP)mvibe_enqueueTask, &gOrigEnqueueTask, @"enqueueTask");

        Class client = NSClassFromString(@"OKMMessengerClient");
        MVHook(client, NSSelectorFromString(@"_reschedulePingTimerWithForInteractive:"),
               (IMP)mvibe_pingInteractive, &gOrigPingInteractive, @"ping interactive");

        MVHookSend(client, NSSelectorFromString(@"sendData:withCommand:retry:callback:"),
                   &gOrigSendRetryCb,
                   (IMP)mvibe_sendRetryCb_obj, (IMP)mvibe_sendRetryCb_int,
                   &gSendRetryCbCmdIsObj, &gSendRetryCbReturnsId,
                   @"sendData retry:callback");
        MVHookSend(client, NSSelectorFromString(@"sendData:withCommand:retry:mapResultTo:"),
                   &gOrigSendRetryMap,
                   (IMP)mvibe_sendRetryMap_obj, (IMP)mvibe_sendRetryMap_int,
                   &gSendRetryMapCmdIsObj, &gSendRetryMapReturnsId,
                   @"sendData retry:mapResultTo");
        MVHookSend(client, NSSelectorFromString(@"sendData:withCommand:callback:"),
                   &gOrigSendCb,
                   (IMP)mvibe_sendCb_obj, (IMP)mvibe_sendCb_int,
                   &gSendCbCmdIsObj, &gSendCbReturnsId,
                   @"sendData callback");
        MVHookSend(client, NSSelectorFromString(@"sendData:withCommand:mapResultTo:"),
                   &gOrigSendMap,
                   (IMP)mvibe_sendMap_obj, (IMP)mvibe_sendMap_int,
                   &gSendMapCmdIsObj, &gSendMapReturnsId,
                   @"sendData mapResultTo");
        MVHookSend(client, NSSelectorFromString(@"sendData:withCommand:serializeBlock:resultBlock:"),
                   &gOrigSendSerialize,
                   (IMP)mvibe_sendSerialize_obj, (IMP)mvibe_sendSerialize_int,
                   &gSendSerializeCmdIsObj, &gSendSerializeReturnsId,
                   @"sendData serialize");

        MVGLog(@"install done sendRetryCb obj=%d retId=%d", gSendRetryCbCmdIsObj, gSendRetryCbReturnsId);
    });
}
