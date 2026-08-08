#import "MaxVibeAntiDelete.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdarg.h>

/*
 * Anti-delete v11 — keep visible + ❌
 *
 * v10 proved peer wipe is kept in Yap (re-open chat → message returns),
 * but: (1) bubble vanishes until re-enter, (2) ❌/\ndeletel did not stick
 * because mutating nested OKMMessageText.text often does not serialize.
 *
 * v11:
 *  - Replace message.text with new OKMMessageText via initWithText:elements:
 *  - Snapshot plain text on okm_saveMessage (C trampoline) for empty delete payloads
 *  - After keep: okm_saveMessage + CALL ChatService _messagesUpdated:inTransaction:
 *    (no method swizzle — that aborted launch in v9)
 *  - Prefer status=Edited (default 9) so UI refresh path runs; fallback live/0
 *  - Push-only wipe intercept (same as v10)
 */

static NSString * const kPrefKey = @"mvibe_anti_delete_enabled";
static NSString * const kDeletedPksKey = @"mvibe_anti_delete_pks";
static NSString * const kTextCacheKey = @"mvibe_anti_delete_text";
static NSString * const kMyUserIdKey = @"mvibe_anti_delete_my_uid";
static NSString * const kPrefix = @"\u274C ";
static NSString * const kDbMarker = @"\ndeletel";
static const NSInteger kStatusRemovedDefault = 10;
static const NSInteger kStatusEditedDefault = 9;

static NSNumber *gMyUserId = nil;
static NSMutableSet *gDeletedPks = nil;
static NSMutableDictionary *gTextCache = nil; // pk -> NSString
static NSInteger gPreferredLiveStatus = 0;
static NSInteger gRemovedStatus = kStatusRemovedDefault;
static NSInteger gEditedStatus = kStatusEditedDefault;

static id gWriteConnection = nil;
static id gYapDatabase = nil;
static id gChatService = nil;

static IMP gOrigSetUserId = NULL;
static IMP gOrigHandleDeleted = NULL;
static IMP gOrigSaveMessage = NULL;
static SEL gSelHandleDeleted;
static SEL gSelSaveMessage;
static SEL gSelMessagesUpdated;

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
        gTextCache = [NSMutableDictionary dictionary];
        NSUserDefaults *p = [NSUserDefaults standardUserDefaults];
        NSArray *saved = [p arrayForKey:kDeletedPksKey];
        if ([saved isKindOfClass:[NSArray class]]) [gDeletedPks addObjectsFromArray:saved];
        NSDictionary *texts = [p dictionaryForKey:kTextCacheKey];
        if ([texts isKindOfClass:[NSDictionary class]]) [gTextCache addEntriesFromDictionary:texts];
        id uid = [p objectForKey:kMyUserIdKey];
        if ([uid isKindOfClass:[NSNumber class]]) gMyUserId = uid;
    });
}

static void MVPersistDeletedPks(void) {
    [[NSUserDefaults standardUserDefaults] setObject:gDeletedPks.allObjects forKey:kDeletedPksKey];
}

static void MVPersistTextCache(void) {
    // Cap cache size
    if (gTextCache.count > 400) {
        NSArray *keys = gTextCache.allKeys;
        for (NSUInteger i = 0; i < 100 && i < keys.count; i++) {
            [gTextCache removeObjectForKey:keys[i]];
        }
    }
    [[NSUserDefaults standardUserDefaults] setObject:gTextCache forKey:kTextCacheKey];
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
        if ([msg respondsToSelector:NSSelectorFromString(@"setLocalRemoveStatus:")] ||
            class_getProperty(object_getClass(msg), "localRemoveStatus")) {
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
        id mt = [msg valueForKey:@"messageText"];
        if ([mt isKindOfClass:[NSString class]]) return mt;
        if (mt) {
            id t = [mt valueForKey:@"text"];
            if ([t isKindOfClass:[NSString class]]) return t;
        }
    } @catch (__unused NSException *ex) {}
    return nil;
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

/** Build a fresh OKMMessageText — in-place mutation of .text often does not persist. */
static id MVMakeMessageText(NSString *text) {
    Class cls = NSClassFromString(@"OKMMessageText");
    if (!cls || !text) return nil;
    @try {
        SEL initSel = NSSelectorFromString(@"initWithText:elements:");
        id obj = [cls alloc];
        if ([obj respondsToSelector:initSel]) {
            obj = ((id (*)(id, SEL, id, id))objc_msgSend)(obj, initSel, text, nil);
            if (obj) return obj;
        }
        obj = [cls alloc];
        SEL setup = NSSelectorFromString(@"_setupTextAndLinks:");
        if ([obj respondsToSelector:setup]) {
            obj = [obj init];
            ((void (*)(id, SEL, id))objc_msgSend)(obj, setup, text);
            return obj;
        }
    } @catch (__unused NSException *ex) {}
    return nil;
}

static BOOL MVSetPlainText(id msg, NSString *text) {
    if (!msg || !text) return NO;
    @try {
        id neu = MVMakeMessageText(text);
        if (neu) {
            [msg setValue:neu forKey:@"text"];
            @try {
                if (class_getProperty(object_getClass(msg), "messageText")) {
                    [msg setValue:neu forKey:@"messageText"];
                }
            } @catch (__unused NSException *ex) {}
            NSString *check = MVPlainTextOfMessage(msg);
            MVLog(@"setText ok=%d len=%lu", (int)[check isEqualToString:text], (unsigned long)text.length);
            return [check isEqualToString:text] || [check containsString:kPrefix];
        }
        // Fallback: mutate existing
        id textObj = [msg valueForKey:@"text"];
        if ([textObj isKindOfClass:[NSString class]]) {
            [msg setValue:text forKey:@"text"];
            return YES;
        }
        if (textObj) {
            [textObj setValue:text forKey:@"text"];
            SEL setup = NSSelectorFromString(@"_setupTextAndLinks:");
            if ([textObj respondsToSelector:setup]) {
                ((void (*)(id, SEL, id))objc_msgSend)(textObj, setup, text);
            }
            return YES;
        }
    } @catch (NSException *ex) {
        MVLog(@"setText fail %@", ex.name);
    }
    return NO;
}

static void MVCacheLiveMessage(id msg) {
    if (!MVIsOKMMessage(msg)) return;
    NSString *pk = MVPkOfMessage(msg);
    if (!pk.length) return;
    NSInteger st = MVStatusOfMessage(msg);
    if (MVIsRemovedStatus(st)) return;
    NSString *text = MVPlainTextOfMessage(msg);
    if ([text containsString:kDbMarker] || [text hasPrefix:kPrefix]) return;
    if (st != -999) {
        gPreferredLiveStatus = st;
        if (st != kStatusEditedDefault && st != gEditedStatus) {
            // keep edited default; learn live for fallback
        }
    }
    if (text.length) {
        gTextCache[pk] = text;
        MVPersistTextCache();
    }
}

static void MVTagMessageText(id msg) {
    NSString *pk = MVPkOfMessage(msg);
    NSString *base = MVStripMarkers(MVPlainTextOfMessage(msg) ?: @"");
    if (!base.length && pk.length) {
        NSString *cached = gTextCache[pk];
        if ([cached isKindOfClass:[NSString class]]) base = MVStripMarkers(cached);
    }
    NSString *tagged = [[kPrefix stringByAppendingString:base] stringByAppendingString:kDbMarker];
    MVSetPlainText(msg, tagged);
    if (pk.length) {
        [gDeletedPks addObject:pk];
        MVPersistDeletedPks();
        gTextCache[pk] = tagged;
        MVPersistTextCache();
    }
}

static void MVConvertIncomingDelete(id msg) {
    NSInteger st = MVStatusOfMessage(msg);
    if (MVIsRemovedStatus(st)) gRemovedStatus = st;
    // Edited triggers ChatService UI refresh path (see assert in _messagesUpdated).
    NSInteger target = gEditedStatus;
    if (target == gRemovedStatus || MVIsRemovedStatus(target)) {
        target = (gPreferredLiveStatus != gRemovedStatus) ? gPreferredLiveStatus : 0;
    }
    MVLog(@"convert pk=%@ status %ld→%ld sender=%@ my=%@ textLen=%lu",
          MVPkOfMessage(msg), (long)st, (long)target, MVSenderIdOfMessage(msg), gMyUserId,
          (unsigned long)(MVPlainTextOfMessage(msg) ?: @"").length);
    MVSetStatus(msg, target);
    MVClearLocalRemove(msg);
    MVTagMessageText(msg);
}

#pragma mark - Yap / ChatService

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

static void MVRememberChatService(id obj) {
    if (!obj) return;
    Class chatCls = NSClassFromString(@"OKMChatService");
    if (chatCls && [obj isKindOfClass:chatCls]) {
        gChatService = obj;
        return;
    }
    if ([obj respondsToSelector:gSelMessagesUpdated]) {
        gChatService = obj;
    }
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
    while (queue.count && steps < 50) {
        id obj = queue[0];
        [queue removeObjectAtIndex:0];
        if (!obj) continue;
        NSValue *ptr = [NSValue valueWithPointer:(__bridge const void *)obj];
        if ([seen containsObject:ptr]) continue;
        [seen addObject:ptr];
        steps++;
        MVRememberChatService(obj);
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

/** CALL (not swizzle) _messagesUpdated — safe; swizzling it aborted launch. */
static void MVCallMessagesUpdated(id tx, NSArray *msgs) {
    if (!msgs.count) return;
    id chat = gChatService;
    if (!chat) {
        Class cls = NSClassFromString(@"OKMChatService");
        // last resort: nothing
        if (!cls) return;
    }
    if (!chat || !gSelMessagesUpdated) return;
    if (![chat respondsToSelector:gSelMessagesUpdated]) return;
    @try {
        ((void (*)(id, SEL, id, id))objc_msgSend)(chat, gSelMessagesUpdated, msgs, tx);
        MVLog(@"ui _messagesUpdated n=%lu status=%ld text=%@",
              (unsigned long)msgs.count,
              (long)MVStatusOfMessage(msgs.firstObject),
              MVPlainTextOfMessage(msgs.firstObject));
    } @catch (NSException *ex) {
        MVLog(@"ui notify fail %@", ex.name);
    }
}

static void MVSaveAndNotify(id seed, NSArray *msgs) {
    if (!msgs.count) return;
    MVFindConnectionFromSeed(seed);
    id conn = MVLooksLikeWriteConnection(gWriteConnection) ? gWriteConnection : MVFindConnectionFromSeed(seed);
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
            for (id msg in msgs) {
                ((void (*)(id, SEL, id))objc_msgSend)(tx, save, msg);
                MVLog(@"save ok pk=%@ status=%ld text=%@",
                      MVPkOfMessage(msg), (long)MVStatusOfMessage(msg), MVPlainTextOfMessage(msg));
            }
            MVCallMessagesUpdated(tx, msgs);
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
            ((void (*)(id, SEL, id, id))objc_msgSend)(conn, asyncRW, write, ^{
                dispatch_async(dispatch_get_main_queue(), ^{
                    // Second pass on main after Yap settles
                    id c2 = gWriteConnection;
                    if (!c2) return;
                    void (^w2)(id) = ^(id tx) { MVCallMessagesUpdated(tx, msgs); };
                    SEL sync = NSSelectorFromString(@"readWriteWithBlock:");
                    if ([c2 respondsToSelector:sync]) {
                        ((void (*)(id, SEL, id))objc_msgSend)(c2, sync, w2);
                    }
                });
            });
        }
        // Extra main-queue nudge after sync write
        dispatch_async(dispatch_get_main_queue(), ^{
            id c2 = gWriteConnection;
            if (!c2 || !msgs.count) return;
            void (^w2)(id) = ^(id tx) {
                for (id msg in msgs) {
                    SEL save = NSSelectorFromString(@"okm_saveMessage:");
                    if ([tx respondsToSelector:save]) {
                        ((void (*)(id, SEL, id))objc_msgSend)(tx, save, msg);
                    }
                }
                MVCallMessagesUpdated(tx, msgs);
            };
            SEL sync = NSSelectorFromString(@"readWriteWithBlock:");
            @try {
                if ([c2 respondsToSelector:sync]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(c2, sync, w2);
                }
            } @catch (NSException *ex) {
                MVLog(@"main nudge fail %@", ex.name);
            }
        });
    } @catch (NSException *ex) {
        MVLog(@"save outer %@", ex.name);
    }
}

#pragma mark - C trampolines

static void mvibe_setCurrentUserId(id self, SEL _cmd, NSNumber *uid) {
    MVRememberMyUserId(uid);
    if (gOrigSetUserId) ((void (*)(id, SEL, id))gOrigSetUserId)(self, _cmd, uid);
}

static void mvibe_saveMessage(id self, SEL _cmd, id msg) {
    if (gOrigSaveMessage) ((void (*)(id, SEL, id))gOrigSaveMessage)(self, _cmd, msg);
    if (MaxVibeAntiDeleteEnabled()) MVCacheLiveMessage(msg);
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
    NSMutableArray *keptMsgs = [NSMutableArray array];
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
            [keptMsgs addObject:item];
        } else {
            [allow addObject:item];
        }
    }
    MVLog(@"handleDeletedMessages chat=%@ keep=%lu allow=%lu",
          chatId, (unsigned long)keptMsgs.count, (unsigned long)allow.count);

    if (keptMsgs.count) {
        MVSaveAndNotify(self, keptMsgs);
    }

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
        gSelSaveMessage = NSSelectorFromString(@"okm_saveMessage:");
        gSelMessagesUpdated = NSSelectorFromString(@"_messagesUpdated:inTransaction:");
        MVLog(@"install begin v11 (❌ text + call _messagesUpdated, no swizzle) enabled=%d",
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

        // Snapshot texts (C trampoline only — do not use block IMPs on hot Yap paths).
        Class yapRW = NSClassFromString(@"YapDatabaseReadWriteTransaction");
        Method mSave = class_getInstanceMethod(yapRW, gSelSaveMessage);
        if (mSave) {
            gOrigSaveMessage = method_getImplementation(mSave);
            method_setImplementation(mSave, (IMP)mvibe_saveMessage);
            MVLog(@"okm_saveMessage cache: OK");
        } else {
            MVLog(@"okm_saveMessage cache: FAIL");
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

        MVLog(@"install done my=%@", gMyUserId);
    });
}
