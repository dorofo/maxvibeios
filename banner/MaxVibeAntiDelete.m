#import "MaxVibeAntiDelete.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdarg.h>

/*
 * Anti-delete (safe):
 * - Do NOT swizzle YapDatabase — that caused doesNotRecognizeSelector on YapDatabase-Write
 *   and crash loops on launch.
 * - Only filter OKMChatService deleteMessages* + OKMPushCleanupHelper handleDeletedMessages
 *   so incoming PKs never enter the official delete pipeline.
 * - Tag text in-memory with \ndeletel when we have an OKMMessage; UILabel shows red "deleted".
 */

static NSString * const kPrefKey = @"mvibe_anti_delete_enabled";
static NSString * const kDeletedPksKey = @"mvibe_anti_delete_pks";
static NSString * const kMyUserIdKey = @"mvibe_anti_delete_my_uid";
static NSString * const kDbMarker = @"\ndeletel";
static NSString * const kUiMarker = @"deleted";

static NSNumber *gMyUserId = nil;
static NSMutableDictionary *gMsgCache = nil; // pk -> @{senderId, text}
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
    if (!gMyUserId || !sender) return YES;
    return sender.unsignedLongLongValue != gMyUserId.unsignedLongLongValue;
}

static BOOL MVPkLooksIncoming(id pkOrKey) {
    if (!pkOrKey) return YES;
    NSString *key = [pkOrKey isKindOfClass:[NSString class]] ? pkOrKey : [pkOrKey description];
    NSDictionary *c = gMsgCache[key];
    if (!c) {
        for (NSString *k in gMsgCache) {
            id sid = gMsgCache[k][@"serverId"];
            if (sid && ([[sid description] isEqualToString:key] || [sid isEqual:pkOrKey])) {
                c = gMsgCache[k];
                break;
            }
        }
    }
    // Unknown pk: do NOT keep by default — otherwise own deletes break.
    // Peer deletes usually still deliver OKMMessage objects to handleDeletedMessages.
    if (!c) return NO;
    NSNumber *sender = c[@"senderId"];
    if (!gMyUserId || !sender) return NO;
    return sender.unsignedLongLongValue != gMyUserId.unsignedLongLongValue;
}

static NSString *MVStripMarkers(NSString *text) {
    if (!text) return text;
    NSString *s = text;
    for (NSString *m in @[kDbMarker, @"\ndeleted", @"\nудалено"]) {
        s = [s stringByReplacingOccurrencesOfString:m withString:@""];
    }
    while ([s hasSuffix:@"\n"]) s = [s substringToIndex:s.length - 1];
    return s;
}

static void MVTagMessageAsDeleted(id msg) {
    NSString *pk = MVPkOfMessage(msg);
    NSString *text = MVStripMarkers(MVPlainTextOfMessage(msg) ?: @"");
    NSString *tagged = [text stringByAppendingString:kDbMarker];
    @try {
        id textObj = [msg valueForKey:@"text"];
        if ([textObj isKindOfClass:[NSString class]]) {
            [msg setValue:tagged forKey:@"text"];
        } else if (textObj) {
            [textObj setValue:tagged forKey:@"text"];
            SEL setup = NSSelectorFromString(@"_setupTextAndLinks:");
            if ([textObj respondsToSelector:setup]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [textObj performSelector:setup withObject:tagged];
#pragma clang diagnostic pop
            }
        }
    } @catch (__unused NSException *ex) {}
    if (pk.length) {
        [gDeletedPks addObject:pk];
        MVPersistDeletedPks();
    }
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

#pragma mark - UI marker

static NSAttributedString *MVBuildMarkedAttributed(NSString *raw) {
    NSString *base = MVStripMarkers(raw ?: @"");
    NSMutableAttributedString *out = [[NSMutableAttributedString alloc] initWithString:base];
    [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
    NSDictionary *attrs = @{
        NSForegroundColorAttributeName: [UIColor redColor],
        NSFontAttributeName: [UIFont italicSystemFontOfSize:UIFont.systemFontSize * 0.875],
    };
    [out appendAttributedString:[[NSAttributedString alloc] initWithString:kUiMarker attributes:attrs]];
    return out;
}

static BOOL MVStringNeedsMarker(NSString *s) {
    return [s isKindOfClass:[NSString class]] &&
           ([s containsString:kDbMarker] || [s containsString:@"\ndeleted"] || [s containsString:@"\nудалено"]);
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
- (void)mvibe_setText:(NSString *)text;
- (void)mvibe_setAttributedText:(NSAttributedString *)text;
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
        if (MVPkLooksIncoming(pk)) {
            keep++;
            NSString *key = [pk isKindOfClass:[NSString class]] ? pk : [pk description];
            [gDeletedPks addObject:key];
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
        if (MVPkLooksIncoming(pk)) {
            NSString *key = [pk isKindOfClass:[NSString class]] ? pk : [pk description];
            [gDeletedPks addObject:key];
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
                // Tag in-memory only — never touch Yap from this hook.
                @try { MVTagMessageAsDeleted(item); } @catch (__unused NSException *ex) {}
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
                @try { MVTagMessageAsDeleted(item); } @catch (__unused NSException *ex) {}
                continue;
            }
        } else if ([item isKindOfClass:[NSString class]] && MVPkLooksIncoming(item)) {
            [gDeletedPks addObject:item];
            MVPersistDeletedPks();
            continue;
        }
        [allow addObject:item];
    }
    MVLog(@"messagesDeleted keep-filtered allow=%lu", (unsigned long)allow.count);
    if (allow.count == 0) return;
    [self mvibe_messagesDeleted:allow inChat:chat];
}

- (void)mvibe_messagesUpdated:(id)messages inTransaction:(id)tx {
    // Cache only — never rewrite here (Yap transaction context).
    if ([messages isKindOfClass:[NSArray class]]) {
        for (id msg in (NSArray *)messages) MVCacheMessage(msg);
    }
    [self mvibe_messagesUpdated:messages inTransaction:tx];
}

- (void)mvibe_messageReceived:(id)message {
    MVCacheMessage(message);
    [self mvibe_messageReceived:message];
}

- (void)mvibe_setText:(NSString *)text {
    if (MVStringNeedsMarker(text)) {
        [self mvibe_setAttributedText:MVBuildMarkedAttributed(text)];
        return;
    }
    [self mvibe_setText:text];
}

- (void)mvibe_setAttributedText:(NSAttributedString *)text {
    if ([text isKindOfClass:[NSAttributedString class]] && MVStringNeedsMarker(text.string)) {
        NSString *s = text.string;
        if ([s containsString:kDbMarker] || [s containsString:@"\nудалено"]) {
            [self mvibe_setAttributedText:MVBuildMarkedAttributed(s)];
            return;
        }
    }
    [self mvibe_setAttributedText:text];
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
        MVLog(@"install begin (safe, no Yap) enabled=%d", MaxVibeAntiDeleteEnabled());

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

        MVExchange([UILabel class], @selector(setText:), @selector(mvibe_setText:));
        MVExchange([UILabel class], @selector(setAttributedText:), @selector(mvibe_setAttributedText:));

        MVLog(@"install done my=%@", gMyUserId);
    });
}
