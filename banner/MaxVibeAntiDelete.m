#import "MaxVibeAntiDelete.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

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
        @try { msg = [self objectForKey:key inCollection:collection]; } @catch (__unused NSException *e) {}
        if (!msg && [key isKindOfClass:[NSString class]]) {
            // synthesize from cache
            NSDictionary *c = gMsgCache[key];
            if (c && gMyUserId && c[@"senderId"] &&
                [c[@"senderId"] unsignedLongLongValue] != gMyUserId.unsignedLongLongValue) {
                MVMarkDeletedPk(key);
                MVLog(@"block remove pk=%@ (cache incoming)", key);
                return; // keep row; UI may still hide until status rewrite path runs
            }
        }
        if (MVIsOKMMessage(msg) && MVIsIncomingMessage(msg)) {
            MVLog(@"block remove+retag pk=%@", MVPkOfMessage(msg));
            gDeleteDepth++;
            @try {
                MVTagMessageAsDeleted(msg);
                MVRestorePriorStatus(msg);
                // Prefer okm_saveMessage if available
                SEL save = NSSelectorFromString(@"okm_saveMessage:");
                if ([self respondsToSelector:save]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    [self performSelector:save withObject:msg];
#pragma clang diagnostic pop
                } else {
                    [self setObject:msg forKey:key inCollection:collection];
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
        @try { msg = [self objectForKey:key inCollection:collection]; } @catch (__unused NSException *e) {}
        BOOL keep = NO;
        if (MVIsOKMMessage(msg) && MVIsIncomingMessage(msg)) {
            keep = YES;
            gDeleteDepth++;
            @try {
                MVTagMessageAsDeleted(msg);
                MVRestorePriorStatus(msg);
                SEL save = NSSelectorFromString(@"okm_saveMessage:");
                if ([self respondsToSelector:save]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    [self performSelector:save withObject:msg];
#pragma clang diagnostic pop
                } else {
                    [self setObject:msg forKey:key inCollection:collection];
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
    MVLog(@"deleteMessagesWithPks count=%lu forAll=%d", (unsigned long)pks.count, deleteForAll);
    gDeleteDepth++;
    @try {
        [self mvibe_deleteMessagesWithPks:pks deleteForAll:deleteForAll];
    } @finally {
        gDeleteDepth--;
    }
}

- (void)mvibe__deleteMessagesWithPks:(NSArray *)pks deleteForAll:(BOOL)deleteForAll enqueueTasks:(BOOL)enqueueTasks {
    MVEnsureStore();
    MVTryLearnCredentialsFrom(self);
    MVLog(@"_deleteMessagesWithPks count=%lu forAll=%d", (unsigned long)pks.count, deleteForAll);
    gDeleteDepth++;
    @try {
        [self mvibe__deleteMessagesWithPks:pks deleteForAll:deleteForAll enqueueTasks:enqueueTasks];
    } @finally {
        gDeleteDepth--;
    }
}

- (void)mvibe_messagesUpdated:(id)messages inTransaction:(id)tx {
    MVEnsureStore();
    MVTryLearnCredentialsFrom(self);
    BOOL anyRemoved = NO;
    if ([messages isKindOfClass:[NSArray class]]) {
        for (id msg in (NSArray *)messages) {
            if (!MVIsOKMMessage(msg)) continue;
            NSDictionary *prev = nil;
            NSString *pk = MVPkOfMessage(msg);
            if (pk) prev = [gMsgCache[pk] copy];
            MVCacheMessage(msg);
            NSInteger st = MVStatusOfMessage(msg);
            if (st == 10 || (gRemovedStatus >= 0 && st == gRemovedStatus) || MVIsDeletedPk(pk)) {
                anyRemoved = YES;
            }
            if (MaxVibeAntiDeleteEnabled() && MVIsIncomingMessage(msg) &&
                (st == 10 || (gRemovedStatus >= 0 && st == gRemovedStatus) || gDeleteDepth > 0)) {
                MVRewriteIfNeeded(msg);
            }
            (void)prev;
        }
    }
    if (anyRemoved) gDeleteDepth++;
    @try {
        [self mvibe_messagesUpdated:messages inTransaction:tx];
    } @finally {
        if (anyRemoved) gDeleteDepth--;
    }
}

- (void)mvibe_handleDeletedMessages:(id)messages inChatWithId:(id)chatId {
    MVEnsureStore();
    MVTryLearnCredentialsFrom(self);
    MVLog(@"handleDeletedMessages chat=%@ msgs=%@", chatId, messages);
    gDeleteDepth++;
    @try {
        // Try to retag before/while original runs
        if (MaxVibeAntiDeleteEnabled()) {
            NSArray *list = nil;
            if ([messages isKindOfClass:[NSArray class]]) list = messages;
            else if ([messages respondsToSelector:@selector(allObjects)]) list = [messages allObjects];
            for (id item in list) {
                id msg = item;
                if (!MVIsOKMMessage(msg) && [item isKindOfClass:[NSString class]]) {
                    // pk string — mark deleted id; rewrite happens on subsequent save/remove
                    MVMarkDeletedPk(item);
                    continue;
                }
                if (!MVIsOKMMessage(msg) && [item isKindOfClass:[NSNumber class]]) {
                    continue;
                }
                if (MVIsOKMMessage(msg) && MVIsIncomingMessage(msg)) {
                    MVRewriteIfNeeded(msg);
                }
            }
        }
        [self mvibe_handleDeletedMessages:messages inChatWithId:chatId];
    } @finally {
        gDeleteDepth--;
    }
}

- (void)mvibe_messagesDeleted:(id)messages inChat:(id)chat {
    MVEnsureStore();
    MVTryLearnCredentialsFrom(self);
    MVLog(@"messagesDeleted chat=%@ msgs=%@", chat, messages);
    gDeleteDepth++;
    @try {
        if (MaxVibeAntiDeleteEnabled() && [messages isKindOfClass:[NSArray class]]) {
            for (id item in (NSArray *)messages) {
                if ([item isKindOfClass:[NSString class]]) MVMarkDeletedPk(item);
                else if (MVIsOKMMessage(item) && MVIsIncomingMessage(item)) MVRewriteIfNeeded(item);
            }
        }
        [self mvibe_messagesDeleted:messages inChat:chat];
    } @finally {
        gDeleteDepth--;
    }
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
    const char *types = method_getTypeEncoding(orig);
    if (!class_addMethod(target, donorSel, method_getImplementation(donor), types)) {
        // donorSel already exists on target — still try exchange with existing
    }
    Method added = class_getInstanceMethod(target, donorSel);
    if (!added) return NO;
    method_exchangeImplementations(orig, added);
    return YES;
}

static void MVSwizzleAllClasses(SEL original, SEL donorSel, NSString *label) {
    int n = objc_getClassList(NULL, 0);
    if (n <= 0) return;
    Class *classes = (Class *)malloc((size_t)n * sizeof(Class));
    if (!classes) return;
    n = objc_getClassList(classes, n);
    int hits = 0;
    for (int i = 0; i < n; i++) {
        Class cls = classes[i];
        Method m = class_getInstanceMethod(cls, original);
        if (!m) continue;
        // Only swizzle the class that implements it (not just inherits)
        Method own = class_getInstanceMethod(cls, original);
        Method superM = class_getInstanceMethod(class_getSuperclass(cls), original);
        if (superM && method_getImplementation(own) == method_getImplementation(superM)) continue;
        if (MVSwizzleInstance(cls, original, donorSel)) {
            hits++;
            MVLog(@"swizzled %@ on %s", label, class_getName(cls));
        }
    }
    free(classes);
    if (!hits) MVLog(@"no class for %@", label);
}

void MaxVibeInstallAntiDelete(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        MVEnsureStore();
        MVLog(@"install begin enabled=%d", MaxVibeAntiDeleteEnabled());

        Class yapRW = NSClassFromString(@"YapDatabaseReadWriteTransaction");
        Class yapR = NSClassFromString(@"YapDatabaseReadTransaction");

        MVSwizzleInstance(yapRW, NSSelectorFromString(@"okm_saveMessage:"),
                          @selector(mvibe_okm_saveMessage:));
        MVSwizzleInstance(yapR ?: yapRW, NSSelectorFromString(@"okm_messageForPk:"),
                          @selector(mvibe_okm_messageForPk:));
        MVSwizzleInstance(yapR ?: yapRW, NSSelectorFromString(@"okm_messageForId:inChat:includeRemoved:"),
                          @selector(mvibe_okm_messageForId:inChat:includeRemoved:));

        // Core Yap — catches Mantle/status writes that skip setters
        MVSwizzleInstance(yapR ?: yapRW, @selector(objectForKey:inCollection:),
                          @selector(mvibe_objectForKey:inCollection:));
        MVSwizzleInstance(yapRW, @selector(setObject:forKey:inCollection:),
                          @selector(mvibe_setObject:forKey:inCollection:));
        MVSwizzleInstance(yapRW,
                          NSSelectorFromString(@"setObject:forKey:inCollection:withMetadata:serializedObject:serializedMetadata:"),
                          @selector(mvibe_setObject:forKey:inCollection:withMetadata:serializedObject:serializedMetadata:));
        MVSwizzleInstance(yapRW, @selector(removeObjectForKey:inCollection:),
                          @selector(mvibe_removeObjectForKey:inCollection:));
        MVSwizzleInstance(yapRW, @selector(removeObjectsForKeys:inCollection:),
                          @selector(mvibe_removeObjectsForKeys:inCollection:));

        Class msgCls = NSClassFromString(@"OKMMessage");
        MVSwizzleInstance(msgCls, NSSelectorFromString(@"setStatus:"),
                          @selector(mvibe_setStatus:));

        Class creds = NSClassFromString(@"OKMMessengerCredentials");
        MVSwizzleInstance(creds, NSSelectorFromString(@"setCurrentUserId:"),
                          @selector(mvibe_setCurrentUserId:));

        Class chat = NSClassFromString(@"OKMChatService");
        MVSwizzleInstance(chat, NSSelectorFromString(@"deleteMessagesWithPks:deleteForAll:"),
                          @selector(mvibe_deleteMessagesWithPks:deleteForAll:));
        MVSwizzleInstance(chat, NSSelectorFromString(@"_deleteMessagesWithPks:deleteForAll:enqueueTasks:"),
                          @selector(mvibe__deleteMessagesWithPks:deleteForAll:enqueueTasks:));
        MVSwizzleInstance(chat, NSSelectorFromString(@"_messagesUpdated:inTransaction:"),
                          @selector(mvibe_messagesUpdated:inTransaction:));

        // Remote delete entry points — class discovered at runtime
        MVSwizzleAllClasses(NSSelectorFromString(@"_handleDeletedMessages:inChatWithId:"),
                            @selector(mvibe_handleDeletedMessages:inChatWithId:),
                            @"_handleDeletedMessages");
        MVSwizzleAllClasses(NSSelectorFromString(@"_messagesDeleted:inChat:"),
                            @selector(mvibe_messagesDeleted:inChat:),
                            @"_messagesDeleted");

        MVSwizzleInstance([UILabel class], @selector(setText:), @selector(mvibe_setText:));
        MVSwizzleInstance([UILabel class], @selector(setAttributedText:), @selector(mvibe_setAttributedText:));

        MVLog(@"install done");
    });
}
