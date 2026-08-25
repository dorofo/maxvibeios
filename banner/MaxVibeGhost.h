#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Install ObjC hooks for hide-online / hide-read / hide-typing (safe to call once). */
void MaxVibeInstallGhost(void);

BOOL MaxVibeHideOnlineEnabled(void);
void MaxVibeSetHideOnlineEnabled(BOOL enabled);

BOOL MaxVibeHideReadEnabled(void);
void MaxVibeSetHideReadEnabled(BOOL enabled);

BOOL MaxVibeHideTypingEnabled(void);
void MaxVibeSetHideTypingEnabled(BOOL enabled);

BOOL MaxVibeHideVpnEnabled(void);
void MaxVibeSetHideVpnEnabled(BOOL enabled);

/** Extra VPN pass after UIKit is up (named + VPNRestriction classes only). */
void MaxVibeRefreshVPNHooks(void);

#ifdef __cplusplus
}
#endif
