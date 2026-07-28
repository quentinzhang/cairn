import SwiftUI

/// The Cairn / 跡 design system.
///
/// Every colour, dimension, radius, shadow and animation curve in the app
/// resolves through this namespace. Views never spell out a literal.
///
/// See `docs/design-system.md` for the rationale behind each scale.
enum Cairn {}

// MARK: - Stone

extension Cairn {
    /// The neutral ramp. A cool green-grey read from wet river stone, running
    /// from dry sand at the top to the darkest stone in shadow at the bottom.
    /// Odd steps are interpolations; even steps come from the original mark.
    enum Stone {
        static let s00 = Color(hex: 0xF5F6F2)
        static let s10 = Color(hex: 0xD4D6C2)
        static let s20 = Color(hex: 0xA8B0A4)
        static let s30 = Color(hex: 0x738C82)
        static let s40 = Color(hex: 0x638080)
        static let s50 = Color(hex: 0x476063)
        static let s60 = Color(hex: 0x2B474A)
        static let s70 = Color(hex: 0x1D373A)
        static let s80 = Color(hex: 0x143638)
        static let s90 = Color(hex: 0x0D1F24)
    }

    /// Cairn's own accent. Jade is the only hue the product speaks in; every
    /// other colour on screen belongs to an agent, not to Cairn.
    enum Brand {
        /// Badges, status dots, anything that is Cairn talking about itself.
        static let jade = Color(hex: 0x1A9E8A)
        /// The lit face of the middle stone.
        static let jadeLight = Color(hex: 0x2A9284)
        /// The shaded face of the middle stone.
        static let jadeDeep = Color(hex: 0x135B54)
        /// The glow thrown when a note arrives.
        static let jadeGlow = Color(hex: 0x1FB89E)
        /// The faces of the base stone. These belong to the mark alone — the
        /// neutral ramp in `Stone` stays free for interface chrome.
        static let stoneLit = Color(hex: 0x758D8E)
        static let stoneShade = Color(hex: 0x3C5659)
        /// The faces of the crown, the lit stone that closes the stack. The
        /// crown is the one face that gets re-read for its ground: pale on the
        /// dark app tile, deeper on a light panel, where a near-white stone
        /// would dissolve into the surface behind it.
        static let crownLit = Color(hex: 0xDCEFBB)
        static let crownShade = Color(hex: 0x7FBF86)
        static let crownLitOnLight = Color(hex: 0xB7DE93)
        static let crownShadeOnLight = Color(hex: 0x45895A)
        /// The point of light itself: a facet on the crown, and its halo.
        static let beacon = Color(hex: 0xF0FADD)
        static let beaconGlow = Color(hex: 0x8FDC8A)
    }

    /// Text colours. Body copy stays on the system semantic colours so the app
    /// follows Increase Contrast and accent-tint settings for free.
    enum Ink {
        static let primary = Color.primary
        static let body = Color.primary.opacity(0.86)
        static let secondary = Color.secondary
        static let tertiary = Color.secondary.opacity(0.62)
    }

    /// Hairlines. Cairn separates surfaces with a light edge, never a dark one:
    /// panels float over unknown wallpaper, and a light edge reads on both.
    enum Stroke {
        static let width: CGFloat = 0.6
        static let controlWidth: CGFloat = 0.8

        static func card(_ scheme: ColorScheme) -> Color {
            Color.white.opacity(scheme == .dark ? 0.08 : 0.48)
        }

        static let controlResting = Color.white.opacity(0.12)
        static let controlHover = Color.white.opacity(0.28)
        static let badge = Color.white.opacity(0.40)
    }

    /// Status of the inbox listener.
    enum Status {
        static let listening = Color(hex: 0x1A9E8A)
        static let degraded = Color(hex: 0xD18529)
    }

    /// One normalized geometry contract for every Cairn stone mark.
    ///
    /// The values match the public website's 108×118 SVG. SwiftUI, AppKit,
    /// the Finder icon generator and the website all preserve this silhouette;
    /// only colour treatment changes by context.
    ///
    /// Two flat stones and a lit crown. The crown is the third stone *and* the
    /// point of light — it is the trace the product is named for, resting on
    /// the stack rather than floating above it. Three elements is also the most
    /// the 16pt menu-bar rendition can hold: at that size the gaps between
    /// stones are barely two device pixels, and a fourth element closes them.
    enum Mark {
        /// One stone, placed by its centre because every renderer rotates it
        /// about that same point.
        ///
        /// `roundness` is a superellipse exponent — 2 is an ellipse, higher
        /// values push the silhouette towards a slab while keeping the corners
        /// soft. `seed` drives a small deterministic wobble so no two stones
        /// share an outline and none of them reads as a capsule.
        struct Stone {
            let center: CGPoint
            let size: CGSize
            let rotation: Double
            let seed: CGFloat
            let roundness: CGFloat
            let jitter: CGFloat

            init(
                x: CGFloat,
                y: CGFloat,
                width: CGFloat,
                height: CGFloat,
                rotation: Double,
                seed: CGFloat,
                roundness: CGFloat = 2.7,
                jitter: CGFloat = 0.035
            ) {
                self.center = CGPoint(x: x, y: y)
                self.size = CGSize(width: width, height: height)
                self.rotation = rotation
                self.seed = seed
                self.roundness = roundness
                self.jitter = jitter
            }
        }

        static let viewBox = CGSize(width: 108, height: 118)
        static let base = Stone(
            x: 54, y: 95, width: 82, height: 21, rotation: -2, seed: 0.6
        )
        static let middle = Stone(
            x: 56, y: 67, width: 58, height: 19, rotation: 4, seed: 3.4
        )
        /// Rounder and lighter than the two below it, so the stack closes.
        static let crown = Stone(
            x: 52, y: 38, width: 24, height: 23.04, rotation: -8,
            seed: 5.2, roundness: 2.2, jitter: 0.06
        )
        /// The lit facet on the crown. Drawn unrotated, on top of the stone.
        static let beacon = CGRect(x: 45.46, y: 31.8, width: 10.08, height: 7.2)
        /// Radius of the halo thrown by the crown, in mark units.
        static let beaconGlowRadius: CGFloat = 28.8
        static let ground = CGRect(x: 16, y: 102.5, width: 76, height: 11)

        /// The outline of a stone in its own space, centred on the origin.
        ///
        /// Keep this identical to `outline` in `Scripts/generate_app_icon.swift`
        /// and to the path data baked into `site/index.html`; the three are the
        /// same curve sampled by three renderers that cannot share code.
        static func outline(_ stone: Stone, steps: Int = 72) -> [CGPoint] {
            let a = stone.size.width / 2
            let b = stone.size.height / 2
            let e = 2 / stone.roundness
            return (0..<steps).map { i in
                let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
                let ct = cos(t), st = sin(t)
                let wobble = 1 + stone.jitter * (
                    sin(stone.seed + t) * 0.62 + sin(stone.seed * 1.7 + t * 2) * 0.38
                )
                return CGPoint(
                    x: a * wobble * (ct < 0 ? -1 : 1) * pow(abs(ct), e),
                    y: b * wobble * (st < 0 ? -1 : 1) * pow(abs(st), e)
                )
            }
        }
    }
}

// MARK: - Agent identity

extension Cairn {
    /// A source hue, resolved for the surface it lands on.
    ///
    /// `hue` is the agent's identity and the only value a new agent has to
    /// choose; everything else is that hue moved until it measures. The card
    /// wash is `hue` at low alpha, so contrast is self-referential: a rail or
    /// a label always sits on a tint of itself. Measured ratios are in
    /// `docs/design-system.md` — labels clear 4.5:1, rails clear 3:1, in both
    /// schemes. Never draw text in `hue`.
    struct Tone {
        let hue: Color
        let railLight: Color
        let railDark: Color
        let labelLight: Color
        let labelDark: Color
        let washLight: Double
        let washDark: Double

        /// Rails, dots and other non-text identity marks.
        func rail(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? railDark : railLight
        }

        /// Any text carrying the agent's colour.
        func label(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? labelDark : labelLight
        }

        /// The card tint that tells four agents apart at a glance.
        func wash(_ scheme: ColorScheme) -> Color {
            hue.opacity(scheme == .dark ? washDark : washLight)
        }

        static let codex = Tone(
            hue: Color(hex: 0x148C7A),
            railLight: Color(hex: 0x148C7A),
            railDark: Color(hex: 0x1FBFA3),
            labelLight: Color(hex: 0x0E6B5C),
            labelDark: Color(hex: 0x3FD6BA),
            washLight: 0.10,
            washDark: 0.16
        )

        static let hermes = Tone(
            hue: Color(hex: 0x8059DB),
            railLight: Color(hex: 0x7A4FD6),
            railDark: Color(hex: 0x9B78EE),
            labelLight: Color(hex: 0x6541C4),
            labelDark: Color(hex: 0xA98CF5),
            washLight: 0.10,
            washDark: 0.16
        )

        static let claudeCode = Tone(
            hue: Color(hex: 0xC75C40),
            railLight: Color(hex: 0xC75C40),
            railDark: Color(hex: 0xDE7050),
            labelLight: Color(hex: 0xA8442C),
            labelDark: Color(hex: 0xE8886A),
            washLight: 0.10,
            washDark: 0.16
        )

        static let openClaw = Tone(
            hue: Color(hex: 0x1F78BF),
            railLight: Color(hex: 0x1F78BF),
            railDark: Color(hex: 0x3E96D8),
            labelLight: Color(hex: 0x1A5F97),
            labelDark: Color(hex: 0x5CACE8),
            washLight: 0.10,
            washDark: 0.16
        )

        /// Any source Cairn has not been taught yet.
        static let unknown = Tone(
            hue: Color(hex: 0xD18529),
            railLight: Color(hex: 0xB5721E),
            railDark: Color(hex: 0xE09A38),
            labelLight: Color(hex: 0x8A5410),
            labelDark: Color(hex: 0xE8AC55),
            washLight: 0.10,
            washDark: 0.16
        )
    }

    /// One place defines what an agent is called and what colour it owns.
    /// Compact note headers use the explicit name instead of a proxy glyph.
    struct Agent {
        let name: String
        let tone: Tone

        static func identity(for source: String) -> Agent {
            switch source {
            case "codex":
                Agent(name: "Codex", tone: .codex)
            case "hermes":
                Agent(name: "Hermes", tone: .hermes)
            case "claude-code":
                Agent(name: "Claude Code", tone: .claudeCode)
            case "openclaw":
                Agent(name: "OpenClaw", tone: .openClaw)
            default:
                Agent(name: source.capitalized, tone: .unknown)
            }
        }
    }
}

// MARK: - Space

extension Cairn {
    /// A 4pt grid. Anything not on it is a mistake or a documented exception.
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 14
        static let xxl: CGFloat = 24
    }

    /// Continuous corners throughout — the product is made of river stones,
    /// and a circular corner reads as machined next to them.
    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
        static let card: CGFloat = 18
        static let control: CGFloat = 22
    }

    /// Component dimensions that are tuned rather than derived. These are part
    /// of the system: change them here, not at the call site.
    enum Metrics {
        static let notePanelWidth: CGFloat = 384
        static let noteCardHeight: CGFloat = 108
        static let noteCardSpacing: CGFloat = 8
        static let noteRailWidth: CGFloat = 3
        static let noteRailHeight: CGFloat = 54
        /// The pill that clears the whole queue, pinned under the stack.
        static let noteClearAllHeight: CGFloat = 26

        static let controlPanel = CGSize(width: 72, height: 82)
        static let controlBody = CGSize(width: 58, height: 66)
        static let badgeSize: CGFloat = 19

        static let menuWidth: CGFloat = 340
        static let dismissTarget: CGFloat = 19

        /// The note queue draws its own scroll thumb: the system overlay
        /// scroller can't be slimmed and disappears over light wallpaper.
        static let scrollThumbWidth: CGFloat = 4
        static let scrollThumbMinHeight: CGFloat = 24

        /// Gap between the control and the note panel, and the margin the
        /// control keeps from any screen edge.
        static let panelGap: CGFloat = 10
        static let screenMargin: CGFloat = 8
        /// Where the control lands the first time Cairn runs: tucked under the
        /// menu bar on the right, clear of the notch and of Control Center.
        static let firstRunInset = CGSize(width: 18, height: 34)
    }
}

// MARK: - Type

extension Cairn {
    /// Six roles, no more. Each maps to a Dynamic Type style where one fits so
    /// the app tracks the user's text size. SF falls back to PingFang SC and
    /// Hiragino Sans for CJK automatically — do not hardcode a CJK face.
    enum Typo {
        /// Menu bar header.
        static let title = Font.headline
        /// The prompt that produced the note.
        static let noteTitle = Font.subheadline.weight(.semibold)
        /// The agent's answer.
        static let noteBody = Font.system(size: 13)
        /// A menu row. Matches what macOS sets its own menus in, because that
        /// is what a person expects to be able to read at a glance.
        static let menuRow = Font.system(size: 13)
        /// Agent name — always paired with a tone label colour.
        static let label = Font.caption.weight(.semibold)
        /// Workspace, status, secondary rows.
        static let meta = Font.caption
        /// Relative time.
        static let micro = Font.caption2
        /// Count badge. Rounded, because it sits on the mark, not in text.
        static let badge = Font.system(size: 9, weight: .bold, design: .rounded)
        /// Glyphs inside small circular targets.
        static let glyph = Font.system(size: 9, weight: .bold)
    }
}

// MARK: - Elevation

extension Cairn {
    /// Cairn owns no chrome, so depth is the only way a surface says it is
    /// above the desktop. Four levels, all soft and all downward except the
    /// attention glow, which is centred so it reads as light, not as height.
    struct Shadow {
        let color: Color
        let radius: CGFloat
        let y: CGFloat

        /// A note resting in the queue.
        static func note(_ scheme: ColorScheme) -> Shadow {
            Shadow(
                color: .black.opacity(scheme == .dark ? 0.22 : 0.13),
                radius: 12,
                y: 6
            )
        }

        static let controlResting = Shadow(color: .black.opacity(0.22), radius: 9, y: 5)
        static let controlHover = Shadow(color: .black.opacity(0.22), radius: 13, y: 5)
        static let controlAttention = Shadow(color: Brand.jadeGlow.opacity(0.54), radius: 17, y: 1)
        static let badge = Shadow(color: .black.opacity(0.18), radius: 3, y: 1)
    }

    /// Gradients that describe the mark. Light falls from the top left on every
    /// stone, so the stack reads as one object.
    enum Surface {
        static let basePebble = LinearGradient(
            colors: [Brand.stoneLit, Brand.stoneShade],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        static let middlePebble = LinearGradient(
            colors: [Brand.jadeLight, Brand.jadeDeep],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        /// The crown resolves against the surface it lands on; the two flat
        /// stones are dark enough to hold on either.
        static func crownPebble(_ scheme: ColorScheme) -> LinearGradient {
            LinearGradient(
                colors: scheme == .dark
                    ? [Brand.crownLit, Brand.crownShade]
                    : [Brand.crownLitOnLight, Brand.crownShadeOnLight],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        static let groundShadow = Color.black.opacity(0.24)
    }
}

// MARK: - Motion

extension Cairn {
    /// Nothing in Cairn animates for longer than a third of a second, and
    /// nothing animates unless the user caused it — except a single arrival
    /// pulse, which is the one moment the app is allowed to ask for attention.
    enum Motion {
        static let hover = Animation.easeOut(duration: 0.16)
        static let dismiss = Animation.easeOut(duration: 0.18)
        static let toggle = Animation.spring(response: 0.28, dampingFraction: 0.78)
        static let enqueue = Animation.spring(response: 0.32, dampingFraction: 0.86)
        /// Looser damping: the stack should overshoot slightly, like a stone
        /// settling, rather than snap.
        static let attention = Animation.spring(response: 0.30, dampingFraction: 0.62)

        /// How long the arrival glow holds before it fades.
        static let attentionHold: Duration = .milliseconds(900)

        static let hoverScale: CGFloat = 1.045
        static let attentionScale: CGFloat = 1.075
    }
}

// MARK: - Helpers

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

extension View {
    func cairnShadow(_ shadow: Cairn.Shadow) -> some View {
        self.shadow(color: shadow.color, radius: shadow.radius, y: shadow.y)
    }
}
