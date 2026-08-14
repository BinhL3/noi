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
    /// Shadow lives under the pill on its own layer: the pill clips contents,
    /// so it would clip its own shadow.
    private let shadowLayer = CALayer()
    /// Hairline light along the pill's edge, drawn above the contents.
    private let rim = CALayer()
    private let dot = CALayer()
    /// One layer per waveform bar. Levels arrive per audio callback and drive
    /// each bar's scaleY from a bottom anchor — the familiar voice-memo look.
    private var bars: [CALayer] = []
    private enum Wave {
        static let count = 24
        static let barWidth: CGFloat = 2.5
        static let gap: CGFloat = 2.5
        static let maxHeight: CGFloat = 16
        static var totalWidth: CGFloat {
            CGFloat(count) * barWidth + CGFloat(count - 1) * gap
        }
    }

    /// Level history for the voice-memo waveform: newest sample on the right,
    /// scrolling left as speech continues — the shape of what was just said,
    /// not merely the current loudness.
    private var levelHistory = [CGFloat](repeating: 0, count: Wave.count)

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

        // What sells "physical object" on Apple's own islands is not the shape
        // but the light: a soft drop shadow below (the pill floats above the
        // wallpaper) and a hairline rim catching light along the bottom edge.
        // The shadow lives on a dedicated layer UNDER the pill, because the
        // pill clips its contents and would clip its own shadow too.
        shadowLayer.backgroundColor = NSColor.black.cgColor
        shadowLayer.cornerRadius = Island.cornerRadius
        shadowLayer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.45
        shadowLayer.shadowRadius = 14
        shadowLayer.shadowOffset = CGSize(width: 0, height: -6) // downward, y-up space
        layer?.addSublayer(shadowLayer)

        rim.borderColor = NSColor.white.withAlphaComponent(0.09).cgColor
        rim.borderWidth = 1
        rim.cornerRadius = Island.cornerRadius
        rim.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        rim.backgroundColor = NSColor.clear.cgColor
        // Only the BOTTOM corners round; the top is behind the housing and must
        // stay square or the seam shows. AppKit's y axis points up, so the
        // bottom corners are the MinY ones — the MaxY pair is the top, which is
        // the opposite of what CSS or UIKit would suggest.
        pill.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        pill.masksToBounds = true
        // Layer-backed and opaque: lets the compositor skip blending work.
        pill.isOpaque = true
        layer?.addSublayer(pill)

        dot.backgroundColor = NSColor.systemPink.cgColor
        dot.cornerRadius = 3
        dot.opacity = 0
        pill.addSublayer(dot)

        for _ in 0..<Wave.count {
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
            bar.cornerRadius = Wave.barWidth / 2
            bar.opacity = 0
            // Anchor at the bottom so scaleY grows the bar upward from its
            // base, not outward from its middle.
            bar.anchorPoint = CGPoint(x: 0.5, y: 0)
            pill.addSublayer(bar)
            bars.append(bar)
        }

        // Above the contents so the hairline is never painted over.
        pill.addSublayer(rim)
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
            shadowLayer.frame = target
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
        // The shadow is a sibling layer (the pill would clip its own shadow),
        // so it must ride the same spring or it visibly lags the pill.
        shadowLayer.frame = target
        shadowLayer.add(spring, forKey: "bounds.size")
        shadowLayer.add(position, forKey: "position")
        layoutContents(in: target, open: open)
        CATransaction.commit()
    }

    /// Content lives in the chin, strictly below the housing — which, in this
    /// bottom-up coordinate space, is the LOWER part of the pill rect. The
    /// housing occupies the top `safeAreaTop` points.
    private func layoutContents(in pillRect: CGRect, open: Bool) {
        let chinHeight = pillRect.height - safeAreaTop
        let centerY = chinHeight / 2

        rim.frame = CGRect(origin: .zero, size: pillRect.size)
        rim.opacity = open ? 1 : 0

        dot.frame = CGRect(x: 20, y: centerY - 3, width: 6, height: 6)
        dot.opacity = open ? 1 : 0

        let waveLeft = (pillRect.width - Wave.totalWidth) / 2
        let baseY = centerY - Wave.maxHeight / 2
        for (i, bar) in bars.enumerated() {
            // frame-setting resets anchored position, so place via bounds+position.
            bar.bounds = CGRect(x: 0, y: 0, width: Wave.barWidth, height: Wave.maxHeight)
            bar.position = CGPoint(
                x: waveLeft + CGFloat(i) * (Wave.barWidth + Wave.gap) + Wave.barWidth / 2,
                y: baseY
            )
            if bar.transform.m22 == 0 {
                bar.transform = CATransform3DMakeScale(1, 0.15, 1)
            }
            bar.opacity = open ? 1 : 0
        }
    }

    /// Mic level, 0...1, at ~24 Hz. Voice-memo style: the new sample enters on
    /// the right and history scrolls left, so the waveform is a picture of the
    /// last second of speech. Each bar is a bottom-anchored scaleY transform;
    /// the implicit CALayer action smooths each step for free, and the
    /// transforms are all the compositor ever touches.
    func setLevel(_ level: CGFloat) {
        levelHistory.removeFirst()
        levelHistory.append(max(0, min(level, 1)))

        for (i, bar) in bars.enumerated() {
            let scale = max(0.12, levelHistory[i])
            bar.transform = CATransform3DMakeScale(1, scale, 1)
        }
    }

    /// A fresh recording starts with a flat line, not the tail of the last one.
    func resetWave() {
        levelHistory = [CGFloat](repeating: 0, count: Wave.count)
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
        view.resetWave()
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
