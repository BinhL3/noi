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

/// The island has three sizes. `closed` is the housing itself, invisible at
/// rest. `peek` is the hover acknowledgement — a small lift that says "I'm
/// here" without opening — and `open` is recording, with the chin content.
enum IslandState {
    case closed, peek, open
}

/// What the open island is FOR. The shape is the same; the content and tint
/// say which. Dictation is Voice Memos red; an instruction is violet — the
/// system's colour for "intelligence" — so the user can tell at a glance that
/// what they say next is a command, not text.
enum IslandMode: Equatable {
    case dictate
    case instruct
    case working(String)
    case done(ok: Bool)

    var isRecording: Bool { self == .dictate || self == .instruct }
}

/// Numbers come from docs/research/notch-ui-design.md §5: they are what
/// boring.notch and DynamicNotchKit ship, checked against Apple's HIG.
private enum Island {
    /// Chin below the housing, per state. Closed is exactly the housing so
    /// the pill is invisible at rest.
    static func chinHeight(_ s: IslandState) -> CGFloat {
        switch s { case .closed: 0; case .peek: 8; case .open: 62 }
    }
    /// How far the body extends past the cutout on each side. Closed carries
    /// a hair of slop so the anti-aliased seam where bezel meets pixels never
    /// shows a light gap; open grows well outward so the island reads as
    /// pushing out from behind the housing rather than merely dropping down.
    static func overhang(_ s: IslandState) -> CGFloat {
        switch s { case .closed: 2; case .peek: 10; case .open: 58 }
    }
    /// The concave fillet where the island meets the top screen edge. This is
    /// what makes it the Dynamic Island shape rather than a pill: the top
    /// corners curve OUTWARD into the edge, like a trumpet bell, so the island
    /// appears to grow out of the surface instead of being stuck onto it.
    /// Both radii grow with the island — a constant radius makes the closed
    /// state look puffy and the open state look boxy.
    static func flare(_ s: IslandState) -> CGFloat {
        switch s { case .closed: 6; case .peek: 10; case .open: 22 }
    }
    /// Bottom corner radius. Open = flare + 5, the ratio the reference apps use.
    static func cornerRadius(_ s: IslandState) -> CGFloat {
        switch s { case .closed: 14; case .peek: 17; case .open: 28 }
    }
    /// Shadow only once lifted: at rest the island must read as hardware, and
    /// hardware does not cast a shadow onto the wallpaper.
    static func shadowOpacity(_ s: IslandState) -> Float {
        switch s { case .closed: 0; case .peek: 0.35; case .open: 0.6 }
    }

    /// Springs as Apple specifies them (WWDC23 "Animate with springs"):
    /// perceptual duration + bounce, converted to CA's mass/stiffness/damping.
    /// Growing carries a small bounce so it reads as physical; shrinking is
    /// critically damped because springing back shut looks indecisive.
    static let growDuration: CFTimeInterval = 0.55
    static let growBounce: CGFloat = 0.15
    static let shrinkDuration: CFTimeInterval = 0.5
    static let shrinkBounce: CGFloat = 0
    /// Content appears a beat after the shape starts moving, once there is
    /// room for it, and leaves a beat before the shape shrinks. Both are what
    /// separates a morph from a pop.
    static let contentInDelay: CFTimeInterval = 0.14
    static let contentInDuration: CFTimeInterval = 0.34
    static let contentOutDuration: CFTimeInterval = 0.22
    static let contentOutLead: CFTimeInterval = 0.12

    /// Hover: dwell before the peek, grace after the pointer leaves, and how
    /// far outside the pill still counts as "on it" (larger once lifted so a
    /// pointer drifting along the edge doesn't flicker it).
    static let hoverDwell: TimeInterval = 0.3
    static let hoverExitGrace: TimeInterval = 0.1
    static func hoverSlop(_ s: IslandState) -> CGFloat {
        switch s { case .closed: 10; case .peek, .open: 30 }
    }
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
    /// Clips everything inside the pill to the island outline, and rides
    /// the same spring, so content is revealed BY the shape opening — it
    /// cannot be seen where the island has not yet grown. Without this the
    /// wave and timer floated in before the chin existed.
    private let clip = CAShapeLayer()
    /// Everything in the chin. Fades and scales in from the top edge as one
    /// unit, so content is revealed by the island opening rather than popping.
    private let content = CALayer()
    /// One layer per waveform bar. Levels arrive per audio callback and drive
    /// each bar's scaleY about its CENTRE, so a bar grows up and down at
    /// once — Voice Memos and the iOS island both mirror the wave around a
    /// midline; a bottom-anchored bar reads as an equaliser, not a voice.
    private var bars: [CALayer] = []
    /// Elapsed time, right of the wave, as Voice Memos pairs them. Digits
    /// are monospaced so the label doesn't jitter as they tick.
    private let timer = CATextLayer()
    /// The Voice Memos recording control: a red rounded square inside a thin
    /// white ring. It is the one glyph that says "recording" without a word.
    private let glyphRing = CAShapeLayer()
    private let glyphSquare = CALayer()
    /// SF Symbol glyphs for the non-dictation modes: sparkles for instruct
    /// and working, a check or an x for done.
    private let symbol = CALayer()
    /// Status text for working/done ("Refining…", "Done").
    private let label = CATextLayer()
    private(set) var mode: IslandMode = .dictate
    private var timerTick: Timer?
    private var recordingStart: Date?
    private enum Wave {
        static let count = 26
        static let barWidth: CGFloat = 3
        static let gap: CGFloat = 3
        static let maxHeight: CGFloat = 26
        /// Silence is a row of dots, not nothing.
        static let minScale: CGFloat = 0.12
        static var totalWidth: CGFloat {
            CGFloat(count) * barWidth + CGFloat(count - 1) * gap
        }
        /// Voice Memos red. White bars read as a generic meter.
        static let tint = NSColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1)
    }
    private enum Text {
        static let font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        static let width: CGFloat = 40
    }
    private enum Tint {
        /// Voice Memos red.
        static let dictate = NSColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1)
        /// systemPurple, the "intelligence" hue.
        static let instruct = NSColor(red: 0.75, green: 0.35, blue: 0.95, alpha: 1)
        static let ok = NSColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1)
        static let fail = NSColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1)
    }
    private enum Glyph {
        static let symbolSize: CGFloat = 20
        static let ringDiameter: CGFloat = 22
        static let ringWidth: CGFloat = 1.5
        static let squareSide: CGFloat = 9
        static let squareRadius: CGFloat = 2.5
    }
    /// Space between glyph, wave and timer. The three are laid out as one
    /// centred cluster — content pinned to opposite walls read as two
    /// unrelated things.
    private static let clusterGap: CGFloat = 14

    /// Level history for the voice-memo waveform: newest sample on the right,
    /// scrolling left as speech continues — the shape of what was just said,
    /// not merely the current loudness.
    private var levelHistory = [CGFloat](repeating: 0, count: Wave.count)

    private var cutoutWidth: CGFloat = 186
    private var safeAreaTop: CGFloat = 32
    private(set) var state: IslandState = .closed

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

        clip.fillColor = NSColor.black.cgColor
        pill.mask = clip

        rim.strokeColor = NSColor.white.withAlphaComponent(0.09).cgColor
        rim.lineWidth = 1
        rim.fillColor = NSColor.clear.cgColor
        layer?.addSublayer(pill)

        content.anchorPoint = CGPoint(x: 0.5, y: 1) // scale from the housing edge
        content.opacity = 0
        pill.addSublayer(content)

        for _ in 0..<Wave.count {
            let bar = CALayer()
            bar.backgroundColor = Wave.tint.cgColor
            bar.cornerRadius = Wave.barWidth / 2
            bar.transform = CATransform3DMakeScale(1, Wave.minScale, 1)
            content.addSublayer(bar)
            bars.append(bar)
        }

        glyphRing.fillColor = NSColor.clear.cgColor
        glyphRing.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        glyphRing.lineWidth = Glyph.ringWidth
        content.addSublayer(glyphRing)
        glyphSquare.backgroundColor = Wave.tint.cgColor
        glyphSquare.cornerRadius = Glyph.squareRadius
        content.addSublayer(glyphSquare)

        symbol.contentsGravity = .resizeAspect
        symbol.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        content.addSublayer(symbol)

        label.font = Text.font
        label.fontSize = Text.font.pointSize
        label.foregroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        label.alignmentMode = .left
        label.truncationMode = .end
        label.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        content.addSublayer(label)

        timer.string = "0:00"
        timer.font = Text.font
        timer.fontSize = Text.font.pointSize
        timer.foregroundColor = Wave.tint.cgColor
        timer.alignmentMode = .left
        timer.truncationMode = .none
        timer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        content.addSublayer(timer)

        // Above the contents so the hairline is never painted over.
        pill.addSublayer(rim)
    }

    required init?(coder: NSCoder) { nil }

    func configure(cutoutWidth: CGFloat, safeAreaTop: CGFloat) {
        self.cutoutWidth = cutoutWidth
        self.safeAreaTop = safeAreaTop
        layoutPill(.closed, animated: false)
    }

    /// AppKit's y axis points up, so the pill hangs from the top of the view.
    private func pillFrame(_ s: IslandState) -> CGRect {
        // The frame includes the flares; the body is inset by flare per side,
        // so the visible body still covers the cutout (plus slop) when closed.
        let width = cutoutWidth + (Island.overhang(s) + Island.flare(s)) * 2
        let height = safeAreaTop + Island.chinHeight(s)
        return CGRect(
            x: (bounds.width - width) / 2,
            y: bounds.height - height,
            width: width,
            height: height
        )
    }

    private func path(for size: CGSize, _ s: IslandState) -> CGPath {
        islandPath(size: size, cornerRadius: Island.cornerRadius(s), flare: Island.flare(s))
    }

    /// The pill's current footprint plus hover slop, in view coordinates.
    var hoverRect: CGRect {
        pillFrame(state).insetBy(dx: -Island.hoverSlop(state), dy: -Island.hoverSlop(state))
    }

    func layoutPill(_ s: IslandState, animated: Bool) {
        let growing = Island.chinHeight(s) > Island.chinHeight(state)
        let leavingOpen = state == .open && s != .open
        state = s
        let target = pillFrame(s)
        let targetPath = path(for: target.size, s)
        let shadowOpacity = Island.shadowOpacity(s)

        guard animated else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pill.frame = target
            pill.path = targetPath
            for shape in [clip, rim] {
                shape.frame = CGRect(origin: .zero, size: target.size)
                shape.path = targetPath
            }
            shadowLayer.frame = target
            shadowLayer.shadowPath = targetPath
            shadowLayer.shadowOpacity = shadowOpacity
            layoutContents(in: target, s)
            CATransaction.commit()
            return
        }

        let duration = growing ? Island.growDuration : Island.shrinkDuration
        let bounce = growing ? Island.growBounce : Island.shrinkBounce

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

        // Leaving the open state: content melts first, then the container
        // follows. Shrinking everything at once is what reads as "sudden" —
        // Apple's islands always retire the content a beat before the shape.
        // The clip and rim live in the pill's own coordinate space, so their
        // centre moves as the bounds grow; they need their own position spring.
        let innerPosition = springAnimation(keyPath: "position", duration: duration, bounce: bounce)
        innerPosition.fromValue = NSValue(point: clip.position)
        innerPosition.toValue = NSValue(point: CGPoint(x: target.width / 2, y: target.height / 2))

        // Content keeps its open geometry always (see layoutContents); only its
        // horizontal centre follows the pill, on the pill's spring, so it never
        // drifts relative to the shape while fading.
        let contentPosition = springAnimation(keyPath: "position", duration: duration, bounce: bounce)
        contentPosition.fromValue = NSValue(point: content.position)
        contentPosition.toValue = NSValue(point: CGPoint(x: target.width / 2, y: Island.chinHeight(.open)))

        let contentLead: CFTimeInterval = leavingOpen ? Island.contentOutLead : 0
        for anim in [size, position, pathSpring, shadowSpring, innerPosition, contentPosition] {
            anim.beginTime = CACurrentMediaTime() + contentLead
            anim.fillMode = .backwards
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        pill.frame = target
        pill.path = targetPath
        pill.add(size, forKey: "bounds.size")
        pill.add(position, forKey: "position")
        pill.add(pathSpring, forKey: "path")
        for shape in [clip, rim] {
            shape.frame = CGRect(origin: .zero, size: target.size)
            shape.path = targetPath
            shape.add(size, forKey: "bounds.size")
            shape.add(innerPosition, forKey: "position")
            shape.add(pathSpring, forKey: "path")
        }
        content.add(contentPosition, forKey: "position")
        // The shadow is a sibling layer (the pill would clip its own shadow).
        shadowLayer.frame = target
        shadowLayer.shadowPath = targetPath
        shadowLayer.shadowOpacity = shadowOpacity
        shadowLayer.add(size, forKey: "bounds.size")
        shadowLayer.add(position, forKey: "position")
        shadowLayer.add(shadowSpring, forKey: "shadowPath")
        layoutContents(in: target, s)
        CATransaction.commit()
    }

    /// Content lives in the chin, strictly below the housing — which, in this
    /// bottom-up coordinate space, is the LOWER part of the pill rect. The
    /// housing occupies the top `safeAreaTop` points.
    private func layoutContents(in pillRect: CGRect, _ s: IslandState) {
        let open = s == .open

        rim.opacity = s == .closed ? 0 : 1

        // The chin, as a layer anchored to the housing's bottom edge. When
        // closed the chin has no height, so we keep the open size and let
        // opacity + scale do the hiding — a zero-size layer would make the
        // reveal a snap instead of a morph.
        // Always the OPEN chin's geometry, whatever state we are entering:
        // content is only ever visible when open, and re-laying it out for a
        // smaller pill made the wave slide down-left as it faded. Its top edge
        // sits at the open chin height in pill coordinates; when the pill is
        // shorter than that the content is above the pill and the mask hides
        // it. Only the horizontal centre tracks the pill.
        let chinSize = CGSize(width: pillFrame(.open).width, height: Island.chinHeight(.open))
        content.bounds = CGRect(origin: .zero, size: chinSize)
        content.position = CGPoint(x: pillRect.width / 2, y: Island.chinHeight(.open))

        // Content in: rides the container's spring. Content out: quick and
        // eased, ahead of the container (see layoutPill).
        let animating = CATransaction.animationDuration() > 0
        if open {
            // Fade + unfold on their own eased curve, delayed so the chin has
            // begun to open before anything appears in it. Springing the
            // opacity would make it flicker on the overshoot.
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = content.presentation()?.opacity ?? content.opacity
            fade.toValue = 1
            let unfold = CABasicAnimation(keyPath: "transform")
            unfold.fromValue = content.presentation()?.transform ?? content.transform
            unfold.toValue = CATransform3DIdentity
            for a in [fade, unfold] {
                a.duration = Island.contentInDuration
                a.beginTime = CACurrentMediaTime() + (animating ? Island.contentInDelay : 0)
                a.fillMode = .backwards
                a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            content.opacity = 1
            content.transform = CATransform3DIdentity
            if animating {
                content.add(fade, forKey: "opacity")
                content.add(unfold, forKey: "transform")
            }
            CATransaction.commit()
        } else {
            let out = animating ? Island.contentOutDuration : 0
            CATransaction.begin()
            CATransaction.setAnimationDuration(out)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeIn))
            content.opacity = 0
            content.transform = CATransform3DMakeScale(0.85, 0.85, 1)
            // Bars fall back to the midline as they fade, so the wave dies
            // rather than being cut off mid-word.
            for bar in bars {
                bar.transform = CATransform3DMakeScale(1, Wave.minScale, 1)
            }
            CATransaction.commit()
        }

        layoutCluster(in: chinSize)
    }

    /// One centred cluster, whose members depend on the mode:
    ///   dictate:  (■) · wave · 0:07          red
    ///   instruct:  ✦  · wave · 0:07          violet
    ///   working:   ✦  · "Refining…"          breathing
    ///   done:      ✓  · "Done"               green, then close
    private func layoutCluster(in chinSize: CGSize) {
        let gap = Self.clusterGap
        let midY = chinSize.height / 2
        let textHeight = ceil(Text.font.ascender - Text.font.descender)
        let recording = mode.isRecording
        let usesRing = mode == .dictate

        // Tint everything that carries the mode colour.
        let tint: NSColor
        switch mode {
        case .dictate: tint = Tint.dictate
        case .instruct: tint = Tint.instruct
        case .working: tint = Tint.instruct
        case .done(let ok): tint = ok ? Tint.ok : Tint.fail
        }
        for bar in bars { bar.backgroundColor = tint.cgColor }
        timer.foregroundColor = tint.cgColor
        glyphSquare.backgroundColor = tint.cgColor

        // Which members are present.
        glyphRing.isHidden = !usesRing
        glyphSquare.isHidden = !usesRing
        symbol.isHidden = usesRing
        for bar in bars { bar.isHidden = !recording }
        timer.isHidden = !recording
        label.isHidden = recording

        // Symbol image + label text for the mode.
        let symbolName: String
        var text = ""
        switch mode {
        case .dictate: symbolName = ""
        case .instruct: symbolName = "sparkles"
        case .working(let s): symbolName = "sparkles"; text = s
        case .done(let ok): symbolName = ok ? "checkmark.circle.fill" : "xmark.circle.fill"; text = ok ? "Done" : "Couldn't do that"
        }
        if !symbolName.isEmpty {
            symbol.contents = symbolImage(symbolName, size: Glyph.symbolSize, color: tint)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        label.string = text
        CATransaction.commit()

        // Measure the cluster.
        let glyphWidth = usesRing ? Glyph.ringDiameter : Glyph.symbolSize
        let labelWidth = text.isEmpty ? 0 : ceil((text as NSString).size(withAttributes: [.font: Text.font]).width) + 2
        let clusterWidth = glyphWidth + gap + (recording ? Wave.totalWidth + gap + Text.width : labelWidth)
        var x = (chinSize.width - clusterWidth) / 2

        // Glyph.
        let glyphRect = CGRect(x: x, y: midY - glyphWidth / 2, width: glyphWidth, height: glyphWidth)
        glyphRing.frame = glyphRect
        glyphRing.path = CGPath(ellipseIn: CGRect(origin: .zero, size: glyphRect.size).insetBy(dx: Glyph.ringWidth / 2, dy: Glyph.ringWidth / 2), transform: nil)
        glyphSquare.frame = CGRect(
            x: glyphRect.midX - Glyph.squareSide / 2,
            y: glyphRect.midY - Glyph.squareSide / 2,
            width: Glyph.squareSide,
            height: Glyph.squareSide
        )
        symbol.frame = glyphRect
        x += glyphWidth + gap

        if recording {
            for (i, bar) in bars.enumerated() {
                // frame-setting resets anchored position, so place via bounds+position.
                bar.bounds = CGRect(x: 0, y: 0, width: Wave.barWidth, height: Wave.maxHeight)
                bar.position = CGPoint(
                    x: x + CGFloat(i) * (Wave.barWidth + Wave.gap) + Wave.barWidth / 2,
                    y: midY
                )
            }
            x += Wave.totalWidth + gap
            timer.frame = CGRect(x: x, y: midY - textHeight / 2 - 1, width: Text.width, height: textHeight)
        } else {
            label.frame = CGRect(x: x, y: midY - textHeight / 2 - 1, width: labelWidth, height: textHeight)
        }

        // Working: the sparkle breathes so a long LLM call still reads as alive.
        if case .working = mode {
            if symbol.animation(forKey: "breathe") == nil {
                let breathe = CABasicAnimation(keyPath: "opacity")
                breathe.fromValue = 1
                breathe.toValue = 0.35
                breathe.duration = 0.8
                breathe.autoreverses = true
                breathe.repeatCount = .infinity
                breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                symbol.add(breathe, forKey: "breathe")
            }
        } else {
            symbol.removeAnimation(forKey: "breathe")
        }
    }

    /// A tinted SF Symbol as a CGImage, at 2x for Retina.
    private func symbolImage(_ name: String, size: CGFloat, color: NSColor) -> CGImage? {
        guard #available(macOS 12.0, *) else { return nil }
        let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = base?.withSymbolConfiguration(config) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// Switch what the open island shows. Content cross-fades within the same
    /// shape; the shape itself does not move.
    func setMode(_ m: IslandMode) {
        guard m != mode else { return }
        let wasRecording = mode.isRecording
        mode = m
        if m.isRecording {
            if !wasRecording { startRecording() }
        } else {
            stopRecording()
        }
        let chinSize = CGSize(width: pillFrame(.open).width, height: Island.chinHeight(.open))
        if state == .open {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.22
            content.add(fade, forKey: "mode")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutCluster(in: chinSize)
        CATransaction.commit()
    }

    /// Mic level, 0...1, at ~24 Hz. Voice-memo style: the new sample enters on
    /// the right and history scrolls left, so the waveform is a picture of the
    /// last second of speech. Each bar is a centre-anchored scaleY transform;
    /// the implicit CALayer action smooths each step for free, and the
    /// transforms are all the compositor ever touches.
    func setLevel(_ level: CGFloat) {
        guard state == .open else { return }
        levelHistory.removeFirst()
        levelHistory.append(max(0, min(level, 1)))

        for (i, bar) in bars.enumerated() {
            let scale = max(Wave.minScale, levelHistory[i])
            bar.transform = CATransform3DMakeScale(1, scale, 1)
        }
    }

    /// A fresh recording starts with a flat line and 0:00, not the tail of
    /// the last one.
    func startRecording() {
        levelHistory = [CGFloat](repeating: 0, count: Wave.count)
        recordingStart = Date()
        updateTimer()
        timerTick?.invalidate()
        timerTick = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateTimer()
        }
    }

    func stopRecording() {
        timerTick?.invalidate()
        timerTick = nil
        recordingStart = nil
    }

    private func updateTimer() {
        guard let start = recordingStart else { return }
        let elapsed = Int(Date().timeIntervalSince(start))
        let text = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
        // Text changes must not cross-fade; a ticking clock should just tick.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        timer.string = text
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

    /// Recording owns the island while true; hover may only peek when it is
    /// idle, and never interrupts an open island.
    private var recording = false
    private var hovering = false
    private var pendingPeek: DispatchWorkItem?
    private var pendingUnpeek: DispatchWorkItem?
    private var mouseMonitors: [Any] = []

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
        let size = NSSize(
            width: cutoutWidth + (Island.overhang(.open) + Island.flare(.open)) * 2 + 40,
            height: safeAreaTop + Island.chinHeight(.open) + 20
        )
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
        // Resident from now on: the closed pill is black over the black
        // housing, so an on-screen panel costs nothing visually, and hover
        // has to work while nothing is being recorded.
        panel.orderFrontRegardless()
        installHoverMonitor(panel: panel, view: view)
        return (panel, view)
    }

    // MARK: Hover

    /// The panel keeps `ignoresMouseEvents = true` — accepting events would
    /// steal menu-bar clicks near the notch — so hover is derived from a
    /// global mouse-moved monitor instead of a tracking area. Global monitors
    /// don't see our own app's events; the local one covers that.
    private func installHoverMonitor(panel: NSPanel, view: IslandView) {
        let handler: (NSEvent) -> Void = { [weak self, weak panel, weak view] _ in
            guard let self, let panel, let view else { return }
            let inWindow = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
            let inView = view.convert(inWindow, from: nil)
            self.setHovering(view.hoverRect.contains(inView))
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: handler) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { e in handler(e); return e }) {
            mouseMonitors.append(local)
        }
    }

    private func setHovering(_ now: Bool) {
        guard now != hovering else { return }
        hovering = now
        guard !recording, let view else { return }
        if now {
            pendingUnpeek?.cancel()
            // A dwell, so a pointer merely crossing the top edge on its way
            // to a menu doesn't make the island twitch.
            let peek = DispatchWorkItem { [weak self] in
                guard let self, self.hovering, !self.recording else { return }
                self.view?.layoutPill(.peek, animated: true)
            }
            pendingPeek = peek
            DispatchQueue.main.asyncAfter(deadline: .now() + Island.hoverDwell, execute: peek)
        } else {
            pendingPeek?.cancel()
            guard view.state == .peek else { return }
            let unpeek = DispatchWorkItem { [weak self] in
                guard let self, !self.hovering, !self.recording else { return }
                self.view?.layoutPill(.closed, animated: true)
            }
            pendingUnpeek = unpeek
            DispatchQueue.main.asyncAfter(deadline: .now() + Island.hoverExitGrace, execute: unpeek)
        }
    }

    /// True only on displays with a camera housing; callers fall back to the
    /// webview overlay when this is false.
    func hasNotch() -> Bool {
        NSScreen.screens.contains { notchMetrics(of: $0) != nil }
    }

    func prepare() {
        _ = ensurePanel()
    }

    /// Open the island. Idempotent while open: the pipeline calls this again
    /// for each phase (recording → transcribing → processing), and re-opening
    /// would restart the timer and re-run the reveal.
    func show() {
        guard let (_, view) = ensurePanel() else { return }
        pendingPeek?.cancel()
        pendingUnpeek?.cancel()
        guard !recording else { return }
        recording = true
        if view.mode.isRecording { view.startRecording() }
        view.layoutPill(.open, animated: true)
    }

    func setMode(_ m: IslandMode) {
        guard let (_, view) = ensurePanel() else { return }
        view.setMode(m)
    }

    /// Show the outcome for a beat, then close. Opens first if needed, so a
    /// tap-refine that never recorded still gets its "Done".
    func finish(ok: Bool) {
        guard let (_, view) = ensurePanel() else { return }
        view.setMode(.done(ok: ok))
        show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.view?.mode == .done(ok: ok) else { return }
            self.hide()
        }
    }

    func hide() {
        guard let view else { return }
        recording = false
        view.stopRecording()
        // The panel stays resident (hover needs it); only the pill collapses.
        // If the pointer is already resting on it, settle into the peek
        // rather than snapping shut under the cursor.
        view.layoutPill(hovering ? .peek : .closed, animated: true)
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

/// Put the island on screen at rest so hover works before the first
/// recording. Harmless to call more than once or on a notchless machine.
@_cdecl("notch_overlay_prepare")
public func notch_overlay_prepare() {
    DispatchQueue.main.async { IslandController.shared.prepare() }
}

@_cdecl("notch_overlay_show")
public func notch_overlay_show() {
    DispatchQueue.main.async { IslandController.shared.show() }
}

/// 0 dictate, 1 instruct, 2 transcribing, 3 refining. Call before show() for
/// a fresh open, or while open to cross-fade the content.
@_cdecl("notch_overlay_set_mode")
public func notch_overlay_set_mode(_ mode: Int32) {
    let m: IslandMode
    switch mode {
    case 1: m = .instruct
    case 2: m = .working("Transcribing…")
    case 3: m = .working("Refining…")
    default: m = .dictate
    }
    DispatchQueue.main.async { IslandController.shared.setMode(m) }
}

/// Show ✓ Done (or ✗) briefly, then close.
@_cdecl("notch_overlay_finish")
public func notch_overlay_finish(_ ok: Int32) {
    DispatchQueue.main.async { IslandController.shared.finish(ok: ok != 0) }
}

@_cdecl("notch_overlay_hide")
public func notch_overlay_hide() {
    DispatchQueue.main.async { IslandController.shared.hide() }
}

@_cdecl("notch_overlay_set_level")
public func notch_overlay_set_level(_ level: Float) {
    DispatchQueue.main.async { IslandController.shared.setLevel(CGFloat(level)) }
}
