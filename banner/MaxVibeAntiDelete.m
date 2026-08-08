#import "MaxVibeAntiDelete.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

/*
 * Anti-delete for MAX iOS (parity with Android MvibeAntiDelete*):
 * - Snapshot incoming messages on Yap save
 * - When status becomes Removed for incoming: keep row, append \ndeletel, remember id
 * - UILabel display: strip \ndeletel → red italic "deleted" on a new line
 * Pref: mvibe_anti_delete_enabled (default OFF)
 */

static NSString * const kPrefKey = @"mvibe_anti_delete_enabled";
static NSString * const kDeletedPksKey = @"mvibe_anti_delete_pks";
static NSString * const kMyUserIdKey = @"mvibe_anti_delete_my_uid";
static NSString * const kDbMarker = @"\ndeletel";
static NSString * const kUiMarker = @"deleted";

static NSInteger gDeleteDepth = 0;
static NSInteger gRemovedStatus = -1;
static NSNumber *gMyUserId = nil;
static NSMutableDictionary *gMsgCache = nil; // pk -> @{status, senderId, text}
static NSMutableSet *gDeletedPks = nil;
static NSMutableSet *gLiveStatuses = nil;
static dispatch_queue_t gStoreQueue;

#pragma mark - Prefs / store

BOOL MaxVibeAntiDeleteEnabled(void) {
    NSUserDefaults *p = [NSUserDefaults standardUserDefaults];
    if ([p objectForKey:kPrefKey] == nil) return NO;
    return [p boolForKey:kPrefKey];
}

void MaxVibeSetAntiDeleteEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kPrefKey];
}

static void MVEnsureStore(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gStoreQueue = dispatch_queue_create("mvibe.antidelete", DISPATCH_QUEUE_SERIAL);
        gMsgCache = [NSMutableDictionary dictionary];
        gDeletedPks = [NSMutableSet set];
        gLiveStatuses = [NSMutableSet set];
        NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:kDeletedPksKey];
        if ([saved isKindOfClass:[NSArray class]]) {
            [gDeletedPks addObjectsFromArray:saved];
        }
        id uid = [[NSUserDefaults standardUserDefaults] objectForKey:kMyUserIdKey];
        if ([uid isKindOfClass:[NSNumber class]]) gMyUserId = uid;
    });
}

static void MVPersistDeletedPks(void) {
    NSArray *arr = [gDeletedPks allObjects];
    [[NSUserDefaults standardUserDefaults] setObject:arr forKey:kDeletedPksKey];
}

static void MVRememberMyUserId(NSNumber *uid) {
    if (![uid isKindOfClass:[NSNumber class]]) return;
    if (uid.longLongValue == 0) return;
    gMyUserId = uid;
    [[NSUserDefaults standardUserDefaults] setObject:uid forKey:kMyUserIdKey];
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
            if ([cid isKindOfClass:[NSNumber class]]) return cid;
        }
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
        id textObj = [msg valueForKey:@"text"];
        if ([textObj isKindOfClass:[NSString class]]) return textObj;
        if (textObj) {
            id t = [textObj valueForKey:@"text"];
            if ([t isKindOfClass:[NSString class]]) return t;
        }
        textObj = [msg valueForKey:@"textContent"];
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
    if (!text) return text;
    NSString *s = text;
    NSArray *marks = @[kDbMarker, @"\ndeleted", @"\nудалено", @"\ndeletel"];
    for (NSString *m in marks) {
        s = [s stringByReplacingOccurrencesOfString:m withString:@""];
    }
    while ([s hasSuffix:@"\n"]) {
        s = [s substringToIndex:s.length - 1];
    }
    if ([s hasSuffix:@"deletel"]) s = [s substringToIndex:s.length - 7];
    if ([s hasSuffix:@"deleted"]) s = [s substringToIndex:s.length - 7];
    return s;
}

static BOOL MVTextHasDbMarker(NSString *text) {
    if (![text isKindOfClass:[NSString class]]) return NO;
    return [text containsString:kDbMarker] ||
           [text containsString:@"\nудалено"];
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
    if (!gMyUserId) {
        // Prefer keeping until we know self (credentials hook fills this early).
        return YES;
    }
    if (!sender) return YES;
    return sender.unsignedLongLongValue != gMyUserId.unsignedLongLongValue;
}

static void MVCacheMessage(id msg) {
    NSString *pk = MVPkOfMessage(msg);
    if (!pk) return;
    NSInteger st = MVStatusOfMessage(msg);
    NSNumber *sid = MVSenderIdOfMessage(msg);
    NSString *text = MVPlainTextOfMessage(msg);
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    if (st != -999) entry[@"status"] = @(st);
    if (sid) entry[@"senderId"] = sid;
    if (text) entry[@"text"] = text;
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
    NSString *text = MVPlainTextOfMessage(msg) ?: @"";
    text = MVStripMarkers(text);
    NSString *tagged = [text stringByAppendingString:kDbMarker];
    MVSetMessagePlainText(msg, tagged);
    if (pk) MVMarkDeletedPk(pk);
}

static void MVRestorePriorStatus(id msg) {
    NSString *pk = MVPkOfMessage(msg);
    NSDictionary *cached = pk ? gMsgCache[pk] : nil;
    NSNumber *prev = cached[@"status"];
    if (prev && gRemovedStatus >= 0 && prev.integerValue == gRemovedStatus) {
        prev = nil;
    }
    if (prev) {
        @try { [msg setValue:prev forKey:@"status"]; } @catch (__unused NSException *ex) {}
        return;
    }
    // Fallback: status 0 is commonly "normal/active" for NS_ENUM message states.
    @try { [msg setValue:@0 forKey:@"status"]; } @catch (__unused NSException *ex) {}
}

static void MVTryLearnCredentialsFrom(id obj) {
    if (!obj || gMyUserId) return;
    @try {
        id creds = nil;
        @try { creds = [obj valueForKey:@"messengerCredentials"]; } @catch (__unused NSException *e) {}
        if (!creds) @try { creds = [obj valueForKey:@"_messengerCredentials"]; } @catch (__unused NSException *e) {}
        NSNumber *uid = [creds valueForKey:@"currentUserId"];
        MVRememberMyUserId(uid);
    } @catch (__unused NSException *ex) {}
}

static void MVObserveAndMaybeRewrite(id msg) {
    if (!msg) return;
    MVEnsureStore();

    NSString *pk = MVPkOfMessage(msg);
    NSDictionary *prev = pk ? [gMsgCache[pk] copy] : nil;
    NSInteger status = MVStatusOfMessage(msg);
    NSString *text = MVPlainTextOfMessage(msg);

    if (gDeleteDepth > 0 && status != -999) {
        gRemovedStatus = status;
    }

    BOOL looksRemoved = (gRemovedStatus >= 0 && status == gRemovedStatus);
    if (!looksRemoved && gDeleteDepth > 0 && MaxVibeAntiDeleteEnabled() && MVIsIncomingMessage(msg)) {
        looksRemoved = YES;
        if (status != -999) gRemovedStatus = status;
    }
    // Remote delete before we've seen a local delete: status left the live set
    if (!looksRemoved && gRemovedStatus < 0 && prev[@"status"] && status != -999) {
        NSInteger oldSt = [prev[@"status"] integerValue];
        if (oldSt != status && gLiveStatuses.count >= 2 &&
            [gLiveStatuses containsObject:@(oldSt)] &&
            ![gLiveStatuses containsObject:@(status)]) {
            looksRemoved = YES;
            gRemovedStatus = status;
        }
    }

    if (status != -999 && !looksRemoved && gDeleteDepth == 0) {
        [gLiveStatuses addObject:@(status)];
    }

    MVCacheMessage(msg);

    if (!MaxVibeAntiDeleteEnabled()) return;
    if (!MVIsIncomingMessage(msg)) return;

    if (!looksRemoved && MVIsDeletedPk(pk)) {
        if (!MVTextHasDbMarker(text)) MVTagMessageAsDeleted(msg);
        MVCacheMessage(msg);
        return;
    }
    if (!looksRemoved) return;

    MVTagMessageAsDeleted(msg);
    MVRestorePriorStatus(msg);
    MVCacheMessage(msg);
}

#pragma mark - Attributed marker (Android-like)

static NSAttributedString *MVBuildMarkedAttributed(NSString *raw) {
    NSString *base = MVStripMarkers(raw ?: @"");
    NSMutableAttributedString *out = [[NSMutableAttributedString alloc] initWithString:base attributes:nil];
    NSAttributedString *nl = [[NSAttributedString alloc] initWithString:@"\n"];
    [out appendAttributedString:nl];
    NSDictionary *attrs = @{
        NSForegroundColorAttributeName: [UIColor redColor],
        NSFontAttributeName: [UIFont italicSystemFontOfSize:UIFont.systemFontSize * 0.875],
    };
    [out appendAttributedString:[[NSAttributedString alloc] initWithString:kUiMarker attributes:attrs]];
    return out;
}

static BOOL MVStringNeedsMarker(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length == 0) return NO;
    return [s containsString:kDbMarker] ||
           [s containsString:@"\ndeleted"] ||
           [s containsString:@"\nудалено"];
}

static NSAttributedString *MVApplyMarkerToAttributed(NSAttributedString *attr) {
    if (![attr isKindOfClass:[NSAttributedString class]]) return attr;
    NSString *s = attr.string;
    if (!MVStringNeedsMarker(s)) return attr;

    // Already rendered UI marker (no DB marker) with color — leave alone
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
- (void)mvibe_setStatus:(NSUInteger)status;
- (void)mvibe_setCurrentUserId:(NSNumber *)uid;
- (void)mvibe_deleteMessagesWithPks:(NSArray *)pks deleteForAll:(BOOL)deleteForAll;
- (void)mvibe__deleteMessagesWithPks:(NSArray *)pks deleteForAll:(BOOL)deleteForAll enqueueTasks:(BOOL)enqueueTasks;
- (void)mvibe_setText:(NSString *)text;
- (void)mvibe_setAttributedText:(NSAttributedString *)text;
@end

@implementation MaxVibeAntiDeleteHooks

- (void)mvibe_okm_saveMessage:(id)message {
    @try { MVObserveAndMaybeRewrite(message); } @catch (__unused NSException *ex) {}
    [self mvibe_okm_saveMessage:message];
}

- (void)mvibe_setStatus:(NSUInteger)status {
    MVEnsureStore();
    if (gDeleteDepth > 0) gRemovedStatus = (NSInteger)status;

    BOOL rewrite = MaxVibeAntiDeleteEnabled() &&
                   gRemovedStatus >= 0 &&
                   (NSInteger)status == gRemovedStatus &&
                   MVIsIncomingMessage(self);

    if (rewrite) {
        @try {
            MVTagMessageAsDeleted(self);
            // Skip Removed — keep prior status by not calling setStatus with Removed.
            NSString *pk = MVPkOfMessage(self);
            NSDictionary *cached = pk ? gMsgCache[pk] : nil;
            NSNumber *prev = cached[@"status"];
            NSUInteger keep = prev ? prev.unsignedIntegerValue : 0;
            if (gRemovedStatus >= 0 && (NSInteger)keep == gRemovedStatus) keep = 0;
            [self mvibe_setStatus:keep];
            MVCacheMessage(self);
            return;
        } @catch (__unused NSException *ex) {}
    }
    [self mvibe_setStatus:status];
    @try { MVCacheMessage(self); } @catch (__unused NSException *ex) {}
}

- (void)mvibe_setCurrentUserId:(NSNumber *)uid {
    MVRememberMyUserId(uid);
    [self mvibe_setCurrentUserId:uid];
}

- (void)mvibe_deleteMessagesWithPks:(NSArray *)pks deleteForAll:(BOOL)deleteForAll {
    MVEnsureStore();
    MVTryLearnCredentialsFrom(self);
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
    gDeleteDepth++;
    @try {
        [self mvibe__deleteMessagesWithPks:pks deleteForAll:deleteForAll enqueueTasks:enqueueTasks];
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

#pragma mark - Swizzle helpers

static BOOL MVSwizzleInstance(Class target, SEL original, SEL donorSel) {
    if (!target) return NO;
    Method donor = class_getInstanceMethod([MaxVibeAntiDeleteHooks class], donorSel);
    Method orig = class_getInstanceMethod(target, original);
    if (!donor || !orig) return NO;
    const char *types = method_getTypeEncoding(orig);
    class_addMethod(target, donorSel, method_getImplementation(donor), types);
    Method added = class_getInstanceMethod(target, donorSel);
    if (!added) return NO;
    method_exchangeImplementations(orig, added);
    return YES;
}

void MaxVibeInstallAntiDelete(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        MVEnsureStore();

        Class yapRW = NSClassFromString(@"YapDatabaseReadWriteTransaction");
        MVSwizzleInstance(yapRW, NSSelectorFromString(@"okm_saveMessage:"),
                          @selector(mvibe_okm_saveMessage:));

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

        // Display marker
        MVSwizzleInstance([UILabel class], @selector(setText:), @selector(mvibe_setText:));
        MVSwizzleInstance([UILabel class], @selector(setAttributedText:), @selector(mvibe_setAttributedText:));
    });
}
