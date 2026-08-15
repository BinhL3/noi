//! Liquid Glass backdrop for the settings window (macOS).
//!
//! The window is created transparent with an overlay title bar, and a
//! system glass view is slid in BEHIND the webview so the desktop refracts
//! through the whole window the way it does through Apple's own Tahoe
//! panels. The web content then only needs translucent surfaces; it never
//! fakes the glass itself.
//!
//! macOS 26 has the real thing, `NSGlassEffectView`. Earlier systems get an
//! `NSVisualEffectView` in the sidebar material, which is the same idea with
//! last year's optics. Both are pure AppKit and cost nothing per frame.

use log::{debug, warn};
use objc2::rc::Retained;
use objc2::runtime::AnyClass;
use objc2_app_kit::{
    NSAutoresizingMaskOptions, NSGlassEffectView, NSView, NSVisualEffectBlendingMode,
    NSVisualEffectMaterial, NSVisualEffectState, NSVisualEffectView, NSWindow,
    NSWindowOrderingMode,
};
use objc2_foundation::MainThreadMarker;
use tauri::WebviewWindow;

/// Install the glass backdrop. Safe to call from any thread; the AppKit work
/// hops to the main thread. A no-op if the window has no AppKit handle.
pub fn apply(window: &WebviewWindow) {
    let w = window.clone();
    let _ = window.run_on_main_thread(move || {
        let Some(mtm) = MainThreadMarker::new() else {
            return;
        };
        let Ok(ptr) = w.ns_window() else {
            warn!("[glass] no NSWindow for main window");
            return;
        };
        // SAFETY: Tauri hands back the live NSWindow* for this window, and we
        // are on the main thread for the duration of this closure.
        let ns_window: &NSWindow = unsafe { &*(ptr as *const NSWindow) };
        let Some(content) = ns_window.contentView() else {
            return;
        };
        let bounds = content.bounds();
        // Anything already in the content view is the webview; the backdrop
        // goes beneath it.
        let first = content.subviews().firstObject();

        let backdrop: Retained<NSView> = if AnyClass::get(c"NSGlassEffectView").is_some() {
            debug!("[glass] NSGlassEffectView (macOS 26+)");
            let glass = unsafe { NSGlassEffectView::initWithFrame(mtm.alloc(), bounds) };
            Retained::into_super(glass)
        } else {
            debug!("[glass] NSVisualEffectView fallback");
            let effect = unsafe { NSVisualEffectView::initWithFrame(mtm.alloc(), bounds) };
            effect.setMaterial(NSVisualEffectMaterial::Sidebar);
            effect.setBlendingMode(NSVisualEffectBlendingMode::BehindWindow);
            effect.setState(NSVisualEffectState::Active);
            Retained::into_super(effect)
        };
        backdrop.setAutoresizingMask(
            NSAutoresizingMaskOptions::ViewWidthSizable
                | NSAutoresizingMaskOptions::ViewHeightSizable,
        );
        unsafe {
            content.addSubview_positioned_relativeTo(
                &backdrop,
                NSWindowOrderingMode::Below,
                first.as_deref(),
            );
        }
    });
}
