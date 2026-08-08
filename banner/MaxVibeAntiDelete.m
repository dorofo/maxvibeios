#import "MaxVibeAntiDelete.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdarg.h>

/*
 * Anti-delete v2 (Android-style):
 * Incoming "delete for everyone" → keep row, UPDATE text with "❌ " prefix.
 * Do NOT swizzle YapDatabase / UILabel (those caused SIGABRT / SIGSEGV).
 * Own deletes pass through unchanged.
 */

static NSString * const kPrefKey = @"mvibe_anti_delete_enabled";
static NSString * const kSafeMigratedKey = @"mvibe_anti_delete_safe_v2";
static NSString * const kDeletedPksKey = @"mvibe_anti_delete_pks";
static NSString * const kMyUserIdKey = @"mvibe_anti_delete_my_uid";
static NSString * const kPrefix = @"❌ ";

static NSNumber *gMyUserId = nil;
static NSMutableDictionary *gMsgCache = nil; // pk -> @{senderId, text, serverId}
static NSMutableSet *gDeletedPks = nil;

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
        gMsgCache = [NSMutableDictionary dictionary];
        gDeletedPks = [NSMutableSet set];
        NSUserDefaults *p = [NSUserDefaults standardUserDefaults];
        // One-shot: old Yap builds left enabled=1 and crash-looped. Force OFF once.
        if (![p boolForKey:kSafeMigratedKey]) {
            [p setBool:NO forKey:kPrefKey];
            [p setBool:YES forKey:kSafeMigratedKey];
            MVLog(@"migration v2: forced anti-delete OFF once");
        }
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
    } @catch (__unused NSException *ex) {}
    return nil;
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

static void MVCacheMessage(id msg) {
    if (!MVIsOKMMessage(msg)) return;
    NSString *pk = MVPkOfMessage(msg);
    if (!pk) return;
    NSMutableDictionary *e = [NSMutableDictionary dictionary];
    NSNumber *sid = MVSenderIdOfMessage(msg);
    NSString *text = MVPlainTextOfMessage(msg);
    if (sid) e[@"senderId"] = sid;
    if (text) e[@"text"] = text;
    id serverId = nil;
    @try { serverId = [msg valueForKey:@"serverId"]; } @catch (__unused NSException *ex) {}
    if (serverId) e[@"serverId"] = serverId;
    gMsgCache[pk] = e;
}

static BOOL MVIsIncomingMessage(id msg) {
    NSNumber *sender = MVSenderIdOfMessage(msg);
    if (!gMyUserId || !sender) return NO; // unknown → do not keep (own deletes must work)
    return sender.unsignedLongLongValue != gMyUserId.unsignedLongLongValue;
}

static NSString *MVNormalizePk(id pkOrKey) {
    if (!pkOrKey) return nil;
    if ([pkOrKey isKindOfClass:[NSString class]]) return pkOrKey;
    if ([pkOrKey respondsToSelector:@selector(stringValue)]) return [pkOrKey stringValue];
    return [pkOrKey description];
}

static NSDictionary *MVCacheEntryForPk(id pkOrKey) {
    NSString *key = MVNormalizePk(pkOrKey);
    if (!key.length) return nil;
    NSDictionary *c = gMsgCache[key];
    if (c) return c;
    for (NSString *k in gMsgCache) {
        id sid = gMsgCache[k][@"serverId"];
        if (sid && ([[sid description] isEqualToString:key] || [sid isEqual:pkOrKey])) {
            return gMsgCache[k];
        }
    }
    return nil;
}

/** YES only when cache proves this pk is incoming. Unknown → NO. */
static BOOL MVPkLooksIncoming(id pkOrKey) {
    NSDictionary *c = MVCacheEntryForPk(pkOrKey);
    if (!c) return NO;
    NSNumber *sender = c[@"senderId"];
    if (!gMyUserId || !sender) return NO;
    return sender.unsignedLongLongValue != gMyUserId.unsignedLongLongValue;
}

static NSString *MVStripMarkers(NSString *text) {
    if (![text isKindOfClass:[NSString class]]) return text ?: @"";
    NSString *s = text;
    if ([s hasPrefix:kPrefix]) s = [s substringFromIndex:kPrefix.length];
    for (NSString *m in @[@"\ndeletel", @"\ndeleted", @"\nудалено"]) {
        s = [s stringByReplacingOccurrencesOfString:m withString:@""];
    }
    while ([s hasSuffix:@"\n"]) s = [s substringToIndex:s.length - 1];
    return s;
}

/** Mark as anti-deleted: prefix ❌, remember pk. Does not touch Yap APIs. */
static void MVMarkMessageDeleted(id msg) {
    if (!MVIsOKMMessage(msg)) return;
    NSString *pk = MVPkOfMessage(msg);
    NSString *base = MVStripMarkers(MVPlainTextOfMessage(msg) ?: @"");
    NSString *tagged = [kPrefix stringByAppendingString:base];
    MVSetPlainText(msg, tagged);
    if (pk.length) {
        [gDeletedPks addObject:pk];
        MVPersistDeletedPks();
    }
    MVCacheMessage(msg);
    MVLog(@"marked deleted pk=%@ text=%@", pk, tagged.length > 60 ? [tagged substringToIndex:60] : tagged);
}

static void MVReapplyMarkerIfNeeded(id msg) {
    if (!MVIsOKMMessage(msg)) return;
    NSString *pk = MVPkOfMessage(msg);
    if (!pk.length || ![gDeletedPks containsObject:pk]) return;
    NSString *text = MVPlainTextOfMessage(msg) ?: @"";
    if ([text hasPrefix:kPrefix]) return;
    MVSetPlainText(msg, [kPrefix stringByAppendingString:MVStripMarkers(text)]);
    MVCacheMessage(msg);
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

#pragma mark - Hooks

@interface MaxVibeAntiDeleteHooks : NSObject
- (void)mvibe_setCurrentUserId:(NSNumber *)uid;
- (void)mvibe_deleteMessagesWithPks:(NSArray *)pks deleteForAll:(BOOL)deleteForAll;
- (void)mvibe__deleteMessagesWithPks:(NSArray *)pks deleteForAll:(BOOL)deleteForAll enqueueTasks:(BOOL)enqueueTasks;
- (void)mvibe_handleDeletedMessages:(id)messages inChatWithId:(id)chatId;
- (void)mvibe_messagesDeleted:(id)messages inChat:(id)chat;
- (void)mvibe_messagesUpdated:(id)messages inTransaction:(id)tx;
- (void)mvibe_messageReceived:(id)message;
@end

@implementation MaxVibeAntiDeleteHooks

- (void)mvibe_setCurrentUserId:(NSNumber *)uid {
    MVRememberMyUserId(uid);
    MVLog(@"myUserId=%@", uid);
    [self mvibe_setCurrentUserId:uid];
}

- (void)mvibe_deleteMessagesWithPks:(NSArray *)pks deleteForAll:(BOOL)deleteForAll {
    MVEnsureStore();
    MVTryLearnCredentialsFrom(self);
    if (!MaxVibeAntiDeleteEnabled() || ![pks isKindOfClass:[NSArray class]]) {
        [self mvibe_deleteMessagesWithPks:pks deleteForAll:deleteForAll];
        return;
    }
    NSMutableArray *allow = [NSMutableArray array];
    NSUInteger keep = 0;
    for (id pk in pks) {
        if (MVPkLooksIncoming(pk) || [gDeletedPks containsObject:MVNormalizePk(pk)]) {
            keep++;
            NSString *key = MVNormalizePk(pk);
            if (key.length) [gDeletedPks addObject:key];
        } else {
            [allow addObject:pk];
        }
    }
    if (keep) MVPersistDeletedPks();
    MVLog(@"deleteMessagesWithPks total=%lu keep=%lu allow=%lu forAll=%d my=%@",
          (unsigned long)pks.count, (unsigned long)keep, (unsigned long)allow.count,
          deleteForAll, gMyUserId);
    if (allow.count == 0) return;
    [self mvibe_deleteMessagesWithPks:allow deleteForAll:deleteForAll];
}

- (void)mvibe__deleteMessagesWithPks:(NSArray *)pks deleteForAll:(BOOL)deleteForAll enqueueTasks:(BOOL)enqueueTasks {
    MVEnsureStore();
    MVTryLearnCredentialsFrom(self);
    if (!MaxVibeAntiDeleteEnabled() || ![pks isKindOfClass:[NSArray class]]) {
        [self mvibe__deleteMessagesWithPks:pks deleteForAll:deleteForAll enqueueTasks:enqueueTasks];
        return;
    }
    NSMutableArray *allow = [NSMutableArray array];
    for (id pk in pks) {
        if (MVPkLooksIncoming(pk) || [gDeletedPks containsObject:MVNormalizePk(pk)]) {
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
    [self mvibe__deleteMessagesWithPks:allow deleteForAll:deleteForAll enqueueTasks:enqueueTasks];
}

- (void)mvibe_handleDeletedMessages:(id)messages inChatWithId:(id)chatId {
    MVEnsureStore();
    MVTryLearnCredentialsFrom(self);

    NSArray *list = nil;
    if ([messages isKindOfClass:[NSArray class]]) list = messages;
    else if ([messages respondsToSelector:@selector(allObjects)]) list = [messages allObjects];

    if (!MaxVibeAntiDeleteEnabled() || !list) {
        [self mvibe_handleDeletedMessages:messages inChatWithId:chatId];
        return;
    }

    NSMutableArray *allow = [NSMutableArray array];
    NSUInteger kept = 0;
    for (id item in list) {
        if (MVIsOKMMessage(item)) {
            MVCacheMessage(item);
            if (MVIsIncomingMessage(item)) {
                kept++;
                MVMarkMessageDeleted(item);
                // Skip original delete = row stays. Marker re-applied on _messagesUpdated.
                // Do not call Yap from PushCleanupHelper (no write connection here).
            } else {
                [allow addObject:item];
            }
        } else {
            [allow addObject:item];
        }
    }
    MVLog(@"handleDeletedMessages chat=%@ keep=%lu allow=%lu my=%@",
          chatId, (unsigned long)kept, (unsigned long)allow.count, gMyUserId);
    if (allow.count == 0) return;
    [self mvibe_handleDeletedMessages:allow inChatWithId:chatId];
}

- (void)mvibe_messagesDeleted:(id)messages inChat:(id)chat {
    MVEnsureStore();
    MVTryLearnCredentialsFrom(self);
    if (!MaxVibeAntiDeleteEnabled() || ![messages isKindOfClass:[NSArray class]]) {
        [self mvibe_messagesDeleted:messages inChat:chat];
        return;
    }
    NSMutableArray *allow = [NSMutableArray array];
    for (id item in (NSArray *)messages) {
        if (MVIsOKMMessage(item)) {
            MVCacheMessage(item);
            if (MVIsIncomingMessage(item)) {
                MVMarkMessageDeleted(item);
                continue;
            }
        } else if ([item isKindOfClass:[NSString class]] &&
                   (MVPkLooksIncoming(item) || [gDeletedPks containsObject:item])) {
            [gDeletedPks addObject:item];
            MVPersistDeletedPks();
            continue;
        }
        [allow addObject:item];
    }
    MVLog(@"messagesDeleted allow=%lu", (unsigned long)allow.count);
    if (allow.count == 0) return;
    [self mvibe_messagesDeleted:allow inChat:chat];
}

- (void)mvibe_messagesUpdated:(id)messages inTransaction:(id)tx {
    if ([messages isKindOfClass:[NSArray class]]) {
        for (id msg in (NSArray *)messages) {
            MVCacheMessage(msg);
            if (MaxVibeAntiDeleteEnabled()) MVReapplyMarkerIfNeeded(msg);
        }
    }
    [self mvibe_messagesUpdated:messages inTransaction:tx];
}

- (void)mvibe_messageReceived:(id)message {
    MVCacheMessage(message);
    if (MaxVibeAntiDeleteEnabled()) MVReapplyMarkerIfNeeded(message);
    [self mvibe_messageReceived:message];
}

@end

#pragma mark - Install

static BOOL MVExchange(Class cls, SEL origSel, SEL donorSel) {
    if (!cls) return NO;
    Method donor = class_getInstanceMethod([MaxVibeAntiDeleteHooks class], donorSel);
    Method orig = class_getInstanceMethod(cls, origSel);
    if (!donor || !orig) return NO;
    class_addMethod(cls, donorSel, method_getImplementation(donor), method_getTypeEncoding(orig));
    Method added = class_getInstanceMethod(cls, donorSel);
    if (!added) return NO;
    method_exchangeImplementations(orig, added);
    return YES;
}

void MaxVibeInstallAntiDelete(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        MVEnsureStore();
        MVLog(@"install begin v2 (update+❌, no Yap/UILabel swizzle) enabled=%d",
              MaxVibeAntiDeleteEnabled());

        Class creds = NSClassFromString(@"OKMMessengerCredentials");
        MVLog(@"setCurrentUserId: %s",
              MVExchange(creds, NSSelectorFromString(@"setCurrentUserId:"),
                         @selector(mvibe_setCurrentUserId:)) ? "OK" : "FAIL");

        Class chat = NSClassFromString(@"OKMChatService");
        MVLog(@"deleteMessagesWithPks: %s",
              MVExchange(chat, NSSelectorFromString(@"deleteMessagesWithPks:deleteForAll:"),
                         @selector(mvibe_deleteMessagesWithPks:deleteForAll:)) ? "OK" : "FAIL");
        MVLog(@"_deleteMessagesWithPks: %s",
              MVExchange(chat, NSSelectorFromString(@"_deleteMessagesWithPks:deleteForAll:enqueueTasks:"),
                         @selector(mvibe__deleteMessagesWithPks:deleteForAll:enqueueTasks:)) ? "OK" : "FAIL");
        MVLog(@"_messagesUpdated: %s",
              MVExchange(chat, NSSelectorFromString(@"_messagesUpdated:inTransaction:"),
                         @selector(mvibe_messagesUpdated:inTransaction:)) ? "OK" : "FAIL");

        Class push = NSClassFromString(@"OKMPushCleanupHelper");
        MVLog(@"_handleDeletedMessages: %s",
              MVExchange(push, NSSelectorFromString(@"_handleDeletedMessages:inChatWithId:"),
                         @selector(mvibe_handleDeletedMessages:inChatWithId:)) ? "OK" : "FAIL");

        Class del = NSClassFromString(@"OKMMessageDeleteListener");
        MVLog(@"_messagesDeleted: %s",
              MVExchange(del, NSSelectorFromString(@"_messagesDeleted:inChat:"),
                         @selector(mvibe_messagesDeleted:inChat:)) ? "OK" : "FAIL");

        Class incoming = NSClassFromString(@"OKMIncomingMessagesListener");
        MVLog(@"_messageReceived: %s",
              MVExchange(incoming, NSSelectorFromString(@"_messageReceived:"),
                         @selector(mvibe_messageReceived:)) ? "OK" : "FAIL");

        MVLog(@"install done my=%@", gMyUserId);
    });
}
