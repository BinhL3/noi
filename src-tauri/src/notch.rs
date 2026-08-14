//! Where the notch is, if there is one.
//!
//! macOS does not expose the notch directly. What it exposes is
//! `NSScreen.safeAreaInsets.top`, which is non-zero only on displays with a
//! camera housing, and `auxiliaryTopLeftArea` — the usable rectangle to the
//! left of the cutout. The cutout width is what those two leave in the middle.
//!
//! `NSScreen::screens` demands a `MainThreadMarker`, but overlay positioning
//! runs on a background thread. So the geometry is snapshotted once at startup
//! on the main thread and read from a cache afterwards; nothing here touches
//! AppKit off the main thread.
//!
//! Consequence worth knowing: hot-plugging a monitor does not refresh the
//! snapshot. Positioning falls back to the non-notch path for screens it has
//! never seen, which is the safe direction to be wrong in.

use log::debug;
use objc2_app_kit::NSScreen;
use objc2_foundation::MainThreadMarker;
use std::sync::OnceLock;

#[derive(Debug, Clone, Copy)]
pub struct NotchGeometry {
    /// Height of the camera housing in points — how far down the usable area
    /// starts. Zero on displays without a notch.
    pub safe_area_top: f64,
    /// Width of the cutout itself, for laying a pill out around it.
    pub cutout_width: f64,
}

#[derive(Debug, Clone, Copy)]
struct ScreenSnapshot {
    width: f64,
    height: f64,
    notch: Option<NotchGeometry>,
}

static SCREENS: OnceLock<Vec<ScreenSnapshot>> = OnceLock::new();

/// Snapshot every screen's notch geometry. Call once, from the main thread,
/// during setup. Later calls are ignored.
pub fn snapshot_screens(mtm: MainThreadMarker) {
    let mut snapshots = Vec::new();

    for screen in NSScreen::screens(mtm).iter() {
        let frame = screen.frame();
        let insets = screen.safeAreaInsets();
        let safe_area_top = insets.top;

        let notch = if safe_area_top > 0.0 {
            // auxiliaryTopLeftArea is the usable strip left of the cutout. The
            // menu bar is symmetric about the notch, so the cutout is whatever
            // is left once both side strips are accounted for.
            let aux_left_width = screen.auxiliaryTopLeftArea().size.width;
            let cutout_width = (frame.size.width - aux_left_width * 2.0).max(0.0);
            Some(NotchGeometry {
                safe_area_top,
                cutout_width,
            })
        } else {
            None
        };

        debug!(
            "[notch] screen {}x{} safe_area_top={} notch={:?}",
            frame.size.width, frame.size.height, safe_area_top, notch
        );

        snapshots.push(ScreenSnapshot {
            width: frame.size.width,
            height: frame.size.height,
            notch,
        });
    }

    let _ = SCREENS.set(snapshots);
}

/// Notch geometry for the screen with these logical dimensions, if it has one.
///
/// Matched on size rather than origin: Cocoa's coordinate space is bottom-left
/// origin and Tauri's is top-left, so the y values do not line up, while
/// width and height are the same in both.
pub fn for_screen_size(width: f64, height: f64) -> Option<NotchGeometry> {
    const TOLERANCE: f64 = 1.0;
    SCREENS
        .get()?
        .iter()
        .find(|s| (s.width - width).abs() < TOLERANCE && (s.height - height).abs() < TOLERANCE)
        .and_then(|s| s.notch)
}
