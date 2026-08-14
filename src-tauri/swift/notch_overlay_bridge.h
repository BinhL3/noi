#ifndef notch_overlay_bridge_h
#define notch_overlay_bridge_h

// C interface to the native notch overlay (see swift/notch_overlay.swift).
// Every function is safe to call from any thread; the Swift side hops to the
// main thread itself, because AppKit requires it and Rust calls in from the
// shortcut and transcription threads.

#ifdef __cplusplus
extern "C" {
#endif

// 1 when the main display has a camera housing. Callers fall back to the
// webview overlay when this is 0.
int notch_overlay_available(void);

// Spring the island open / closed. Idempotent.
void notch_overlay_show(void);
void notch_overlay_hide(void);

// Microphone level, 0.0 ... 1.0.
void notch_overlay_set_level(float level);

#ifdef __cplusplus
}
#endif

#endif /* notch_overlay_bridge_h */
