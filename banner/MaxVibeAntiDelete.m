#import "MaxVibeAntiDelete.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdarg.h>

/*
 * Anti-delete v5 — UPDATE instead of DELETE (Android parity).
 *
 * Android: UPDATE messages SET text=text||'\ndeletel' ...
 * iOS Yap has no SQL messages table → equivalent is okm_saveMessage: after
 * rewriting text to "❌ "+text+"\ndeletel", and skipping the remove.
 *
 * Do NOT hook _messagesUpdated / Yap setObject/remove (launch SIGABRT / SIGSEGV).
 * Do NOT read Yap from inside ChatService delete (nested tx risk).
 * ChatService hooks only skip PKs already in gDeletedPks.
 */

static NSString * const kPrefKey = @"mvibe_anti_delete_enabled";
static NSString * const kDeletedPksKey = @"mvibe_anti_delete_pks";
static NSString * const kMyUserIdKey = @"mvibe_anti_delete_my_uid";
static NSString * const kPrefix = @"❌ ";
static NSString * const kDbMarker = @"\ndeletel";

static NSNumber *gMyUserId = nil;
static NSMutableSet *gDeletedPks = nil;
static __weak id gChatService = nil;

static IMP gOrigSetUserId = NULL;
static IMP gOrigDeletePks = NULL;
static IMP gOrigDeletePksEnq = NULL;
static IMP gOrigHandleDeleted = NULL;
static IMP gOrigMessagesDeleted = NULL;

#pragma mark - Prefs

BOOL MaxVibeAntiDeleteEnabled(void) {
    NSUserDefaults *p = [NSUserDefaults standardUserDefaults];
    if ([p objectForKey:kPrefKey] == nil) return NO;
    return [p boolForKey:kPrefKey];
}

void MaxVibeSetAntiDeleteEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kPrefKey];
}

#pragma mark - Helpers

static void MVLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void MVLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[MaxVibeAntiDelete] %@", line);
}

static void MVEnsureStore(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gDeletedPks = [NSMutableSet set];
        NSUserDefaults *p = [NSUserDefaults standardUserDefaults];
        NSArray *saved = [p arrayForKey:kDeletedPksKey];
        if ([saved isKindOfClass:[NSArray class]]) [gDeletedPks addObjectsFromArray:saved];
        id uid = [p objectForKey:kMyUserIdKey];
        if ([uid isKindOfClass:[NSNumber class]]) gMyUserId = uid;
    });
}

static void MVPersistDeletedPks(void) {
    [[NSUserDefaults standardUserDefaults] setObject:gDeletedPks.allObjects forKey:kDeletedPksKey];
}

static void MVRememberMyUserId(NSNumber *uid) {
    if (![uid isKindOfClass:[NSNumber class]] || uid.longLongValue == 0) return;
    gMyUserId = uid;
    [[NSUserDefaults standardUserDefaults] setObject:uid forKey:kMyUserIdKey];
}

static void MVRememberChatService(id obj) {
    Class chat = NSClassFromString(@"OKMChatService");
    if (chat && obj && [obj isKindOfClass:chat]) gChatService = obj;
}

static BOOL MVIsOKMMessage(id obj) {
    Class cls = NSClassFromString(@"OKMMessage");
    return cls && obj && [obj isKindOfClass:cls];
}

static NSString *MVNormalizePk(id pkOrKey) {
    if (!pkOrKey) return nil;
    if ([pkOrKey isKindOfClass:[NSString class]]) return (NSString *)pkOrKey;
    if ([pkOrKey respondsToSelector:@selector(stringValue)]) return [pkOrKey stringValue];
    return [pkOrKey description];
}

static NSString *MVPkOfMessage(id msg) {
    @try {
        id pk = [msg valueForKey:@"primaryKey"];
        if ([pk isKindOfClass:[NSString class]] && [(NSString *)pk length]) return pk;
    } @catch (__unused NSException *ex) {}
    return nil;
}

static NSNumber *MVSenderIdOfMessage(id msg) {
    @try {
        id sid = [msg valueForKey:@"senderId"];
        if ([sid isKindOfClass:[NSNumber class]]) return sid;
        id sender = [msg valueForKey:@"sender"];
        if (sender) {
            id sid2 = [sender valueForKey:@"id"];
            if (!sid2) sid2 = [sender valueForKey:@"userId"];
            if ([sid2 isKindOfClass:[NSNumber class]]) return sid2;
        }
    } @catch (__unused NSException *ex) {}
    return nil;
}

static BOOL MVMessageIsIncoming(id msg) {
    if (!MVIsOKMMessage(msg)) return NO;
    @try {
        id inc = [msg valueForKey:@"isIncoming"];
        if ([inc respondsToSelector:@selector(boolValue)]) return [inc boolValue];
    } @catch (__unused NSException *ex) {}
    @try {
        id outg = [msg valueForKey:@"outgoing"];
        if ([outg respondsToSelector:@selector(boolValue)]) return ![outg boolValue];
    } @catch (__unused NSException *ex) {}
    NSNumber *sender = MVSenderIdOfMessage(msg);
    if (!gMyUserId || !sender) return NO;
    return sender.unsignedLongLongValue != gMyUserId.unsignedLongLongValue;
}

static NSString *MVPlainTextOfMessage(id msg) {
    @try {
        id textObj = [msg valueForKey:@"text"];
        if ([textObj isKindOfClass:[NSString class]]) return textObj;
        if (textObj) {
            id t = [textObj valueForKey:@"text"];
            if ([t isKindOfClass:[NSString class]]) return t;
        }
    } @catch (__unused NSException *ex) {}
    return nil;
}

static void MVSetPlainText(id msg, NSString *text) {
    if (!msg || !text) return;
    @try {
        id textObj = [msg valueForKey:@"text"];
        if ([textObj isKindOfClass:[NSString class]]) {
            [msg setValue:text forKey:@"text"];
        } else if (textObj) {
            [textObj setValue:text forKey:@"text"];
            SEL setup = NSSelectorFromString(@"_setupTextAndLinks:");
            if ([textObj respondsToSelector:setup]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [textObj performSelector:setup withObject:text];
#pragma clang diagnostic pop
            }
        }
    } @catch (__unused NSException *ex) {}
}

static NSString *MVStripMarkers(NSString *text) {
    if (![text isKindOfClass:[NSString class]]) return text ?: @"";
    NSString *s = text;
    if ([s hasPrefix:kPrefix]) s = [s substringFromIndex:kPrefix.length];
    for (NSString *m in @[kDbMarker, @"\ndeleted", @"\nудалено"]) {
        s = [s stringByReplacingOccurrencesOfString:m withString:@""];
    }
    while ([s hasSuffix:@"\n"]) s = [s substringToIndex:s.length - 1];
    return s;
}

static void MVTagMessageText(id msg) {
    NSString *base = MVStripMarkers(MVPlainTextOfMessage(msg) ?: @"");
    // Same idea as Android: keep body + deletel marker; ❌ is the visible cue.
    NSString *tagged = [[kPrefix stringByAppendingString:base] stringByAppendingString:kDbMarker];
    MVSetPlainText(msg, tagged);
    NSString *pk = MVPkOfMessage(msg);
    if (pk.length) {
        [gDeletedPks addObject:pk];
        MVPersistDeletedPks();
    }
}

static id MVYapConnectionFrom(id host) {
    if (!host) host = gChatService;
    if (!host) return nil;
    for (NSString *key in @[@"dbWriteConnection", @"_dbWriteConnection",
                            @"writeConnection", @"_writeConnection", @"rwConnection"]) {
        id conn = nil;
        @try { conn = [host valueForKey:key]; } @catch (__unused NSException *e) { conn = nil; }
        if (conn) return conn;
    }
    return nil;
}

/** Async UPDATE (= okm_saveMessage), never nested in the delete call stack. */
static void MVAsyncSaveMessage(id host, id msg) {
    if (!msg) return;
    id retainedMsg = msg;
    id retainedHost = host ?: (id)gChatService;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @try {
            id conn = MVYapConnectionFrom(retainedHost);
            if (!conn) {
                MVLog(@"UPDATE skip: no write connection");
                return;
            }
            void (^write)(id) = ^(id tx) {
                @try {
                    SEL save = NSSelectorFromString(@"okm_saveMessage:");
                    if ([tx respondsToSelector:save]) {
                        ((void (*)(id, SEL, id))objc_msgSend)(tx, save, retainedMsg);
                        MVLog(@"UPDATE okm_saveMessage pk=%@", MVPkOfMessage(retainedMsg));
                    }
                } @catch (NSException *ex) {
                    MVLog(@"UPDATE fail: %@", ex.name);
                }
            };
            SEL asyncRW = NSSelectorFromString(@"asyncReadWriteWithBlock:completionBlock:");
            SEL syncRW = NSSelectorFromString(@"readWriteWithBlock:");
            if ([conn respondsToSelector:asyncRW]) {
                ((void (*)(id, SEL, id, id))objc_msgSend)(conn, asyncRW, write, ^{});
            } else if ([conn respondsToSelector:syncRW]) {
                ((void (*)(id, SEL, id))objc_msgSend)(conn, syncRW, write);
            }
        } @catch (NSException *ex) {
            MVLog(@"UPDATE outer: %@", ex.name);
        }
    });
}

static void MVConvertDeleteToUpdate(id host, id msg) {
    if (!MVMessageIsIncoming(msg)) return;
    MVTagMessageText(msg);
    MVLog(@"convert DELETE→UPDATE pk=%@", MVPkOfMessage(msg));
    MVAsyncSaveMessage(host, msg);
}

#pragma mark - Hooks

static void mvibe_setCurrentUserId(id self, SEL _cmd, NSNumber *uid) {
    MVRememberMyUserId(uid);
    if (gOrigSetUserId) ((void (*)(id, SEL, id))gOrigSetUserId)(self, _cmd, uid);
}

/** Only skip PKs already marked — no Yap reads here. */
static void mvibe_deleteMessagesWithPks(id self, SEL _cmd, NSArray *pks, BOOL deleteForAll) {
    MVEnsureStore();
    MVRememberChatService(self);
    if (!MaxVibeAntiDeleteEnabled() || ![pks isKindOfClass:[NSArray class]] || !gOrigDeletePks) {
        if (gOrigDeletePks) ((void (*)(id, SEL, id, BOOL))gOrigDeletePks)(self, _cmd, pks, deleteForAll);
        return;
    }
    NSMutableArray *allow = [NSMutableArray array];
    NSUInteger keep = 0;
    for (id pk in pks) {
        NSString *key = MVNormalizePk(pk);
        if (key.length && [gDeletedPks containsObject:key]) {
            keep++;
        } else {
            [allow addObject:pk];
        }
    }
    MVLog(@"deleteMessagesWithPks total=%lu keep=%lu allow=%lu forAll=%d",
          (unsigned long)pks.count, (unsigned long)keep, (unsigned long)allow.count, deleteForAll);
    if (allow.count == 0) return;
    ((void (*)(id, SEL, id, BOOL))gOrigDeletePks)(self, _cmd, allow, deleteForAll);
}

static void mvibe_deleteMessagesWithPksEnq(id self, SEL _cmd, NSArray *pks, BOOL deleteForAll, BOOL enqueueTasks) {
    MVEnsureStore();
    MVRememberChatService(self);
    if (!MaxVibeAntiDeleteEnabled() || ![pks isKindOfClass:[NSArray class]] || !gOrigDeletePksEnq) {
        if (gOrigDeletePksEnq)
            ((void (*)(id, SEL, id, BOOL, BOOL))gOrigDeletePksEnq)(self, _cmd, pks, deleteForAll, enqueueTasks);
        return;
    }
    NSMutableArray *allow = [NSMutableArray array];
    for (id pk in pks) {
        NSString *key = MVNormalizePk(pk);
        if (key.length && [gDeletedPks containsObject:key]) continue;
        [allow addObject:pk];
    }
    MVLog(@"_deleteMessagesWithPks total=%lu allow=%lu forAll=%d",
          (unsigned long)pks.count, (unsigned long)allow.count, deleteForAll);
    if (allow.count == 0) return;
    ((void (*)(id, SEL, id, BOOL, BOOL))gOrigDeletePksEnq)(self, _cmd, allow, deleteForAll, enqueueTasks);
}

static void mvibe_handleDeletedMessages(id self, SEL _cmd, id messages, id chatId) {
    MVEnsureStore();
    if (!MaxVibeAntiDeleteEnabled() || !gOrigHandleDeleted) {
        if (gOrigHandleDeleted) ((void (*)(id, SEL, id, id))gOrigHandleDeleted)(self, _cmd, messages, chatId);
        return;
    }
    NSArray *list = nil;
    if ([messages isKindOfClass:[NSArray class]]) list = messages;
    else if ([messages respondsToSelector:@selector(allObjects)]) list = [messages allObjects];
    if (!list) {
        ((void (*)(id, SEL, id, id))gOrigHandleDeleted)(self, _cmd, messages, chatId);
        return;
    }
    NSMutableArray *allow = [NSMutableArray array];
    NSUInteger kept = 0;
    for (id item in list) {
        if (MVMessageIsIncoming(item)) {
            kept++;
            // Mark PK first so a later ChatService delete skips it.
            MVConvertDeleteToUpdate(gChatService, item);
        } else {
            [allow addObject:item];
        }
    }
    MVLog(@"handleDeletedMessages chat=%@ keep=%lu allow=%lu my=%@",
          chatId, (unsigned long)kept, (unsigned long)allow.count, gMyUserId);
    if (allow.count == 0) return;
    if (allow.count == list.count) {
        ((void (*)(id, SEL, id, id))gOrigHandleDeleted)(self, _cmd, messages, chatId);
    } else {
        ((void (*)(id, SEL, id, id))gOrigHandleDeleted)(self, _cmd, allow, chatId);
    }
}

static void mvibe_messagesDeleted(id self, SEL _cmd, id messages, id chat) {
    MVEnsureStore();
    if (!MaxVibeAntiDeleteEnabled() || !gOrigMessagesDeleted) {
        if (gOrigMessagesDeleted) ((void (*)(id, SEL, id, id))gOrigMessagesDeleted)(self, _cmd, messages, chat);
        return;
    }
    if (![messages isKindOfClass:[NSArray class]]) {
        ((void (*)(id, SEL, id, id))gOrigMessagesDeleted)(self, _cmd, messages, chat);
        return;
    }
    NSMutableArray *allow = [NSMutableArray array];
    for (id item in (NSArray *)messages) {
        if (MVMessageIsIncoming(item)) {
            MVConvertDeleteToUpdate(gChatService, item);
            continue;
        }
        [allow addObject:item];
    }
    MVLog(@"messagesDeleted allow=%lu", (unsigned long)allow.count);
    if (allow.count == 0) return;
    if (allow.count == [(NSArray *)messages count]) {
        ((void (*)(id, SEL, id, id))gOrigMessagesDeleted)(self, _cmd, messages, chat);
    } else {
        ((void (*)(id, SEL, id, id))gOrigMessagesDeleted)(self, _cmd, allow, chat);
    }
}

#pragma mark - Install

static BOOL MVReplace(Class cls, SEL sel, IMP neu, IMP *outOrig) {
    if (!cls || !sel || !neu || !outOrig) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    *outOrig = method_getImplementation(m);
    if (!*outOrig) return NO;
    method_setImplementation(m, neu);
    return YES;
}

void MaxVibeInstallAntiDelete(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        MVEnsureStore();
        MVLog(@"install begin v5 (DELETE→UPDATE okm_saveMessage) enabled=%d",
              MaxVibeAntiDeleteEnabled());

        Class creds = NSClassFromString(@"OKMMessengerCredentials");
        MVLog(@"setCurrentUserId: %s",
              MVReplace(creds, NSSelectorFromString(@"setCurrentUserId:"),
                        (IMP)mvibe_setCurrentUserId, &gOrigSetUserId) ? "OK" : "FAIL");

        Class chat = NSClassFromString(@"OKMChatService");
        MVLog(@"deleteMessagesWithPks: %s",
              MVReplace(chat, NSSelectorFromString(@"deleteMessagesWithPks:deleteForAll:"),
                        (IMP)mvibe_deleteMessagesWithPks, &gOrigDeletePks) ? "OK" : "FAIL");
        MVLog(@"_deleteMessagesWithPks: %s",
              MVReplace(chat, NSSelectorFromString(@"_deleteMessagesWithPks:deleteForAll:enqueueTasks:"),
                        (IMP)mvibe_deleteMessagesWithPksEnq, &gOrigDeletePksEnq) ? "OK" : "FAIL");

        Class push = NSClassFromString(@"OKMPushCleanupHelper");
        MVLog(@"_handleDeletedMessages: %s",
              MVReplace(push, NSSelectorFromString(@"_handleDeletedMessages:inChatWithId:"),
                        (IMP)mvibe_handleDeletedMessages, &gOrigHandleDeleted) ? "OK" : "FAIL");

        Class del = NSClassFromString(@"OKMMessageDeleteListener");
        MVLog(@"_messagesDeleted: %s",
              MVReplace(del, NSSelectorFromString(@"_messagesDeleted:inChat:"),
                        (IMP)mvibe_messagesDeleted, &gOrigMessagesDeleted) ? "OK" : "FAIL");

        MVLog(@"install done my=%@", gMyUserId);
    });
}
