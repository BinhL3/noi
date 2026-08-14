// Native notch overlay.
//
// The webview overlay could not match Alcove's smoothness, and the reason is
// structural rather than a matter of tuning: in a webview the pill is DOM, so
// every frame of a size change costs layout and paint. Here the pill is a
// CALayer and the system animates it on the GPU with CASpringAnimation — real
// spring physics, no layout, nothing for the CPU to recompute per frame.
//
// Rust owns when the overlay appears and what it says; this file owns how it
// looks and moves. The C entry points at the bottom are the whole interface,
// and every one of them hops to the main thread because AppKit demands it and
// Rust calls them from the shortcut and transcription threads.

import AppKit
import QuartzCore

// MARK: - Geometry

private enum Island {
    /// Collapsed: exactly the camera housing, so the pill is invisible at rest.
    static let restHeight: CGFloat = 0
    /// Expanded: housing plus a chin below it for content.
    static let chinHeight: CGFloat = 44
    /// Grown slightly wider than the cutout when open, so the island reads as
    /// pushing outward from behind the housing rather than merely dropping down.
    static let openOverhang: CGFloat = 26
    static let cornerRadius: CGFloat = 22
}

private final class IslandView: NSView {
    let pill = CALayer()
    private let dot = CALayer()
    private let bar = CALayer()

    private var cutoutWidth: CGFloat = 186
    private var safeAreaTop: CGFloat = 32

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false

        // Black, so it fuses with the physically black housing. Any other
        // colour reads as a separate object sitting under the notch.
        pill.backgroundColor = NSColor.black.cgColor
        pill.cornerRadius = Island.cornerRadius
        // Only the bottom corners round; the top is behind the housing.
        pill.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        pill.masksToBounds = true
        // Layer-backed and opaque: lets the compositor skip blending work.
        pill.isOpaque = true
        layer?.addSublayer(pill)

        dot.backgroundColor = NSColor.systemPink.cgColor
        dot.cornerRadius = 3
        dot.opacity = 0
        pill.addSublayer(dot)

        bar.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
        bar.cornerRadius = 1.5
        bar.opacity = 0
        pill.addSublayer(bar)
    }

    required init?(coder: NSCoder) { nil }

    func configure(cutoutWidth: CGFloat, safeAreaTop: CGFloat) {
        self.cutoutWidth = cutoutWidth
        self.safeAreaTop = safeAreaTop
        layoutPill(open: false, animated: false)
    }

    /// AppKit's y axis points up, so the pill hangs from the top of the view.
    private func pillFrame(open: Bool) -> CGRect {
        let width = open ? cutoutWidth + Island.openOverhang * 2 : cutoutWidth
        let height = safeAreaTop + (open ? Island.chinHeight : Island.restHeight)
        return CGRect(
            x: (bounds.width - width) / 2,
            y: bounds.height - height,
            width: width,
            height: height
        )
    }

    func layoutPill(open: Bool, animated: Bool) {
        let target = pillFrame(open: open)

        guard animated else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pill.frame = target
            layoutContents(in: target, open: open)
            CATransaction.commit()
            return
        }

        // A spring, not an ease. Damping just under critical gives a single
        // small overshoot — the thing that reads as physical rather than
        // animated. Opening is looser than closing: springing back shut looks
        // indecisive, so the close is stiffer and damped harder.
        let spring = CASpringAnimation(keyPath: "bounds.size")
        spring.mass = 1.0
        spring.stiffness = open ? 260 : 340
        spring.damping = open ? 22 : 30
        spring.initialVelocity = 0
        spring.fromValue = NSValue(size: pill.bounds.size)
        spring.toValue = NSValue(size: target.size)
        spring.duration = spring.settlingDuration

        let position = CASpringAnimation(keyPath: "position")
        position.mass = spring.mass
        position.stiffness = spring.stiffness
        position.damping = spring.damping
        position.fromValue = NSValue(point: pill.position)
        position.toValue = NSValue(point: CGPoint(x: target.midX, y: target.midY))
        position.duration = spring.duration

        CATransaction.begin()
        CATransaction.setAnimationDuration(spring.duration)
        pill.frame = target
        pill.add(spring, forKey: "bounds.size")
        pill.add(position, forKey: "position")
        layoutContents(in: target, open: open)
        CATransaction.commit()
    }

    /// Content lives strictly below the housing, or the camera covers it.
    private func layoutContents(in pillRect: CGRect, open: Bool) {
        let chinTop = pillRect.height - safeAreaTop
        let centerY = chinTop / 2

        dot.frame = CGRect(x: 18, y: centerY - 3, width: 6, height: 6)
        dot.opacity = open ? 1 : 0

        let barWidth = max(pillRect.width - 80, 20)
        bar.frame = CGRect(x: 40, y: centerY - 1.5, width: barWidth, height: 3)
        bar.opacity = open ? 1 : 0
    }

    /// Mic level, 0...1. Scales the bar horizontally — a transform on an
    /// existing layer, so it costs nothing per frame.
    func setLevel(_ level: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let clamped = max(0.04, min(level, 1))
        bar.transform = CATransform3DMakeScale(clamped, 1, 1)
        CATransaction.commit()
    }
}

// MARK: - Panel

/// Housing height and cutout width, or nil when this screen has no notch.
///
/// The APIs are macOS 12+, while the bridge targets 11.0 to match the rest of
/// the Swift build. No notched Mac ever shipped below 12, so an older system
/// simply reports "no notch" and the caller uses the webview overlay.
private func notchMetrics(of screen: NSScreen) -> (safeAreaTop: CGFloat, cutoutWidth: CGFloat)? {
    guard #available(macOS 12.0, *) else { return nil }
    let safeAreaTop = screen.safeAreaInsets.top
    guard safeAreaTop > 0 else { return nil }
    let auxWidth = screen.auxiliaryTopLeftArea?.width ?? 0
    return (safeAreaTop, max(screen.frame.width - auxWidth * 2, 0))
}

private final class IslandController {
    static let shared = IslandController()

    private var panel: NSPanel?
    private var view: IslandView?

    private func ensurePanel() -> (NSPanel, IslandView)? {
        if let panel, let view { return (panel, view) }
        guard let screen = NSScreen.main,
              let metrics = notchMetrics(of: screen)
        else { return nil }

        let safeAreaTop = metrics.safeAreaTop
        let cutoutWidth = metrics.cutoutWidth

        // Wide and tall enough for the fully open island; the panel itself never
        // resizes, so nothing but the layer moves during an animation.
        let size = NSSize(width: cutoutWidth + Island.openOverhang * 4, height: safeAreaTop + Island.chinHeight + 20)
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height
        )

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false

        let view = IslandView(frame: NSRect(origin: .zero, size: size))
        view.configure(cutoutWidth: cutoutWidth, safeAreaTop: safeAreaTop)
        panel.contentView = view

        self.panel = panel
        self.view = view
        return (panel, view)
    }

    /// True only on displays with a camera housing; callers fall back to the
    /// webview overlay when this is false.
    func hasNotch() -> Bool {
        guard let screen = NSScreen.main else { return false }
        return notchMetrics(of: screen) != nil
    }

    func show() {
        guard let (panel, view) = ensurePanel() else { return }
        panel.orderFrontRegardless()
        view.layoutPill(open: true, animated: true)
    }

    func hide() {
        guard let view else { return }
        view.layoutPill(open: false, animated: true)
        // Order out only once the spring has settled, or the collapse is never
        // seen. Matches the close spring's settling time.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
            self?.panel?.orderOut(nil)
        }
    }

    func setLevel(_ level: CGFloat) {
        view?.setLevel(level)
    }
}

// MARK: - C interface
//
// Rust calls these from arbitrary threads; AppKit requires the main thread.

@_cdecl("notch_overlay_available")
public func notch_overlay_available() -> Int32 {
    if Thread.isMainThread {
        return IslandController.shared.hasNotch() ? 1 : 0
    }
    return DispatchQueue.main.sync { IslandController.shared.hasNotch() ? 1 : 0 }
}

@_cdecl("notch_overlay_show")
public func notch_overlay_show() {
    DispatchQueue.main.async { IslandController.shared.show() }
}

@_cdecl("notch_overlay_hide")
public func notch_overlay_hide() {
    DispatchQueue.main.async { IslandController.shared.hide() }
}

@_cdecl("notch_overlay_set_level")
public func notch_overlay_set_level(_ level: Float) {
    DispatchQueue.main.async { IslandController.shared.setLevel(CGFloat(level)) }
}
