#import "MaxVibeAntiDelete.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdarg.h>

/*
 * Anti-delete v3:
 * - IMP replace (no method_exchange).
 * - Never mutate OKMMessage inside Yap _messagesUpdated (that SIGSEGV'd on own delete).
 * - Cache pk→sender on message receive / messagesUpdated (read-only).
 * - Filter ChatService deletes + PushCleanup handleDeleted for incoming.
 * - Incoming → skip delete, prefix "❌ " on the in-memory message only outside Yap tx.
 */

static NSString * const kPrefKey = @"mvibe_anti_delete_enabled";
static NSString * const kDeletedPksKey = @"mvibe_anti_delete_pks";
static NSString * const kMyUserIdKey = @"mvibe_anti_delete_my_uid";
static NSString * const kPrefix = @"❌ ";

static NSNumber *gMyUserId = nil;
static NSMutableDictionary *gMsgCache = nil; // pk -> @{senderId, incoming}
static NSMutableSet *gDeletedPks = nil;

static IMP gOrigSetUserId = NULL;
static IMP gOrigDeletePks = NULL;
static IMP gOrigDeletePksEnq = NULL;
static IMP gOrigHandleDeleted = NULL;
static IMP gOrigMessagesDeleted = NULL;
static IMP gOrigMessagesUpdated = NULL;
static IMP gOrigMessageReceived = NULL;

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
        gMsgCache = [NSMutableDictionary dictionary];
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

static BOOL MVIsOKMMessage(id obj) {
    Class cls = NSClassFromString(@"OKMMessage");
    return cls && obj && [obj isKindOfClass:cls];
}

static NSString *MVPkOfMessage(id msg) {
    @try {
        id pk = [msg valueForKey:@"primaryKey"];
        if ([pk isKindOfClass:[NSString class]] && [pk length]) return pk;
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

static BOOL MVMessageLooksIncoming(id msg) {
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

/** Read-only cache — safe inside Yap transaction. */
static void MVCacheMessage(id msg) {
    if (!MVIsOKMMessage(msg)) return;
    NSString *pk = MVPkOfMessage(msg);
    if (!pk) return;
    NSMutableDictionary *e = [NSMutableDictionary dictionary];
    NSNumber *sid = MVSenderIdOfMessage(msg);
    if (sid) e[@"senderId"] = sid;
    e[@"incoming"] = @(MVMessageLooksIncoming(msg));
    id serverId = nil;
    @try { serverId = [msg valueForKey:@"serverId"]; } @catch (__unused NSException *ex) {}
    if (serverId) e[@"serverId"] = serverId;
    gMsgCache[pk] = e;
}

static NSString *MVNormalizePk(id pkOrKey) {
    if (!pkOrKey) return nil;
    if ([pkOrKey isKindOfClass:[NSString class]]) return pkOrKey;
    if ([pkOrKey respondsToSelector:@selector(stringValue)]) return [pkOrKey stringValue];
    return [pkOrKey description];
}

static BOOL MVPkLooksIncoming(id pkOrKey) {
    NSString *key = MVNormalizePk(pkOrKey);
    if (!key.length) return NO;
    if ([gDeletedPks containsObject:key]) return YES;
    NSDictionary *c = gMsgCache[key];
    if (!c) {
        for (NSString *k in gMsgCache) {
            id sid = gMsgCache[k][@"serverId"];
            if (sid && ([[sid description] isEqualToString:key] || [sid isEqual:pkOrKey])) {
                c = gMsgCache[k];
                key = k;
                break;
            }
        }
    }
    if (!c) return NO;
    id inc = c[@"incoming"];
    if ([inc respondsToSelector:@selector(boolValue)]) return [inc boolValue];
    NSNumber *sender = c[@"senderId"];
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
    for (NSString *m in @[@"\ndeletel", @"\ndeleted", @"\nудалено"]) {
        s = [s stringByReplacingOccurrencesOfString:m withString:@""];
    }
    return s;
}

/** Mutate text — only call outside Yap write transaction. */
static void MVMarkMessageDeleted(id msg) {
    if (!MVIsOKMMessage(msg)) return;
    NSString *pk = MVPkOfMessage(msg);
    NSString *base = MVStripMarkers(MVPlainTextOfMessage(msg) ?: @"");
    MVSetPlainText(msg, [kPrefix stringByAppendingString:base]);
    if (pk.length) {
        [gDeletedPks addObject:pk];
        MVPersistDeletedPks();
    }
    MVCacheMessage(msg);
    MVLog(@"marked ❌ pk=%@", pk);
}

#pragma mark - Hooks

static void mvibe_setCurrentUserId(id self, SEL _cmd, NSNumber *uid) {
    MVRememberMyUserId(uid);
    if (gOrigSetUserId) ((void (*)(id, SEL, id))gOrigSetUserId)(self, _cmd, uid);
}

static void mvibe_deleteMessagesWithPks(id self, SEL _cmd, NSArray *pks, BOOL deleteForAll) {
    MVEnsureStore();
    if (!MaxVibeAntiDeleteEnabled() || ![pks isKindOfClass:[NSArray class]] || !gOrigDeletePks) {
        if (gOrigDeletePks) ((void (*)(id, SEL, id, BOOL))gOrigDeletePks)(self, _cmd, pks, deleteForAll);
        return;
    }
    NSMutableArray *allow = [NSMutableArray array];
    NSUInteger keep = 0;
    for (id pk in pks) {
        if (MVPkLooksIncoming(pk)) {
            keep++;
            NSString *key = MVNormalizePk(pk);
            if (key.length) [gDeletedPks addObject:key];
        } else {
            [allow addObject:pk];
        }
    }
    if (keep) MVPersistDeletedPks();
    MVLog(@"deleteMessagesWithPks total=%lu keep=%lu allow=%lu forAll=%d",
          (unsigned long)pks.count, (unsigned long)keep, (unsigned long)allow.count, deleteForAll);
    if (allow.count == 0) return;
    ((void (*)(id, SEL, id, BOOL))gOrigDeletePks)(self, _cmd, allow, deleteForAll);
}

static void mvibe_deleteMessagesWithPksEnq(id self, SEL _cmd, NSArray *pks, BOOL deleteForAll, BOOL enqueueTasks) {
    MVEnsureStore();
    if (!MaxVibeAntiDeleteEnabled() || ![pks isKindOfClass:[NSArray class]] || !gOrigDeletePksEnq) {
        if (gOrigDeletePksEnq)
            ((void (*)(id, SEL, id, BOOL, BOOL))gOrigDeletePksEnq)(self, _cmd, pks, deleteForAll, enqueueTasks);
        return;
    }
    NSMutableArray *allow = [NSMutableArray array];
    for (id pk in pks) {
        if (MVPkLooksIncoming(pk)) {
            NSString *key = MVNormalizePk(pk);
            if (key.length) [gDeletedPks addObject:key];
        } else {
            [allow addObject:pk];
        }
    }
    MVPersistDeletedPks();
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
        MVCacheMessage(item);
        if (MVMessageLooksIncoming(item)) {
            kept++;
            MVMarkMessageDeleted(item);
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
        MVCacheMessage(item);
        if (MVMessageLooksIncoming(item)) {
            MVMarkMessageDeleted(item);
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

/** Cache only — never mutate here (Yap transaction). */
static void mvibe_messagesUpdated(id self, SEL _cmd, id messages, id tx) {
    MVEnsureStore();
    if ([messages isKindOfClass:[NSArray class]]) {
        for (id msg in (NSArray *)messages) MVCacheMessage(msg);
    }
    if (gOrigMessagesUpdated) ((void (*)(id, SEL, id, id))gOrigMessagesUpdated)(self, _cmd, messages, tx);
}

static void mvibe_messageReceived(id self, SEL _cmd, id message) {
    MVEnsureStore();
    MVCacheMessage(message);
    if (gOrigMessageReceived) ((void (*)(id, SEL, id))gOrigMessageReceived)(self, _cmd, message);
}

#pragma mark - Install

static BOOL MVReplace(Class cls, SEL sel, IMP neu, IMP *outOrig) {
    if (!cls || !sel || !neu || !outOrig) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    *outOrig = method_getImplementation(m);
    method_setImplementation(m, neu);
    return YES;
}

void MaxVibeInstallAntiDelete(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        MVEnsureStore();
        MVLog(@"install begin v3 (IMP, cache-only Yap) enabled=%d", MaxVibeAntiDeleteEnabled());

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
        MVLog(@"_messagesUpdated: %s",
              MVReplace(chat, NSSelectorFromString(@"_messagesUpdated:inTransaction:"),
                        (IMP)mvibe_messagesUpdated, &gOrigMessagesUpdated) ? "OK" : "FAIL");

        Class push = NSClassFromString(@"OKMPushCleanupHelper");
        MVLog(@"_handleDeletedMessages: %s",
              MVReplace(push, NSSelectorFromString(@"_handleDeletedMessages:inChatWithId:"),
                        (IMP)mvibe_handleDeletedMessages, &gOrigHandleDeleted) ? "OK" : "FAIL");

        Class del = NSClassFromString(@"OKMMessageDeleteListener");
        MVLog(@"_messagesDeleted: %s",
              MVReplace(del, NSSelectorFromString(@"_messagesDeleted:inChat:"),
                        (IMP)mvibe_messagesDeleted, &gOrigMessagesDeleted) ? "OK" : "FAIL");

        Class incoming = NSClassFromString(@"OKMIncomingMessagesListener");
        MVLog(@"_messageReceived: %s",
              MVReplace(incoming, NSSelectorFromString(@"_messageReceived:"),
                        (IMP)mvibe_messageReceived, &gOrigMessageReceived) ? "OK" : "FAIL");

        MVLog(@"install done my=%@", gMyUserId);
    });
}
