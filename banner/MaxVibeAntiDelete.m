#import "MaxVibeAntiDelete.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdarg.h>

/*
 * Anti-delete v14.3 — in-place _messagesUpdated (delayed install)
 *
 * UI wipe happens in ChatService _messagesUpdated with status=Removed.
 * Swizzle that replaced the messages collection → launch SIGABRT.
 * Calling it after keep did nothing visible.
 *
 * v14.3: install _messagesUpdated AFTER launch settle; mutate messages
 * IN PLACE (same collection object); keep rules = v14 (incoming || known).
 * Still block late Removed on okm_saveMessage for already-known keys only.
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
static NSMutableDictionary *gTextCache = nil;
static NSInteger gPreferredLiveStatus = 0;
static NSInteger gRemovedStatus = kStatusRemovedDefault;
static NSInteger gEditedStatus = kStatusEditedDefault;

static id gWriteConnection = nil;
static id gYapDatabase = nil;
static __weak id gChatService = nil;
static int gOurSaveDepth = 0;
static int gMessagesUpdatedDepth = 0;

static IMP gOrigSetUserId = NULL;
static IMP gOrigHandleDeleted = NULL;
static IMP gOrigMessagesDeleted = NULL;
static IMP gOrigMessagesUpdated = NULL;
static IMP gOrigSaveMessage = NULL;
static IMP gOrigProcessHistoryChunk = NULL;
static IMP gOrigMsgMessageText = NULL;
static IMP gOrigMsgText = NULL;
static IMP gOrigMsgTextContent = NULL;
static SEL gSelHandleDeleted;
static SEL gSelMessagesDeleted;
static SEL gSelSaveMessage;
static SEL gSelMessagesUpdated;
static SEL gSelProcessHistoryChunk;

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
    // Never drop texts for known deleted messages — that caused "❌" with no body after hours.
    if (gTextCache.count > 800) {
        NSArray *keys = gTextCache.allKeys;
        NSUInteger removed = 0;
        for (NSString *k in keys) {
            if (removed >= 200) break;
            if ([gDeletedPks containsObject:k]) continue;
            [gTextCache removeObjectForKey:k];
            removed++;
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

static NSString *MVStripMarkers(NSString *text);

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

static NSString *MVStringifyId(id v) {
    if ([v isKindOfClass:[NSString class]]) return (NSString *)v;
    if ([v respondsToSelector:@selector(stringValue)]) return [v stringValue];
    return nil;
}

static NSArray<NSString *> *MVStableKeysForMessage(id msg) {
    NSMutableOrderedSet<NSString *> *keys = [NSMutableOrderedSet orderedSet];
    NSString *pk = MVPkOfMessage(msg);
    if (pk.length) [keys addObject:pk];
    @try {
        NSString *chat = MVStringifyId([msg valueForKey:@"chatId"]);
        if (!chat.length) chat = MVStringifyId([msg valueForKey:@"chatPrimaryKey"]);
        NSString *server = MVStringifyId([msg valueForKey:@"serverId"]);
        NSString *mid = MVStringifyId([msg valueForKey:@"messageId"]);
        if (chat.length && server.length) [keys addObject:[NSString stringWithFormat:@"chat:%@:server:%@", chat, server]];
        if (chat.length && mid.length) [keys addObject:[NSString stringWithFormat:@"chat:%@:msg:%@", chat, mid]];
        if (server.length) [keys addObject:[NSString stringWithFormat:@"server:%@", server]];
    } @catch (__unused NSException *ex) {}
    return keys.array;
}

static BOOL MVDeletedKnownForMessage(id msg) {
    for (NSString *k in MVStableKeysForMessage(msg)) {
        if ([gDeletedPks containsObject:k]) return YES;
    }
    return NO;
}

/** Prefer longest non-empty original body (markers stripped). */
static NSString *MVCachedOriginalForMessage(id msg) {
    NSString *best = @"";
    for (NSString *k in MVStableKeysForMessage(msg)) {
        NSString *v = gTextCache[k];
        if (![v isKindOfClass:[NSString class]]) continue;
        NSString *plain = MVStripMarkers(v);
        if (plain.length > best.length) best = plain;
    }
    return best.length ? best : nil;
}

/** Store only original body. Never overwrite a good original with empty / marker-only. */
static void MVStoreOriginalText(id msg, NSString *text) {
    NSString *plain = MVStripMarkers(text ?: @"");
    if (!plain.length) return;
    for (NSString *k in MVStableKeysForMessage(msg)) {
        if (!k.length) continue;
        NSString *prev = MVStripMarkers(gTextCache[k] ?: @"");
        if (prev.length && prev.length >= plain.length) continue;
        gTextCache[k] = plain;
    }
    MVPersistTextCache();
}

static void MVRememberDeletedAndText(id msg, NSString *originalOrTagged) {
    NSString *plain = MVStripMarkers(originalOrTagged ?: @"");
    // Keep previous original if new one is empty (re-delete hours later with blank body).
    if (!plain.length) plain = MVCachedOriginalForMessage(msg) ?: @"";
    for (NSString *k in MVStableKeysForMessage(msg)) {
        if (k.length) [gDeletedPks addObject:k];
        if (k.length && plain.length) {
            NSString *prev = MVStripMarkers(gTextCache[k] ?: @"");
            if (!prev.length || plain.length >= prev.length) gTextCache[k] = plain;
        }
    }
    MVPersistDeletedPks();
    MVPersistTextCache();
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
    @try { [msg setValue:@(status) forKey:@"status"]; } @catch (__unused NSException *ex) {}
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

static id MVMakeMessageText(NSString *text) {
    Class cls = NSClassFromString(@"OKMMessageText");
    if (!cls || !text) return nil;
    @try {
        SEL initSel = NSSelectorFromString(@"initWithText:elements:");
        id obj = [cls alloc];
        if ([obj respondsToSelector:initSel]) {
            return ((id (*)(id, SEL, id, id))objc_msgSend)(obj, initSel, text, nil);
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
                if ([msg respondsToSelector:NSSelectorFromString(@"setMessageText:")]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(msg, NSSelectorFromString(@"setMessageText:"), text);
                } else if (class_getProperty(object_getClass(msg), "messageText")) {
                    [msg setValue:text forKey:@"messageText"];
                }
            } @catch (__unused NSException *ex) {}
            @try { [msg setValue:text forKey:@"_messageText"]; } @catch (__unused NSException *ex) {}
            @try { [msg setValue:neu forKey:@"textContent"]; } @catch (__unused NSException *ex) {}
            @try { [msg setValue:neu forKey:@"_textContent"]; } @catch (__unused NSException *ex) {}
            @try { [msg setValue:neu forKey:@"messageText"]; } @catch (__unused NSException *ex) {}
            NSString *check = MVPlainTextOfMessage(msg) ?: @"";
            BOOL ok = [check isEqualToString:text] || [check hasPrefix:kPrefix];
            MVLog(@"setText ok=%d gotLen=%lu wantLen=%lu", (int)ok,
                  (unsigned long)check.length, (unsigned long)text.length);
            return ok;
        }
        id textObj = [msg valueForKey:@"text"];
        if ([textObj isKindOfClass:[NSString class]]) {
            [msg setValue:text forKey:@"text"];
            return YES;
        }
        if (textObj) {
            [textObj setValue:text forKey:@"text"];
            SEL setup = NSSelectorFromString(@"_setupTextAndLinks:");
            if ([textObj respondsToSelector:setup])
                ((void (*)(id, SEL, id))objc_msgSend)(textObj, setup, text);
            return YES;
        }
    } @catch (NSException *ex) {
        MVLog(@"setText fail %@", ex.name);
    }
    return NO;
}

static void MVCacheLiveMessage(id msg) {
    if (!MVIsOKMMessage(msg)) return;
    NSInteger st = MVStatusOfMessage(msg);
    if (MVIsRemovedStatus(st)) return;
    NSString *text = MVPlainTextOfMessage(msg);
    if ([text containsString:kDbMarker] || [text hasPrefix:kPrefix]) return;
    if (st != -999 && !MVIsRemovedStatus(st) && st != gEditedStatus)
        gPreferredLiveStatus = st;
    MVStoreOriginalText(msg, text);
}

static void MVTagMessageText(id msg) {
    NSString *base = MVStripMarkers(MVPlainTextOfMessage(msg) ?: @"");
    if (!base.length) base = MVCachedOriginalForMessage(msg) ?: @"";
    // Never persist a marker-only body over a known original.
    if (!base.length) {
        MVLog(@"tag skip empty body pk=%@", MVPkOfMessage(msg));
        // Still mark deleted keys; do not wipe original cache.
        MVRememberDeletedAndText(msg, @"");
        // If Remember recovered nothing, leave message as-is.
        base = MVCachedOriginalForMessage(msg) ?: @"";
        if (!base.length) return;
    }
    NSString *tagged = [[kPrefix stringByAppendingString:base] stringByAppendingString:kDbMarker];
    MVSetPlainText(msg, tagged);
    MVRememberDeletedAndText(msg, base);
}

static NSString *MVVisibleTaggedString(NSString *text) {
    NSString *base = MVStripMarkers(text ?: @"");
    return [base hasPrefix:kPrefix] ? base : [kPrefix stringByAppendingString:base];
}

static BOOL MVShouldRenderTagged(id msg) {
    if (MVDeletedKnownForMessage(msg)) return YES;
    NSString *text = MVPlainTextOfMessage(msg) ?: @"";
    return [text containsString:kDbMarker] || [text hasPrefix:kPrefix];
}

static id MVRenderTaggedValue(id msg, id originalValue) {
    if (!MVShouldRenderTagged(msg)) return originalValue;
    NSString *cached = MVCachedOriginalForMessage(msg);
    if ([originalValue isKindOfClass:[NSString class]]) {
        NSString *best = MVStripMarkers((NSString *)originalValue);
        if (!best.length && cached.length) best = cached;
        if (!best.length) best = @"";
        return MVVisibleTaggedString(best);
    }
    NSString *plain = MVStripMarkers(MVPlainTextOfMessage(msg) ?: @"");
    if (!plain.length && [originalValue respondsToSelector:@selector(valueForKey:)]) {
        @try {
            id t = [originalValue valueForKey:@"text"];
            if ([t isKindOfClass:[NSString class]]) plain = MVStripMarkers(t);
        } @catch (__unused NSException *ex) {}
    }
    if (!plain.length && cached.length) plain = cached;
    plain = MVVisibleTaggedString(plain ?: @"");
    id neu = MVMakeMessageText(plain);
    return neu ?: originalValue;
}

static void MVCacheTextFromRenderedValue(id msg, id value) {
    if (!MVIsOKMMessage(msg)) return;
    NSArray<NSString *> *keys = MVStableKeysForMessage(msg);
    if (!keys.count) return;
    NSString *text = nil;
    if ([value isKindOfClass:[NSString class]]) {
        text = (NSString *)value;
    } else if (value) {
        @try {
            id t = [value valueForKey:@"text"];
            if ([t isKindOfClass:[NSString class]]) text = t;
        } @catch (__unused NSException *ex) {}
    }
    text = MVStripMarkers(text ?: @"");
    if (!text.length) return;
    // Even for known-deleted: recover/refresh original if we see real body again.
    MVStoreOriginalText(msg, text);
}

static void MVConvertIncomingDelete(id msg) {
    NSInteger st = MVStatusOfMessage(msg);
    if (MVIsRemovedStatus(st)) gRemovedStatus = st;
    NSInteger target = gEditedStatus;
    if (MVIsRemovedStatus(target)) target = 0;
    MVLog(@"convert pk=%@ status %ld→%ld sender=%@ textLen=%lu cache=%d",
          MVPkOfMessage(msg), (long)st, (long)target, MVSenderIdOfMessage(msg),
          (unsigned long)(MVPlainTextOfMessage(msg) ?: @"").length,
          MVCachedOriginalForMessage(msg) ? 1 : 0);
    MVSetStatus(msg, target);
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

static void MVRememberChatService(id obj) {
    if (!obj) return;
    Class cls = NSClassFromString(@"OKMChatService");
    if (cls && [obj isKindOfClass:cls]) {
        gChatService = obj;
        return;
    }
    if ([obj respondsToSelector:NSSelectorFromString(@"_messagesUpdated:inTransaction:")])
        gChatService = obj;
}

static id MVFindChatServiceFromUI(void) {
    if (gChatService) return gChatService;
    NSMutableArray *stack = [NSMutableArray array];
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (w.rootViewController) [stack addObject:w.rootViewController];
    }
    NSUInteger steps = 0;
    while (stack.count && steps < 80) {
        UIViewController *vc = stack[0];
        [stack removeObjectAtIndex:0];
        steps++;
        id cs = MVKVC(vc, @"chatService") ?: MVKVC(vc, @"_chatService");
        MVRememberChatService(cs);
        if (gChatService) return gChatService;
        id deps = MVKVC(vc, @"dependencies");
        if (deps) MVRememberChatService(MVKVC(deps, @"chatService"));
        if (gChatService) return gChatService;
        if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
        if ([vc isKindOfClass:[UINavigationController class]]) {
            for (UIViewController *c in [(UINavigationController *)vc viewControllers]) [stack addObject:c];
        } else if ([vc isKindOfClass:[UITabBarController class]]) {
            for (UIViewController *c in [(UITabBarController *)vc viewControllers]) [stack addObject:c];
        } else {
            for (UIViewController *c in vc.childViewControllers) [stack addObject:c];
        }
    }
    return gChatService;
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

/** Prefer full Yap row (includeRemoved) over push stub. */
static id MVMessageFromTx(id tx, id hint) {
    if (!tx || !hint) return hint;
    NSString *pk = MVPkOfMessage(hint);
    if (!pk.length) return hint;
    @try {
        SEL byPk = NSSelectorFromString(@"okm_messageForPk:");
        if ([tx respondsToSelector:byPk]) {
            id full = ((id (*)(id, SEL, id))objc_msgSend)(tx, byPk, pk);
            if (MVIsOKMMessage(full)) {
                NSString *t = MVPlainTextOfMessage(full) ?: @"";
                NSString *ht = MVPlainTextOfMessage(hint) ?: @"";
                if (t.length >= ht.length) return full;
            }
        }
        // includeRemoved variant if we can get chat id
        id chatId = nil;
        @try { chatId = [hint valueForKey:@"chatId"]; } @catch (__unused NSException *ex) {}
        if (!chatId) @try { chatId = [hint valueForKey:@"chatPrimaryKey"]; } @catch (__unused NSException *ex) {}
        id serverId = nil;
        @try { serverId = [hint valueForKey:@"serverId"]; } @catch (__unused NSException *ex) {}
        SEL byId = NSSelectorFromString(@"okm_messageForId:inChat:includeRemoved:");
        if (chatId && serverId && [tx respondsToSelector:byId]) {
            id full = ((id (*)(id, SEL, id, id, BOOL))objc_msgSend)(tx, byId, serverId, chatId, YES);
            if (MVIsOKMMessage(full)) return full;
        }
    } @catch (__unused NSException *ex) {}
    return hint;
}

static id MVLookupFullMessage(id seed, id hint) {
    NSString *pk = MVPkOfMessage(hint);
    if (!pk.length) return hint;
    // Use cached text onto hint if lookup fails later
    id conn = MVFindConnectionFromSeed(seed);
    if (!conn) return hint;
    SEL readSel = NSSelectorFromString(@"readWithBlock:");
    if (![conn respondsToSelector:readSel]) return hint;
    __block id found = nil;
    void (^block)(id) = ^(id tx) {
        found = MVMessageFromTx(tx, hint);
    };
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(conn, readSel, block);
    } @catch (__unused NSException *ex) {}
    return found ?: hint;
}

static void MVPostYapModified(id conn) {
    if (!conn && !gYapDatabase) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            id obj = gYapDatabase ?: conn;
            [[NSNotificationCenter defaultCenter] postNotificationName:@"YapDatabaseModifiedNotification"
                                                                object:obj];
        } @catch (__unused NSException *ex) {}
    });
}

static void MVSaveMessagesOnConn(id seed, NSArray *msgs) {
    if (!msgs.count) return;
    MVRememberChatService(seed);
    id conn = MVFindConnectionFromSeed(seed);
    if (!conn) {
        MVLog(@"save skip: no conn");
        return;
    }
    void (^write)(id) = ^(id tx) {
        @try {
            SEL save = NSSelectorFromString(@"okm_saveMessage:");
            if (![tx respondsToSelector:save]) {
                MVLog(@"save skip: no selector on %@", NSStringFromClass([tx class]));
                return;
            }
            for (id msg in msgs) {
                ((void (*)(id, SEL, id))objc_msgSend)(tx, save, msg);
                MVLog(@"save ok pk=%@ status=%ld text=%@",
                      MVPkOfMessage(msg), (long)MVStatusOfMessage(msg), MVPlainTextOfMessage(msg));
            }
        } @catch (NSException *ex) {
            MVLog(@"save fail %@", ex.name);
        }
    };
    @try {
        SEL syncRW = NSSelectorFromString(@"readWriteWithBlock:");
        if ([conn respondsToSelector:syncRW]) {
            gOurSaveDepth++;
            ((void (*)(id, SEL, id))objc_msgSend)(conn, syncRW, write);
            gOurSaveDepth--;
            MVPostYapModified(conn);
        }
    } @catch (NSException *ex) {
        gOurSaveDepth = MAX(0, gOurSaveDepth - 1);
        MVLog(@"save outer %@", ex.name);
    }
}

/** Shared keep logic for push + delete listener paths. */
static NSUInteger MVProcessIncomingDeletes(id seed, NSArray *list, NSMutableArray *allowOut, NSMutableArray *keptOut) {
    NSUInteger kept = 0;
    for (id item in list) {
        if (!MVIsOKMMessage(item)) {
            if (allowOut) [allowOut addObject:item];
            continue;
        }
        MVLog(@"del pk=%@ sender=%@ inc=%d status=%ld textLen=%lu",
              MVPkOfMessage(item), MVSenderIdOfMessage(item),
              MVMessageIsIncoming(item), (long)MVStatusOfMessage(item),
              (unsigned long)(MVPlainTextOfMessage(item) ?: @"").length);
        // If myUserId isn't available yet, MVMessageIsIncoming() may be false.
        // In that case, still keep if we already know this message was deleted
        // (stable-key hit). This prevents rare "disappears after hours".
        BOOL keepThis = MVMessageIsIncoming(item) || MVDeletedKnownForMessage(item);
        if (keepThis) {
            id full = MVLookupFullMessage(seed, item);
            MVConvertIncomingDelete(full);
            if (keptOut) [keptOut addObject:full];
            kept++;
        } else if (allowOut) {
            [allowOut addObject:item];
        }
    }
    return kept;
}

#pragma mark - C trampolines

static void mvibe_setCurrentUserId(id self, SEL _cmd, NSNumber *uid) {
    MVRememberMyUserId(uid);
    if (gOrigSetUserId) ((void (*)(id, SEL, id))gOrigSetUserId)(self, _cmd, uid);
}

static void mvibe_saveMessage(id self, SEL _cmd, id msg) {
    // Already-known deleted row being re-saved as Removed (re-enter flicker source).
    if (MaxVibeAntiDeleteEnabled() && MVIsOKMMessage(msg) &&
        MVDeletedKnownForMessage(msg) && MVIsRemovedStatus(MVStatusOfMessage(msg))) {
        MVConvertIncomingDelete(msg);
        MVLog(@"save blocked late Removed pk=%@", MVPkOfMessage(msg));
    }
    if (gOrigSaveMessage) ((void (*)(id, SEL, id))gOrigSaveMessage)(self, _cmd, msg);
    if (MaxVibeAntiDeleteEnabled()) MVCacheLiveMessage(msg);
}

static void mvibe_processHistoryChunk(id self, SEL _cmd, id chunk, BOOL notify) {
    if (MaxVibeAntiDeleteEnabled() && [chunk isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)chunk) {
            if (!MVIsOKMMessage(item)) continue;
            if (!MVDeletedKnownForMessage(item)) continue;
            if (MVIsRemovedStatus(MVStatusOfMessage(item)))
                MVConvertIncomingDelete(item);
        }
    }
    if (gOrigProcessHistoryChunk)
        ((void (*)(id, SEL, id, BOOL))gOrigProcessHistoryChunk)(self, _cmd, chunk, notify);
}

/** In-place rewrite — never replace `messages` collection (that crashed v16). */
static void mvibe_messagesUpdated(id self, SEL _cmd, id messages, id tx) {
    MVRememberChatService(self);
    if (!gOrigMessagesUpdated) return;

    if (MaxVibeAntiDeleteEnabled() && messages && gMessagesUpdatedDepth == 0) {
        @try {
            NSUInteger n = 0;
            // Fast enumeration works for NSArray and NSSet without copying.
            for (id item in messages) {
                if (!MVIsOKMMessage(item)) continue;
                BOOL known = MVDeletedKnownForMessage(item);
                BOOL incoming = MVMessageIsIncoming(item);
                if (!(incoming || known)) continue;
                NSInteger st = MVStatusOfMessage(item);
                if (!(MVIsRemovedStatus(st) || known)) continue;
                MVConvertIncomingDelete(item);
                n++;
            }
            if (n) MVLog(@"messagesUpdated in-place keep=%lu", (unsigned long)n);
        } @catch (NSException *ex) {
            MVLog(@"messagesUpdated catch %@", ex.name);
        }
    }

    gMessagesUpdatedDepth++;
    ((void (*)(id, SEL, id, id))gOrigMessagesUpdated)(self, _cmd, messages, tx);
    gMessagesUpdatedDepth--;
}

static id mvibe_messageText(id self, SEL _cmd) {
    id orig = gOrigMsgMessageText ? ((id (*)(id, SEL))gOrigMsgMessageText)(self, _cmd) : nil;
    if (MaxVibeAntiDeleteEnabled()) MVCacheTextFromRenderedValue(self, orig);
    return MVRenderTaggedValue(self, orig);
}

static id mvibe_text(id self, SEL _cmd) {
    id orig = gOrigMsgText ? ((id (*)(id, SEL))gOrigMsgText)(self, _cmd) : nil;
    if (MaxVibeAntiDeleteEnabled()) MVCacheTextFromRenderedValue(self, orig);
    return MVRenderTaggedValue(self, orig);
}

static id mvibe_textContent(id self, SEL _cmd) {
    id orig = gOrigMsgTextContent ? ((id (*)(id, SEL))gOrigMsgTextContent)(self, _cmd) : nil;
    if (MaxVibeAntiDeleteEnabled()) MVCacheTextFromRenderedValue(self, orig);
    return MVRenderTaggedValue(self, orig);
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
    NSMutableArray *kept = [NSMutableArray array];
    NSUInteger keptN = MVProcessIncomingDeletes(self, list, allow, kept);
    MVLog(@"handleDeletedMessages chat=%@ keep=%lu allow=%lu",
          chatId, (unsigned long)keptN, (unsigned long)allow.count);
    if (kept.count) MVSaveMessagesOnConn(self, kept);

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
        if (gOrigMessagesDeleted)
            ((void (*)(id, SEL, id, id))gOrigMessagesDeleted)(self, _cmd, messages, chat);
        return;
    }
    MVFindConnectionFromSeed(self);

    NSArray *list = nil;
    if ([messages isKindOfClass:[NSArray class]]) list = messages;
    else if ([messages respondsToSelector:@selector(allObjects)]) list = [messages allObjects];
    if (!list) {
        ((void (*)(id, SEL, id, id))gOrigMessagesDeleted)(self, _cmd, messages, chat);
        return;
    }

    NSMutableArray *allow = [NSMutableArray array];
    NSMutableArray *kept = [NSMutableArray array];
    NSUInteger keptN = MVProcessIncomingDeletes(self, list, allow, kept);
    MVLog(@"messagesDeleted chat=%@ keep=%lu allow=%lu",
          chat, (unsigned long)keptN, (unsigned long)allow.count);
    if (kept.count) MVSaveMessagesOnConn(self, kept);

    if (allow.count == 0) return;
    if (allow.count == list.count) {
        ((void (*)(id, SEL, id, id))gOrigMessagesDeleted)(self, _cmd, messages, chat);
    } else {
        ((void (*)(id, SEL, id, id))gOrigMessagesDeleted)(self, _cmd, allow, chat);
    }
}

static void MVInstallMessagesUpdatedHook(void) {
    if (gOrigMessagesUpdated) return;
    Class chatSvc = NSClassFromString(@"OKMChatService");
    SEL sel = gSelMessagesUpdated ?: NSSelectorFromString(@"_messagesUpdated:inTransaction:");
    Method m = class_getInstanceMethod(chatSvc, sel);
    if (!m) {
        MVLog(@"_messagesUpdated delayed: FAIL no method");
        return;
    }
    gOrigMessagesUpdated = method_getImplementation(m);
    method_setImplementation(m, (IMP)mvibe_messagesUpdated);
    MVLog(@"_messagesUpdated delayed in-place: OK");
}

void MaxVibeInstallAntiDelete(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        MVEnsureStore();
        gSelHandleDeleted = NSSelectorFromString(@"_handleDeletedMessages:inChatWithId:");
        gSelMessagesDeleted = NSSelectorFromString(@"_messagesDeleted:inChat:");
        gSelSaveMessage = NSSelectorFromString(@"okm_saveMessage:");
        gSelMessagesUpdated = NSSelectorFromString(@"_messagesUpdated:inTransaction:");
        gSelProcessHistoryChunk = NSSelectorFromString(@"processHistoryChunk:notify:");
        MVLog(@"install begin v14.3 (delayed in-place _messagesUpdated) enabled=%d",
              MaxVibeAntiDeleteEnabled());

        Class creds = NSClassFromString(@"OKMMessengerCredentials");
        Method mCred = class_getInstanceMethod(creds, NSSelectorFromString(@"setCurrentUserId:"));
        if (mCred) {
            gOrigSetUserId = method_getImplementation(mCred);
            method_setImplementation(mCred, (IMP)mvibe_setCurrentUserId);
            MVLog(@"setCurrentUserId: OK");
        }

        Class yapRW = NSClassFromString(@"YapDatabaseReadWriteTransaction");
        Method mSave = class_getInstanceMethod(yapRW, gSelSaveMessage);
        if (mSave) {
            gOrigSaveMessage = method_getImplementation(mSave);
            method_setImplementation(mSave, (IMP)mvibe_saveMessage);
            MVLog(@"okm_saveMessage cache: OK");
        } else {
            MVLog(@"okm_saveMessage cache: FAIL");
        }

        Class del = NSClassFromString(@"OKMMessageDeleteListener");
        Method mDel = class_getInstanceMethod(del, gSelMessagesDeleted);
        if (mDel) {
            gOrigMessagesDeleted = method_getImplementation(mDel);
            method_setImplementation(mDel, (IMP)mvibe_messagesDeleted);
            MVLog(@"_messagesDeleted: OK");
        } else {
            MVLog(@"_messagesDeleted: FAIL");
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

        Class loader = NSClassFromString(@"OKMChatHistoryLoader");
        Method mChunk = class_getInstanceMethod(loader, gSelProcessHistoryChunk);
        if (mChunk) {
            gOrigProcessHistoryChunk = method_getImplementation(mChunk);
            method_setImplementation(mChunk, (IMP)mvibe_processHistoryChunk);
            MVLog(@"processHistoryChunk: OK");
        } else {
            MVLog(@"processHistoryChunk: FAIL");
        }

        Class msg = NSClassFromString(@"OKMMessage");
        Method mMsgText = class_getInstanceMethod(msg, NSSelectorFromString(@"messageText"));
        if (mMsgText) {
            gOrigMsgMessageText = method_getImplementation(mMsgText);
            method_setImplementation(mMsgText, (IMP)mvibe_messageText);
            MVLog(@"OKMMessage messageText: OK");
        }
        Method mText = class_getInstanceMethod(msg, NSSelectorFromString(@"text"));
        if (mText) {
            gOrigMsgText = method_getImplementation(mText);
            method_setImplementation(mText, (IMP)mvibe_text);
            MVLog(@"OKMMessage text: OK");
        }
        Method mTextContent = class_getInstanceMethod(msg, NSSelectorFromString(@"textContent"));
        if (mTextContent) {
            gOrigMsgTextContent = method_getImplementation(mTextContent);
            method_setImplementation(mTextContent, (IMP)mvibe_textContent);
            MVLog(@"OKMMessage textContent: OK");
        }

        // Delay UI wipe hook past launch/login sync — early install crashed before.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            MVInstallMessagesUpdatedHook();
        });

        MVLog(@"install done my=%@ (messagesUpdated pending)", gMyUserId);
    });
}
