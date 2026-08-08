#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Install ObjC hooks for anti-delete (safe to call once). */
void MaxVibeInstallAntiDelete(void);

BOOL MaxVibeAntiDeleteEnabled(void);
void MaxVibeSetAntiDeleteEnabled(BOOL enabled);

#ifdef __cplusplus
}
#endif
