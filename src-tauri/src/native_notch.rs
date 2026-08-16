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
    fn notch_overlay_set_mode(mode: i32);
    fn notch_overlay_finish(outcome: i32);
    fn notch_overlay_set_clock(enabled: i32);
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

/// What the open island is showing. Mirrors `IslandMode` on the Swift side.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(i32)]
pub enum Mode {
    Dictate = 0,
    Instruct = 1,
    Transcribing = 2,
    Refining = 3,
    /// Refine key tapped once; waiting to see if a hold follows.
    Armed = 4,
}

/// Set before `show()` for a fresh open, or while open to cross-fade.
pub fn set_mode(mode: Mode) {
    if !is_available() {
        return;
    }
    unsafe { notch_overlay_set_mode(mode as i32) }
}

/// What the island shows for a beat before closing.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(i32)]
pub enum Outcome {
    Failed = 0,
    Done = 1,
    Noted = 2,
}

/// Show the outcome for a beat, then close. Replaces `hide()` at the end of
/// an operation the user should see the result of.
pub fn finish(ok: bool) {
    finish_with(if ok { Outcome::Done } else { Outcome::Failed })
}

pub fn finish_with(outcome: Outcome) {
    if !is_available() {
        return;
    }
    unsafe { notch_overlay_finish(outcome as i32) }
}

/// Whether the island shows its small clock once a dictation runs long.
pub fn set_clock(enabled: bool) {
    if !is_available() {
        return;
    }
    unsafe { notch_overlay_set_clock(enabled as i32) }
}

/// Microphone level, clamped to 0.0..=1.0.
pub fn set_level(level: f32) {
    if !is_available() {
        return;
    }
    unsafe { notch_overlay_set_level(level.clamp(0.0, 1.0)) }
}
