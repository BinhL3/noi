//! Rust side of the native notch overlay (swift/notch_overlay.swift).
//!
//! The webview overlay animates DOM, so every frame of a size change costs
//! layout and paint and it never felt like Alcove. The native island is a
//! CALayer driven by CASpringAnimation: real spring physics on the GPU, no
//! layout, nothing recomputed per frame.
//!
//! Every entry point is safe to call from any thread — the Swift side hops to
//! the main thread itself, which matters because these are called from the
//! shortcut and transcription threads.

use log::debug;
use std::sync::OnceLock;

unsafe extern "C" {
    fn notch_overlay_available() -> i32;
    fn notch_overlay_prepare();
    fn notch_overlay_show();
    fn notch_overlay_hide();
    fn notch_overlay_set_level(level: f32);
}

/// Whether the main display has a camera housing. Cached: it requires a main
/// thread hop, and the built-in display does not sprout a notch at runtime.
pub fn is_available() -> bool {
    static AVAILABLE: OnceLock<bool> = OnceLock::new();
    *AVAILABLE.get_or_init(|| {
        let available = unsafe { notch_overlay_available() } == 1;
        debug!("[native-notch] available={available}");
        available
    })
}

/// Put the island on screen at rest so hover-to-peek works before the first
/// recording. Cheap and idempotent.
pub fn prepare() {
    if !is_available() {
        return;
    }
    unsafe { notch_overlay_prepare() }
}

pub fn show() {
    if !is_available() {
        return;
    }
    unsafe { notch_overlay_show() }
}

pub fn hide() {
    if !is_available() {
        return;
    }
    unsafe { notch_overlay_hide() }
}

/// Microphone level, clamped to 0.0..=1.0.
pub fn set_level(level: f32) {
    if !is_available() {
        return;
    }
    unsafe { notch_overlay_set_level(level.clamp(0.0, 1.0)) }
}
