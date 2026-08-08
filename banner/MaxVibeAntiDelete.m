#import "MaxVibeAntiDelete.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdarg.h>

/*
 * Anti-delete v10 — launch-safe
 *
 * v9 hooked _messagesUpdated via block IMP → SIGABRT on YapDatabase-Write
 * at launch (doesNotRecognizeSelector). Do NOT hook _messagesUpdated.
 *
 * v10:
 *  - No ChatService hooks at all (delete* or _messagesUpdated)
 *  - Only PushCleanup _handleDeletedMessages via C trampoline (not blocks)
 *  - setCurrentUserId: C trampoline
 *  - Incoming peer wipe → status away from Removed(10), tag ❌+\ndeletel,
 *    okm_saveMessage on app write connection, skip original wipe
 *  - Own deletes untouched
 */

static NSString * const kPrefKey = @"mvibe_anti_delete_enabled";
static NSString * const kDeletedPksKey = @"mvibe_anti_delete_pks";
static NSString * const kMyUserIdKey = @"mvibe_anti_delete_my_uid";
static NSString * const kPrefix = @"\u274C ";
static NSString * const kDbMarker = @"\ndeletel";
static const NSInteger kStatusRemovedDefault = 10;

static NSNumber *gMyUserId = nil;
static NSMutableSet *gDeletedPks = nil;
static NSInteger gPreferredLiveStatus = 0;
static NSInteger gRemovedStatus = kStatusRemovedDefault;

static id gWriteConnection = nil;
static id gYapDatabase = nil;

static IMP gOrigSetUserId = NULL;
static IMP gOrigHandleDeleted = NULL;
static SEL gSelHandleDeleted;

#pragma mark - Prefs

BOOL MaxVibeAntiDeleteEnabled(void) {
    NSUserDefaults *p = [NSUserDefaults standardUserDefaults];
    if ([p objectForKey:kPrefKey] == nil) return NO;
    return [p boolForKey:kPrefKey];
}

void MaxVibeSetAntiDeleteEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kPrefKey];
}

#pragma mark - Log

static void MVLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void MVLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[MaxVibeAntiDelete] %@", line);
    @try {
        NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        if (!doc.length) return;
        NSString *path = [doc stringByAppendingPathComponent:@"mvibe_antidelete.log"];
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

static NSNumber *MVNumberize(id v) {
    if ([v isKindOfClass:[NSNumber class]]) return v;
    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) {
        return @([(NSString *)v longLongValue]);
    }
    return nil;
}

static NSNumber *MVSenderIdOfMessage(id msg) {
    @try {
        NSNumber *sid = MVNumberize([msg valueForKey:@"senderId"]);
        if (sid) return sid;
        sid = MVNumberize([msg valueForKey:@"authorId"]);
        if (sid) return sid;
        id sender = [msg valueForKey:@"sender"];
        if (!sender) sender = [msg valueForKey:@"senderContact"];
        if (sender) {
            sid = MVNumberize([sender valueForKey:@"id"]);
            if (!sid) sid = MVNumberize([sender valueForKey:@"userId"]);
            if (!sid) sid = MVNumberize([sender valueForKey:@"contactId"]);
            if (sid) return sid;
        }
    } @catch (__unused NSException *ex) {}
    return nil;
}

static BOOL MVMessageIsIncoming(id msg) {
    if (!MVIsOKMMessage(msg)) return NO;
    NSNumber *sender = MVSenderIdOfMessage(msg);
    if (gMyUserId && sender) {
        return sender.unsignedLongLongValue != gMyUserId.unsignedLongLongValue;
    }
    return NO;
}

static NSInteger MVStatusOfMessage(id msg) {
    @try {
        id st = [msg valueForKey:@"status"];
        if ([st respondsToSelector:@selector(longLongValue)]) return (NSInteger)[st longLongValue];
    } @catch (__unused NSException *ex) {}
    return -999;
}

static void MVSetStatus(id msg, NSInteger status) {
    if (!msg || status == -999) return;
    @try {
        [msg setValue:@(status) forKey:@"status"];
    } @catch (__unused NSException *ex) {}
}

static void MVClearLocalRemove(id msg) {
    @try {
        if (class_getProperty(object_getClass(msg), "localRemoveStatus") ||
            [msg respondsToSelector:NSSelectorFromString(@"setLocalRemoveStatus:")]) {
            [msg setValue:@0 forKey:@"localRemoveStatus"];
        }
    } @catch (__unused NSException *ex) {}
}

static BOOL MVIsRemovedStatus(NSInteger st) {
    if (st == -999) return NO;
    return st == gRemovedStatus || st == kStatusRemovedDefault;
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
    for (NSString *m in @[kDbMarker, @"\ndeleted", @"\n\u0443\u0434\u0430\u043b\u0435\u043d\u043e"]) {
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

static void MVConvertIncomingDelete(id msg) {
    NSInteger st = MVStatusOfMessage(msg);
    if (MVIsRemovedStatus(st)) gRemovedStatus = st;
    NSInteger live = gPreferredLiveStatus;
    if (MVIsRemovedStatus(live)) live = 0;
    MVLog(@"convert pk=%@ status %ld→%ld sender=%@ my=%@",
          MVPkOfMessage(msg), (long)st, (long)live, MVSenderIdOfMessage(msg), gMyUserId);
    MVSetStatus(msg, live);
    MVClearLocalRemove(msg);
    MVTagMessageText(msg);
}

#pragma mark - Yap

static BOOL MVLooksLikeWriteConnection(id obj) {
    if (!obj) return NO;
    return [obj respondsToSelector:NSSelectorFromString(@"asyncReadWriteWithBlock:completionBlock:")] ||
           [obj respondsToSelector:NSSelectorFromString(@"readWriteWithBlock:")];
}

static id MVKVC(id obj, NSString *key) {
    if (!obj || !key.length) return nil;
    @try { return [obj valueForKey:key]; } @catch (__unused NSException *ex) { return nil; }
}

static void MVRememberConnection(id conn) {
    if (!MVLooksLikeWriteConnection(conn)) return;
    gWriteConnection = conn;
    id db = MVKVC(conn, @"database");
    if (db) gYapDatabase = db;
}

static id MVFindConnectionFromSeed(id seed) {
    if (MVLooksLikeWriteConnection(gWriteConnection)) return gWriteConnection;
    if (!seed) return nil;
    NSArray *connKeys = @[
        @"dbWriteConnection", @"_dbWriteConnection", @"writeConnection", @"_writeConnection",
        @"rwConnection", @"yapDatabaseConnection", @"connection"
    ];
    NSArray *nextKeys = @[
        @"chatService", @"_chatService", @"messengerClient", @"_messengerClient", @"client",
        @"dependencies", @"_dependencies", @"database", @"yapDatabase", @"_yapDatabase", @"db"
    ];
    NSMutableArray *queue = [NSMutableArray arrayWithObject:seed];
    NSMutableSet *seen = [NSMutableSet set];
    NSUInteger steps = 0;
    while (queue.count && steps < 40) {
        id obj = queue[0];
        [queue removeObjectAtIndex:0];
        if (!obj) continue;
        NSValue *ptr = [NSValue valueWithPointer:(__bridge const void *)obj];
        if ([seen containsObject:ptr]) continue;
        [seen addObject:ptr];
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
            gYapDatabase = db;
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
            if (!n) continue;
            NSValue *np = [NSValue valueWithPointer:(__bridge const void *)n];
            if (![seen containsObject:np]) [queue addObject:n];
        }
    }
    return gWriteConnection;
}

static void MVSaveMessageStandalone(id seed, id msg) {
    id conn = MVFindConnectionFromSeed(seed);
    if (!conn) {
        MVLog(@"save skip: no conn");
        return;
    }
    void (^write)(id) = ^(id tx) {
        @try {
            SEL save = NSSelectorFromString(@"okm_saveMessage:");
            if (![tx respondsToSelector:save]) {
                MVLog(@"save skip: no okm_saveMessage on %@", NSStringFromClass([tx class]));
                return;
            }
            ((void (*)(id, SEL, id))objc_msgSend)(tx, save, msg);
            MVLog(@"save ok pk=%@ status=%ld", MVPkOfMessage(msg), (long)MVStatusOfMessage(msg));
        } @catch (NSException *ex) {
            MVLog(@"save fail %@", ex.name);
        }
    };
    @try {
        SEL syncRW = NSSelectorFromString(@"readWriteWithBlock:");
        SEL asyncRW = NSSelectorFromString(@"asyncReadWriteWithBlock:completionBlock:");
        if ([conn respondsToSelector:syncRW]) {
            ((void (*)(id, SEL, id))objc_msgSend)(conn, syncRW, write);
        } else if ([conn respondsToSelector:asyncRW]) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(conn, asyncRW, write, ^{});
        }
    } @catch (NSException *ex) {
        MVLog(@"save outer %@", ex.name);
    }
}

#pragma mark - C trampolines (no block IMPs)

static void mvibe_setCurrentUserId(id self, SEL _cmd, NSNumber *uid) {
    MVRememberMyUserId(uid);
    if (gOrigSetUserId) ((void (*)(id, SEL, id))gOrigSetUserId)(self, _cmd, uid);
}

static void mvibe_handleDeletedMessages(id self, SEL _cmd, id messages, id chatId) {
    MVEnsureStore();
    if (!MaxVibeAntiDeleteEnabled() || !gOrigHandleDeleted) {
        if (gOrigHandleDeleted)
            ((void (*)(id, SEL, id, id))gOrigHandleDeleted)(self, _cmd, messages, chatId);
        return;
    }

    MVFindConnectionFromSeed(self);

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
        if (!MVIsOKMMessage(item)) {
            [allow addObject:item];
            continue;
        }
        MVLog(@"push pk=%@ sender=%@ inc=%d status=%ld",
              MVPkOfMessage(item), MVSenderIdOfMessage(item),
              MVMessageIsIncoming(item), (long)MVStatusOfMessage(item));
        if (MVMessageIsIncoming(item)) {
            MVConvertIncomingDelete(item);
            MVSaveMessageStandalone(self, item);
            kept++;
        } else {
            [allow addObject:item];
        }
    }
    MVLog(@"handleDeletedMessages chat=%@ keep=%lu allow=%lu",
          chatId, (unsigned long)kept, (unsigned long)allow.count);
    if (allow.count == 0) return;
    if (allow.count == list.count) {
        ((void (*)(id, SEL, id, id))gOrigHandleDeleted)(self, _cmd, messages, chatId);
    } else {
        ((void (*)(id, SEL, id, id))gOrigHandleDeleted)(self, _cmd, allow, chatId);
    }
}

void MaxVibeInstallAntiDelete(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        MVEnsureStore();
        gSelHandleDeleted = NSSelectorFromString(@"_handleDeletedMessages:inChatWithId:");
        MVLog(@"install begin v10 (launch-safe, push-only C trampoline) enabled=%d",
              MaxVibeAntiDeleteEnabled());

        Class creds = NSClassFromString(@"OKMMessengerCredentials");
        Method mCred = class_getInstanceMethod(creds, NSSelectorFromString(@"setCurrentUserId:"));
        if (mCred) {
            gOrigSetUserId = method_getImplementation(mCred);
            method_setImplementation(mCred, (IMP)mvibe_setCurrentUserId);
            MVLog(@"setCurrentUserId: OK");
        } else {
            MVLog(@"setCurrentUserId: FAIL");
        }

        Class push = NSClassFromString(@"OKMPushCleanupHelper");
        Method mPush = class_getInstanceMethod(push, gSelHandleDeleted);
        if (mPush) {
            gOrigHandleDeleted = method_getImplementation(mPush);
            method_setImplementation(mPush, (IMP)mvibe_handleDeletedMessages);
            MVLog(@"_handleDeletedMessages: OK");
        } else {
            MVLog(@"_handleDeletedMessages: FAIL");
        }

        MVLog(@"install done my=%@ (no _messagesUpdated / no ChatService delete hooks)", gMyUserId);
    });
}
