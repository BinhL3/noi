//! Gesture grammar for the refine-on-selection key.
//!
//! - tap                      → refine the selection now, no recording
//! - tap, then press-and-hold → record an instruction while held;
//!                              release → stop and apply it
//! - double-tap               → record an instruction until the next tap
//!                              (the second press released quickly means
//!                              "keep listening"); that tap applies it
//!
//! Users describe the second gesture as "double tap", so both grammars
//! work and mean the same thing. Cancel is Handy's cancel binding (Escape).
//!
//! A tap is only known to be a lone tap once the double-tap window has passed
//! with no second press, so refine runs `TAP_WINDOW` late — invisible next to
//! the LLM call. A second press inside the window starts recording at once,
//! and its release ends it. A quick double tap therefore records ~nothing,
//! which the pipeline treats as a silent refine — the same result as one tap.
//!
//! State is a press timestamp, a "holding" flag, and a generation counter:
//! each press bumps the generation, and the deferred refine only fires if the
//! generation it captured is still current when its window closes.

use log::{debug, warn};
use once_cell::sync::Lazy;
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tauri::AppHandle;

use crate::actions::{capture_refine_selection, refine_selection_now, ACTION_MAP};

/// Two presses closer than this are one gesture.
/// Long enough that the island's armed acknowledgement is seen arriving,
/// short enough that a plain refine feels immediate next to the model call.
const TAP_WINDOW: Duration = Duration::from_millis(450);
/// A second press released faster than this was a tap, not a hold: keep
/// recording until the next tap instead of stopping on release.
const QUICK_RELEASE: Duration = Duration::from_millis(280);

struct Gesture {
    last_press: Option<Instant>,
    /// The second press is down and recording; its release stops — unless it
    /// was quick, in which case recording continues (`latched`).
    holding: bool,
    holding_since: Option<Instant>,
    /// Recording continues after a quick double-tap; the next press stops.
    latched: bool,
    generation: u64,
}

static GESTURE: Lazy<Mutex<Gesture>> = Lazy::new(|| {
    Mutex::new(Gesture {
        last_press: None,
        holding: false,
        holding_since: None,
        latched: false,
        generation: 0,
    })
});

pub fn event(app: &AppHandle, binding_id: &str, hotkey_string: &str, is_pressed: bool) {
    if is_pressed {
        press(app, binding_id, hotkey_string);
    } else {
        release(app, binding_id, hotkey_string);
    }
}

fn press(app: &AppHandle, binding_id: &str, hotkey_string: &str) {
    // A press while latched (double-tapped, still recording) ends it.
    let latched = {
        let Ok(mut g) = GESTURE.lock() else { return };
        std::mem::replace(&mut g.latched, false)
    };
    if latched {
        debug!("Refine gesture: tap while listening → stop and apply the instruction");
        if let Ok(mut g) = GESTURE.lock() {
            g.last_press = None;
            g.generation += 1;
        }
        if let Some(action) = ACTION_MAP.get(binding_id) {
            action.stop(app, binding_id, hotkey_string);
        }
        return;
    }

    let (second, generation) = {
        let Ok(mut g) = GESTURE.lock() else { return };
        if g.holding {
            // Autorepeat while held, or a re-press we cannot make sense of.
            return;
        }
        let now = Instant::now();
        let second = g
            .last_press
            .is_some_and(|t| now.duration_since(t) < TAP_WINDOW);
        g.last_press = if second { None } else { Some(now) };
        g.generation += 1;
        if second {
            g.holding = true;
            g.holding_since = Some(now);
        }
        (second, g.generation)
    };

    if second {
        debug!("Refine gesture: second press → recording an instruction while held");
        let Some(action) = ACTION_MAP.get(binding_id) else {
            warn!("No action in ACTION_MAP for '{binding_id}'");
            return;
        };
        // start() captures the selection itself; the first press's copy is
        // still valid but re-copying is harmless and keeps start() whole.
        action.start(app, binding_id, hotkey_string);
        return;
    }

    // First press: copy now, while the selection certainly still exists, and
    // decide what to do with it once the window closes.
    if !capture_refine_selection(app) {
        if let Ok(mut g) = GESTURE.lock() {
            g.last_press = None;
        }
        return;
    }
    debug!("Refine gesture: tap → refine once the window closes");
    // Acknowledge on screen right away: sparkle, "Refine", capsule 60%.
    crate::overlay::show_armed_overlay(app);
    let app = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(TAP_WINDOW);
        if GESTURE
            .lock()
            .is_ok_and(|g| g.generation == generation && !g.holding)
        {
            refine_selection_now(&app);
        }
    });
}

fn release(app: &AppHandle, binding_id: &str, hotkey_string: &str) {
    let (was_holding, quick) = {
        let Ok(mut g) = GESTURE.lock() else { return };
        let was = std::mem::replace(&mut g.holding, false);
        let quick = g
            .holding_since
            .take()
            .is_some_and(|t| t.elapsed() < QUICK_RELEASE);
        if was && quick {
            g.latched = true;
        }
        (was, quick)
    };
    if !was_holding {
        return;
    }
    if quick {
        debug!("Refine gesture: double-tap → keep listening until the next tap");
        return;
    }
    debug!("Refine gesture: released → stop and apply the instruction");
    let Some(action) = ACTION_MAP.get(binding_id) else {
        warn!("No action in ACTION_MAP for '{binding_id}'");
        return;
    };
    action.stop(app, binding_id, hotkey_string);
}
