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

        /// The one place the rule above bends. A borrowed-light edge is
        /// invisible on a white desktop, which left the control's shadow doing
        /// all the work of saying where the control ends — and a shadow asked
        /// to draw an edge has to be dark enough to look like one. On light the
        /// control takes a stone hairline instead, and the shadow goes back to
        /// being depth.
        static func controlResting(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? .white.opacity(0.12) : Stone.s50.opacity(0.20)
        }

        static func controlHover(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? .white.opacity(0.28) : Stone.s50.opacity(0.30)
        }

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

        /// Graphite, because OpenAI's mark has no colour to borrow — and
        /// because the teal Codex used to wear was Cairn's own jade, which
        /// made every Codex note look like a message from the app itself.
        static let codex = Tone(
            hue: Color(hex: 0x5A6B75),
            railLight: Color(hex: 0x4E5F6A),
            railDark: Color(hex: 0x8FA3AE),
            labelLight: Color(hex: 0x3D4C55),
            labelDark: Color(hex: 0xA8BAC4),
            washLight: 0.10,
            washDark: 0.16
        )

        /// Purple by Cairn's choice: Nous Research brands Hermes in black and
        /// white, so there is nothing to match and a free hue to spend.
        static let hermes = Tone(
            hue: Color(hex: 0x8059DB),
            railLight: Color(hex: 0x7A4FD6),
            railDark: Color(hex: 0x9B78EE),
            labelLight: Color(hex: 0x6541C4),
            labelDark: Color(hex: 0xA98CF5),
            washLight: 0.10,
            washDark: 0.16
        )

        /// Anthropic's clay. The one tone here that is straightforwardly its
        /// agent's own colour.
        static let claudeCode = Tone(
            hue: Color(hex: 0xD97757),
            railLight: Color(hex: 0xC2643E),
            railDark: Color(hex: 0xE08A66),
            labelLight: Color(hex: 0x9E4C28),
            labelDark: Color(hex: 0xF0A585),
            washLight: 0.10,
            washDark: 0.16
        )

        /// Blue, though OpenClaw's lobster is red. Tried the red: at wash
        /// strength it is the same pink as Claude Code's clay, and telling
        /// four agents apart is the only job this colour has. The mark carries
        /// the brand; the tone carries the difference.
        static let openClaw = Tone(
            hue: Color(hex: 0x1F78BF),
            railLight: Color(hex: 0x1F78BF),
            railDark: Color(hex: 0x3E96D8),
            labelLight: Color(hex: 0x1A5F97),
            labelDark: Color(hex: 0x5CACE8),
            washLight: 0.10,
            washDark: 0.16
        )

        /// Moss green. OpenCode has no durable product hue to borrow, so it
        /// takes the remaining family between Claude's clay and OpenClaw's
        /// blue. It is deliberately yellow enough to remain distinct from
        /// Cairn's own jade in peripheral vision.
        static let openCode = Tone(
            hue: Color(hex: 0x7E9C3A),
            railLight: Color(hex: 0x657F28),
            railDark: Color(hex: 0xA8C95B),
            labelLight: Color(hex: 0x4E651C),
            labelDark: Color(hex: 0xBEDC78),
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

    /// One place defines what an agent is called, what colour it owns, and —
    /// through `id` — which mark `AgentIconAsset` draws for it. The note
    /// `source` is the canonical key: every other id in the app maps onto it.
    struct Agent {
        let id: String
        let name: String
        let tone: Tone

        static func identity(for source: String) -> Agent {
            switch source {
            case "codex":
                Agent(id: source, name: "Codex", tone: .codex)
            case "hermes":
                Agent(id: source, name: "Hermes", tone: .hermes)
            case "claude-code":
                Agent(id: source, name: "Claude Code", tone: .claudeCode)
            case "openclaw":
                Agent(id: source, name: "OpenClaw", tone: .openClaw)
            case "opencode":
                Agent(id: source, name: "OpenCode", tone: .openCode)
            default:
                Agent(id: source, name: source.capitalized, tone: .unknown)
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
        /// Agent marks. Three sizes because three surfaces: beside a menu's
        /// meta text, beside a note's label, and leading a window row whose
        /// text is a subheadline.
        static let agentGlyphMenu: CGFloat = 13
        static let agentGlyphNote: CGFloat = 12
        static let agentGlyphRow: CGFloat = 16

        static let noteRailWidth: CGFloat = 3
        static let noteRailHeight: CGFloat = 54
        /// The queue's own controls — the search field and the pill that
        /// clears everything — pinned in one row above the stack. One height
        /// for both: they sit side by side, and a pill a hair taller than the
        /// field beside it reads as a mistake rather than as a hierarchy.
        static let noteChromeHeight: CGFloat = 26
        /// What a search that found nothing costs. One line of `Typo.meta`
        /// with room to breathe — smaller than a card, because the panel
        /// shrinking is itself part of the answer.
        static let noteEmptyResultHeight: CGFloat = 40
        /// A stacked note's shoulder: how far the card underneath peeks out
        /// below the top one, and how far it is drawn in from each side. Enough
        /// curve to read as another card, not enough to be mistaken for one you
        /// can act on.
        static let noteStackShoulder: CGFloat = 6
        static let noteStackInset: CGFloat = 8

        /// The desktop control at rest. Every part of it — panel, body, mark,
        /// badge — is these numbers times `CairnControlSize.scale`, so the two
        /// sizes it offers are one multiplication rather than two sets of
        /// tuned values.
        static let controlPanel = CGSize(width: 72, height: 82)
        static let controlBody = CGSize(width: 58, height: 66)
        static let controlMark = CGSize(width: 54, height: 59)
        static let badgeSize: CGFloat = 19

        /// How far a shadow may reach past the control before the panel window
        /// cuts it off: 7pt to either side, 8pt above and below. Cairn's panels
        /// are transparent windows drawn tight around their content, and a blur
        /// that runs past the frame is not faded, it is truncated — which is
        /// what a dark ring around the control actually is.
        static let controlShadowRoom = CGSize(
            width: (controlPanel.width - controlBody.width) / 2,
            height: (controlPanel.height - controlBody.height) / 2
        )

        /// The same room around a note: the queue pads its cards by `Space.lg`
        /// and the panel ends there.
        static let noteShadowRoom = Space.lg

        static let menuWidth: CGFloat = 340
        static let dismissTarget: CGFloat = 19

        /// The settings window. Nothing in it reflows — it is a sheet of
        /// switches, not a document — so the size is tuned here like the
        /// control's rather than left to the content.
        static let settingsWindow = CGSize(width: 520, height: 740)
        /// The mark that heads that window, as a multiple of the one the
        /// desktop control draws. Large enough to read as the product's face,
        /// not so large that the switches start below the fold.
        static let settingsMarkScale: CGFloat = 1.15

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
        /// Count badge. Rounded, because it sits on the mark, not in text —
        /// and the one label that grows with the desktop control.
        static func badge(_ scale: CGFloat = 1) -> Font {
            .system(size: 9 * scale, weight: .bold, design: .rounded)
        }
        /// Glyphs inside small circular targets.
        static let glyph = Font.system(size: 9, weight: .bold)
        /// Glyphs in the queue's own control row, whose targets are half again
        /// the size of the ones inside a card. A seventh role rather than a
        /// reused sixth because `glyph` is tuned to survive being tiny — bold,
        /// and only ever asked to draw an × or a chevron. The control row
        /// carries a symbol that has to stay readable as a *picture*, and 9pt
        /// bold turns one of those into a smudge.
        static let chromeGlyph = Font.system(size: 11, weight: .semibold)
    }
}

// MARK: - Elevation

extension Cairn {
    /// Cairn owns no chrome, so depth is the only way a surface says it is
    /// above the desktop. Four levels, all soft and all downward except the
    /// attention glow, which is centred so it reads as light, not as height.
    ///
    /// Each level is drawn in two passes, the way light actually falls: an
    /// ambient wash that says how far off the desktop the surface floats, and a
    /// shorter contact pass that seats its lower edge. One blur dark enough to
    /// be felt is also dark enough to show its own rim; the pair carries the
    /// same weight with a falloff that has nowhere to break.
    ///
    /// Both passes are then sized to the room the surface actually has. Cairn
    /// draws into transparent windows fitted tightly around their content, and
    /// a window does not fade a blur that runs past its frame — it cuts it. A
    /// generous radius in a tight panel therefore does not read as a soft
    /// shadow at all: it reads as a grey band with a hard outer edge, obvious
    /// on white and hidden on black, which is precisely how the rim around the
    /// control used to look. So a level's extent — roughly `2 × radius + y` —
    /// stays inside `Metrics.controlShadowRoom` / `Metrics.noteShadowRoom`.
    /// Depth here is bought with tone, never with reach.
    struct Shadow {
        struct Layer {
            let color: Color
            let radius: CGFloat
            let y: CGFloat
        }

        /// The far pass: the wider, fainter one.
        let ambient: Layer
        /// The near pass, seating the edge. Absent where a second blur would
        /// only muddy something small.
        let contact: Layer?

        /// Shadows on a light desktop are cast in stone rather than in black.
        /// Neutral black over cream or white greys everything it crosses and
        /// reads as dirt on the wallpaper; the mark's own cool green-grey reads
        /// as depth. On a dark desktop black is still the honest answer.
        static func ink(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? .black : Stone.s70
        }

        /// A note resting in the queue. Room: 12pt to the panel edge, and 8pt
        /// to the card below — a shadow landing on that card is light falling
        /// where it should, so the panel edge is the constraint.
        static func note(_ scheme: ColorScheme) -> Shadow {
            let dark = scheme == .dark
            return Shadow(
                ambient: Layer(color: ink(scheme).opacity(dark ? 0.20 : 0.10), radius: 4, y: 3),
                contact: Layer(color: ink(scheme).opacity(dark ? 0.12 : 0.055), radius: 1.5, y: 1)
            )
        }

        /// The control, with 7pt of room to its sides and 8pt above and below.
        /// Hovering deepens the tone rather than widening the blur; the reach
        /// is fixed by the window, and the lift is carried by `Motion.hover`.
        static func controlResting(_ scheme: ColorScheme) -> Shadow {
            control(scheme, ambient: scheme == .dark ? 0.26 : 0.12)
        }

        static func controlHover(_ scheme: ColorScheme) -> Shadow {
            control(scheme, ambient: scheme == .dark ? 0.32 : 0.16)
        }

        private static func control(_ scheme: ColorScheme, ambient: Double) -> Shadow {
            Shadow(
                ambient: Layer(color: ink(scheme).opacity(ambient), radius: 3, y: 2),
                contact: Layer(color: ink(scheme).opacity(ambient * 0.5), radius: 1, y: 0.5)
            )
        }

        /// The arrival glow. It has the same 7pt to work in as the shadow it
        /// replaces, so it is a bright rim rather than a bloom — the reach the
        /// signal needs comes from the halo the mark throws inside the control,
        /// which no window edge can cut.
        static let controlAttention = Shadow(
            ambient: Layer(color: Brand.jadeGlow.opacity(0.62), radius: 3.5, y: 0),
            contact: Layer(color: Brand.jadeGlow.opacity(0.38), radius: 1.5, y: 0)
        )

        /// The badge is 19pt across. A second pass on something that small only
        /// muddies it.
        static let badge = Shadow(
            ambient: Layer(color: .black.opacity(0.16), radius: 2, y: 1),
            contact: nil
        )
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

        /// The pool the stack stands in. Faint, and blurred by
        /// `groundShadowBlur` where it is drawn — a crisp 24% ellipse read as a
        /// fourth stone lying flat rather than as the ground giving way.
        static let groundShadow = Color.black.opacity(0.17)

        /// Blur applied to that pool, in mark units, so it scales with the mark.
        static let groundShadowBlur: CGFloat = 3.5

        /// The ground a Cairn window stands on: wet stone in the dark, dry
        /// sand in the light. Vertical and lit from above, like every other
        /// surface the product draws, so the mark at the top of the window
        /// sits in the light and the way out sits in the shade.
        static func windowGround(_ scheme: ColorScheme) -> LinearGradient {
            LinearGradient(
                colors: scheme == .dark
                    ? [Stone.s80, Stone.s90]
                    : [.white, Stone.s00],
                startPoint: .top,
                endPoint: .bottom
            )
        }

        /// A card resting on that ground. Always light borrowed from above —
        /// a darker rectangle would read as a hole cut in the window rather
        /// than as a group of rows lifted off it.
        static func card(_ scheme: ColorScheme) -> Color {
            Color.white.opacity(scheme == .dark ? 0.05 : 0.70)
        }

        /// The run of text a query landed on.
        ///
        /// Jade, because the rule this system runs on is that jade is Cairn
        /// talking about itself and every other hue on screen belongs to an
        /// agent. A highlight is the search answering "this is why you are
        /// seeing this note" — Cairn's voice, over an agent's words. Tinting
        /// it with the agent's own colour would put that hue on the rail, the
        /// label and the sentence, and a colour used three ways stops meaning
        /// any of them.
        static func searchHit(_ scheme: ColorScheme) -> Color {
            Cairn.Brand.jade.opacity(scheme == .dark ? 0.42 : 0.22)
        }

        /// One alpha step — thin enough to be invisible, thick enough to exist.
        ///
        /// macOS routes the pointer *through* any pixel a borderless window
        /// leaves fully clear, and the note panel only paints where its cards
        /// are. That handed every scroll wheel event landing in the gap between
        /// two cards to whatever sat behind the panel, so the queue stopped
        /// scrolling wherever the pointer happened to rest. Painting the whole
        /// panel with a veil makes the gaps part of the window again.
        static let eventVeil = Color.black.opacity(0.01)
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

extension CGSize {
    func scaled(by factor: CGFloat) -> CGSize {
        CGSize(width: width * factor, height: height * factor)
    }
}

extension View {
    /// Contact first, then ambient: the near pass has to be laid down before
    /// the far one so the wide wash falls across it rather than under it.
    func cairnShadow(_ shadow: Cairn.Shadow) -> some View {
        self
            .shadow(
                color: shadow.contact?.color ?? .clear,
                radius: shadow.contact?.radius ?? 0,
                y: shadow.contact?.y ?? 0
            )
            .shadow(color: shadow.ambient.color, radius: shadow.ambient.radius, y: shadow.ambient.y)
    }
}
