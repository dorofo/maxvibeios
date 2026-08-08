#import "MaxVibeAntiDelete.h"
#import <Foundation/Foundation.h>

/*
 * Anti-delete temporarily DISABLED.
 * v2/v3 hooks caused SIGSEGV on launch / own-delete (Yap / IMP paths).
 * Prefs + settings toggle remain so UI still works; no ObjC swizzles.
 */

static NSString * const kPrefKey = @"mvibe_anti_delete_enabled";

BOOL MaxVibeAntiDeleteEnabled(void) {
    NSUserDefaults *p = [NSUserDefaults standardUserDefaults];
    if ([p objectForKey:kPrefKey] == nil) return NO;
    return [p boolForKey:kPrefKey];
}

void MaxVibeSetAntiDeleteEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kPrefKey];
}

void MaxVibeInstallAntiDelete(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Force OFF and install zero hooks — app must be launchable.
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:kPrefKey];
        NSLog(@"[MaxVibeAntiDelete] install DISABLED (v4 kill-switch) — no hooks");
    });
}
