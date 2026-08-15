//! Tap grammar for the refine-on-selection key.
//!
//! The binding used to be press-and-hold: hold, say nothing, release → refine;
//! hold, speak, release → apply the instruction. Holding a modifier while
//! thinking of an instruction is awkward, and a silent hold is a slow way to
//! say "just fix it". So the key now reads taps instead, all on key press:
//!
//! - idle, one tap        → refine the selection now, no recording
//! - idle, two taps       → start recording an instruction
//! - recording, one tap   → stop and apply the instruction
//! - recording, two taps  → cancel
//!
//! "One tap" is only known once the double-tap window has passed with no
//! second press, so the single-tap actions run `TAP_WINDOW` late. For refine
//! that is invisible next to the LLM call; for stop it adds a beat of silence
//! to the recording, which transcription ignores.
//!
//! State is a press timestamp and a generation counter: each press bumps the
//! generation, and a deferred single-tap action only fires if the generation
//! it captured is still current when its window closes.

use log::{debug, warn};
use once_cell::sync::Lazy;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Manager};

use crate::actions::{capture_refine_selection, refine_selection_now, ACTION_MAP};
use crate::managers::audio::AudioRecordingManager;
use crate::utils;

/// Two presses closer than this are one double tap.
const TAP_WINDOW: Duration = Duration::from_millis(300);

struct Gesture {
    last_press: Option<Instant>,
    generation: u64,
}

static GESTURE: Lazy<Mutex<Gesture>> = Lazy::new(|| {
    Mutex::new(Gesture {
        last_press: None,
        generation: 0,
    })
});

/// Handle a press of the refine key. Releases are not needed by this grammar
/// and the caller does not forward them.
pub fn press(app: &AppHandle, binding_id: &str, hotkey_string: &str) {
    let recording = app
        .try_state::<Arc<AudioRecordingManager>>()
        .is_some_and(|a| a.is_recording());

    let (double, generation) = {
        let Ok(mut g) = GESTURE.lock() else { return };
        let now = Instant::now();
        let double = g
            .last_press
            .is_some_and(|t| now.duration_since(t) < TAP_WINDOW);
        // A double tap consumes both presses; a third quick press starts over.
        g.last_press = if double { None } else { Some(now) };
        g.generation += 1;
        (double, g.generation)
    };

    let Some(action) = ACTION_MAP.get(binding_id) else {
        warn!("No action in ACTION_MAP for '{binding_id}'");
        return;
    };

    match (recording, double) {
        (true, true) => {
            debug!("Refine gesture: double tap while recording → cancel");
            utils::cancel_current_operation(app);
        }
        (true, false) => {
            debug!("Refine gesture: tap while recording → stop after window");
            let app = app.clone();
            let action = Arc::clone(action);
            let binding_id = binding_id.to_string();
            let hotkey_string = hotkey_string.to_string();
            std::thread::spawn(move || {
                std::thread::sleep(TAP_WINDOW);
                if is_current(generation) {
                    action.stop(&app, &binding_id, &hotkey_string);
                }
            });
        }
        (false, true) => {
            debug!("Refine gesture: double tap → record an instruction");
            // start() captures the selection itself (again — the first tap's
            // copy is still valid, but re-copying is harmless and keeps start()
            // self-contained).
            action.start(app, binding_id, hotkey_string);
        }
        (false, false) => {
            // Copy now, while the selection certainly still exists; decide
            // what to do with it once the window closes.
            if !capture_refine_selection(app) {
                if let Ok(mut g) = GESTURE.lock() {
                    g.last_press = None;
                }
                return;
            }
            debug!("Refine gesture: tap → refine after window");
            let app = app.clone();
            std::thread::spawn(move || {
                std::thread::sleep(TAP_WINDOW);
                if is_current(generation) {
                    refine_selection_now(&app);
                }
            });
        }
    }
}

fn is_current(generation: u64) -> bool {
    GESTURE.lock().is_ok_and(|g| g.generation == generation)
}
