//! Rust side of Apple's on-device speech engine (swift/apple_speech.swift).
//!
//! macOS 26's SpeechAnalyzer: Apple's dictation model on the Neural Engine, no
//! download, no network. Exposed as one more model in the list. Batch only —
//! the pipeline hands it the recording's samples after the key is released.

use std::ffi::{CStr, CString};
use std::sync::OnceLock;

unsafe extern "C" {
    fn apple_speech_available() -> i32;
    fn apple_speech_transcribe(
        samples: *const f32,
        count: usize,
        sample_rate: i32,
        locale: *const std::os::raw::c_char,
    ) -> *mut std::os::raw::c_char;
    fn apple_speech_free(text: *mut std::os::raw::c_char);
    fn apple_speech_prepare(locale: *const std::os::raw::c_char);
}

/// Warm the engine for `language` so the first dictation is as fast as the
/// second (setup is ~2 s cold, recognition ~100 ms warm). Returns at once.
pub fn prepare(language: &str) {
    if !is_available() {
        return;
    }
    let locale = CString::new(language).unwrap_or_default();
    unsafe { apple_speech_prepare(locale.as_ptr()) }
}

/// The model id the engine appears under.
pub const MODEL_ID: &str = "apple-speech";

/// True on macOS 26+ builds that compiled the real bridge. Cached.
pub fn is_available() -> bool {
    static AVAILABLE: OnceLock<bool> = OnceLock::new();
    *AVAILABLE.get_or_init(|| unsafe { apple_speech_available() } == 1)
}

/// Transcribe 16 kHz mono float samples. `language` is Handy's code ("en",
/// "auto"); the Swift side maps it to a supported locale.
pub fn transcribe(samples: &[f32], sample_rate: u32, language: &str) -> anyhow::Result<String> {
    if !is_available() {
        anyhow::bail!("Apple Speech is not available on this system");
    }
    let locale = CString::new(language).unwrap_or_default();
    let ptr = unsafe {
        apple_speech_transcribe(
            samples.as_ptr(),
            samples.len(),
            sample_rate as i32,
            locale.as_ptr(),
        )
    };
    if ptr.is_null() {
        anyhow::bail!("Apple Speech returned no transcription (see log)");
    }
    let text = unsafe { CStr::from_ptr(ptr) }
        .to_string_lossy()
        .into_owned();
    unsafe { apple_speech_free(ptr) };
    Ok(text)
}
