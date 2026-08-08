#import "MaxVibeAntiDelete.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdarg.h>

/*
 * Anti-delete v7
 *
 * Peer delete order: ChatService deleteMessages* wipes Yap FIRST, then
 * PushCleanup _handleDeletedMessages. v6 only hooked the second step and often
 * saw keep=0 (bad isIncoming) or saved too late for UI.
 *
 * v7:
 *  - Hook ChatService deletes via imp_implementationWithBlock (BOOL-safe).
 *  - Before wipe: read OKMMessage on a FRESH Yap connection, if incoming →
 *    tag + okm_saveMessage (UPDATE) and drop PK from delete list.
 *  - Also hook PushCleanup / MessageDeleteListener as backup.
 *  - File log: Documents/mvibe_antidelete.log
 */

static NSString * const kPrefKey = @"mvibe_anti_delete_enabled";
static NSString * const kDeletedPksKey = @"mvibe_anti_delete_pks";
static NSString * const kMyUserIdKey = @"mvibe_anti_delete_my_uid";
static NSString * const kPrefix = @"\u274C ";
static NSString * const kDbMarker = @"\ndeletel";

static NSNumber *gMyUserId = nil;
static NSMutableSet *gDeletedPks = nil;
static id gWriteConnection = nil;
static id gYapDatabase = nil;

static IMP gOrigSetUserId = NULL;
static IMP gOrigDeletePks = NULL;
static IMP gOrigDeletePksEnq = NULL;
static IMP gOrigHandleDeleted = NULL;
static IMP gOrigMessagesDeleted = NULL;
static SEL gSelDeletePks;
static SEL gSelDeletePksEnq;
static SEL gSelHandleDeleted;
static SEL gSelMessagesDeleted;

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

static id MVOpenYapdbFallback(void) {
    Class YapDatabase = NSClassFromString(@"YapDatabase");
    if (!YapDatabase) return nil;
    NSString *lib = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
    if (!lib.length) return nil;
    NSString *found = nil;
    NSDirectoryEnumerator *en = [[NSFileManager defaultManager] enumeratorAtPath:lib];
    NSString *rel = nil;
    while ((rel = [en nextObject])) {
        if ([rel.lastPathComponent isEqualToString:@"yapdb.sqlite"]) {
            found = [lib stringByAppendingPathComponent:rel];
            break;
        }
    }
    if (!found.length) return nil;
    @try {
        NSURL *url = [NSURL fileURLWithPath:found];
        id db = ((id (*)(id, SEL, id, id))objc_msgSend)([YapDatabase alloc],
                        NSSelectorFromString(@"initWithURL:options:"), url, nil);
        if (!db) return nil;
        gYapDatabase = db;
        SEL newConn = NSSelectorFromString(@"newConnection");
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id c = [db performSelector:newConn];
#pragma clang diagnostic pop
        MVRememberConnection(c);
        MVLog(@"opened yapdb fallback");
        return c;
    } @catch (NSException *ex) {
        MVLog(@"yap fallback fail %@", ex.name);
        return nil;
    }
}

static id MVFindConnectionFromSeed(id seed) {
    if (MVLooksLikeWriteConnection(gWriteConnection)) return gWriteConnection;
    if (!seed) return MVOpenYapdbFallback();

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
    return MVOpenYapdbFallback();
}

/** Fresh connection — safe to read during ChatService delete (no nested tx). */
static id MVFreshConnection(id seed) {
    id db = gYapDatabase;
    if (!db) {
        id existing = MVFindConnectionFromSeed(seed);
        db = gYapDatabase ?: MVKVC(existing, @"database");
    }
    if (!db) {
        MVOpenYapdbFallback();
        db = gYapDatabase;
    }
    if (!db) return gWriteConnection;
    SEL newConn = NSSelectorFromString(@"newConnection");
    if (![db respondsToSelector:newConn]) return gWriteConnection;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id c = [db performSelector:newConn];
#pragma clang diagnostic pop
    return c ?: gWriteConnection;
}

static id MVLookupMessageByPk(id seed, id pk) {
    NSString *key = MVNormalizePk(pk);
    if (!key.length) return nil;
    id conn = MVFreshConnection(seed);
    if (!conn) return nil;
    SEL readSel = NSSelectorFromString(@"readWithBlock:");
    if (![conn respondsToSelector:readSel]) return nil;
    __block id found = nil;
    void (^block)(id) = ^(id tx) {
        @try {
            SEL byPk = NSSelectorFromString(@"okm_messageForPk:");
            if ([tx respondsToSelector:byPk]) {
                found = ((id (*)(id, SEL, id))objc_msgSend)(tx, byPk, key);
            }
        } @catch (__unused NSException *ex) {}
    };
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(conn, readSel, block);
    } @catch (__unused NSException *ex) {}
    return found;
}

static void MVSaveMessageNow(id seed, id msg) {
    if (!msg) return;
    id conn = MVFreshConnection(seed);
    if (!conn) {
        MVLog(@"UPDATE skip: no conn");
        return;
    }
    void (^write)(id) = ^(id tx) {
        @try {
            SEL save = NSSelectorFromString(@"okm_saveMessage:");
            if ([tx respondsToSelector:save]) {
                ((void (*)(id, SEL, id))objc_msgSend)(tx, save, msg);
                MVLog(@"UPDATE ok pk=%@", MVPkOfMessage(msg));
            } else {
                MVLog(@"UPDATE skip: no okm_saveMessage");
            }
        } @catch (NSException *ex) {
            MVLog(@"UPDATE fail %@", ex.name);
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
        MVLog(@"UPDATE outer %@", ex.name);
    }
}

static void MVConvertDeleteToUpdate(id seed, id msg) {
    MVLog(@"convert pk=%@ sender=%@ my=%@ inc=%d",
          MVPkOfMessage(msg), MVSenderIdOfMessage(msg), gMyUserId, MVMessageIsIncoming(msg));
    if (!MVMessageIsIncoming(msg)) return;
    MVTagMessageText(msg);
    MVSaveMessageNow(seed, msg);
}

#pragma mark - Hooks

static void mvibe_setCurrentUserId(id self, SEL _cmd, NSNumber *uid) {
    MVRememberMyUserId(uid);
    if (gOrigSetUserId) ((void (*)(id, SEL, id))gOrigSetUserId)(self, _cmd, uid);
}

static NSArray *MVFilterDeletePks(id self, NSArray *pks) {
    NSMutableArray *allow = [NSMutableArray array];
    NSUInteger keep = 0;
    for (id pk in pks) {
        NSString *key = MVNormalizePk(pk);
        if (key.length && [gDeletedPks containsObject:key]) {
            keep++;
            continue;
        }
        id msg = MVLookupMessageByPk(self, pk);
        MVLog(@"pk=%@ msg=%@ sender=%@ inc=%d",
              key, msg ? @"yes" : @"no", MVSenderIdOfMessage(msg), MVMessageIsIncoming(msg));
        if (msg && MVMessageIsIncoming(msg)) {
            keep++;
            MVConvertDeleteToUpdate(self, msg);
            continue;
        }
        [allow addObject:pk];
    }
    MVLog(@"filterDelete keep=%lu allow=%lu", (unsigned long)keep, (unsigned long)allow.count);
    return allow;
}

#pragma mark - Install

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
        MVLog(@"install begin v7 (ChatService block hooks + UPDATE) enabled=%d",
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

        Class chat = NSClassFromString(@"OKMChatService");
        gSelDeletePks = NSSelectorFromString(@"deleteMessagesWithPks:deleteForAll:");
        BOOL ok1 = MVHookBlock(chat, gSelDeletePks, ^void(id self, NSArray *pks, BOOL deleteForAll) {
            MVEnsureStore();
            MVFindConnectionFromSeed(self);
            if (!MaxVibeAntiDeleteEnabled() || ![pks isKindOfClass:[NSArray class]] || !gOrigDeletePks) {
                if (gOrigDeletePks)
                    ((void (*)(id, SEL, id, BOOL))gOrigDeletePks)(self, gSelDeletePks, pks, deleteForAll);
                return;
            }
            NSArray *allow = MVFilterDeletePks(self, pks);
            if (allow.count == 0) return;
            ((void (*)(id, SEL, id, BOOL))gOrigDeletePks)(self, gSelDeletePks, allow, deleteForAll);
        }, &gOrigDeletePks);
        MVLog(@"deleteMessagesWithPks: %s", ok1 ? "OK" : "FAIL");

        gSelDeletePksEnq = NSSelectorFromString(@"_deleteMessagesWithPks:deleteForAll:enqueueTasks:");
        BOOL ok2 = MVHookBlock(chat, gSelDeletePksEnq,
            ^void(id self, NSArray *pks, BOOL deleteForAll, BOOL enqueueTasks) {
            MVEnsureStore();
            MVFindConnectionFromSeed(self);
            if (!MaxVibeAntiDeleteEnabled() || ![pks isKindOfClass:[NSArray class]] || !gOrigDeletePksEnq) {
                if (gOrigDeletePksEnq)
                    ((void (*)(id, SEL, id, BOOL, BOOL))gOrigDeletePksEnq)(
                        self, gSelDeletePksEnq, pks, deleteForAll, enqueueTasks);
                return;
            }
            NSArray *allow = MVFilterDeletePks(self, pks);
            if (allow.count == 0) return;
            ((void (*)(id, SEL, id, BOOL, BOOL))gOrigDeletePksEnq)(
                self, gSelDeletePksEnq, allow, deleteForAll, enqueueTasks);
        }, &gOrigDeletePksEnq);
        MVLog(@"_deleteMessagesWithPks: %s", ok2 ? "OK" : "FAIL");

        Class push = NSClassFromString(@"OKMPushCleanupHelper");
        gSelHandleDeleted = NSSelectorFromString(@"_handleDeletedMessages:inChatWithId:");
        BOOL ok3 = MVHookBlock(push, gSelHandleDeleted, ^void(id self, id messages, id chatId) {
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
            NSUInteger kept = 0;
            for (id item in list) {
                MVLog(@"push item class=%@ okm=%d pk=%@ sender=%@ inc=%d",
                      NSStringFromClass([item class]), MVIsOKMMessage(item),
                      MVPkOfMessage(item), MVSenderIdOfMessage(item), MVMessageIsIncoming(item));
                if (MVMessageIsIncoming(item)) {
                    kept++;
                    MVConvertDeleteToUpdate(self, item);
                } else {
                    [allow addObject:item];
                }
            }
            MVLog(@"handleDeletedMessages chat=%@ keep=%lu allow=%lu",
                  chatId, (unsigned long)kept, (unsigned long)allow.count);
            if (allow.count == 0) return;
            if (allow.count == list.count) {
                ((void (*)(id, SEL, id, id))gOrigHandleDeleted)(self, gSelHandleDeleted, messages, chatId);
            } else {
                ((void (*)(id, SEL, id, id))gOrigHandleDeleted)(self, gSelHandleDeleted, allow, chatId);
            }
        }, &gOrigHandleDeleted);
        MVLog(@"_handleDeletedMessages: %s", ok3 ? "OK" : "FAIL");

        Class del = NSClassFromString(@"OKMMessageDeleteListener");
        gSelMessagesDeleted = NSSelectorFromString(@"_messagesDeleted:inChat:");
        BOOL ok4 = MVHookBlock(del, gSelMessagesDeleted, ^void(id self, id messages, id chat) {
            MVEnsureStore();
            MVFindConnectionFromSeed(self);
            if (!MaxVibeAntiDeleteEnabled() || !gOrigMessagesDeleted) {
                if (gOrigMessagesDeleted)
                    ((void (*)(id, SEL, id, id))gOrigMessagesDeleted)(self, gSelMessagesDeleted, messages, chat);
                return;
            }
            if (![messages isKindOfClass:[NSArray class]]) {
                ((void (*)(id, SEL, id, id))gOrigMessagesDeleted)(self, gSelMessagesDeleted, messages, chat);
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
            if (allow.count == 0) return;
            if (allow.count == [(NSArray *)messages count]) {
                ((void (*)(id, SEL, id, id))gOrigMessagesDeleted)(self, gSelMessagesDeleted, messages, chat);
            } else {
                ((void (*)(id, SEL, id, id))gOrigMessagesDeleted)(self, gSelMessagesDeleted, allow, chat);
            }
        }, &gOrigMessagesDeleted);
        MVLog(@"_messagesDeleted: %s", ok4 ? "OK" : "FAIL");

        MVLog(@"install done my=%@", gMyUserId);
    });
}
