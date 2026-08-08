#import "MaxVibeAntiDelete.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdarg.h>

/*
 * Anti-delete v6
 *
 * Logs (v5): own "delete for all" → keep=0 allow=1 → SIGSEGV.
 * Cause: ChatService deleteMessages* IMP trampolines (even pass-through).
 *
 * Fix:
 *  - Do NOT hook OKMChatService deletes at all (own delete stays vanilla).
 *  - Hook only OKMPushCleanupHelper _handleDeletedMessages + MessageDeleteListener.
 *  - Incoming → tag "❌ "+\ndeletel, async okm_saveMessage: (UPDATE), skip remove.
 *  - Discover Yap write connection by walking KVC from the helper / chatting client,
 *    or by opening yapdb.sqlite as a last resort.
 */

static NSString * const kPrefKey = @"mvibe_anti_delete_enabled";
static NSString * const kDeletedPksKey = @"mvibe_anti_delete_pks";
static NSString * const kMyUserIdKey = @"mvibe_anti_delete_my_uid";
static NSString * const kPrefix = @"❌ ";
static NSString * const kDbMarker = @"\ndeletel";

static NSNumber *gMyUserId = nil;
static NSMutableSet *gDeletedPks = nil;
static id gWriteConnection = nil; // retained YapDatabaseConnection

static IMP gOrigSetUserId = NULL;
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

#pragma mark - Log / store

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

#pragma mark - Message helpers

static BOOL MVIsOKMMessage(id obj) {
    Class cls = NSClassFromString(@"OKMMessage");
    return cls && obj && [obj isKindOfClass:cls];
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
    NSString *tagged = [[kPrefix stringByAppendingString:base] stringByAppendingString:kDbMarker];
    MVSetPlainText(msg, tagged);
    NSString *pk = MVPkOfMessage(msg);
    if (pk.length) {
        [gDeletedPks addObject:pk];
        MVPersistDeletedPks();
    }
}

#pragma mark - Yap connection discovery

static BOOL MVLooksLikeWriteConnection(id obj) {
    if (!obj) return NO;
    return [obj respondsToSelector:NSSelectorFromString(@"asyncReadWriteWithBlock:completionBlock:")] ||
           [obj respondsToSelector:NSSelectorFromString(@"readWriteWithBlock:")];
}

static void MVRememberConnection(id conn) {
    if (!MVLooksLikeWriteConnection(conn)) return;
    if (gWriteConnection != conn) {
        gWriteConnection = conn; // strong
        MVLog(@"got write connection %s", object_getClassName(conn));
    }
}

static id MVKVC(id obj, NSString *key) {
    if (!obj || !key.length) return nil;
    @try { return [obj valueForKey:key]; } @catch (__unused NSException *ex) { return nil; }
}

static id MVFindConnectionFromSeed(id seed) {
    if (MVLooksLikeWriteConnection(gWriteConnection)) return gWriteConnection;
    if (!seed) return nil;

    static NSArray *connKeys;
    static NSArray *nextKeys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        connKeys = @[
            @"dbWriteConnection", @"_dbWriteConnection", @"writeConnection", @"_writeConnection",
            @"rwConnection", @"_rwConnection", @"yapDatabaseConnection", @"connection"
        ];
        nextKeys = @[
            @"chatService", @"_chatService", @"messengerClient", @"_messengerClient", @"client",
            @"dependencies", @"_dependencies", @"database", @"_database", @"yapDatabase",
            @"_yapDatabase", @"db", @"messengerCredentials", @"_messengerCredentials"
        ];
    });

    NSMutableArray *queue = [NSMutableArray arrayWithObject:seed];
    NSHashTable *seen = [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory];
    NSUInteger steps = 0;
    while (queue.count && steps < 40) {
        id obj = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (!obj || [seen containsObject:obj]) continue;
        [seen addObject:obj];
        steps++;

        for (NSString *k in connKeys) {
            id c = MVKVC(obj, k);
            if (MVLooksLikeWriteConnection(c)) {
                MVRememberConnection(c);
                return c;
            }
        }
        id db = MVKVC(obj, @"yapDatabase");
        if (!db) db = MVKVC(obj, @"database");
        if (db) {
            SEL newConn = NSSelectorFromString(@"newConnection");
            if ([db respondsToSelector:newConn]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                id c = [db performSelector:newConn];
#pragma clang diagnostic pop
                if (MVLooksLikeWriteConnection(c)) {
                    MVRememberConnection(c);
                    return c;
                }
            }
        }
        for (NSString *k in nextKeys) {
            id n = MVKVC(obj, k);
            if (n && ![seen containsObject:n]) [queue addObject:n];
        }
    }
    return nil;
}

/** Last resort: open Library/**/yapdb.sqlite via YapDatabase. */
static id MVOpenYapdbFallback(void) {
    if (MVLooksLikeWriteConnection(gWriteConnection)) return gWriteConnection;
    Class YapDatabase = NSClassFromString(@"YapDatabase");
    if (!YapDatabase) return nil;

    NSString *lib = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
    if (!lib.length) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:lib];
    NSString *rel = nil;
    NSString *found = nil;
    while ((rel = [en nextObject])) {
        if ([rel.lastPathComponent isEqualToString:@"yapdb.sqlite"]) {
            found = [lib stringByAppendingPathComponent:rel];
            break;
        }
    }
    if (!found.length) {
        MVLog(@"yapdb.sqlite not found under Library");
        return nil;
    }
    @try {
        NSURL *url = [NSURL fileURLWithPath:found];
        id db = ((id (*)(id, SEL, id, id))objc_msgSend)([YapDatabase alloc],
                        NSSelectorFromString(@"initWithURL:options:"), url, nil);
        if (!db) return nil;
        SEL newConn = NSSelectorFromString(@"newConnection");
        if (![db respondsToSelector:newConn]) return nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id c = [db performSelector:newConn];
#pragma clang diagnostic pop
        MVRememberConnection(c);
        MVLog(@"opened fallback yapdb %@", found);
        return c;
    } @catch (NSException *ex) {
        MVLog(@"fallback yap open fail: %@", ex.name);
        return nil;
    }
}

static id MVResolveWriteConnection(id seed) {
    id c = MVFindConnectionFromSeed(seed);
    if (c) return c;
    return MVOpenYapdbFallback();
}

static void MVAsyncSaveMessage(id seed, id msg) {
    if (!msg) return;
    id retainedMsg = msg;
    id seedRet = seed;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @try {
            id conn = MVResolveWriteConnection(seedRet);
            if (!conn) {
                MVLog(@"UPDATE skip: no connection");
                return;
            }
            void (^write)(id) = ^(id tx) {
                @try {
                    SEL save = NSSelectorFromString(@"okm_saveMessage:");
                    if ([tx respondsToSelector:save]) {
                        ((void (*)(id, SEL, id))objc_msgSend)(tx, save, retainedMsg);
                        MVLog(@"UPDATE ok pk=%@", MVPkOfMessage(retainedMsg));
                    } else {
                        MVLog(@"UPDATE skip: no okm_saveMessage:");
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

static void MVConvertDeleteToUpdate(id seed, id msg) {
    NSNumber *sid = MVSenderIdOfMessage(msg);
    MVLog(@"candidate pk=%@ sender=%@ my=%@ incoming=%d",
          MVPkOfMessage(msg), sid, gMyUserId, MVMessageIsIncoming(msg));
    if (!MVMessageIsIncoming(msg)) return;
    MVTagMessageText(msg);
    MVLog(@"DELETE→UPDATE pk=%@", MVPkOfMessage(msg));
    MVAsyncSaveMessage(seed, msg);
}

#pragma mark - Hooks (block IMPs — no ChatService)

static void mvibe_setCurrentUserId(id self, SEL _cmd, NSNumber *uid) {
    MVRememberMyUserId(uid);
    if (gOrigSetUserId) ((void (*)(id, SEL, id))gOrigSetUserId)(self, _cmd, uid);
}

static void mvibe_handleDeletedMessages(id self, SEL _cmd, id messages, id chatId) {
    MVEnsureStore();
    // Always try to learn a DB connection from the cleanup helper graph.
    MVResolveWriteConnection(self);

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
            MVConvertDeleteToUpdate(self, item);
        } else {
            [allow addObject:item];
        }
    }
    MVLog(@"handleDeletedMessages chat=%@ keep=%lu allow=%lu my=%@",
          chatId, (unsigned long)kept, (unsigned long)allow.count, gMyUserId);

    // Own / unknown → vanilla path with ORIGINAL array when unchanged.
    if (allow.count == 0) return;
    if (allow.count == list.count) {
        ((void (*)(id, SEL, id, id))gOrigHandleDeleted)(self, _cmd, messages, chatId);
    } else {
        ((void (*)(id, SEL, id, id))gOrigHandleDeleted)(self, _cmd, allow, chatId);
    }
}

static void mvibe_messagesDeleted(id self, SEL _cmd, id messages, id chat) {
    MVEnsureStore();
    MVResolveWriteConnection(self);
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
            MVConvertDeleteToUpdate(self, item);
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
        MVLog(@"install begin v6 (no ChatService hooks; DELETE→UPDATE) enabled=%d",
              MaxVibeAntiDeleteEnabled());

        Class creds = NSClassFromString(@"OKMMessengerCredentials");
        MVLog(@"setCurrentUserId: %s",
              MVReplace(creds, NSSelectorFromString(@"setCurrentUserId:"),
                        (IMP)mvibe_setCurrentUserId, &gOrigSetUserId) ? "OK" : "FAIL");

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
