// brightkeys -- Control-Option-Up / Control-Option-Down change the built-in panel's brightness under the XeGfx desktop.
// Runs as a login agent (install.sh). Since XeGfxIntelFB 0.9.7 the panel has native brightness (AppleBacklightDisplay +
// XeGfxBacklight), so this goes through DisplayServices, the API behind the system slider: the slider stays in step and
// no permission is needed. (2026-11-17: posting the system brightness keys instead was refused by TCC, authValue 0,
// because an ad-hoc rebuild invalidates the Accessibility grant; the first version wrote debug.nvaccel_backlight
// itself and restored a level at login, which fought the system's own.) The keyboard's own brightness keys never reach
// macOS on this ThinkBook (they are an EC query), so they stay unhandled. Steps of 1/16, like a Mac's keys.
#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <IOKit/hidsystem/ev_keymap.h>
#include <os/log.h>

static os_log_t gLog;
extern int DisplayServicesGetBrightness(CGDirectDisplayID d, float *b);
extern int DisplayServicesSetBrightness(CGDirectDisplayID d, float b);

static CGDirectDisplayID builtIn(void) {
    CGDirectDisplayID ids[8]; uint32_t n = 0;
    if (CGGetOnlineDisplayList(8, ids, &n) != kCGErrorSuccess) return kCGNullDirectDisplay;
    for (uint32_t i = 0; i < n; i++) if (CGDisplayIsBuiltin(ids[i])) return ids[i];
    return kCGNullDirectDisplay;
}
static void step(float delta) {
    const CGDirectDisplayID d = builtIn();
    float b = 0;
    if (d == kCGNullDirectDisplay || DisplayServicesGetBrightness(d, &b) != 0) { os_log_error(gLog, "no built-in display brightness"); return; }
    b += delta; if (b < 0) b = 0; if (b > 1) b = 1;
    const int r = DisplayServicesSetBrightness(d, b);
    os_log(gLog, "brightness %.3f (%d)", b, r);
}

static OSStatus hotKey(EventHandlerCallRef h, EventRef e, void *u) {
    EventHotKeyID id; GetEventParameter(e, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof id, NULL, &id);
    step(id.id == 1 ? 1.0f / 16 : -1.0f / 16);
    return noErr;
}

int main(void) {
    @autoreleasepool {
        gLog = os_log_create("local.brightkeys", "keys");
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        EventTypeSpec spec = { kEventClassKeyboard, kEventHotKeyPressed };
        InstallApplicationEventHandler(&hotKey, 1, &spec, NULL, NULL);
        EventHotKeyRef up, dn;
        RegisterEventHotKey(kVK_UpArrow, controlKey | optionKey, (EventHotKeyID){ 'brkt', 1 }, GetApplicationEventTarget(), 0, &up);
        RegisterEventHotKey(kVK_DownArrow, controlKey | optionKey, (EventHotKeyID){ 'brkt', 2 }, GetApplicationEventTarget(), 0, &dn);
        os_log(gLog, "Control-Option-Up/Down: DisplayServices brightness, built-in display %u", builtIn());
        [NSApp run];
    }
    return 0;
}
