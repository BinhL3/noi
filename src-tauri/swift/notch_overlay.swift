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

/// Numbers come from docs/research/notch-ui-design.md §5: they are what
/// boring.notch and DynamicNotchKit ship, checked against Apple's HIG.
private enum Island {
    /// Collapsed: exactly the camera housing, so the pill is invisible at rest.
    static let restHeight: CGFloat = 0
    /// Expanded: housing plus a chin below it for content.
    static let chinHeight: CGFloat = 44
    /// Collapsed body is a hair wider than the cutout so the anti-aliased seam
    /// where the bezel meets the pixels never shows a light gap.
    static let closedSlop: CGFloat = 4
    /// Grown wider than the cutout when open, so the island reads as pushing
    /// outward from behind the housing rather than merely dropping down.
    static let openOverhang: CGFloat = 36

    /// The concave fillet where the island meets the top screen edge. This is
    /// what makes it the Dynamic Island shape rather than a pill: the top
    /// corners curve OUTWARD into the edge, like a trumpet bell, so the island
    /// appears to grow out of the surface instead of being stuck onto it.
    /// Both radii grow with the island — a constant radius makes the closed
    /// state look puffy and the open state look boxy.
    static func flare(open: Bool) -> CGFloat { open ? 18 : 6 }
    /// Bottom corner radius. Open = flare + 5, the ratio the reference apps use.
    static func cornerRadius(open: Bool) -> CGFloat { open ? 23 : 14 }

    /// Springs as Apple specifies them (WWDC23 "Animate with springs"):
    /// perceptual duration + bounce, converted to CA's mass/stiffness/damping.
    /// Opening carries a small bounce so it reads as physical; closing is
    /// critically damped because springing back shut looks indecisive.
    static let openDuration: CFTimeInterval = 0.42
    static let openBounce: CGFloat = 0.22
    static let closeDuration: CFTimeInterval = 0.42
    static let closeBounce: CGFloat = 0
}

/// stiffness = (2π/d)², damping = 4π(1−bounce)/d, mass 1 — Apple's formulas.
private func springAnimation(keyPath: String, duration: CFTimeInterval, bounce: CGFloat) -> CASpringAnimation {
    let spring = CASpringAnimation(keyPath: keyPath)
    spring.mass = 1
    spring.stiffness = pow(2 * .pi / duration, 2)
    spring.damping = 4 * .pi * (1 - bounce) / duration
    spring.initialVelocity = 0
    // CA snaps to the final value when `duration` elapses, so the animation
    // must run to settle. The perceptual duration governs when we ORDER OUT
    // (Apple: don't wait for settling), not how long the layer animates.
    spring.duration = spring.settlingDuration
    return spring
}

/// The island outline in layer coordinates (y-up, top edge at maxY).
///
/// Top corners are concave quadratic fillets flaring outward to the top edge;
/// bottom corners are ordinary convex rounds. The body is inset by `flare` on
/// each side so the flares stay inside the frame.
private func islandPath(size: CGSize, cornerRadius r: CGFloat, flare f: CGFloat) -> CGPath {
    let w = size.width
    let h = size.height
    let path = CGMutablePath()

    // Top-left outer corner, on the screen edge.
    path.move(to: CGPoint(x: 0, y: h))
    // Concave fillet: curve from the edge down into the left wall at x = f.
    path.addQuadCurve(to: CGPoint(x: f, y: h - f), control: CGPoint(x: f, y: h))
    // Left wall.
    path.addLine(to: CGPoint(x: f, y: r))
    // Bottom-left round.
    path.addQuadCurve(to: CGPoint(x: f + r, y: 0), control: CGPoint(x: f, y: 0))
    // Bottom edge.
    path.addLine(to: CGPoint(x: w - f - r, y: 0))
    // Bottom-right round.
    path.addQuadCurve(to: CGPoint(x: w - f, y: r), control: CGPoint(x: w - f, y: 0))
    // Right wall.
    path.addLine(to: CGPoint(x: w - f, y: h - f))
    // Concave fillet back out to the edge.
    path.addQuadCurve(to: CGPoint(x: w, y: h), control: CGPoint(x: w - f, y: h))
    path.closeSubpath()
    return path
}

private final class IslandView: NSView {
    let pill = CAShapeLayer()
    /// Shadow lives under the pill on its own layer: the pill clips contents,
    /// so it would clip its own shadow.
    private let shadowLayer = CALayer()
    /// Hairline light along the pill's edge, drawn above the contents.
    private let rim = CAShapeLayer()
    /// Everything in the chin. Fades and scales in from the top edge as one
    /// unit, so content is revealed by the island opening rather than popping.
    private let content = CALayer()
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
        // colour reads as a separate object sitting under the notch. The shape
        // comes entirely from the path (concave top flares), so no cornerRadius
        // and no masksToBounds — a rect clip would slice the flares off.
        pill.fillColor = NSColor.black.cgColor
        pill.backgroundColor = NSColor.clear.cgColor

        // What sells "physical object" on Apple's own islands is not the shape
        // but the light: a soft drop shadow below (the pill floats above the
        // wallpaper) and a hairline rim catching light along the bottom edge.
        // The shadow lives on a dedicated layer UNDER the pill, because the
        // pill clips its contents and would clip its own shadow too.
        // Only when open: at rest the island must read as hardware, and
        // hardware does not cast a shadow onto the wallpaper.
        shadowLayer.backgroundColor = NSColor.clear.cgColor
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0
        shadowLayer.shadowRadius = 8
        shadowLayer.shadowOffset = CGSize(width: 0, height: -4) // downward, y-up space
        layer?.addSublayer(shadowLayer)

        rim.strokeColor = NSColor.white.withAlphaComponent(0.09).cgColor
        rim.lineWidth = 1
        rim.fillColor = NSColor.clear.cgColor
        layer?.addSublayer(pill)

        content.anchorPoint = CGPoint(x: 0.5, y: 1) // scale from the housing edge
        content.opacity = 0
        pill.addSublayer(content)

        dot.backgroundColor = NSColor.systemPink.cgColor
        dot.cornerRadius = 3
        content.addSublayer(dot)

        for _ in 0..<Wave.count {
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
            bar.cornerRadius = Wave.barWidth / 2
            // Anchor at the bottom so scaleY grows the bar upward from its
            // base, not outward from its middle.
            bar.anchorPoint = CGPoint(x: 0.5, y: 0)
            content.addSublayer(bar)
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
        // The frame includes the flares; the body is inset by flare per side,
        // so the visible body still covers the cutout (plus slop) when closed.
        let flares = Island.flare(open: open) * 2
        let body = open ? cutoutWidth + Island.openOverhang * 2 : cutoutWidth + Island.closedSlop
        let width = body + flares
        let height = safeAreaTop + (open ? Island.chinHeight : Island.restHeight)
        return CGRect(
            x: (bounds.width - width) / 2,
            y: bounds.height - height,
            width: width,
            height: height
        )
    }

    private func path(for size: CGSize, open: Bool) -> CGPath {
        islandPath(size: size, cornerRadius: Island.cornerRadius(open: open), flare: Island.flare(open: open))
    }

    func layoutPill(open: Bool, animated: Bool) {
        let target = pillFrame(open: open)
        let targetPath = path(for: target.size, open: open)
        let shadowOpacity: Float = open ? 0.6 : 0

        guard animated else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pill.frame = target
            pill.path = targetPath
            shadowLayer.frame = target
            shadowLayer.shadowPath = targetPath
            shadowLayer.shadowOpacity = shadowOpacity
            layoutContents(in: target, open: open)
            CATransaction.commit()
            return
        }

        let duration = open ? Island.openDuration : Island.closeDuration
        let bounce = open ? Island.openBounce : Island.closeBounce

        // Bounds, position and path must ride the identical spring, or the
        // flares visibly detach from the corners mid-animation and the shadow
        // lags the pill.
        let size = springAnimation(keyPath: "bounds.size", duration: duration, bounce: bounce)
        size.fromValue = NSValue(size: pill.bounds.size)
        size.toValue = NSValue(size: target.size)

        let position = springAnimation(keyPath: "position", duration: duration, bounce: bounce)
        position.fromValue = NSValue(point: pill.position)
        position.toValue = NSValue(point: CGPoint(x: target.midX, y: target.midY))

        let pathSpring = springAnimation(keyPath: "path", duration: duration, bounce: bounce)
        pathSpring.fromValue = pill.path
        pathSpring.toValue = targetPath

        let shadowSpring = springAnimation(keyPath: "shadowPath", duration: duration, bounce: bounce)
        shadowSpring.fromValue = shadowLayer.shadowPath
        shadowSpring.toValue = targetPath

        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        pill.frame = target
        pill.path = targetPath
        pill.add(size, forKey: "bounds.size")
        pill.add(position, forKey: "position")
        pill.add(pathSpring, forKey: "path")
        // The shadow is a sibling layer (the pill would clip its own shadow).
        shadowLayer.frame = target
        shadowLayer.shadowPath = targetPath
        shadowLayer.shadowOpacity = shadowOpacity
        shadowLayer.add(size, forKey: "bounds.size")
        shadowLayer.add(position, forKey: "position")
        shadowLayer.add(shadowSpring, forKey: "shadowPath")
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
        rim.path = path(for: pillRect.size, open: open)
        rim.opacity = open ? 1 : 0

        // The chin, as a layer anchored to the housing's bottom edge. When
        // closed the chin has no height, so we keep the open size and let
        // opacity + scale do the hiding — a zero-size layer would make the
        // reveal a snap instead of a morph.
        let chinSize = CGSize(width: pillRect.width, height: max(chinHeight, Island.chinHeight))
        content.bounds = CGRect(origin: .zero, size: chinSize)
        content.position = CGPoint(x: pillRect.width / 2, y: chinHeight)
        content.opacity = open ? 1 : 0
        content.transform = open ? CATransform3DIdentity : CATransform3DMakeScale(1, 0.6, 1)

        let midY = chinSize.height / 2
        dot.frame = CGRect(x: Island.flare(open: true) + 20, y: midY - 3, width: 6, height: 6)

        let waveLeft = (chinSize.width - Wave.totalWidth) / 2
        let baseY = midY - Wave.maxHeight / 2
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
        // The notched screen, NOT NSScreen.main: main is the screen with
        // keyboard focus, so with an external monitor attached the island
        // would center itself on the wrong display.
        guard let screen = NSScreen.screens.first(where: { notchMetrics(of: $0) != nil }),
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
        NSScreen.screens.contains { notchMetrics(of: $0) != nil }
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
        // Order out once the close is perceptually done — Apple's rule is the
        // perceptual duration, not the settling time — plus a hair so the
        // last frame of a critically damped close is never cut.
        DispatchQueue.main.asyncAfter(deadline: .now() + Island.closeDuration + 0.05) { [weak self] in
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
