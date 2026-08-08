#import "MaxVibeAntiDelete.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdarg.h>

/*
 * Anti-delete for MAX iOS (parity with Android MvibeAntiDelete*):
 *
 * Peer "delete for everyone" does NOT go through OKMChatService deleteMessagesWithPks
 * on our device — it arrives via delete listeners / _messagesUpdated / Yap writes.
 *
 * Strategy:
 * 1) Cache OKMMessage on Yap reads + writes (so we know text/sender before delete)
 * 2) Raise gDeleteDepth around remote-delete handlers (discovered at runtime)
 * 3) On Yap setObject / okm_saveMessage / setStatus: for incoming → keep, tag \ndeletel
 * 4) On Yap removeObject(s): block incoming keys, re-save tagged instead
 * 5) UILabel: \ndeletel → red italic "deleted"
 */

static NSString * const kPrefKey = @"mvibe_anti_delete_enabled";
static NSString * const kDeletedPksKey = @"mvibe_anti_delete_pks";
static NSString * const kMyUserIdKey = @"mvibe_anti_delete_my_uid";
static NSString * const kDbMarker = @"\ndeletel";
static NSString * const kUiMarker = @"deleted";

static NSInteger gDeleteDepth = 0;
static NSInteger gRemovedStatus = -1;
static NSNumber *gMyUserId = nil;
static NSMutableDictionary *gMsgCache = nil; // pk -> @{status,senderId,text,chatPk,serverId}
static NSMutableSet *gDeletedPks = nil;
static NSMutableSet *gLiveStatuses = nil;
static NSMutableSet *gMessageCollections = nil;

#pragma mark - Prefs

BOOL MaxVibeAntiDeleteEnabled(void) {
    NSUserDefaults *p = [NSUserDefaults standardUserDefaults];
    if ([p objectForKey:kPrefKey] == nil) return NO;
    return [p boolForKey:kPrefKey];
}

void MaxVibeSetAntiDeleteEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kPrefKey];
}

#pragma mark - Logging

static void MVLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void MVLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[MaxVibeAntiDelete] %@", line);
    @try {
        NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        if (!doc) return;
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

#pragma mark - Store

static void MVEnsureStore(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gMsgCache = [NSMutableDictionary dictionary];
        gDeletedPks = [NSMutableSet set];
        gLiveStatuses = [NSMutableSet set];
        gMessageCollections = [NSMutableSet setWithObjects:@"messages", @"Messages", @"okm_messages", nil];
        NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:kDeletedPksKey];
        if ([saved isKindOfClass:[NSArray class]]) [gDeletedPks addObjectsFromArray:saved];
        id uid = [[NSUserDefaults standardUserDefaults] objectForKey:kMyUserIdKey];
        if ([uid isKindOfClass:[NSNumber class]]) gMyUserId = uid;
    });
}

static void MVPersistDeletedPks(void) {
    [[NSUserDefaults standardUserDefaults] setObject:gDeletedPks.allObjects forKey:kDeletedPksKey];
}

static void MVRememberMyUserId(NSNumber *uid) {
    if (![uid isKindOfClass:[NSNumber class]] || uid.longLongValue == 0) return;
    if (gMyUserId && [gMyUserId isEqualToNumber:uid]) return;
    gMyUserId = uid;
    [[NSUserDefaults standardUserDefaults] setObject:uid forKey:kMyUserIdKey];
    MVLog(@"myUserId=%@", uid);
}

static BOOL MVIsOKMMessage(id obj) {
    if (!obj) return NO;
    Class cls = NSClassFromString(@"OKMMessage");
    return cls && [obj isKindOfClass:cls];
}

static NSString *MVPkOfMessage(id msg) {
    if (!msg) return nil;
    @try {
        id pk = [msg valueForKey:@"primaryKey"];
        if ([pk isKindOfClass:[NSString class]] && [pk length]) return pk;
        pk = [msg valueForKey:@"pk"];
        if ([pk isKindOfClass:[NSString class]] && [pk length]) return pk;
    } @catch (__unused NSException *ex) {}
    return nil;
}

static NSNumber *MVSenderIdOfMessage(id msg) {
    if (!msg) return nil;
    @try {
        id sid = [msg valueForKey:@"senderId"];
        if ([sid isKindOfClass:[NSNumber class]]) return sid;
        id contact = [msg valueForKey:@"senderContact"];
        if (contact) {
            id cid = [contact valueForKey:@"id"];
            if (![cid isKindOfClass:[NSNumber class]]) cid = [contact valueForKey:@"userId"];
            if (![cid isKindOfClass:[NSNumber class]]) cid = [contact valueForKey:@"contactId"];
            if ([cid isKindOfClass:[NSNumber class]]) return cid;
        }
        id author = [msg valueForKey:@"authorId"];
        if ([author isKindOfClass:[NSNumber class]]) return author;
    } @catch (__unused NSException *ex) {}
    return nil;
}

static NSInteger MVStatusOfMessage(id msg) {
    @try {
        id st = [msg valueForKey:@"status"];
        if ([st respondsToSelector:@selector(integerValue)]) return [st integerValue];
    } @catch (__unused NSException *ex) {}
    return -999;
}

static NSString *MVPlainTextOfMessage(id msg) {
    if (!msg) return nil;
    @try {
        for (NSString *key in @[@"text", @"textContent", @"messageText"]) {
            id textObj = [msg valueForKey:key];
            if ([textObj isKindOfClass:[NSString class]]) return textObj;
            if (textObj) {
                id t = [textObj valueForKey:@"text"];
                if ([t isKindOfClass:[NSString class]]) return t;
            }
        }
    } @catch (__unused NSException *ex) {}
    return nil;
}

static NSString *MVStripMarkers(NSString *text) {
    if (!text) return text;
    NSString *s = text;
    for (NSString *m in @[kDbMarker, @"\ndeleted", @"\nудалено", @"\ndeletel"]) {
        s = [s stringByReplacingOccurrencesOfString:m withString:@""];
    }
    while ([s hasSuffix:@"\n"]) s = [s substringToIndex:s.length - 1];
    if ([s hasSuffix:@"deletel"]) s = [s substringToIndex:s.length - 7];
    if ([s hasSuffix:@"deleted"]) s = [s substringToIndex:s.length - 7];
    return s;
}

static BOOL MVTextHasDbMarker(NSString *text) {
    return [text isKindOfClass:[NSString class]] &&
           ([text containsString:kDbMarker] || [text containsString:@"\nудалено"]);
}

static void MVSetMessagePlainText(id msg, NSString *newText) {
    if (!msg || !newText) return;
    @try {
        id textObj = [msg valueForKey:@"text"];
        if ([textObj isKindOfClass:[NSString class]]) {
            [msg setValue:newText forKey:@"text"];
            return;
        }
        if (textObj) {
            [textObj setValue:newText forKey:@"text"];
            SEL setup = NSSelectorFromString(@"_setupTextAndLinks:");
            if ([textObj respondsToSelector:setup]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [textObj performSelector:setup withObject:newText];
#pragma clang diagnostic pop
            }
            return;
        }
        Class mtCls = NSClassFromString(@"OKMMessageText");
        if (mtCls) {
            id created = ((id (*)(id, SEL))objc_msgSend)(mtCls, @selector(alloc));
            SEL initSel = NSSelectorFromString(@"initWithText:elements:");
            if ([created respondsToSelector:initSel]) {
                created = ((id (*)(id, SEL, id, id))objc_msgSend)(created, initSel, newText, nil);
                if (created) [msg setValue:created forKey:@"text"];
            }
        }
    } @catch (__unused NSException *ex) {}
}

static BOOL MVIsIncomingMessage(id msg) {
    NSNumber *sender = MVSenderIdOfMessage(msg);
    if (!gMyUserId) return YES;
    if (!sender) return YES;
    return sender.unsignedLongLongValue != gMyUserId.unsignedLongLongValue;
}

static void MVCacheMessage(id msg) {
    if (!MVIsOKMMessage(msg)) return;
    NSString *pk = MVPkOfMessage(msg);
    if (!pk) return;
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    NSInteger st = MVStatusOfMessage(msg);
    NSNumber *sid = MVSenderIdOfMessage(msg);
    NSString *text = MVPlainTextOfMessage(msg);
    id chatPk = nil;
    id serverId = nil;
    @try { chatPk = [msg valueForKey:@"chatPrimaryKey"]; } @catch (__unused NSException *e) {}
    @try { serverId = [msg valueForKey:@"serverId"]; } @catch (__unused NSException *e) {}
    if (st != -999) entry[@"status"] = @(st);
    if (sid) entry[@"senderId"] = sid;
    if (text) entry[@"text"] = text;
    if ([chatPk isKindOfClass:[NSString class]]) entry[@"chatPk"] = chatPk;
    if (serverId) entry[@"serverId"] = serverId;
    // Keep previous non-removed status / text if current looks empty+removed
    NSDictionary *old = gMsgCache[pk];
    if (old[@"text"] && (!text.length || MVTextHasDbMarker(text))) {
        if (!text.length) entry[@"text"] = old[@"text"];
    }
    if (old[@"status"] && gRemovedStatus >= 0 && st == gRemovedStatus) {
        entry[@"prevStatus"] = old[@"status"];
    } else if (old[@"prevStatus"]) {
        entry[@"prevStatus"] = old[@"prevStatus"];
    } else if (st != -999 && (gRemovedStatus < 0 || st != gRemovedStatus)) {
        entry[@"prevStatus"] = @(st);
    }
    gMsgCache[pk] = entry;
}

static void MVMarkDeletedPk(NSString *pk) {
    if (!pk.length) return;
    [gDeletedPks addObject:pk];
    MVPersistDeletedPks();
}

static BOOL MVIsDeletedPk(NSString *pk) {
    return pk.length && [gDeletedPks containsObject:pk];
}

static void MVTagMessageAsDeleted(id msg) {
    NSString *pk = MVPkOfMessage(msg);
    NSString *text = MVPlainTextOfMessage(msg);
    if (!text.length && pk) {
        text = gMsgCache[pk][@"text"];
    }
    text = MVStripMarkers(text ?: @"");
    MVSetMessagePlainText(msg, [text stringByAppendingString:kDbMarker]);
    if (pk) MVMarkDeletedPk(pk);
}

static void MVRestorePriorStatus(id msg) {
    NSString *pk = MVPkOfMessage(msg);
    NSDictionary *cached = pk ? gMsgCache[pk] : nil;
    NSNumber *prev = cached[@"prevStatus"] ?: cached[@"status"];
    if (prev && gRemovedStatus >= 0 && prev.integerValue == gRemovedStatus) prev = nil;
    NSNumber *value = prev ?: @0;
    @try { [msg setValue:value forKey:@"status"]; } @catch (__unused NSException *ex) {}
}

static void MVTryLearnCredentialsFrom(id obj) {
    if (!obj || gMyUserId) return;
    @try {
        id creds = nil;
        @try { creds = [obj valueForKey:@"messengerCredentials"]; } @catch (__unused NSException *e) {}
        if (!creds) @try { creds = [obj valueForKey:@"_messengerCredentials"]; } @catch (__unused NSException *e) {}
        MVRememberMyUserId([creds valueForKey:@"currentUserId"]);
    } @catch (__unused NSException *ex) {}
}

/** YES if pk refers to an incoming message (prefer keep when unknown). */
static BOOL MVPkLooksIncoming(id pkOrKey) {
    if (!pkOrKey) return YES;
    NSString *key = nil;
    if ([pkOrKey isKindOfClass:[NSString class]]) key = pkOrKey;
    else if ([pkOrKey respondsToSelector:@selector(stringValue)]) key = [pkOrKey stringValue];
    else key = [pkOrKey description];

    NSDictionary *c = gMsgCache[key];
    if (!c) {
        for (NSString *k in gMsgCache) {
            id sid = gMsgCache[k][@"serverId"];
            if (sid && [sid isEqual:pkOrKey]) { c = gMsgCache[k]; key = k; break; }
            if (sid && [[sid description] isEqualToString:key]) { c = gMsgCache[k]; key = k; break; }
        }
    }
    if (!c) return YES; // not cached — keep (safer for peer deletes)
    NSNumber *sender = c[@"senderId"];
    if (!gMyUserId || !sender) return YES;
    return sender.unsignedLongLongValue != gMyUserId.unsignedLongLongValue;
}

static void MVTryPersistMessage(id host, id msg) {
    if (!msg) return;
    // Best-effort: find a Yap write connection on host / deps and save.
    NSArray *keys = @[
        @"dbWriteConnection", @"writeConnection", @"rwConnection",
        @"_dbWriteConnection", @"_writeConnection", @"connection",
        @"databaseConnection", @"yapConnection"
    ];
    id conn = nil;
    for (NSString *k in keys) {
        @try { conn = [host valueForKey:k]; } @catch (__unused NSException *e) { conn = nil; }
        if (conn) break;
    }
    if (!conn) {
        @try {
            id deps = [host valueForKey:@"dependencies"];
            for (NSString *k in keys) {
                @try { conn = [deps valueForKey:k]; } @catch (__unused NSException *e) { conn = nil; }
                if (conn) break;
            }
        } @catch (__unused NSException *e) {}
    }
    if (!conn) {
        MVLog(@"persist skipped (no connection) pk=%@", MVPkOfMessage(msg));
        return;
    }
    SEL rw = NSSelectorFromString(@"readWriteWithBlock:");
    if (![conn respondsToSelector:rw]) {
        MVLog(@"persist skipped (no readWriteWithBlock) pk=%@", MVPkOfMessage(msg));
        return;
    }
    @try {
        void (^block)(id) = ^(id tx) {
            @try {
                SEL save = NSSelectorFromString(@"okm_saveMessage:");
                if ([tx respondsToSelector:save]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(tx, save, msg);
                } else {
                    NSString *pk = MVPkOfMessage(msg);
                    if (pk) {
                        ((void (*)(id, SEL, id, id, id))objc_msgSend)(
                            tx, @selector(setObject:forKey:inCollection:), msg, pk, @"messages");
                    }
                }
            } @catch (__unused NSException *ex) {}
        };
        ((void (*)(id, SEL, id))objc_msgSend)(conn, rw, block);
        MVLog(@"persist ok pk=%@", MVPkOfMessage(msg));
    } @catch (__unused NSException *ex) {
        MVLog(@"persist failed pk=%@", MVPkOfMessage(msg));
    }
}

static id MVLoadMessageByPk(id host, id pk) {
    if (!host || !pk) return nil;
    NSArray *keys = @[@"dbReadConnection", @"readConnection", @"_dbReadConnection",
                      @"dbWriteConnection", @"writeConnection", @"connection"];
    id conn = nil;
    for (NSString *k in keys) {
        @try { conn = [host valueForKey:k]; } @catch (__unused NSException *e) { conn = nil; }
        if (conn) break;
    }
    if (!conn) return nil;
    __block id found = nil;
    SEL readSel = NSSelectorFromString(@"readWithBlock:");
    if (![conn respondsToSelector:readSel]) return nil;
    void (^block)(id) = ^(id tx) {
        @try {
            SEL m1 = NSSelectorFromString(@"okm_messageForPk:");
            if ([tx respondsToSelector:m1]) {
                found = ((id (*)(id, SEL, id))objc_msgSend)(tx, m1, pk);
            }
            if (!found) {
                NSString *key = [pk isKindOfClass:[NSString class]] ? pk : [pk description];
                found = ((id (*)(id, SEL, id, id))objc_msgSend)(tx, @selector(objectForKey:inCollection:), key, @"messages");
            }
        } @catch (__unused NSException *ex) {}
    };
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(conn, readSel, block);
    } @catch (__unused NSException *ex) {}
    return found;
}

static void MVKeepIncomingPk(id host, id pk) {
    NSString *key = [pk isKindOfClass:[NSString class]] ? pk : [pk description];
    MVMarkDeletedPk(key);
    id msg = MVLoadMessageByPk(host, pk);
    if (!msg && [pk isKindOfClass:[NSNumber class]]) {
        msg = MVLoadMessageByPk(host, key);
    }
    if (MVIsOKMMessage(msg)) {
        @try {
            MVTagMessageAsDeleted(msg);
            MVTryPersistMessage(host, msg);
        } @catch (__unused NSException *ex) {}
    } else {
        MVLog(@"keep pk=%@ (no msg object to tag)", key);
    }
}

static BOOL MVLooksLikeMessagesCollection(NSString *collection) {
    if (![collection isKindOfClass:[NSString class]] || !collection.length) return NO;
    if ([gMessageCollections containsObject:collection]) return YES;
    NSString *l = collection.lowercaseString;
    if ([l containsString:@"message"] && ![l containsString:@"attach"] && ![l containsString:@"draft"]) {
        [gMessageCollections addObject:collection];
        return YES;
    }
    return NO;
}

static BOOL MVShouldTreatAsRemoved(id msg, NSDictionary *prev) {
    NSInteger status = MVStatusOfMessage(msg);
    NSString *pk = MVPkOfMessage(msg);

    if (gDeleteDepth > 0) {
        if (status != -999) gRemovedStatus = status;
        return YES;
    }
    if (gRemovedStatus >= 0 && status == gRemovedStatus) return YES;
    if (MVIsDeletedPk(pk)) return YES;

    // Android uses status==10 for deleted; iOS often matches.
    if (status == 10) {
        gRemovedStatus = 10;
        return YES;
    }

    // Learned Removed via prior delete: also accept identical transition
    // from a live status into an unseen one ONLY after we've already
    // locked gRemovedStatus (handled above). No broad guess here — it
    // falsely catches EDITED on first sight.
    (void)prev;
    return NO;
}

/** Rewrite incoming removed message in-place; returns YES if rewritten. */
static BOOL MVRewriteIfNeeded(id msg) {
    if (!MVIsOKMMessage(msg)) return NO;
    MVEnsureStore();

    NSString *pk = MVPkOfMessage(msg);
    NSDictionary *prev = pk ? [gMsgCache[pk] copy] : nil;
    NSInteger status = MVStatusOfMessage(msg);

    BOOL looksRemoved = MVShouldTreatAsRemoved(msg, prev);

    if (status != -999 && !looksRemoved && gDeleteDepth == 0) {
        [gLiveStatuses addObject:@(status)];
    }

    MVCacheMessage(msg);

    if (!MaxVibeAntiDeleteEnabled()) return NO;
    if (!MVIsIncomingMessage(msg)) return NO;

    if (!looksRemoved) {
        // Still ensure marker if we already tracked this pk
        if (MVIsDeletedPk(pk) && !MVTextHasDbMarker(MVPlainTextOfMessage(msg))) {
            MVTagMessageAsDeleted(msg);
            MVRestorePriorStatus(msg);
            MVCacheMessage(msg);
            return YES;
        }
        return NO;
    }

    MVLog(@"keep incoming pk=%@ status=%ld depth=%ld", pk, (long)status, (long)gDeleteDepth);
    MVTagMessageAsDeleted(msg);
    MVRestorePriorStatus(msg);
    MVCacheMessage(msg);
    return YES;
}

#pragma mark - UI marker

static NSAttributedString *MVBuildMarkedAttributed(NSString *raw) {
    NSString *base = MVStripMarkers(raw ?: @"");
    NSMutableAttributedString *out = [[NSMutableAttributedString alloc] initWithString:base attributes:nil];
    [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
    NSDictionary *attrs = @{
        NSForegroundColorAttributeName: [UIColor redColor],
        NSFontAttributeName: [UIFont italicSystemFontOfSize:UIFont.systemFontSize * 0.875],
    };
    [out appendAttributedString:[[NSAttributedString alloc] initWithString:kUiMarker attributes:attrs]];
    return out;
}

static BOOL MVStringNeedsMarker(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || !s.length) return NO;
    return [s containsString:kDbMarker] ||
           [s containsString:@"\ndeleted"] ||
           [s containsString:@"\nудалено"];
}

static NSAttributedString *MVApplyMarkerToAttributed(NSAttributedString *attr) {
    if (![attr isKindOfClass:[NSAttributedString class]]) return attr;
    NSString *s = attr.string;
    if (!MVStringNeedsMarker(s)) return attr;
    if (!MVTextHasDbMarker(s)) {
        NSRange r = [s rangeOfString:@"\ndeleted" options:NSBackwardsSearch];
        if (r.location != NSNotFound && (r.location + 1) < s.length) {
            NSDictionary *a = [attr attributesAtIndex:r.location + 1 effectiveRange:NULL];
            if (a[NSForegroundColorAttributeName]) return attr;
        }
    }
    return MVBuildMarkedAttributed(s);
}

#pragma mark - Hook donors

@interface MaxVibeAntiDeleteHooks : NSObject
- (void)mvibe_okm_saveMessage:(id)message;
- (id)mvibe_okm_messageForPk:(id)pk;
- (id)mvibe_okm_messageForId:(id)mid inChat:(id)chat includeRemoved:(BOOL)inc;
- (id)mvibe_objectForKey:(NSString *)key inCollection:(NSString *)collection;
- (void)mvibe_setObject:(id)object forKey:(NSString *)key inCollection:(NSString *)collection;
- (void)mvibe_setObject:(id)object forKey:(NSString *)key inCollection:(NSString *)collection withMetadata:(id)metadata serializedObject:(id)so serializedMetadata:(id)sm;
- (void)mvibe_removeObjectForKey:(NSString *)key inCollection:(NSString *)collection;
- (void)mvibe_removeObjectsForKeys:(NSArray *)keys inCollection:(NSString *)collection;
- (void)mvibe_setStatus:(NSUInteger)status;
- (void)mvibe_setCurrentUserId:(NSNumber *)uid;
- (void)mvibe_deleteMessagesWithPks:(NSArray *)pks deleteForAll:(BOOL)deleteForAll;
- (void)mvibe__deleteMessagesWithPks:(NSArray *)pks deleteForAll:(BOOL)deleteForAll enqueueTasks:(BOOL)enqueueTasks;
- (void)mvibe_messagesUpdated:(id)messages inTransaction:(id)tx;
- (void)mvibe_handleDeletedMessages:(id)messages inChatWithId:(id)chatId;
- (void)mvibe_messagesDeleted:(id)messages inChat:(id)chat;
- (void)mvibe_setText:(NSString *)text;
- (void)mvibe_setAttributedText:(NSAttributedString *)text;
@end

@implementation MaxVibeAntiDeleteHooks

- (void)mvibe_okm_saveMessage:(id)message {
    @try { MVRewriteIfNeeded(message); } @catch (__unused NSException *ex) {}
    [self mvibe_okm_saveMessage:message];
}

- (id)mvibe_okm_messageForPk:(id)pk {
    id msg = [self mvibe_okm_messageForPk:pk];
    @try { MVCacheMessage(msg); } @catch (__unused NSException *ex) {}
    return msg;
}

- (id)mvibe_okm_messageForId:(id)mid inChat:(id)chat includeRemoved:(BOOL)inc {
    id msg = [self mvibe_okm_messageForId:mid inChat:chat includeRemoved:inc];
    @try { MVCacheMessage(msg); } @catch (__unused NSException *ex) {}
    return msg;
}

- (id)mvibe_objectForKey:(NSString *)key inCollection:(NSString *)collection {
    id obj = [self mvibe_objectForKey:key inCollection:collection];
    if (MVIsOKMMessage(obj)) {
        @try {
            MVCacheMessage(obj);
            if (collection.length) [gMessageCollections addObject:collection];
        } @catch (__unused NSException *ex) {}
    }
    return obj;
}

- (void)mvibe_setObject:(id)object forKey:(NSString *)key inCollection:(NSString *)collection {
    if (MVIsOKMMessage(object)) {
        if (collection.length) [gMessageCollections addObject:collection];
        @try { MVRewriteIfNeeded(object); } @catch (__unused NSException *ex) {}
    }
    [self mvibe_setObject:object forKey:key inCollection:collection];
}

- (void)mvibe_setObject:(id)object forKey:(NSString *)key inCollection:(NSString *)collection withMetadata:(id)metadata serializedObject:(id)so serializedMetadata:(id)sm {
    if (MVIsOKMMessage(object)) {
        if (collection.length) [gMessageCollections addObject:collection];
        @try { MVRewriteIfNeeded(object); } @catch (__unused NSException *ex) {}
    }
    [self mvibe_setObject:object forKey:key inCollection:collection withMetadata:metadata serializedObject:so serializedMetadata:sm];
}

- (void)mvibe_removeObjectForKey:(NSString *)key inCollection:(NSString *)collection {
    MVEnsureStore();
    if (MaxVibeAntiDeleteEnabled() && MVLooksLikeMessagesCollection(collection)) {
        id msg = nil;
        @try {
            msg = ((id (*)(id, SEL, id, id))objc_msgSend)(self, @selector(objectForKey:inCollection:), key, collection);
        } @catch (__unused NSException *e) {}
        if (!msg && [key isKindOfClass:[NSString class]]) {
            NSDictionary *c = gMsgCache[key];
            if (c && gMyUserId && c[@"senderId"] &&
                [c[@"senderId"] unsignedLongLongValue] != gMyUserId.unsignedLongLongValue) {
                MVMarkDeletedPk(key);
                MVLog(@"block remove pk=%@ (cache incoming)", key);
                return;
            }
        }
        if (MVIsOKMMessage(msg) && MVIsIncomingMessage(msg)) {
            MVLog(@"block remove+retag pk=%@", MVPkOfMessage(msg));
            gDeleteDepth++;
            @try {
                MVTagMessageAsDeleted(msg);
                MVRestorePriorStatus(msg);
                SEL save = NSSelectorFromString(@"okm_saveMessage:");
                if ([self respondsToSelector:save]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(self, save, msg);
                } else {
                    ((void (*)(id, SEL, id, id, id))objc_msgSend)(self, @selector(setObject:forKey:inCollection:), msg, key, collection);
                }
            } @catch (__unused NSException *ex) {
            } @finally {
                gDeleteDepth--;
            }
            return;
        }
    }
    [self mvibe_removeObjectForKey:key inCollection:collection];
}

- (void)mvibe_removeObjectsForKeys:(NSArray *)keys inCollection:(NSString *)collection {
    MVEnsureStore();
    if (!MaxVibeAntiDeleteEnabled() || !MVLooksLikeMessagesCollection(collection) ||
        ![keys isKindOfClass:[NSArray class]] || keys.count == 0) {
        [self mvibe_removeObjectsForKeys:keys inCollection:collection];
        return;
    }

    NSMutableArray *allow = [NSMutableArray array];
    for (id key in keys) {
        id msg = nil;
        @try {
            msg = ((id (*)(id, SEL, id, id))objc_msgSend)(self, @selector(objectForKey:inCollection:), key, collection);
        } @catch (__unused NSException *e) {}
        BOOL keep = NO;
        if (MVIsOKMMessage(msg) && MVIsIncomingMessage(msg)) {
            keep = YES;
            gDeleteDepth++;
            @try {
                MVTagMessageAsDeleted(msg);
                MVRestorePriorStatus(msg);
                SEL save = NSSelectorFromString(@"okm_saveMessage:");
                if ([self respondsToSelector:save]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(self, save, msg);
                } else {
                    ((void (*)(id, SEL, id, id, id))objc_msgSend)(self, @selector(setObject:forKey:inCollection:), msg, key, collection);
                }
            } @catch (__unused NSException *ex) {
            } @finally {
                gDeleteDepth--;
            }
        } else if ([key isKindOfClass:[NSString class]]) {
            NSDictionary *c = gMsgCache[key];
            if (c[@"senderId"] && gMyUserId &&
                [c[@"senderId"] unsignedLongLongValue] != gMyUserId.unsignedLongLongValue) {
                keep = YES;
                MVMarkDeletedPk(key);
            }
        }
        if (!keep) [allow addObject:key];
        else MVLog(@"block batch-remove key=%@", key);
    }
    if (allow.count) {
        [self mvibe_removeObjectsForKeys:allow inCollection:collection];
    }
}

- (void)mvibe_setStatus:(NSUInteger)status {
    MVEnsureStore();
    if (gDeleteDepth > 0) gRemovedStatus = (NSInteger)status;

    BOOL rewrite = MaxVibeAntiDeleteEnabled() && MVIsIncomingMessage(self) &&
        (gDeleteDepth > 0 || (gRemovedStatus >= 0 && (NSInteger)status == gRemovedStatus));

    if (rewrite) {
        @try {
            if (gRemovedStatus < 0) gRemovedStatus = (NSInteger)status;
            MVTagMessageAsDeleted(self);
            NSString *pk = MVPkOfMessage(self);
            NSDictionary *cached = pk ? gMsgCache[pk] : nil;
            NSNumber *prev = cached[@"prevStatus"] ?: cached[@"status"];
            NSUInteger keep = prev ? prev.unsignedIntegerValue : 0;
            if (gRemovedStatus >= 0 && (NSInteger)keep == gRemovedStatus) keep = 0;
            [self mvibe_setStatus:keep];
            MVCacheMessage(self);
            MVLog(@"setStatus blocked -> %lu pk=%@", (unsigned long)keep, pk);
            return;
        } @catch (__unused NSException *ex) {}
    }
    [self mvibe_setStatus:status];
    @try {
        NSInteger st = (NSInteger)status;
        if (gDeleteDepth == 0 && (gRemovedStatus < 0 || st != gRemovedStatus)) {
            [gLiveStatuses addObject:@(st)];
        }
        MVCacheMessage(self);
    } @catch (__unused NSException *ex) {}
}

- (void)mvibe_setCurrentUserId:(NSNumber *)uid {
    MVRememberMyUserId(uid);
    [self mvibe_setCurrentUserId:uid];
}

- (void)mvibe_deleteMessagesWithPks:(NSArray *)pks deleteForAll:(BOOL)deleteForAll {
    MVEnsureStore();
    MVTryLearnCredentialsFrom(self);
    if (![pks isKindOfClass:[NSArray class]]) {
        [self mvibe_deleteMessagesWithPks:pks deleteForAll:deleteForAll];
        return;
    }
    NSArray *allow = pks;
    if (MaxVibeAntiDeleteEnabled()) {
        NSMutableArray *out = [NSMutableArray array];
        NSMutableArray *kept = [NSMutableArray array];
        for (id pk in pks) {
            if (MVPkLooksIncoming(pk)) [kept addObject:pk];
            else [out addObject:pk];
        }
        MVLog(@"deleteMessagesWithPks total=%lu keep=%lu allow=%lu forAll=%d my=%@",
              (unsigned long)pks.count, (unsigned long)kept.count, (unsigned long)out.count,
              deleteForAll, gMyUserId);
        for (id pk in kept) {
            MVKeepIncomingPk(self, pk);
        }
        allow = out;
        if (allow.count == 0) return; // nothing to delete via app — kept locally
    } else {
        MVLog(@"deleteMessagesWithPks count=%lu forAll=%d (off)", (unsigned long)pks.count, deleteForAll);
    }
    gDeleteDepth++;
    @try {
        [self mvibe_deleteMessagesWithPks:allow deleteForAll:deleteForAll];
    } @finally {
        gDeleteDepth--;
    }
}

- (void)mvibe__deleteMessagesWithPks:(NSArray *)pks deleteForAll:(BOOL)deleteForAll enqueueTasks:(BOOL)enqueueTasks {
    MVEnsureStore();
    MVTryLearnCredentialsFrom(self);
    if (![pks isKindOfClass:[NSArray class]]) {
        [self mvibe__deleteMessagesWithPks:pks deleteForAll:deleteForAll enqueueTasks:enqueueTasks];
        return;
    }
    NSArray *allow = pks;
    if (MaxVibeAntiDeleteEnabled()) {
        NSMutableArray *out = [NSMutableArray array];
        for (id pk in pks) {
            if (MVPkLooksIncoming(pk)) {
                MVKeepIncomingPk(self, pk);
            } else {
                [out addObject:pk];
            }
        }
        MVLog(@"_deleteMessagesWithPks total=%lu allow=%lu forAll=%d",
              (unsigned long)pks.count, (unsigned long)out.count, deleteForAll);
        allow = out;
        if (allow.count == 0) return;
    }
    gDeleteDepth++;
    @try {
        [self mvibe__deleteMessagesWithPks:allow deleteForAll:deleteForAll enqueueTasks:enqueueTasks];
    } @finally {
        gDeleteDepth--;
    }
}

- (void)mvibe_messagesUpdated:(id)messages inTransaction:(id)tx {
    MVEnsureStore();
    MVTryLearnCredentialsFrom(self);
    // Only rewrite already-removed incoming; do not mutate unrelated updates.
    if (MaxVibeAntiDeleteEnabled() && [messages isKindOfClass:[NSArray class]]) {
        for (id msg in (NSArray *)messages) {
            if (!MVIsOKMMessage(msg) || !MVIsIncomingMessage(msg)) continue;
            NSInteger st = MVStatusOfMessage(msg);
            if (st == 10 || (gRemovedStatus >= 0 && st == gRemovedStatus) || MVIsDeletedPk(MVPkOfMessage(msg))) {
                @try { MVRewriteIfNeeded(msg); } @catch (__unused NSException *ex) {}
            } else {
                MVCacheMessage(msg);
            }
        }
    }
    [self mvibe_messagesUpdated:messages inTransaction:tx];
}

- (void)mvibe_handleDeletedMessages:(id)messages inChatWithId:(id)chatId {
    MVEnsureStore();
    MVTryLearnCredentialsFrom(self);

    NSArray *list = nil;
    if ([messages isKindOfClass:[NSArray class]]) list = messages;
    else if ([messages respondsToSelector:@selector(allObjects)]) list = [messages allObjects];

    MVLog(@"handleDeletedMessages chat=%@ count=%lu my=%@", chatId, (unsigned long)list.count, gMyUserId);

    if (!MaxVibeAntiDeleteEnabled() || !list) {
        [self mvibe_handleDeletedMessages:messages inChatWithId:chatId];
        return;
    }

    NSMutableArray *allow = [NSMutableArray array];
    NSMutableArray *kept = [NSMutableArray array];
    for (id item in list) {
        if (MVIsOKMMessage(item)) {
            MVCacheMessage(item);
            if (MVIsIncomingMessage(item)) [kept addObject:item];
            else [allow addObject:item];
        } else if ([item isKindOfClass:[NSString class]] || [item isKindOfClass:[NSNumber class]]) {
            if (MVPkLooksIncoming(item)) {
                NSString *key = [item isKindOfClass:[NSString class]] ? item : [item description];
                MVMarkDeletedPk(key);
            } else {
                [allow addObject:item];
            }
        } else {
            [allow addObject:item];
        }
    }

    MVLog(@"handleDeletedMessages keep=%lu allow=%lu", (unsigned long)kept.count, (unsigned long)allow.count);

    // Tag kept messages WITHOUT feeding them to the original delete pipeline
    // (mutating then calling original caused SIGSEGV at 0x10).
    for (id msg in kept) {
        @try {
            MVTagMessageAsDeleted(msg);
            MVMarkDeletedPk(MVPkOfMessage(msg));
            MVTryPersistMessage(self, msg);
        } @catch (__unused NSException *ex) {
            MVLog(@"tag/persist failed pk=%@", MVPkOfMessage(msg));
        }
    }

    if (allow.count == 0) {
        MVLog(@"handleDeletedMessages skipped original (all kept)");
        return;
    }
    [self mvibe_handleDeletedMessages:allow inChatWithId:chatId];
}

- (void)mvibe_messagesDeleted:(id)messages inChat:(id)chat {
    MVEnsureStore();
    MVTryLearnCredentialsFrom(self);
    MVLog(@"messagesDeleted chat=%@ msgs=%@", chat, messages);

    if (!MaxVibeAntiDeleteEnabled()) {
        [self mvibe_messagesDeleted:messages inChat:chat];
        return;
    }

    NSArray *list = [messages isKindOfClass:[NSArray class]] ? messages : nil;
    if (!list) {
        [self mvibe_messagesDeleted:messages inChat:chat];
        return;
    }
    NSMutableArray *allow = [NSMutableArray array];
    for (id item in list) {
        if (MVIsOKMMessage(item) && MVIsIncomingMessage(item)) {
            @try {
                MVTagMessageAsDeleted(item);
                MVMarkDeletedPk(MVPkOfMessage(item));
                MVTryPersistMessage(self, item);
            } @catch (__unused NSException *ex) {}
        } else if ([item isKindOfClass:[NSString class]] && MVPkLooksIncoming(item)) {
            MVMarkDeletedPk(item);
        } else {
            [allow addObject:item];
        }
    }
    if (allow.count == 0) return;
    [self mvibe_messagesDeleted:allow inChat:chat];
}

- (void)mvibe_setText:(NSString *)text {
    if (MVStringNeedsMarker(text)) {
        [self mvibe_setAttributedText:MVBuildMarkedAttributed(text)];
        return;
    }
    [self mvibe_setText:text];
}

- (void)mvibe_setAttributedText:(NSAttributedString *)text {
    [self mvibe_setAttributedText:MVApplyMarkerToAttributed(text)];
}

@end

#pragma mark - Swizzle

static BOOL MVSwizzleInstance(Class target, SEL original, SEL donorSel) {
    if (!target || !original || !donorSel) return NO;
    Method donor = class_getInstanceMethod([MaxVibeAntiDeleteHooks class], donorSel);
    Method orig = class_getInstanceMethod(target, original);
    if (!donor || !orig) return NO;
    // Only swizzle if this class itself implements the method (not inherited).
    unsigned int count = 0;
    Method *list = class_copyMethodList(target, &count);
    BOOL owns = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(list[i]) == original) { owns = YES; break; }
    }
    if (list) free(list);
    if (!owns) return NO;

    const char *types = method_getTypeEncoding(orig);
    class_addMethod(target, donorSel, method_getImplementation(donor), types);
    Method added = class_getInstanceMethod(target, donorSel);
    if (!added) return NO;
    method_exchangeImplementations(orig, added);
    return YES;
}

static void MVLogSwizzle(BOOL ok, Class cls, NSString *sel) {
    MVLog(@"swizzle %@: %s -> %s", sel, cls ? class_getName(cls) : "(nil)", ok ? "OK" : "FAIL");
}

void MaxVibeInstallAntiDelete(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        MVEnsureStore();
        MVLog(@"install begin enabled=%d", MaxVibeAntiDeleteEnabled());

        Class yapRW = NSClassFromString(@"YapDatabaseReadWriteTransaction");
        Class yapR = NSClassFromString(@"YapDatabaseReadTransaction");
        MVLog(@"yapRW=%s yapR=%s", yapRW ? class_getName(yapRW) : "nil",
              yapR ? class_getName(yapR) : "nil");

        MVLogSwizzle(MVSwizzleInstance(yapRW, NSSelectorFromString(@"okm_saveMessage:"),
                          @selector(mvibe_okm_saveMessage:)), yapRW, @"okm_saveMessage:");
        // Category methods: class_copyMethodList may miss them — force swizzle without owns check via direct exchange
        // Re-try with looser helper for categories:
        if (yapR || yapRW) {
            Class c = yapR ?: yapRW;
            Method donor = class_getInstanceMethod([MaxVibeAntiDeleteHooks class], @selector(mvibe_okm_messageForPk:));
            Method orig = class_getInstanceMethod(c, NSSelectorFromString(@"okm_messageForPk:"));
            if (donor && orig) {
                class_addMethod(c, @selector(mvibe_okm_messageForPk:), method_getImplementation(donor), method_getTypeEncoding(orig));
                method_exchangeImplementations(orig, class_getInstanceMethod(c, @selector(mvibe_okm_messageForPk:)));
                MVLog(@"swizzle okm_messageForPk: OK");
            }
            donor = class_getInstanceMethod([MaxVibeAntiDeleteHooks class], @selector(mvibe_objectForKey:inCollection:));
            orig = class_getInstanceMethod(c, @selector(objectForKey:inCollection:));
            if (donor && orig) {
                class_addMethod(c, @selector(mvibe_objectForKey:inCollection:), method_getImplementation(donor), method_getTypeEncoding(orig));
                method_exchangeImplementations(orig, class_getInstanceMethod(c, @selector(mvibe_objectForKey:inCollection:)));
                MVLog(@"swizzle objectForKey:inCollection: OK");
            }
        }
        if (yapRW) {
            Method donor = class_getInstanceMethod([MaxVibeAntiDeleteHooks class], @selector(mvibe_setObject:forKey:inCollection:));
            Method orig = class_getInstanceMethod(yapRW, @selector(setObject:forKey:inCollection:));
            if (donor && orig) {
                class_addMethod(yapRW, @selector(mvibe_setObject:forKey:inCollection:), method_getImplementation(donor), method_getTypeEncoding(orig));
                method_exchangeImplementations(orig, class_getInstanceMethod(yapRW, @selector(mvibe_setObject:forKey:inCollection:)));
                MVLog(@"swizzle setObject:forKey:inCollection: OK");
            }
            donor = class_getInstanceMethod([MaxVibeAntiDeleteHooks class], @selector(mvibe_removeObjectsForKeys:inCollection:));
            orig = class_getInstanceMethod(yapRW, @selector(removeObjectsForKeys:inCollection:));
            if (donor && orig) {
                class_addMethod(yapRW, @selector(mvibe_removeObjectsForKeys:inCollection:), method_getImplementation(donor), method_getTypeEncoding(orig));
                method_exchangeImplementations(orig, class_getInstanceMethod(yapRW, @selector(mvibe_removeObjectsForKeys:inCollection:)));
                MVLog(@"swizzle removeObjectsForKeys:inCollection: OK");
            }
            donor = class_getInstanceMethod([MaxVibeAntiDeleteHooks class], @selector(mvibe_removeObjectForKey:inCollection:));
            orig = class_getInstanceMethod(yapRW, @selector(removeObjectForKey:inCollection:));
            if (donor && orig) {
                class_addMethod(yapRW, @selector(mvibe_removeObjectForKey:inCollection:), method_getImplementation(donor), method_getTypeEncoding(orig));
                method_exchangeImplementations(orig, class_getInstanceMethod(yapRW, @selector(mvibe_removeObjectForKey:inCollection:)));
                MVLog(@"swizzle removeObjectForKey:inCollection: OK");
            }
            donor = class_getInstanceMethod([MaxVibeAntiDeleteHooks class], @selector(mvibe_okm_saveMessage:));
            orig = class_getInstanceMethod(yapRW, NSSelectorFromString(@"okm_saveMessage:"));
            if (donor && orig) {
                // already attempted via MVSwizzleInstance; ensure once
            }
        }

        Class msgCls = NSClassFromString(@"OKMMessage");
        Method donor = class_getInstanceMethod([MaxVibeAntiDeleteHooks class], @selector(mvibe_setStatus:));
        Method orig = class_getInstanceMethod(msgCls, NSSelectorFromString(@"setStatus:"));
        if (donor && orig) {
            class_addMethod(msgCls, @selector(mvibe_setStatus:), method_getImplementation(donor), method_getTypeEncoding(orig));
            method_exchangeImplementations(orig, class_getInstanceMethod(msgCls, @selector(mvibe_setStatus:)));
            MVLog(@"swizzle setStatus: OK");
        } else {
            MVLog(@"swizzle setStatus: FAIL");
        }

        Class creds = NSClassFromString(@"OKMMessengerCredentials");
        donor = class_getInstanceMethod([MaxVibeAntiDeleteHooks class], @selector(mvibe_setCurrentUserId:));
        orig = class_getInstanceMethod(creds, NSSelectorFromString(@"setCurrentUserId:"));
        if (donor && orig) {
            class_addMethod(creds, @selector(mvibe_setCurrentUserId:), method_getImplementation(donor), method_getTypeEncoding(orig));
            method_exchangeImplementations(orig, class_getInstanceMethod(creds, @selector(mvibe_setCurrentUserId:)));
            MVLog(@"swizzle setCurrentUserId: OK");
        }

        Class chat = NSClassFromString(@"OKMChatService");
        donor = class_getInstanceMethod([MaxVibeAntiDeleteHooks class], @selector(mvibe_deleteMessagesWithPks:deleteForAll:));
        orig = class_getInstanceMethod(chat, NSSelectorFromString(@"deleteMessagesWithPks:deleteForAll:"));
        if (donor && orig) {
            class_addMethod(chat, @selector(mvibe_deleteMessagesWithPks:deleteForAll:), method_getImplementation(donor), method_getTypeEncoding(orig));
            method_exchangeImplementations(orig, class_getInstanceMethod(chat, @selector(mvibe_deleteMessagesWithPks:deleteForAll:)));
            MVLog(@"swizzle deleteMessagesWithPks: OK");
        }
        donor = class_getInstanceMethod([MaxVibeAntiDeleteHooks class], @selector(mvibe__deleteMessagesWithPks:deleteForAll:enqueueTasks:));
        orig = class_getInstanceMethod(chat, NSSelectorFromString(@"_deleteMessagesWithPks:deleteForAll:enqueueTasks:"));
        if (donor && orig) {
            class_addMethod(chat, @selector(mvibe__deleteMessagesWithPks:deleteForAll:enqueueTasks:), method_getImplementation(donor), method_getTypeEncoding(orig));
            method_exchangeImplementations(orig, class_getInstanceMethod(chat, @selector(mvibe__deleteMessagesWithPks:deleteForAll:enqueueTasks:)));
            MVLog(@"swizzle _deleteMessagesWithPks: OK");
        }
        donor = class_getInstanceMethod([MaxVibeAntiDeleteHooks class], @selector(mvibe_messagesUpdated:inTransaction:));
        orig = class_getInstanceMethod(chat, NSSelectorFromString(@"_messagesUpdated:inTransaction:"));
        if (donor && orig) {
            class_addMethod(chat, @selector(mvibe_messagesUpdated:inTransaction:), method_getImplementation(donor), method_getTypeEncoding(orig));
            method_exchangeImplementations(orig, class_getInstanceMethod(chat, @selector(mvibe_messagesUpdated:inTransaction:)));
            MVLog(@"swizzle _messagesUpdated: OK");
        }

        // Exact remote-delete classes only (no global scan — it crashed via bad exchanges)
        Class pushHelper = NSClassFromString(@"OKMPushCleanupHelper");
        donor = class_getInstanceMethod([MaxVibeAntiDeleteHooks class], @selector(mvibe_handleDeletedMessages:inChatWithId:));
        orig = class_getInstanceMethod(pushHelper, NSSelectorFromString(@"_handleDeletedMessages:inChatWithId:"));
        if (donor && orig) {
            class_addMethod(pushHelper, @selector(mvibe_handleDeletedMessages:inChatWithId:), method_getImplementation(donor), method_getTypeEncoding(orig));
            method_exchangeImplementations(orig, class_getInstanceMethod(pushHelper, @selector(mvibe_handleDeletedMessages:inChatWithId:)));
            MVLog(@"swizzle OKMPushCleanupHelper _handleDeletedMessages OK");
        } else {
            MVLog(@"swizzle OKMPushCleanupHelper _handleDeletedMessages FAIL orig=%p", orig);
        }

        Class delListener = NSClassFromString(@"OKMMessageDeleteListener");
        donor = class_getInstanceMethod([MaxVibeAntiDeleteHooks class], @selector(mvibe_messagesDeleted:inChat:));
        orig = class_getInstanceMethod(delListener, NSSelectorFromString(@"_messagesDeleted:inChat:"));
        if (donor && orig) {
            class_addMethod(delListener, @selector(mvibe_messagesDeleted:inChat:), method_getImplementation(donor), method_getTypeEncoding(orig));
            method_exchangeImplementations(orig, class_getInstanceMethod(delListener, @selector(mvibe_messagesDeleted:inChat:)));
            MVLog(@"swizzle OKMMessageDeleteListener _messagesDeleted OK");
        } else {
            MVLog(@"swizzle OKMMessageDeleteListener _messagesDeleted FAIL orig=%p", orig);
        }

        donor = class_getInstanceMethod([MaxVibeAntiDeleteHooks class], @selector(mvibe_setText:));
        orig = class_getInstanceMethod([UILabel class], @selector(setText:));
        if (donor && orig) {
            class_addMethod([UILabel class], @selector(mvibe_setText:), method_getImplementation(donor), method_getTypeEncoding(orig));
            method_exchangeImplementations(orig, class_getInstanceMethod([UILabel class], @selector(mvibe_setText:)));
        }
        donor = class_getInstanceMethod([MaxVibeAntiDeleteHooks class], @selector(mvibe_setAttributedText:));
        orig = class_getInstanceMethod([UILabel class], @selector(setAttributedText:));
        if (donor && orig) {
            class_addMethod([UILabel class], @selector(mvibe_setAttributedText:), method_getImplementation(donor), method_getTypeEncoding(orig));
            method_exchangeImplementations(orig, class_getInstanceMethod([UILabel class], @selector(mvibe_setAttributedText:)));
        }

        MVLog(@"install done");
    });
}
