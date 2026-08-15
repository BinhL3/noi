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
import CoreImage

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
    /// Label plus the SF Symbol that says which kind of work: transcribing
    /// shows lines of text (speech becoming text — not a waveform, which now
    /// means recording), refining the sparkle.
    case working(String, symbol: String)
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
        switch s { case .closed: 0; case .peek: 0.4; case .open: 0.7 }
    }

    /// Springs as Apple specifies them (WWDC23 "Animate with springs"):
    /// perceptual duration + bounce, converted to CA's mass/stiffness/damping.
    /// Growing carries a small bounce so it reads as physical; shrinking is
    /// nearly critically damped — a bounce on the way shut looks indecisive.
    static let growDuration: CFTimeInterval = 0.55
    static let growBounce: CGFloat = 0.15
    static let shrinkDuration: CFTimeInterval = 0.5
    /// A hint of bounce on the way shut — enough that the collapse reads as
    /// the island settling into the housing, not enough to look indecisive.
    static let shrinkBounce: CGFloat = 0.08
    /// Content appears a beat after the shape starts moving, once there is
    /// room for it, and leaves a beat before the shape shrinks. Both are what
    /// separates a morph from a pop.
    static let contentInDelay: CFTimeInterval = 0.14
    static let contentInDuration: CFTimeInterval = 0.34
    static let contentOutDuration: CFTimeInterval = 0.32
    static let contentOutLead: CFTimeInterval = 0.06
    /// Content blurs as it leaves, the way iOS island content does.
    static let contentOutBlur: CGFloat = 8

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
/// Coordinates are CENTRED: x runs from -w/2 to w/2, y from 0 (bottom) to h
/// (top). Every layer in the island uses this frame, anchored at top-centre,
/// so nothing's position depends on the current width — the pill's centre is
/// fixed and its bounds grow symmetrically about it. When positions were
/// measured from the pill's left edge, any two springs that were not
/// bit-identical showed as a horizontal slide mid-animation.
private func islandPath(size: CGSize, cornerRadius r: CGFloat, flare f: CGFloat, closed: Bool = true) -> CGPath {
    let raw = islandPathLeftOrigin(size: size, cornerRadius: r, flare: f, closed: closed)
    var shift = CGAffineTransform(translationX: -size.width / 2, y: 0)
    return raw.copy(using: &shift) ?? raw
}

/// Centred bounds for a pill of `size`, top-centre anchored.
private func islandBounds(_ size: CGSize) -> CGRect {
    CGRect(x: -size.width / 2, y: 0, width: size.width, height: size.height)
}

/// `closed: false` leaves out the top edge — the segment along the screen
/// edge — for stroking: the fill needs it, but a key line drawn there is a
/// seam between the island and the housing, and lightens the island's top so
/// it no longer matches the notch's black.
private func islandPathLeftOrigin(size: CGSize, cornerRadius r: CGFloat, flare f: CGFloat, closed: Bool) -> CGPath {
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
    if closed { path.closeSubpath() }
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
    /// The voice: a Siri-style layered wave — three translucent sine
    /// composites that re-roll toward fresh random shapes as the level
    /// changes (after alfianlosari/SiriWaveView, via Talkify), drawn in the
    /// brand blues. It is the logo, live. Each layer is a CAShapeLayer whose
    /// path is rebuilt on a 30 Hz tick with a fixed point count, so the
    /// implicit path animation morphs it smoothly between ticks.
    private var waveLayers: [CAShapeLayer] = []
    private var waveShapes: [SiriWave] = []
    private var waveTargets: [SiriWave] = []
    private var wavePower: CGFloat = 0
    private var wavePowerTarget: CGFloat = 0
    private var waveTick: Timer?
    private var waveRect: CGRect = .zero
    private var lastReroll: TimeInterval = 0
    /// Elapsed time, right of the wave, as Voice Memos pairs them. Digits
    /// are monospaced so the label doesn't jitter as they tick.
    private let timer = CATextLayer()
    /// SF Symbol glyphs for the non-dictation modes: sparkles for instruct
    /// and working, a check or an x for done.
    private let symbol = CALayer()
    /// The completion mark: a green disc that pops in and a white check that
    /// draws itself on — Apple's own completion gesture (Apple Pay, Shortcuts),
    /// not a static glyph.
    private let checkDisc = CAShapeLayer()
    private let checkStroke = CAShapeLayer()
    /// Status text for working/done ("Refining…", "Done").
    private let label = CATextLayer()
    /// A band of light sweeping through the working label — the system's
    /// "thinking" shimmer — so a wait reads as alive rather than stuck.
    private let shimmer = CAGradientLayer()
    private(set) var mode: IslandMode = .dictate
    /// User setting: show the small clock once a dictation runs long.
    var clockEnabled = true
    private var timerTick: Timer?
    private var recordingStart: Date?
    private enum Wave {
        static let totalWidth: CGFloat = 196
        static let maxHeight: CGFloat = 46
        /// Points per wave path; constant so paths morph.
        static let samples = 48
        /// How often each layer picks a new random composition.
        static let rerollInterval: TimeInterval = 0.3
        /// A whisper of motion at silence, so the wave reads as listening.
        static let idlePower: CGFloat = 0.06
    }
    /// The three wave colours per mode: brand blues for dictation, lavender
    /// for an instruction, so the two still read differently at a glance.
    private enum WavePalette {
        static let dictate: [NSColor] = [
            NSColor(red: 0.44, green: 0.66, blue: 0.86, alpha: 0.85),
            NSColor(red: 0.62, green: 0.77, blue: 0.91, alpha: 0.75),
            NSColor(red: 0.90, green: 0.96, blue: 1.00, alpha: 0.65),
        ]
        static let instruct: [NSColor] = [
            NSColor(red: 0.62, green: 0.50, blue: 0.92, alpha: 0.85),
            NSColor(red: 0.76, green: 0.66, blue: 0.96, alpha: 0.75),
            NSColor(red: 0.94, green: 0.90, blue: 1.00, alpha: 0.65),
        ]
    }
    private enum Text {
        static let font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        static let width: CGFloat = 40
        /// The clock is small and only appears once a dictation runs long
        /// enough that "am I still recording?" becomes a real question.
        static let clockFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        static let clockWidth: CGFloat = 34
        static let clockAfter: TimeInterval = 8
    }
    private enum Tint {
        /// Voice Memos red.
        static let dictate = NSColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1)
        /// The brand accent — a light steel blue — for anything that is the
        /// assistant rather than the recording.
        static let instruct = NSColor(red: 0.62, green: 0.77, blue: 0.91, alpha: 1)
        static let ok = NSColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1)
        static let fail = NSColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1)
    }
    private enum Glyph {
        static let symbolSize: CGFloat = 20
    }
    /// Space between glyph, wave and timer. The three are laid out as one
    /// centred cluster — content pinned to opposite walls read as two
    /// unrelated things.
    private static let clusterGap: CGFloat = 14

    /// Level history for the voice-memo waveform: newest sample on the right,
    /// scrolling left as speech continues — the shape of what was just said,
    /// not merely the current loudness.

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
        shadowLayer.shadowRadius = 10
        shadowLayer.shadowOffset = CGSize(width: 0, height: -5) // downward, y-up space
        layer?.addSublayer(shadowLayer)

        // The pill and its shadow hang from the top-centre of the view. Inside
        // the pill, local y = 0 is the bottom edge and y = h the top; the mask
        // and rim are anchored at bottom-centre, position (0, 0), so their
        // bounds (0...h) coincide with the pill's at every height with no
        // position to animate. See islandPath.
        for l in [pill, shadowLayer] as [CALayer] {
            l.anchorPoint = CGPoint(x: 0.5, y: 1)
        }
        for l in [clip, rim] as [CALayer] {
            l.anchorPoint = CGPoint(x: 0.5, y: 0)
        }

        clip.fillColor = NSColor.black.cgColor
        pill.mask = clip

        // The HIG key line: on a dark desktop a pure-black island vanishes
        // into the wallpaper and the menu bar; a hairline of light along its
        // edge is what separates it. Drawn just inside the outline so the
        // flares keep their crisp meeting with the screen edge.
        rim.strokeColor = NSColor.white.withAlphaComponent(0.14).cgColor
        rim.lineWidth = 1
        rim.lineCap = .butt
        rim.fillColor = NSColor.clear.cgColor
        layer?.addSublayer(pill)

        content.anchorPoint = CGPoint(x: 0.5, y: 1) // scale from the housing edge
        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.name = "blur"
            blur.setValue(0, forKey: kCIInputRadiusKey)
            content.filters = [blur]
        }
        content.opacity = 0
        pill.addSublayer(content)

        for _ in 0..<3 {
            let wave = CAShapeLayer()
            wave.lineWidth = 0
            // Screen-blend so overlaps go lighter, the way stacked light does.
            wave.compositingFilter = "screenBlendMode"
            content.addSublayer(wave)
            waveLayers.append(wave)
            waveShapes.append(SiriWave.random(power: 0))
            waveTargets.append(SiriWave.random(power: 0))
        }


        checkDisc.fillColor = NSColor.systemGreen.cgColor
        checkDisc.isHidden = true
        content.addSublayer(checkDisc)
        checkStroke.strokeColor = NSColor.white.cgColor
        checkStroke.fillColor = NSColor.clear.cgColor
        checkStroke.lineWidth = 2.4
        checkStroke.lineCap = .round
        checkStroke.lineJoin = .round
        checkStroke.isHidden = true
        content.addSublayer(checkStroke)

        symbol.contentsGravity = .resizeAspect
        symbol.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        content.addSublayer(symbol)

        label.font = Text.font
        label.fontSize = Text.font.pointSize
        label.foregroundColor = NSColor.white.cgColor
        label.alignmentMode = .left
        label.truncationMode = .end
        label.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        content.addSublayer(label)

        shimmer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmer.colors = [
            NSColor.white.withAlphaComponent(0.55).cgColor,
            NSColor.white.cgColor,
            NSColor.white.withAlphaComponent(0.55).cgColor,
        ]
        shimmer.locations = [0.35, 0.5, 0.65]

        timer.string = "0:00"
        timer.font = Text.clockFont
        timer.fontSize = Text.clockFont.pointSize
        timer.foregroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
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

    private func path(for size: CGSize, _ s: IslandState, closed: Bool = true) -> CGPath {
        islandPath(size: size, cornerRadius: Island.cornerRadius(s), flare: Island.flare(s), closed: closed)
    }

    /// The pill's current footprint plus hover slop, in view coordinates.
    var hoverRect: CGRect {
        pillFrame(state).insetBy(dx: -Island.hoverSlop(state), dy: -Island.hoverSlop(state))
    }

    /// Where the top-centre of the pill sits in the view. Constant.
    private var pillTop: CGPoint { CGPoint(x: bounds.width / 2, y: bounds.height) }

    func layoutPill(_ s: IslandState, animated: Bool) {
        let growing = Island.chinHeight(s) > Island.chinHeight(state)
        let leavingOpen = state == .open && s != .open
        state = s
        let target = pillFrame(s)
        let targetBounds = islandBounds(target.size)
        let targetPath = path(for: target.size, s)
        let shadowOpacity = Island.shadowOpacity(s)

        guard animated else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for l in [pill, shadowLayer] {
                l.position = pillTop
                l.bounds = targetBounds
            }
            pill.path = targetPath
            for shape in [clip, rim] {
                shape.position = .zero
                shape.bounds = targetBounds
            }
            clip.path = targetPath
            rim.path = path(for: target.size, s, closed: false)
            shadowLayer.shadowPath = targetPath
            shadowLayer.shadowOpacity = shadowOpacity
            layoutContents(s)
            CATransaction.commit()
            return
        }

        let duration = growing ? Island.growDuration : Island.shrinkDuration
        let bounce = growing ? Island.growBounce : Island.shrinkBounce

        // One spring for bounds, one for the outline; nothing has a position
        // to animate. Bounds and path must share the identical spring, or the
        // flares visibly detach from the corners mid-animation.
        let boundsSpring = springAnimation(keyPath: "bounds", duration: duration, bounce: bounce)
        boundsSpring.fromValue = NSValue(rect: pill.bounds)
        boundsSpring.toValue = NSValue(rect: targetBounds)

        let pathSpring = springAnimation(keyPath: "path", duration: duration, bounce: bounce)
        pathSpring.fromValue = pill.path
        pathSpring.toValue = targetPath

        // The rim strokes the outline minus the top edge; same spring, its
        // own (unclosed) path.
        let rimPath = path(for: target.size, s, closed: false)
        let rimSpring = springAnimation(keyPath: "path", duration: duration, bounce: bounce)
        rimSpring.fromValue = rim.path
        rimSpring.toValue = rimPath

        let shadowSpring = springAnimation(keyPath: "shadowPath", duration: duration, bounce: bounce)
        shadowSpring.fromValue = shadowLayer.shadowPath
        shadowSpring.toValue = targetPath

        // Leaving the open state: content melts first, then the container
        // follows. Shrinking everything at once is what reads as "sudden" —
        // Apple's islands always retire the content a beat before the shape.
        let contentLead: CFTimeInterval = leavingOpen ? Island.contentOutLead : 0
        for anim in [boundsSpring, pathSpring, shadowSpring, rimSpring] {
            anim.beginTime = CACurrentMediaTime() + contentLead
            anim.fillMode = .backwards
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        pill.bounds = targetBounds
        pill.path = targetPath
        pill.add(boundsSpring, forKey: "bounds")
        pill.add(pathSpring, forKey: "path")
        for shape in [clip, rim] {
            shape.bounds = targetBounds
            shape.add(boundsSpring, forKey: "bounds")
        }
        clip.path = targetPath
        clip.add(pathSpring, forKey: "path")
        rim.path = rimPath
        rim.add(rimSpring, forKey: "path")
        // The shadow is a sibling layer (the pill would clip its own shadow).
        shadowLayer.bounds = targetBounds
        shadowLayer.shadowPath = targetPath
        shadowLayer.shadowOpacity = shadowOpacity
        shadowLayer.add(boundsSpring, forKey: "bounds")
        shadowLayer.add(shadowSpring, forKey: "shadowPath")
        layoutContents(s)
        CATransaction.commit()
    }

    /// Content lives in the chin, strictly below the housing — which, in this
    /// bottom-up coordinate space, is the LOWER part of the pill rect. The
    /// housing occupies the top `safeAreaTop` points.
    private func layoutContents(_ s: IslandState) {
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
        // it. x = 0 is the pill's centre line, always.
        let chinSize = CGSize(width: pillFrame(.open).width, height: Island.chinHeight(.open))
        content.bounds = CGRect(origin: .zero, size: chinSize)
        content.position = CGPoint(x: 0, y: Island.chinHeight(.open))

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
            content.setValue(0, forKeyPath: "filters.blur.inputRadius")
            if animating {
                let unblur = CABasicAnimation(keyPath: "filters.blur.inputRadius")
                unblur.fromValue = Island.contentOutBlur
                unblur.toValue = 0
                unblur.duration = fade.duration
                unblur.beginTime = fade.beginTime
                unblur.fillMode = .backwards
                unblur.timingFunction = fade.timingFunction
                content.add(fade, forKey: "opacity")
                content.add(unfold, forKey: "transform")
                content.add(unblur, forKey: "blur")
            }
            CATransaction.commit()
        } else {
            let out = animating ? Island.contentOutDuration : 0
            CATransaction.begin()
            CATransaction.setAnimationDuration(out)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.4, 0, 0.6, 1))
            // Content is drawn up into the housing as it goes: it shrinks
            // about the housing edge (its anchor), blurs and fades — the iOS
            // island's exit, not a fade in place.
            content.opacity = 0
            content.transform = CATransform3DMakeScale(0.7, 0.7, 1)
            content.setValue(Island.contentOutBlur, forKeyPath: "filters.blur.inputRadius")
            CATransaction.commit()
            wavePowerTarget = 0
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

        // Tint everything that carries the mode colour.
        let tint: NSColor
        switch mode {
        case .dictate: tint = Tint.dictate
        case .instruct: tint = Tint.instruct
        case .working: tint = Tint.instruct
        case .done(let ok): tint = ok ? Tint.ok : Tint.fail
        }
        let palette = mode == .instruct ? WavePalette.instruct : WavePalette.dictate
        for (i, wave) in waveLayers.enumerated() { wave.fillColor = palette[i].cgColor }
        // The clock reads in white beside a coloured wave; the record glyph
        // keeps its red — the one universally understood "recording" cue.
        timer.foregroundColor = NSColor.white.withAlphaComponent(0.92).cgColor

        // Which members are present.
        // Recording modes are the wave and the clock, nothing else: the wave
        // is the recording indicator. Glyphs belong to working/done.
        let isCheck = mode == .done(ok: true)
        symbol.isHidden = recording || isCheck
        checkDisc.isHidden = !isCheck
        checkStroke.isHidden = !isCheck
        for wave in waveLayers { wave.isHidden = !recording; wave.opacity = 1 }
        timer.isHidden = !recording
        // Starts invisible; updateTimer fades it in after Text.clockAfter.
        timer.opacity = 0
        symbol.opacity = 1
        label.isHidden = recording

        // Symbol image + label text for the mode.
        let symbolName: String
        var text = ""
        switch mode {
        case .dictate: symbolName = ""
        case .instruct: symbolName = "sparkles"
        case .working(let s, let sym): symbolName = sym; text = s
        case .done(let ok): symbolName = ok ? "" : "xmark.circle.fill"; text = ok ? "Done" : "Couldn't do that"
        }
        if !symbolName.isEmpty {
            symbol.contents = symbolImage(symbolName, size: Glyph.symbolSize, color: tint)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        label.string = text
        CATransaction.commit()

        // Measure the cluster: recording = wave · clock; otherwise glyph · label.
        let glyphWidth = Glyph.symbolSize
        let labelWidth = text.isEmpty ? 0 : ceil((text as NSString).size(withAttributes: [.font: Text.font]).width) + 2
        let clusterWidth = recording ? Wave.totalWidth : glyphWidth + gap + labelWidth
        var x = (chinSize.width - clusterWidth) / 2

        if !recording {
            let glyphRect = CGRect(x: x, y: midY - glyphWidth / 2, width: glyphWidth, height: glyphWidth)
            symbol.frame = glyphRect
            if isCheck {
                layoutCheck(in: glyphRect)
            }
            x += glyphWidth + gap
        }

        if recording {
            waveRect = CGRect(x: x, y: midY - Wave.maxHeight / 2, width: Wave.totalWidth, height: Wave.maxHeight)
            for wave in waveLayers { wave.frame = waveRect }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            redrawWaves()
            CATransaction.commit()
            // The clock sits at the right margin, off the wave, so its arrival
            // moves nothing.
            let clockHeight = ceil(Text.clockFont.ascender - Text.clockFont.descender)
            timer.frame = CGRect(
                x: chinSize.width - Island.flare(.open) - 12 - Text.clockWidth,
                y: midY - clockHeight / 2 - 1,
                width: Text.clockWidth,
                height: clockHeight
            )
        } else {
            label.frame = CGRect(x: x, y: midY - textHeight / 2 - 1, width: labelWidth, height: textHeight)
        }

        // Working: the sparkle breathes and light sweeps through the label, so
        // a long call still reads as alive.
        if case .working = mode {
            // The gradient is three label-widths wide and slides one width per
            // cycle, so the bright band crosses the text left to right.
            let w = max(labelWidth, 1)
            shimmer.frame = CGRect(x: -w, y: 0, width: w * 3, height: label.bounds.height)
            label.mask = shimmer
            if shimmer.animation(forKey: "sweep") == nil {
                let sweep = CABasicAnimation(keyPath: "position.x")
                sweep.fromValue = shimmer.position.x - w
                sweep.toValue = shimmer.position.x + w
                sweep.duration = 1.4
                sweep.repeatCount = .infinity
                sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                shimmer.add(sweep, forKey: "sweep")
            }
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
            shimmer.removeAnimation(forKey: "sweep")
            label.mask = nil
        }
    }

    /// Place the completion mark in `rect` and play it: disc pops (scale
    /// 0.5 → 1 with a small overshoot), then the check strokes on over
    /// 0.28s. Re-layout while showing does not replay.
    private func layoutCheck(in rect: CGRect) {
        let d = rect.width
        checkDisc.frame = rect
        checkDisc.path = CGPath(ellipseIn: CGRect(origin: .zero, size: rect.size), transform: nil)
        checkStroke.frame = rect
        // Check geometry in the disc's local space (y-up): short stroke down
        // to the elbow, long stroke up to the tip.
        let p = CGMutablePath()
        p.move(to: CGPoint(x: d * 0.28, y: d * 0.52))
        p.addLine(to: CGPoint(x: d * 0.44, y: d * 0.35))
        p.addLine(to: CGPoint(x: d * 0.73, y: d * 0.66))
        checkStroke.path = p

        guard checkDisc.animation(forKey: "pop") == nil else { return }
        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.5
        pop.toValue = 1
        pop.mass = 1; pop.stiffness = 320; pop.damping = 18
        pop.duration = pop.settlingDuration
        checkDisc.add(pop, forKey: "pop")

        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = 0.28
        draw.beginTime = CACurrentMediaTime() + 0.08
        draw.fillMode = .backwards
        draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
        checkStroke.strokeEnd = 1
        checkStroke.add(draw, forKey: "draw")
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
    /// How long the wave takes to settle on release before the next mode is
    /// revealed. This is the "event" of stopping: without it the wave simply
    /// evaporated and the release felt like nothing happened.
    private static let releaseSettle: CFTimeInterval = 0.34
    private var modeGeneration = 0

    func setMode(_ m: IslandMode) {
        guard m != mode else { return }
        let wasRecording = mode.isRecording
        mode = m
        modeGeneration += 1
        let generation = modeGeneration
        if m.isRecording {
            if !wasRecording { startRecording() }
        } else {
            stopRecording()
        }

        let reveal = { [weak self] in
            guard let self, self.modeGeneration == generation else { return }
            let chinSize = CGSize(width: self.pillFrame(.open).width, height: Island.chinHeight(.open))
            if self.state == .open {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.22
                self.content.add(fade, forKey: "mode")
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.layoutCluster(in: chinSize)
            CATransaction.commit()
        }

        // Recording → anything else while open: let the wave settle first.
        // Bars fall to the midline, timer and glyph fade; then reveal.
        guard wasRecording, !m.isRecording, state == .open else {
            reveal()
            return
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.releaseSettle)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        // The wave drains to a still line; the tick keeps
        // running through the settle so the drain is drawn, not cut.
        wavePowerTarget = 0
        for wave in waveLayers { wave.opacity = 0.35 }
        timer.opacity = 0
        symbol.opacity = 0
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.releaseSettle * 0.85, execute: reveal)
    }

    /// Mic level, 0...1, at ~24 Hz. Sets the wave's power target and the
    /// the 30 Hz tick eases toward it.
    func setLevel(_ level: CGFloat) {
        // Levels can trail the stop by a few callbacks; once the mode has left
        // recording they must not fight the wave's settle.
        guard state == .open, mode.isRecording else { return }
        let l = max(0, min(level, 1))
        wavePowerTarget = Wave.idlePower + (1 - Wave.idlePower) * l
    }

    /// One frame of wave motion: ease power and each layer's composition
    /// toward their targets, re-roll targets on the interval, redraw.
    private func tickWaves() {
        let now = CACurrentMediaTime()
        wavePower += (wavePowerTarget - wavePower) * 0.25
        if now - lastReroll > Wave.rerollInterval {
            lastReroll = now
            for i in waveTargets.indices { waveTargets[i] = SiriWave.random(power: 1) }
        }
        for i in waveShapes.indices { waveShapes[i].ease(toward: waveTargets[i], by: 0.18) }
        CATransaction.begin()
        CATransaction.setAnimationDuration(1.0 / 30.0)
        redrawWaves()
        CATransaction.commit()
        // Stop ticking once drained and idle.
        if !mode.isRecording, wavePower < 0.005 {
            waveTick?.invalidate(); waveTick = nil
        }
    }

    private func redrawWaves() {
        guard waveRect.width > 0 else { return }
        let size = waveRect.size
        for (i, wave) in waveLayers.enumerated() {
            wave.path = waveShapes[i].path(in: size, power: wavePower, phaseShift: Double(i) * 0.9)
        }
    }

    private func startWaveTick() {
        waveTick?.invalidate()
        waveTick = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tickWaves()
        }
    }

    /// A fresh recording starts with a still wave and 0:00, not the tail of
    /// the last one.
    func startRecording() {
        wavePower = 0
        wavePowerTarget = Wave.idlePower
        startWaveTick()
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
        wavePowerTarget = 0
        // Keep ticking so the drain is drawn; tickWaves stops itself once still.
        if waveTick == nil { startWaveTick() }
    }

    private func updateTimer() {
        guard let start = recordingStart else { return }
        let seconds = Date().timeIntervalSince(start)
        let elapsed = Int(seconds)
        let text = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
        // Text changes must not cross-fade; a ticking clock should just tick.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        timer.string = text
        CATransaction.commit()
        if clockEnabled, seconds >= Text.clockAfter, timer.opacity == 0, mode.isRecording {
            timer.opacity = 1 // implicit fade
        }
    }
}

// MARK: - Siri wave

/// One sine component: amplitude, frequency, phase.
private struct SiriCurve {
    var a: Double, k: Double, t: Double
    static func random() -> SiriCurve {
        SiriCurve(a: .random(in: 0.2...1.0), k: .random(in: 0.6...0.9), t: .random(in: -1.0...4.0))
    }
    mutating func ease(toward o: SiriCurve, by f: Double) {
        a += (o.a - a) * f; k += (o.k - k) * f; t += (o.t - t) * f
    }
}

/// A composition of four curves. `path` renders it as a closed shape mirrored
/// about the midline, attenuated toward the ends so it tapers like the mark.
private struct SiriWave {
    var curves: [SiriCurve]
    static func random(power: Double) -> SiriWave {
        SiriWave(curves: (0..<4).map { _ in SiriCurve.random() })
    }
    mutating func ease(toward o: SiriWave, by f: Double) {
        for i in curves.indices { curves[i].ease(toward: o.curves[i], by: f) }
    }
    func path(in size: CGSize, power: CGFloat, phaseShift: Double) -> CGPath {
        let n = 48
        let w = Double(size.width), h = Double(size.height)
        let midY = h / 2
        let amp = Double(power) * midY * 0.95
        var top: [CGPoint] = []
        top.reserveCapacity(n + 1)
        for i in 0...n {
            let u = Double(i) / Double(n)          // 0...1
            let x = (u * 2 - 1) * 2                // -2...2 like the original
            let att = pow(4 / (4 + pow(x, 4)), 4)  // bell envelope
            var y = 0.0
            for c in curves { y += c.a * sin(c.k * x * .pi + c.t + phaseShift) }
            y = y / Double(curves.count) * att * amp
            top.append(CGPoint(x: u * w, y: midY + y))
        }
        let p = CGMutablePath()
        p.move(to: top[0])
        for pt in top.dropFirst() { p.addLine(to: pt) }
        for pt in top.reversed() { p.addLine(to: CGPoint(x: pt.x, y: 2 * midY - pt.y)) }
        p.closeSubpath()
        return p
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

    func setClock(_ enabled: Bool) {
        guard let (_, view) = ensurePanel() else { return }
        view.clockEnabled = enabled
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
        // Once shut, forget the last mode so the next open — even another
        // "done" — lays out and animates fresh. setMode ignores same-mode
        // calls, so without this a second refine in a row would not replay
        // the completion mark.
        DispatchQueue.main.asyncAfter(deadline: .now() + Island.shrinkDuration + 0.1) { [weak self] in
            guard let self, !self.recording, let view = self.view, view.state != .open else { return }
            view.setMode(.dictate)
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
    case 2: m = .working("Transcribing…", symbol: "text.alignleft")
    case 3: m = .working("Refining…", symbol: "sparkles")
    default: m = .dictate
    }
    DispatchQueue.main.async { IslandController.shared.setMode(m) }
}

/// Show or hide the small long-dictation clock (user setting).
@_cdecl("notch_overlay_set_clock")
public func notch_overlay_set_clock(_ enabled: Int32) {
    DispatchQueue.main.async { IslandController.shared.setClock(enabled != 0) }
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
