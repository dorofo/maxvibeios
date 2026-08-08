#import "MaxVibeAntiDelete.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdarg.h>

/*
 * Anti-delete v9 — keep it simple
 *
 * Why previous versions failed:
 *  - ChatService deleteMessages* hooks → SIGSEGV on own "delete for all"
 *  - Push-only UPDATE left status=Removed(10) → UI queries hide the bubble
 *  - Calling _messagesUpdated ourselves with nil tx → unstable
 *
 * What actually drives the bubble:
 *  OKMChatService _messagesUpdated:inTransaction:
 *  (assert path: status == Edited || status == Removed)
 *  Removed ≈ 10. Chat list SQL: status != Removed, localRemoveStatus filters.
 *
 * v9:
 *  1) Do NOT hook ChatService delete* (own delete untouched → no crash)
 *  2) Hook _messagesUpdated: incoming + Removed → rewrite to live status,
 *     tag ❌+\ndeletel, okm_saveMessage: on the same tx, then call original
 *     so UI treats it as an update, not a wipe
 *  3) Hook PushCleanup _handleDeletedMessages as backup (skip wipe for kept)
 *  4) Credentials setCurrentUserId: only for myUserId
 */

static NSString * const kPrefKey = @"mvibe_anti_delete_enabled";
static NSString * const kDeletedPksKey = @"mvibe_anti_delete_pks";
static NSString * const kMyUserIdKey = @"mvibe_anti_delete_my_uid";
static NSString * const kPrefix = @"\u274C ";
static NSString * const kDbMarker = @"\ndeletel";

/** Observed in earlier builds / asserts: OKMMessageStatusRemoved == 10 */
static const NSInteger kStatusRemovedDefault = 10;

static NSNumber *gMyUserId = nil;
static NSMutableSet *gDeletedPks = nil;
static NSInteger gPreferredLiveStatus = 0;
static NSInteger gRemovedStatus = kStatusRemovedDefault;

static id gWriteConnection = nil;
static id gYapDatabase = nil;
static id gChatService = nil;

static IMP gOrigSetUserId = NULL;
static IMP gOrigMessagesUpdated = NULL;
static IMP gOrigHandleDeleted = NULL;
static SEL gSelMessagesUpdated;
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
    @try {
        id outg = [msg valueForKey:@"outgoing"];
        if ([outg respondsToSelector:@selector(boolValue)]) return ![outg boolValue];
    } @catch (__unused NSException *ex) {}
    @try {
        id inc = [msg valueForKey:@"isIncoming"];
        if ([inc respondsToSelector:@selector(boolValue)]) return [inc boolValue];
    } @catch (__unused NSException *ex) {}
    // Without myUserId, do NOT keep — safer than blocking own deletes.
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
        SEL setSel = NSSelectorFromString(@"setStatus:");
        if ([msg respondsToSelector:setSel]) {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(msg, setSel, status);
            return;
        }
        [msg setValue:@(status) forKey:@"status"];
    } @catch (__unused NSException *ex) {}
}

static void MVClearLocalRemove(id msg) {
    @try {
        SEL setSel = NSSelectorFromString(@"setLocalRemoveStatus:");
        if ([msg respondsToSelector:setSel]) {
            ((void (*)(id, SEL, unsigned long long))objc_msgSend)(msg, setSel, 0);
            return;
        }
        if ([msg respondsToSelector:NSSelectorFromString(@"localRemoveStatus")]) {
            [msg setValue:@0 forKey:@"localRemoveStatus"];
        }
    } @catch (__unused NSException *ex) {}
}

static BOOL MVIsRemovedStatus(NSInteger st) {
    if (st == -999) return NO;
    if (st == gRemovedStatus) return YES;
    if (st == kStatusRemovedDefault) return YES;
    return NO;
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

static void MVNoteLiveIfNeeded(id msg) {
    if (!MVIsOKMMessage(msg)) return;
    NSString *text = MVPlainTextOfMessage(msg) ?: @"";
    if ([text containsString:kDbMarker] || [text hasPrefix:kPrefix]) return;
    NSInteger st = MVStatusOfMessage(msg);
    if (st == -999 || MVIsRemovedStatus(st)) return;
    gPreferredLiveStatus = st;
}

/** Rewrite incoming delete into visible tagged message. force=YES on push-delete path. */
static BOOL MVConvertIncomingDelete(id msg, BOOL force) {
    if (!MVIsOKMMessage(msg) || !MVMessageIsIncoming(msg)) return NO;
    NSInteger st = MVStatusOfMessage(msg);
    NSString *pk = MVPkOfMessage(msg);
    BOOL already = pk.length && [gDeletedPks containsObject:pk];
    BOOL removed = MVIsRemovedStatus(st);
    if (!force && !removed && !already) return NO;
    if (removed) gRemovedStatus = st;

    NSInteger live = gPreferredLiveStatus;
    if (MVIsRemovedStatus(live)) live = 0;

    MVLog(@"convert pk=%@ status %ld→%ld force=%d sender=%@ my=%@",
          pk, (long)st, (long)live, force, MVSenderIdOfMessage(msg), gMyUserId);
    MVSetStatus(msg, live);
    MVClearLocalRemove(msg);
    MVTagMessageText(msg);
    return YES;
}

static void MVSaveInTransaction(id tx, id msg) {
    if (!tx || !msg) return;
    @try {
        SEL save = NSSelectorFromString(@"okm_saveMessage:");
        if ([tx respondsToSelector:save]) {
            ((void (*)(id, SEL, id))objc_msgSend)(tx, save, msg);
            MVLog(@"save tx pk=%@ status=%ld", MVPkOfMessage(msg), (long)MVStatusOfMessage(msg));
        }
    } @catch (NSException *ex) {
        MVLog(@"save tx fail %@", ex.name);
    }
}

#pragma mark - Yap helpers (push path only)

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
    void (^write)(id) = ^(id tx) { MVSaveInTransaction(tx, msg); };
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

/** Tell UI to refresh without going through our hook (use saved IMP). */
static void MVNotifyUI(NSArray *msgs) {
    if (!gChatService || !gOrigMessagesUpdated || !msgs.count) return;
    @try {
        ((void (*)(id, SEL, id, id))gOrigMessagesUpdated)(gChatService, gSelMessagesUpdated, msgs, nil);
        MVLog(@"ui notify n=%lu", (unsigned long)msgs.count);
    } @catch (NSException *ex) {
        MVLog(@"ui notify fail %@", ex.name);
    }
}

#pragma mark - Hooks

static void mvibe_setCurrentUserId(id self, SEL _cmd, NSNumber *uid) {
    MVRememberMyUserId(uid);
    if (gOrigSetUserId) ((void (*)(id, SEL, id))gOrigSetUserId)(self, _cmd, uid);
}

static BOOL MVHookBlock(Class cls, SEL sel, id block, IMP *outOrig) {
    if (!cls || !sel || !block || !outOrig) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    *outOrig = method_getImplementation(m);
    if (!*outOrig) return NO;
    IMP neu = imp_implementationWithBlock(block);
    method_setImplementation(m, neu);
    return YES;
}

void MaxVibeInstallAntiDelete(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        MVEnsureStore();
        gSelMessagesUpdated = NSSelectorFromString(@"_messagesUpdated:inTransaction:");
        gSelHandleDeleted = NSSelectorFromString(@"_handleDeletedMessages:inChatWithId:");
        MVLog(@"install begin v9 (messagesUpdated rewrite, no ChatService delete hooks) enabled=%d removed=%ld",
              MaxVibeAntiDeleteEnabled(), (long)gRemovedStatus);

        Class creds = NSClassFromString(@"OKMMessengerCredentials");
        Method mCred = class_getInstanceMethod(creds, NSSelectorFromString(@"setCurrentUserId:"));
        if (mCred) {
            gOrigSetUserId = method_getImplementation(mCred);
            method_setImplementation(mCred, (IMP)mvibe_setCurrentUserId);
            MVLog(@"setCurrentUserId: OK");
        } else {
            MVLog(@"setCurrentUserId: FAIL");
        }

        // Main UI path: turn Removed → tagged update before ChatService applies it.
        Class chat = NSClassFromString(@"OKMChatService");
        BOOL okUpd = MVHookBlock(chat, gSelMessagesUpdated, ^void(id self, id messages, id tx) {
            MVEnsureStore();
            gChatService = self;
            MVRememberConnection(MVKVC(self, @"dbWriteConnection") ?: MVKVC(self, @"writeConnection"));
            if (!MaxVibeAntiDeleteEnabled() || !gOrigMessagesUpdated) {
                if (gOrigMessagesUpdated)
                    ((void (*)(id, SEL, id, id))gOrigMessagesUpdated)(self, gSelMessagesUpdated, messages, tx);
                return;
            }
            if (![messages isKindOfClass:[NSArray class]]) {
                ((void (*)(id, SEL, id, id))gOrigMessagesUpdated)(self, gSelMessagesUpdated, messages, tx);
                return;
            }
            NSUInteger converted = 0;
            for (id msg in (NSArray *)messages) {
                if (!MVIsOKMMessage(msg)) continue;
                MVNoteLiveIfNeeded(msg);
                if (!MVConvertIncomingDelete(msg, NO)) continue;
                MVSaveInTransaction(tx, msg);
                converted++;
            }
            if (converted) {
                MVLog(@"messagesUpdated converted=%lu total=%lu",
                      (unsigned long)converted, (unsigned long)[(NSArray *)messages count]);
            }
            ((void (*)(id, SEL, id, id))gOrigMessagesUpdated)(self, gSelMessagesUpdated, messages, tx);
        }, &gOrigMessagesUpdated);
        MVLog(@"_messagesUpdated: %s", okUpd ? "OK" : "FAIL");

        // Backup: push cleanup still tries to wipe Yap for peer deletes.
        Class push = NSClassFromString(@"OKMPushCleanupHelper");
        BOOL okPush = MVHookBlock(push, gSelHandleDeleted, ^void(id self, id messages, id chatId) {
            MVEnsureStore();
            MVFindConnectionFromSeed(self);
            if (!MaxVibeAntiDeleteEnabled() || !gOrigHandleDeleted) {
                if (gOrigHandleDeleted)
                    ((void (*)(id, SEL, id, id))gOrigHandleDeleted)(self, gSelHandleDeleted, messages, chatId);
                return;
            }
            NSArray *list = nil;
            if ([messages isKindOfClass:[NSArray class]]) list = messages;
            else if ([messages respondsToSelector:@selector(allObjects)]) list = [messages allObjects];
            if (!list) {
                ((void (*)(id, SEL, id, id))gOrigHandleDeleted)(self, gSelHandleDeleted, messages, chatId);
                return;
            }
            NSMutableArray *allow = [NSMutableArray array];
            NSMutableArray *keptMsgs = [NSMutableArray array];
            NSUInteger kept = 0;
            for (id item in list) {
                if (!MVIsOKMMessage(item)) {
                    [allow addObject:item];
                    continue;
                }
                MVLog(@"push pk=%@ sender=%@ inc=%d status=%ld",
                      MVPkOfMessage(item), MVSenderIdOfMessage(item),
                      MVMessageIsIncoming(item), (long)MVStatusOfMessage(item));
                if (MVMessageIsIncoming(item) && MVConvertIncomingDelete(item, YES)) {
                    MVSaveMessageStandalone(self, item);
                    [keptMsgs addObject:item];
                    kept++;
                } else {
                    [allow addObject:item];
                }
            }
            MVLog(@"handleDeletedMessages chat=%@ keep=%lu allow=%lu",
                  chatId, (unsigned long)kept, (unsigned long)allow.count);
            if (keptMsgs.count) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    MVNotifyUI(keptMsgs);
                });
            }
            if (allow.count == 0) return;
            if (allow.count == list.count) {
                ((void (*)(id, SEL, id, id))gOrigHandleDeleted)(self, gSelHandleDeleted, messages, chatId);
            } else {
                ((void (*)(id, SEL, id, id))gOrigHandleDeleted)(self, gSelHandleDeleted, allow, chatId);
            }
        }, &gOrigHandleDeleted);
        MVLog(@"_handleDeletedMessages: %s", okPush ? "OK" : "FAIL");

        MVLog(@"install done my=%@", gMyUserId);
    });
}
