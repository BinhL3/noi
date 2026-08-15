# Notch / Dynamic Island UI design — research notes

Researched 2026-08-14 against primary sources. Every claim carries a source. Claims
are tagged **[verified]** (read directly in the source) or **[inference]** (my
reading of a screenshot / changelog wording / arithmetic). Numbers pulled from
Swift source are the strongest evidence here; Alcove is closed-source, so its
specifics come from its changelog, marketing image and press.

Scope: distil concrete specs for our native AppKit/CALayer island in
`handy/src-tauri/swift/notch_overlay.swift`.

---

## 0. TL;DR — recommended spec for our island

| Parameter | Recommendation | Basis |
|---|---|---|
| Collapsed silhouette | Exactly the housing: width = `screen.frame.width − auxiliaryTopLeftArea.width − auxiliaryTopRightArea.width` (+2–4 pt to hide bezel seams), height = `safeAreaInsets.top`. Fill pure black. | boring.notch `getClosedNotchSize` (+4), DynamicNotchKit `notchSize`; HIG "black opaque background" |
| Top-edge flare (concave fillet) | 6 pt closed → 15–19 pt open. Quad curve from screen edge to wall. | boring.notch `cornerRadiusInsets` closed.top 6 / opened.top 19; DynamicNotchKit compact 6 / expanded 15 |
| Bottom corner radius | 14 pt closed → 20–24 pt open. Roughly **0.35–0.45 × collapsed height** closed; open radius = flare + ~5. Ratio bottom:top ≈ 1.25–2.3. | boring.notch closed.bottom 14 / opened.bottom 24; DynamicNotchKit 14 / 20; Apple iOS island 44 pt radius on a 36.67 pt tall compact island (radius > half height → full round ends) |
| Corner curve | Use continuous (squircle) curvature where you can (`CALayer.cornerCurve = .continuous`); iOS island corners "match the TrueDepth camera". A quad-curve fillet is what both open-source notch apps actually ship. | HIG Live Activities; CALayerCornerCurve docs |
| Expansion | Grow **outward and downward** with the top edge pinned to the screen edge; open width ≫ closed (boring: 640 pt open vs ~185–200 closed; DynamicNotchKit adds 15 pt safe-area inset each side plus content). Content appears with scale-from-top + opacity (+ blur) rather than a hard resize. | boring.notch `openNotchSize`, `.transition(.scale(0.8, anchor:.top).combined(with:.opacity))`; DynamicNotchKit `.blur(10) + .scale(y:0.6, anchor:.top) + .opacity` |
| Open spring | `perceptualDuration ≈ 0.40–0.42 s, bounce ≈ 0.15–0.30` (SwiftUI `.bouncy(duration:0.4)` = bounce 0.3; boring `spring(response:0.42, dampingFraction:0.8)` ≈ bounce 0.2). CA equivalent: mass 1, stiffness (2π/d)², damping 4π(1−bounce)/d. | WWDC23 "Animate with springs"; SwiftUI docs; boring.notch; DynamicNotchKit |
| Close spring | `duration ≈ 0.40–0.45 s, bounce 0` (critically damped). Both open-source apps close with **no** bounce. | boring `spring(response:0.45, dampingFraction:1.0)`; DynamicNotchKit `.smooth(duration:0.4)`; WWDC18 "start with 100% damping" |
| Hover | Slight lift on hover-enter (haptic + shadow up + content padding grows 12 pt); open after a **0.3 s** dwell (default, user-tunable); close **100 ms** after hover-exit. Hover hit-area extends 30 pt beyond the pill (10 pt when the pill is 0-height). | boring.notch `minimumHoverDuration` 0.3, `handleHover`, `extendedHoverPadding` 30 |
| Shadow | Only when open/hovered: black @ 0.5–0.7 opacity, radius 6–10 (20 on hover). Collapsed = no shadow (it must read as hardware). | boring `.shadow(.black.opacity(0.7), radius: 6)` gated on open/hover; DynamicNotchKit 0.5/10 → 0.8/20 hover; Alcove "Reduced elevated shadow opacity" |
| Content padding | Open: horizontal inset = top flare radius (19) plus 12 pt all sides; DynamicNotchKit: 15 pt sides/bottom, and top inset = housing height. Compact wings: 8 pt outer, 4 pt top, 8 pt bottom, **zero** padding against the camera. | boring `NotchLayout()` padding; DynamicNotchKit `safeAreaInset`; HIG "don't add padding between content and the TrueDepth camera" |
| Type | macOS text styles: Headline 13 bold, Body 13, Subheadline 11, Caption 10; medium weight or heavier; boring uses 12–14 pt medium for HUD labels and `.headline` rounded for its header. Never below 10 pt. | HIG Typography macOS table; HIG Live Activities "medium weight or higher"; boring.notch fonts |
| Order-out | Wait for the close spring's **perceptual duration** (≈0.4 s), not `settlingDuration`; Apple explicitly says not to wait for settling. Our current 0.32 s is shorter than our own close spring's perceptual duration (0.34 s) — see §6. | WWDC23 "Animate with springs" |
| Waveform | 4 bars × 2 pt wide, 2 pt gap, 14 pt tall, rounded caps, ~0.3 s update timer in boring; Alcove ships a "live waveform (0–1% total CPU)" that it reworked to be "truly 1:1 with iOS". | boring `MusicVisualizer.swift`; Alcove changelog 1.7.x |
| Window | `NSPanel`, borderless + nonactivating, `level = .mainMenu + 3` (boring) or `.statusBar` (ours), `hasShadow = false`, `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`, panel never resizes — only layers move. | boring `BoringNotchWindow.swift`; ours |

---

## 1. Alcove (tryalcove.com)

Closed source, sold direct ($14.99 one-time via Stripe, 72 h trial, no App Store
listing) — https://tryalcove.com/ , https://tryalcove.com/faqs **[verified]**.
Developer Henrik Ruscon; first public release Nov 2024
(https://tryalcove.com/changelog 1.0.x entries; https://macsources.com/alcove-for-mac-a-truly-native-looking-mac-app/).
The changelog is rendered from `https://api.tryalcove.com/changelog` (JSON) — that
is where the entries below were read **[verified]**.

### 1.1 What the landing page says (little)
- Feature words: "Fluid transitions", "Instant Notifications", "Live Activities",
  "Swipe gestures", "Customizable HUDs", "Lock Screen Widgets", "Blazing fast
  native app", "Psst… it's interactive!" — https://tryalcove.com/ **[verified]**.
- Meta keywords: "macos, swift, macos app, … dynamic, island, notch, media,
  controls, hud, interface" — it is a Swift app **[verified]**.
- The site loads a `squircle-*.js` module and uses a custom `--ease-spring:
  cubic-bezier(.34, 1.2, .64, 1)` (overshoot ease) for its own hover effects
  (`/assets/style-B05buE_1.css`) **[verified, web only — not the Mac app]**.
- Marketing image (https://tryalcove.com/images/meta.png): a floating black
  **pill** (all four corners rounded, radius ≈ 0.25 × height) hanging from the
  top of a lock-screen wallpaper with a white SF `lock.fill` glyph on the leading
  side and empty trailing side. This is the notchless/lock-screen "pill" look,
  not the notch-fused look **[inference from screenshot]**.

### 1.2 Design facts recoverable from the changelog (https://tryalcove.com/changelog) — all **[verified quotes]**

Shape / fusing with the housing
- 1.0.2 "Added ability to fine tune notch height"; 1.3.x "Added notch width fine
  tuning" and "Improved padding with fine tuned notch height" → the island's
  rest silhouette is user-calibrated to the physical cutout.
- 1.0.2 "Increased safe padding around notch area"; 1.2.0 "Fixed expanded notch
  padding for MacBook Air with notch".
- 1.3.x "Fixed rounded inset corners on notch (macOS Tahoe)"; 1.7.3 "Improved
  notch shape", "Fixed notch radius inset bug"; 1.7.0-era "Improved notch radius
  logic"; "Increased notch radius for notifications", "Increased corner radius
  for notifications" → the corner radius is **state-dependent** (bigger when a
  notification/expanded view is showing).
- 1.7.x "Reduced width of simulated notch", "Added simulated notch toggle",
  "Restored simulated notch hide logic", 1.7.1 note: "For those who preferred
  the notch over the pill, you can now force enable the simulated notch."
- 1.7.0 "Added pill shape for notchless displays"; later "Decreased pill width",
  "Fixed pill hitbox", "Improved pill hide/show animation", "Fixed top edge
  interaction for pill shape press/hover".
- 1.7.x "Added contrast outline (macOS 26+)", "Added colored outline support",
  "Added compact outline support", "Improved outline sampling", "Improved outline
  visibility" → a key-line/outline around the island whose colour is sampled from
  what's beneath — mirrors HIG "key line appears around the Dynamic Island" in
  dark contexts (see §3).
- 1.6.x "Added progressive blur"; later "Removed progressive blur toggle
  (enforced)", "Fixed progressive blur thin edge", "Fixed progressive blur capture
  related issues" → the expanded island sits on a captured, progressively-blurred
  backdrop rather than flat black (Tahoe glass era). 1.7.8 "Fixed issue where
  glass prevented toggle", "Improved clear glass".
- "Reduced elevated shadow opacity", "Fixed shadow glitch" → it does draw an
  elevated shadow when raised.

States and interaction
- 1.1.0 "Added hover duration option for expand on hover" → **hover-to-expand
  with a user-set dwell**. Also "Fixed incorrect padding on for click expand"
  (click-to-expand exists), "Added disable expand while inactive option",
  "Changed to expand when lacking activity action".
- "Quick Peek"/"QuickPeek": a hover preview state (entries: "Fixed Quick Peek
  album art hover scale while disabled", "Increased hover area for album art and
  waveform", "Added swipe to dismiss QuickPeek", "Disabled haptic for Quick Peek
  if it's disabled") → hover gives a light peek + haptic before full expand
  **[inference from names]**.
- Swipes: 1.0.x "Fixed natural scrolling for swipe gestures"; 1.1.0 "Added
  natural movement option for swipes"; 1.3.x "Added swipe down while expanded";
  1.6.x "Added swipe down to cycle expanded activity", "Increased swipe threshold
  for cycle", "Limited swipe to one action per swipe", "Prevented swipes on
  mouse" (trackpad only), "Improved swipe to expand animation to blur".
- 1.5.0 "Reworked Alcove to fully match Tahoe style", "Added multiple live
  activity support"; 1.7.0 "Added duo mode" (two activities side by side).
- HUD: "Added HUD overshoot" (1.6.x), "Tweaked overshoot visuals", "Removed
  overshoot HDR glow", "Improved HUD to close faster when overshooting", "Changed
  to allow single press overshoot while hud is already open" → volume/brightness
  HUD physically overshoots the notch on key repeat.
- Timing: 1.1.0 "Lowered default HUD duration", "Lowered notification default
  duration"; "Fixed expand interaction delay", "Fixed cycle interaction delay",
  "Fixed race condition hover freeze".
- Idle: "Optimized Alcove to prefer lower frame rate while in idle"; 1.6.0 "Added
  idle activity option"; "Fixed now playing idle".

Content placement
- Now playing: album art on one wing, waveform on the other in compact; expanded
  has artwork, marquee title, gradient progress slider ("Fixed slider color change
  animation", "Improved seeker progress animations"), skips ("Fixed skips…"),
  shuffle/repeat (1.2.0), "Improved padding for artwork on simulated notch",
  "Improved artwork radius logic", "Constrained album art height size".
- Waveform: 1.7.x "Added live waveform (0-1% Total CPU)", "Reworked waveform to
  visually match iOS", "Removed waveform style options", "Improved waveform
  visuals to be truly 1:1 with iOS", "Added replace waveform with focus mode",
  "Improved transition between waveform and other symbols".
- Marquee: 1.1.0 "Improved marquee design to better match iOS", "Fixed marquee
  clipping text", "Improved marquee symbol sharpness (non-retina)".
- Timers: calendar countdowns — "Improved countdown animation", "Fixed countdown
  0s bug", "Fixed reverse progress also reversing hourglass", "Fixed remaining
  time animation", 1.4 "time to leave notifications".
- Notifications in the notch: battery, connectivity (AirPods), focus, display,
  sound; "Prevented expanded from overlapping with notifications"; "Fixed
  animation from QuickPeek to notification".

### 1.3 Press on Alcove's feel
- "It just gently fades in when you need it and fades out when you don't … It
  never tries to sit in one fixed place on your screen. There's no big window or
  bloated UI." — developer quoted at
  https://medium.com/@teslathewest/the-story-behind-alcove-macos-dynamic-island-app-dadb5d97e8b0 **[verified]**.
- "looks and runs like it's built into macOS", "Fluid animations and transitions" —
  https://macsources.com/alcove-for-mac-a-truly-native-looking-mac-app/ **[verified]**.
- MacSources says Alcove "sticks to the functionality Apple built into the
  Dynamic Island, and nothing more" **[verified]**.

### 1.4 Competitor idiom docs
- NotchNook (https://lo.cafe/notchnook): configurable to open "with a click, with
  a hover, with a swipe" (per https://www.howtogeek.com/these-apps-turn-your-macbook-notch-into-a-dynamic-island/);
  "did i tell you you can scroll swipe and it works deliciously?"; on notchless
  Macs "it turns into a nice handler with the exact same functions" **[verified]**.
- Boring Notch (HowToGeek): compact = "small live activity preview with album art
  and a 'Now Playing' animation on either side of the notch"; "Hover the area to
  see more details and playback controls" **[verified]**.

---

## 2. Boring Notch and DynamicNotchKit — concrete numbers from Swift (PRIMARY)

Repos: https://github.com/TheBoredTeam/boring.notch (clone at commit
`71e50d8`, 2026-08-08) and its shape's origin
https://github.com/MrKai77/DynamicNotchKit (commit `cd0b3e5`, 2026-02-18).
All **[verified]** by reading the files named.

### 2.1 Notch shape path (`boringNotch/components/Notch/NotchShape.swift`, from DynamicNotchKit `Views/NotchShape.swift`)
- Two radii, both animatable: `topCornerRadius` (default 6) = the **concave
  flare** at the screen edge, `bottomCornerRadius` (default 14) = convex bottom
  round.
- Path: `move(minX,minY)` → `addQuadCurve(to: (minX+top, minY+top), control:
  (minX+top, minY))` (concave fillet) → line down the wall → `addQuadCurve(to:
  (minX+top+bottom, maxY), control: (minX+top, maxY))` (bottom round) → mirror.
  Note the wall sits at `x = top` — the flare is *added outside* the body, so
  total width = body + 2×top.
- Preview frame: 200 × 32 with (6, 14).

### 2.2 Sizes (`boringNotch/sizing/matters.swift`)
- `openNotchSize = 640 × 190`; `shadowPadding = 20`; window = 640 × 210.
- `cornerRadiusInsets = (opened: (top: 19, bottom: 24), closed: (top: 6, bottom: 14))`.
- Album art radius 13 open / 4 closed; art 90×90 open, 20×20 closed.
- Closed width: `screen.frame.width − auxiliaryTopLeftArea.width −
  auxiliaryTopRightArea.width + 4` (2 pt over each side); default width 185 if
  unknown. Closed height: `safeAreaInsets.top` in "match real notch" mode, or
  menu-bar height (`frame.maxY − visibleFrame.maxY`), or user value
  (`notchHeight` default 32, `nonNotchHeight` default 32 — `models/Constants.swift`).
- Compact wing content sizes: album art / visualizer are squares of
  `closedHeight − 12`; compact width grows by `2×(closedHeight−12) + 20`
  (`ContentView.computedChinWidth`).

### 2.3 Animation (`boringNotch/ContentView.swift`, `animations/drop.swift`)
- Open: `Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)`.
- Close: `Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)`
  — **critically damped close**.
- Hover/gesture/scale: `interactiveSpring(response: 0.38, dampingFraction: 0.8)`.
- Library default: `.spring(.bouncy(duration: 0.4))` on macOS 14+, else
  `timingCurve(0.16, 1, 0.3, 1, duration: 0.7)`.
- Expanded content: `.transition(.scale(scale: 0.8, anchor: .top).combined(with:
  .opacity).animation(.smooth(duration: 0.35)))`; header/blur reveal:
  `.blur(radius: closed ? 20 : 0)`.
- Gesture pull: `scaleEffect(1 + gestureProgress*0.01, anchor: .top)`, floor 0.6.
- Shadow: `.shadow(color: (open || hovering) && enableShadow ? .black.opacity(0.7)
  : .clear, radius: cornerRadiusScaling ? 6 : 4)`.
- A 1-pt black `Rectangle` overlaid along the top edge, inset by
  `topCornerRadius`, hides the anti-aliased seam against the bezel.
- Content padding when open: horizontal `cornerRadiusInsets.opened.top` (19)
  then `.padding([.horizontal, .bottom], 12)`; closed: horizontal
  `closed.bottom` (14), no extra.

### 2.4 Hover logic (`ContentView.handleHover`)
- On enter: `withAnimation(animationSpring) { isHovering = true }`, haptic
  (`.sensoryFeedback(.alignment)`) if closed; then `Task.sleep(minimumHoverDuration)`
  (default **0.3 s**, `Constants.swift:79`) and open if still hovering & closed
  & no sneak-peek showing & `openNotchOnHover`.
- On exit: sleep **100 ms**, then un-hover and close if open.
- Hover padding constants: `extendedHoverPadding = 30`, `zeroHeightHoverPadding = 10`.
- Down-pan gesture: `gestureSensitivity` default 200 pt; opens when translation
  exceeds it; up-pan closes.
- Hovering the closed notch grows the inline HUD wing from `height−12` to full
  height (`InlineHUD.swift`: `.frame(width: 100 − (hover ? 0 : 12) …, height:
  notchSize.height − (hover ? 0 : 12))`) — i.e. a **12 pt hover-expand delta**.

### 2.5 Window (`BoringNotchWindow.swift`)
- `NSPanel`, `isFloatingPanel`, `isOpaque=false`, clear background,
  `level = .mainMenu + 3`, `hasShadow = false`, `collectionBehavior =
  [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]`,
  `canBecomeKey = false`.

### 2.6 Waveform / HUD (`components/Music/MusicVisualizer.swift`, `InlineHUD.swift`, `OpenNotchHUD.swift`)
- 4 bars, 2 pt wide, 2 pt spacing, 14 pt tall, `CAShapeLayer` rounded caps
  (`xRadius = barWidth/2`), initial scale 0.35, `Timer` 0.3 s.
- Fonts: HUD label `.subheadline .medium`, values `.caption`; open HUD
  `.system(size: 14, weight: .medium)` / 13 / 12; header `.headline` rounded;
  system-event value `.system(size:12, weight:.medium)`.
- Symbols use `.contentTransition(.interpolate)` / `.numericText()`.

### 2.7 DynamicNotchKit defaults (`Sources/DynamicNotchKit/...`)
- `DynamicNotchStyle.notch = .notch(topCornerRadius: 15, bottomCornerRadius: 20)`;
  `.floating(cornerRadius: 20)`. Doc comment: **"Outer Radius = Inner Radius +
  Padding"** (`DynamicNotchStyle.swift`).
- `NotchView`: compact radii `(6, 14)`, expanded from style; `minWidth =
  notchSize.width + 2×topCornerRadius`; expanded content `safeAreaInset` 15 pt
  sides/bottom, top inset = `notchSize.height`; compact wings 8 pt outer, 4 pt
  top, 8 pt bottom; the black background is `.padding(-50)` "The opening/closing
  animation can overshoot, so this makes sure that it's still black".
- Animations (`DynamicNotchStyle.swift`): opening `.bouncy(duration: 0.4)` for
  notch style / `.snappy(duration: 0.4)` for floating; closing `.smooth(duration:
  0.4)`; compact↔expanded conversion `.snappy(duration: 0.4)`; hover shadow
  change `.snappy(duration: 0.4)`.
- Transitions: compact wing `.blur(intensity: 10) + .scale(x: 0, anchor:
  trailing/leading) + .opacity`; expanded `.blur(10) + .scale(y: 0.6, anchor: .top)
  + .opacity`.
- Shadow (`NotchContentView.swift`): opacity 0.5 expanded / 0 otherwise / 0.8 on
  hover; radius 10 (20 on hover, 0 hidden). Hover behaviours: `.keepVisible`,
  `.hapticFeedback`, `.increaseShadow`.
- Notch detection (`NSScreen+Extensions.swift`): `hasNotch = auxiliaryTopLeftArea
  != nil && auxiliaryTopRightArea != nil`; height `safeAreaInsets.top`;
  notchless fallback frame 300 × menubarHeight.

---

## 3. Apple: Dynamic Island / Live Activities design language

### 3.1 HIG "Live Activities" (https://developer.apple.com/design/human-interface-guidelines/live-activities) **[verified]**
- Presentations: **compact** (leading + trailing halves around the camera),
  **minimal** (attached circle/oval + detached one), **expanded** (touch-and-hold),
  Lock Screen; on Mac, Live Activities appear "in the Menu bar … using the
  compact, minimal, and expanded presentations".
- Sizes (pt): compact leading/trailing **62.33 × 36.67** (430×932 screen) or
  **52.33 × 36.67** (393×852); minimal **36.67–45 × 36.67**; expanded **408 ×
  84–160** / **371 × 84–160**. Island widths: compact/minimal **250** (Pro Max /
  Plus / Air) or **230** (Pro / base); expanded **408** or **371**.
- **"The Dynamic Island uses a corner radius of 44 points, and its rounded corner
  shape matches the TrueDepth camera."**
- "Live Activities in the Dynamic Island use a black opaque background."
- Key line: "When the background is dark … a key line appears around the Dynamic
  Island to distinguish it from other content" — tint it to your content.
- Margins: "Use consistent margins and concentric placement … match its corner
  radius to the outer corner radius of the Live Activity by subtracting the
  margin" (`ContainerRelativeShape`). Lock Screen standard margin **14 pt**.
- Compact: "Keep content as narrow as possible and ensure it's snug against the
  TrueDepth camera … don't add padding between content and the TrueDepth camera."
- Expanded: "an enlarged version of the compact or minimal presentation … Wrap
  content tightly around the TrueDepth camera"; height should change dynamically
  with content.
- Text: "Use large, heavier-weight text — a medium weight or higher. Use small text
  sparingly."
- Animation: "system and custom animations with a maximum duration of two
  seconds"; "animate elements in and out with the default content-replace
  transition, or create custom transitions using scale, opacity, and movement";
  "preserve as much of the existing layout as possible by animating existing
  elements to their new positions"; "avoid overlapping elements".
- Alerts "show the expanded presentation in the Dynamic Island".

### 3.2 WWDC23 "Design dynamic Live Activities" (https://developer.apple.com/videos/play/wwdc2023/10194/) **[verified quotes]**
- "Rounded shapes nest inside of each other with even margins all the way around";
  "blur the object, and make sure the resultant shape is as concentric as
  possible to the outer border".
- Compact: "the encapsulation as narrow as possible with no wasted space"; "snug
  against the sensor region … no wider than it needs to be".
- Expanded: "Avoid having a 'forehead' at the top that calls attention to the
  sensor region. Rather, try and hug the sensor as tightly as possible and wrap
  content all the way around it"; heights range "from taller views … down to
  shorter pill sized views … Avoid a height right on the edge between them".
- Style: "Extra rounded, thicker shapes, as well as large, heavier weight,
  easy-to-read text works well"; "Liberal use of color to establish identity".
- Motion philosophy: inspired by "biological form and motion … with a deliberate
  elasticity that serves as a playful contrast to the fixed nature of the
  hardware".
- Alerting: "Rather than sending a push notification, when possible, expand the
  island to present that information".
- Apple Newsroom (https://www.apple.com/newsroom/2022/09/apple-debuts-iphone-14-pro-and-iphone-14-pro-max/):
  "blurs the line between hardware and software, fluidly expanding into different
  shapes"; "tap-and-hold" for controls.

### 3.3 WWDC23 "Animate with springs" (https://developer.apple.com/videos/play/wwdc2023/10158/) + SwiftUI docs **[verified]**
- Parameters: **duration** (perceptual, "chosen to be predictable and not move
  around") and **bounce** −1…1. Bounce 0 = critically damped "smooth"; >0
  overshoots; <0 overdamped.
- Guidance: "When you're not sure, use a spring with bounce 0"; ~0.15 "not very
  bouncy, but … a little more brisk"; ~0.3 "noticeable bounciness"; "be cautious
  about using values higher than around 0.4"; add bounce "when you want an
  animation to feel more physical, like … at the end of a gesture".
- **Do not wait for `settlingDuration`** for UI changes; use perceptual duration /
  completion handlers.
- Conversion (mass = 1): `stiffness = (2π / duration)²`, `damping = 4π(1 −
  bounce)/duration` for bounce ≥ 0 (verified against SwiftUI `Spring` docs:
  `Spring(duration: 0.5, bounce: 0.3)` → mass 1, stiffness 157.9, damping 17.6 —
  https://developer.apple.com/documentation/swiftui/spring).
- Presets (https://developer.apple.com/documentation/swiftui/animation/smooth(duration:extrabounce:) etc.):
  `.smooth` = duration **0.5**, bounce **0**; `.snappy` = 0.5, **0.15**;
  `.bouncy` = 0.5, **0.3**; `.spring(duration: 0.5, bounce: 0.0)` defaults;
  legacy `.spring(response: 0.5, dampingFraction: 0.825)`;
  `.interactiveSpring(response: 0.15, dampingFraction: 0.86, blendDuration: 0.25)`.
- Core Animation: `CASpringAnimation(perceptualDuration:bounce:)` — **macOS 14+**
  (https://developer.apple.com/documentation/quartzcore/caspringanimation/init(perceptualduration:bounce:)).

### 3.4 WWDC18 "Designing Fluid Interfaces" (https://developer.apple.com/videos/play/wwdc2018/803/) **[verified quotes]**
- "we recommend starting with 100% damping, or no overshoot … smooth, graceful,
  and seamless motion that doesn't distract"; reward gesture momentum with a
  little overshoot (Music: tap = 100% damping, swipe-dismiss = 80%).
- "Everything needs to respond instantly … Be vigilant and mindful of all the
  latencies or timers"; interruptible/redirectable animations; gesture
  hysteresis "usually 10 points".

### 3.5 Corner curve / squircle
- `CALayer.cornerCurve = .continuous` — macOS 10.15+
  (https://developer.apple.com/documentation/quartzcore/calayercornercurve/continuous);
  SwiftUI `RoundedCornerStyle.continuous` "Continuous curvature rounded rect
  corners" macOS 10.15+ **[verified]**. Note `cornerCurve` only affects
  `cornerRadius` clipping, not a `CAShapeLayer.path`; for the notch shape a path
  is unavoidable (flare), so a continuous look must be approximated with a
  cubic fillet or by nesting a `cornerCurve` layer for the bottom **[inference]**.

### 3.6 Type sizes (HIG Typography, https://developer.apple.com/design/human-interface-guidelines/typography) **[verified]**
- macOS: Headline **13 bold**, Body 13, Callout 12, Subheadline 11, Footnote 10,
  Caption 10; default 13 pt, minimum **10 pt**.
- iOS (what island content is designed at): Headline 17 semibold, Body 17,
  Callout 16, Subhead 15, Footnote 13, Caption 1 12, Caption 2 11.
- "avoid light font weights … prefer Regular, Medium, Semibold, or Bold".

### 3.7 macOS notch APIs
- `NSScreen.safeAreaInsets` (macOS 12+): "On some Macs, the insets reflect the
  portion of the screen covered by the camera housing"
  (https://developer.apple.com/documentation/appkit/nsscreen/safeareainsets).
- `NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea`: "The unobscured
  portion of the top-left/right corner of the screen"
  (https://developer.apple.com/documentation/appkit/nsscreen) — nil on non-notch
  displays, which is how both open-source apps detect a notch.
- HIG Layout: "Avoid displaying content within the camera housing at the top
  edge of the window" (https://developer.apple.com/design/human-interface-guidelines/layout).

---

## 4. mononote (digitalminimalist.com/tools/mononote)

- Page: "A minimalist notes app designed to help you focus on one note at a
  time"; features: Home Screen widget, "Lock Screen pinning", "Dynamic Island
  Live Activity for urgent items"; freemium; iPhone/iPad/Mac; App Store id
  6788222857 — https://www.digitalminimalist.com/tools/mononote **[verified]**.
- App Store lookup (https://itunes.apple.com/lookup?id=6788222857): "Mononote:
  One Note", seller THE DIGITAL MINIMALIST PTE. LTD., v1.0.2 (2026-08-06), min
  iOS 17, Mac listed as supported device; description: "start a Live Activity to
  pin it to your Lock Screen and Dynamic Island when it's something more urgent
  … showing only one active note at a time"; release notes: "Added a smaller text
  size option. Choose between the default, monospace, and serif fonts." **[verified]**
- Screenshots (App Store): single full-screen text field, "Start typing…"
  placeholder, one black full-width "Done" pill button, "…" overflow; Live
  Activity is the **standard iOS Lock Screen banner** with body-size regular
  text on a translucent grey card; no chrome. **[inference from screenshots]**
- **Conclusion:** mononote is not a macOS notch overlay. Its "notch" presence is
  Apple's own Live Activity in the iPhone Dynamic Island (and, per HIG, mirrored
  into the Mac menu bar). What is transferable is the *content* discipline: one
  note, one type size (with a smaller option), system fonts (SF / SF Mono / NY),
  black-on-light, one action. Typography and states are entirely Apple's.

---

## 5. Distilled spec for a CALayer island (numbers to adopt)

Geometry (in points; `H` = `safeAreaInsets.top`, `W` = cutout width)
1. **Rest**: width `W + 2…4`, height `H`, black `#000`, flare 6, bottom radius 14
   (≈ 0.4 H for H≈32–37), no shadow, no outline. Rationale: §2.2, §2.7, HIG black.
2. **Peek/hover** (optional intermediate): same silhouette; content wing grows
   by 12 pt (§2.4) or shadow rises 0.5→0.8 / 10→20 (§2.7); haptic
   `NSHapticFeedbackManager` alignment (§2.4). Dwell 0.3 s before full open.
3. **Open**: width `W + 2×overhang` where overhang ≥ 15 pt content inset + wing
   content (boring goes to 640 total; DynamicNotchKit ≈ W + 2×15 + content).
   Height `H + chin`. Flare 15–19, bottom radius 20–24 (bottom = flare + 5).
   Content inset: 15 pt sides/bottom (DNK) or 19 + 12 (boring); top of content
   starts at `H` (never draw in the housing).
4. **Concentricity**: any rounded element inside uses `outer − margin` as its
   radius (HIG; DNK doc comment).
5. Hide the anti-alias seam with a 1-pt black strip along the top edge inset by
   the flare (§2.3), or over-paint the black backing by −50 pt (§2.7).

Motion
6. Open: perceptual duration 0.40–0.42, bounce 0.15–0.30 (`.bouncy(0.4)` /
   `spring(response:0.42, damping:0.8)`); as CA: mass 1, stiffness ≈ 224–247,
   damping ≈ 22–27.
7. Close: duration 0.40–0.45, bounce 0 → CA: stiffness ≈ 195–247, damping ≈
   28–31 (critical = 2√k).
8. Bounds, position and path must share the identical spring (we do this).
9. Content in/out: opacity + scale from top (0.8, or 0.6 y-only) + optional
   blur 10–20 pt, `.smooth(0.35)`; morph, don't swap.
10. Order-out after ≈ perceptual close duration (0.40–0.45 s), never before;
    Apple: don't wait for settling.
11. Hover-exit close delay 100 ms; hover hit-slop 30 pt (10 pt when height 0).
12. Waveform: 4–5 bars × 2 pt, 2 pt gap, 12–14 pt tall, rounded caps, updates
    ≤ ~24–30 Hz, bottom-anchored scaleY (ours) — Alcove and boring both animate
    bars, Alcove's is a live audio tap at "0–1% Total CPU".

Type
13. Labels 12–13 pt medium/semibold SF Pro (macOS Body/Headline), values
    `.numericText` transitions, captions 10–11 pt; never < 10 pt; SF Pro Rounded
    acceptable for the header (boring) and matches WWDC23 "extra rounded, thicker
    shapes".

---

## 6. Where we are vs. this spec (`handy/src-tauri/swift/notch_overlay.swift`, read 2026-08-14)

Ours today: `restHeight 0`, `chinHeight 44`, `openOverhang 26`, `cornerRadius
22`, `flare 12`; open spring mass 1 / stiffness 260 / damping 22; close 340 / 30;
shadow black 0.45, radius 14, offset (0,−6), always drawn; `ignoresMouseEvents =
true`; order-out after 0.32 s; single fixed silhouette (flare and radius don't
change between states); no outline; no hover.

Converted with Apple's formulas (§3.3):
- Open: duration = 2π/√260 ≈ **0.39 s**, ζ = 22/(2√260) ≈ 0.68 → **bounce ≈ 0.32**
  (at the "cautious above 0.4" edge; boring uses ≈0.2, DNK 0.3).
- Close: duration = 2π/√340 ≈ **0.34 s**, ζ = 30/(2√340) ≈ 0.81 → **bounce ≈ 0.19**.
  Both open-source apps and WWDC18 close with **bounce 0**. Our order-out
  (0.32 s) fires *before* the close's own perceptual duration (0.34 s), let alone
  visual settle → last frames of the collapse are cut.
- Radius: 22 pt bottom on a 44 pt chin is 0.5 × chin, and constant across
  states; reference apps scale 14 → 20/24 with state.
- Shadow: ours 0.45 @ 14 always; references only when open/hovered, 0.5–0.7 @
  6–10.

### "What Alcove does that we don't" (gap list)
Verified from Alcove's changelog unless noted:
1. **Hover-to-expand with configurable dwell** and click-to-expand; we ignore
   the mouse entirely.
2. **State-dependent corner radius** ("Increased notch radius for
   notifications") and a **notch-shape rework** (1.7.3) — our radius/flare are
   constants.
3. **Outline / key line** sampled from what's under the island ("contrast
   outline", "colored outline", "compact outline"); HIG describes the same key
   line. We have a `rim` layer only when open.
4. **Progressive blur / glass backdrop** behind the expanded island (Tahoe) —
   ours is flat black. (Flat black is still HIG-correct for the Dynamic Island
   itself.)
5. **Elevated shadow only when raised**, opacity tuned down; ours is constant.
6. **Live audio waveform "1:1 with iOS"** — ours is a mic-level history bar
   (fine for our recording use case; visual bar spec in §2.6).
7. **Marquee** text that "matches iOS" for long strings — we have no text yet.
8. **Swipe gestures** (down to expand/cycle, dismiss QuickPeek; trackpad only)
   and **HUD overshoot** — out of scope for a voice overlay, listed for
   completeness.
9. **Pill shape for notchless displays / external monitors**, "show notch on all
   displays", simulated-notch toggle — we bail to the webview overlay when there
   is no notch (`hasNotch()`), which is the right v1 call per PLAN.md.
10. **User calibration** of notch width/height (Alcove 1.0.2/1.3.x) — we read
    `safeAreaInsets` / `auxiliaryTopLeftArea` only. Alcove's "Increased safe
    padding around notch area" suggests +2–4 pt slop is worth adding (boring adds
    exactly +4).
11. **Idle frame-rate reduction** and hide-in-fullscreen options.
12. **Duo mode / multiple live activities** — n/a.

Non-gaps (things we already match): CALayer/CASpringAnimation on the GPU;
`NSPanel` nonactivating at status level with `.canJoinAllSpaces,
.fullScreenAuxiliary, .stationary`; panel never resizes; shadow on a sibling
layer riding the same spring; content strictly below the housing; concave
top-edge flare (both open-source apps use the same quad-curve construction).

---

## Sources
- https://tryalcove.com/ ; https://tryalcove.com/changelog (JSON at https://api.tryalcove.com/changelog) ; https://tryalcove.com/faqs ; https://tryalcove.com/images/meta.png
- https://macsources.com/alcove-for-mac-a-truly-native-looking-mac-app/
- https://medium.com/@teslathewest/the-story-behind-alcove-macos-dynamic-island-app-dadb5d97e8b0
- https://www.howtogeek.com/these-apps-turn-your-macbook-notch-into-a-dynamic-island/ ; https://lo.cafe/notchnook
- https://github.com/TheBoredTeam/boring.notch — `boringNotch/ContentView.swift`, `components/Notch/NotchShape.swift`, `sizing/matters.swift`, `models/Constants.swift`, `models/BoringViewModel.swift`, `components/Notch/BoringNotchWindow.swift`, `animations/drop.swift`, `components/Music/MusicVisualizer.swift`, `components/Live activities/InlineHUD.swift`, `components/Live activities/OpenNotchHUD.swift`
- https://github.com/MrKai77/DynamicNotchKit — `Sources/DynamicNotchKit/Views/NotchShape.swift`, `Views/NotchView.swift`, `Views/NotchContentView.swift`, `DynamicNotch/DynamicNotchStyle.swift`, `DynamicNotch/DynamicNotchHoverBehavior.swift`, `Utility/NSScreen+Extensions.swift`
- https://developer.apple.com/design/human-interface-guidelines/live-activities
- https://developer.apple.com/design/human-interface-guidelines/typography
- https://developer.apple.com/design/human-interface-guidelines/layout
- https://developer.apple.com/videos/play/wwdc2023/10194/ (Design dynamic Live Activities)
- https://developer.apple.com/videos/play/wwdc2023/10158/ (Animate with springs)
- https://developer.apple.com/videos/play/wwdc2018/803/ (Designing Fluid Interfaces)
- https://developer.apple.com/documentation/swiftui/spring ; …/swiftui/animation/smooth(duration:extrabounce:) ; …/snappy(duration:extrabounce:) ; …/bouncy(duration:extrabounce:) ; …/spring(duration:bounce:blendduration:) ; …/spring(response:dampingfraction:blendduration:) ; …/interactivespring(response:dampingfraction:blendduration:)
- https://developer.apple.com/documentation/quartzcore/caspringanimation/init(perceptualduration:bounce:) ; https://developer.apple.com/documentation/quartzcore/calayercornercurve/continuous ; https://developer.apple.com/documentation/swiftui/roundedcornerstyle/continuous
- https://developer.apple.com/documentation/appkit/nsscreen/safeareainsets ; https://developer.apple.com/documentation/appkit/nsscreen
- https://www.apple.com/newsroom/2022/09/apple-debuts-iphone-14-pro-and-iphone-14-pro-max/
- https://www.digitalminimalist.com/tools/mononote ; https://apps.apple.com/us/app/mononote-one-note/id6788222857 (via https://itunes.apple.com/lookup?id=6788222857)
