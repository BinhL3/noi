//! Capture the text the user currently has selected in the frontmost app.
//!
//! macOS has no supported way to read another app's selection directly, so we
//! do what every tool in this space does: synthesise Cmd+C and read the
//! pasteboard. The subtlety is knowing whether the copy actually happened.
//!
//! Cmd+C with nothing selected is a silent no-op — the pasteboard keeps its
//! previous contents. If we simply read it afterwards we would pick up whatever
//! the user copied ten minutes ago, refine THAT, and paste it over their
//! cursor. So we compare `NSPasteboard.changeCount` before and after: it only
//! advances when something was genuinely written. No advance means no
//! selection, and the caller must not proceed.
//!
//! The user's previous clipboard is read and kept so it can be restored, but
//! restoring is not wired up yet — see `restore_clipboard` for why.

use enigo::{Direction, Enigo, Key, Keyboard};
use log::{debug, warn};
use objc2_app_kit::NSPasteboard;
use objc2_foundation::NSString;
use std::time::{Duration, Instant};

/// How long to wait for the frontmost app to service the synthetic Cmd+C.
/// Slow Electron apps are the reason this is not 50ms.
const COPY_TIMEOUT: Duration = Duration::from_millis(400);
const POLL_INTERVAL: Duration = Duration::from_millis(10);

pub struct CapturedSelection {
    pub text: String,
    /// Whatever was on the pasteboard before we clobbered it, so the caller can
    /// put it back once the replacement text has been pasted. See restore_clipboard.
    #[allow(dead_code)]
    pub previous_clipboard: Option<String>,
}

fn read_pasteboard_string(pasteboard: &NSPasteboard) -> Option<String> {
    let ns_type = NSString::from_str("public.utf8-plain-text");
    pasteboard.stringForType(&ns_type).map(|s| s.to_string())
}

/// Copy the current selection and return it, or `None` when nothing is
/// selected. `None` is a normal outcome, not an error — the caller aborts the
/// gesture entirely rather than turning into plain dictation, so that this
/// shortcut always means the same thing.
pub fn capture_selection(enigo: &mut Enigo) -> Option<CapturedSelection> {
    let pasteboard = NSPasteboard::generalPasteboard();
    let before = pasteboard.changeCount();
    let previous_clipboard = read_pasteboard_string(&pasteboard);

    if let Err(e) = press_copy(enigo) {
        warn!("[selection] failed to synthesise Cmd+C: {e}");
        return None;
    }

    // Poll rather than sleep-and-hope: most apps answer in a few ms, and
    // waiting the full timeout on every invocation would be felt.
    let deadline = Instant::now() + COPY_TIMEOUT;
    while Instant::now() < deadline {
        if pasteboard.changeCount() != before {
            let text = read_pasteboard_string(&pasteboard).unwrap_or_default();
            if text.trim().is_empty() {
                debug!("[selection] copy landed but selection was whitespace");
                return None;
            }
            debug!("[selection] captured {} chars", text.len());
            return Some(CapturedSelection {
                text,
                previous_clipboard,
            });
        }
        std::thread::sleep(POLL_INTERVAL);
    }

    debug!("[selection] no pasteboard change — nothing was selected");
    None
}

/// Put back whatever the user had on the clipboard before we borrowed it.
///
/// NOT wired up yet, deliberately. Handy's paste path (`paste_tx`) publishes the
/// replacement text as a *lazy pasteboard promise* and watches `changeCount` to
/// detect a newer user copy. Restoring the clipboard right after a paste would
/// look exactly like that newer copy and could cancel the paste it is racing.
/// Sequencing this correctly means hooking the point where `paste_tx` settles,
/// which is more surgery than the feature needs on day one — and stock Handy
/// already leaves the transcript on the clipboard, so this matches its
/// behaviour rather than regressing it.
#[allow(dead_code)]
pub fn restore_clipboard(previous: Option<String>) {
    let Some(previous) = previous else { return };
    let pasteboard = NSPasteboard::generalPasteboard();
    pasteboard.clearContents();
    let ns_type = NSString::from_str("public.utf8-plain-text");
    let value = NSString::from_str(&previous);
    pasteboard.setString_forType(&value, &ns_type);
}

/// `kVK_ANSI_C`. A raw virtual keycode, NOT `Key::Unicode('c')`: the Unicode
/// path makes enigo look the character up in the active keyboard layout via
/// `TSMGetInputSourceProperty`, which asserts it is on the main thread and
/// SIGTRAPs the process when called from the shortcut handler thread. Handy's
/// own paste does the same thing with `Key::Other(9)` for V (see input.rs).
const KEYCODE_C: u16 = 8;

fn press_copy(enigo: &mut Enigo) -> Result<(), String> {
    enigo
        .key(Key::Meta, Direction::Press)
        .map_err(|e| e.to_string())?;
    enigo
        .key(Key::Other(KEYCODE_C as u32), Direction::Press)
        .map_err(|e| e.to_string())?;
    enigo
        .key(Key::Other(KEYCODE_C as u32), Direction::Release)
        .map_err(|e| e.to_string())?;
    enigo
        .key(Key::Meta, Direction::Release)
        .map_err(|e| e.to_string())?;
    Ok(())
}
