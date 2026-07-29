# Cairn 跡 — Design System

Cairn is a floating queue of notes that agents leave behind. It has no window,
no title bar, and no chrome to inherit style from — every pixel is drawn by
this system. That makes the system load-bearing rather than decorative.

The implementation is [`Sources/Cairn/DesignSystem.swift`](../Sources/Cairn/DesignSystem.swift).
No view in the app spells out a colour, a radius, a duration or a dimension;
they all resolve through the `Cairn` namespace. If you need a value that isn't
here, add it here first.

---

## 1. Name

**The product is called Cairn, in every locale.** `跡` is its seal, not a
translation of its name.

| | | |
| --- | --- | --- |
| Name | `Cairn` | /kɛərn/ — unchanged in every market |
| Seal | `跡` ja · zh-Hant<br>`迹` zh-Hans | read あと (ja) or jì (zh) when someone asks what the character is |

This split is not a nicety. A name has to survive three tests, and `跡` fails
all three:

- **It has to be sayable.** `跡` reads あと in Japanese and jì in Chinese, so
  the spoken name of the product would change at the border. Cairn does not.
- **It has to be findable.** `跡` is a top-frequency character in both
  languages. Someone recommending the product types "Cairn".
- **It has to be a proper noun.** `跡` means, literally, the thing this
  product makes. Calling it that in CJK is calling a notes app "Notes" — it
  reads as a category, not a brand. In Japanese a lone `跡` is more likely
  parsed as the common noun あと.

The product's own surface has already settled this: the bundle, the binary,
`~/Library/Application Support/Cairn`, every hook script and the `cairn-save`
skill are all `Cairn`. `跡` has never named anything the user can point at.

What `跡` *is* good at is being a mark. One dense glyph, instantly
distinctive, carrying the entire thesis in a single character — 足 walking
away from what it left. Demoting it from name to seal costs the CJK markets a
little of the made-for-us feel; the answer to that is composition, not
naming. **In CJK layouts the seal still dominates the hero — as the
watermark behind the type, not as a glyph clipped to the wordmark.** The name
is Latin; the page is not.

**The seal localises with the script.** `跡` in Japanese and Traditional
Chinese, `迹` in Simplified.

The tempting rule is the opposite one — freeze a single drawn form, the way a
logotype does not change when it crosses a border. It is wrong here, and the
reason is the paragraph above: the seal earns its keep by being *real
vocabulary the copy can lean on*. That only works while the seal and the word
in the tagline are the same character. Setting `跡` over 「每完成一次，留一道
迹。」 puts the same word in two glyphs six inches apart and breaks the gloss.

`跡` is standard in two of the three markets and foreign-looking in the third,
so freezing it marks the largest CJK audience as the odd one out to save a
consistency nobody but a locale-switcher ever sees. The cost is real but
small: cross-market recognition is carried by the **stone mark**, which is in
the app icon, the menu bar, the favicon and the floating control. The seal
appears only on the website, tied to copy. Freeze the mark; let the seal read.

The two forms share `亦` and differ only in radical — `足` (foot) against `辶`
(walk). Both are traces of going somewhere.

The name is literal: a Cairn note *is* the trace a finished turn left behind.
`軌跡` (trajectory), `足跡` (footprint) and `遺跡` (remains) are all on-brand
readings. Avoid contexts in Japanese where `跡` reads as `傷跡` — a scar.

The taglines use `跡` as an ordinary word — 「終わりに、跡を。」, 「每完成一次，
留一道迹。」 — and that is the payoff of choosing a seal that is also real
vocabulary: the copy glosses the mark without ever explaining it.

### Where each one goes

**`Cairn` is the wordmark on every surface, in every locale.** Nav, hero,
footer, menu bar, bundle name — one word, unlocalised. Hiding it in ja/zh
leaves the reader bridging a title they cannot search to a body paragraph that
says "Cairn".

**The seal is never set inline beside the name.** It goes behind the type, as
the hero watermark, at a size where it reads as ground rather than as a word
waiting to be pronounced.

That is the whole rule, and it comes from asking what a `跡` next to `Cairn`
actually costs and buys. It costs an English reader a question — *what is
that, how do I say it* — for a character they will never type. It buys
nothing, because at 0.68em beside a wordmark the seal is the smallest it will
ever be on the page, while the watermark behind it is 300–560px. Moving the
seal to the background does not hide it. It stops asking the reader to parse
it and lets them absorb it.

The trade is real and worth naming: a Japanese or Chinese visitor now meets a
Latin wordmark rather than a native one. What holds the composition CJK-first
is the watermark and the copy, not the title. If that ever stops feeling like
enough, the fix is to grow the seal, not to reattach it to the name.

The seal is welcome anywhere identity is already established — watermark,
dividers, chrome. Never as a page or window title: a title has to answer
*what is this called*.

### Setting the seal

- Set in the system CJK face at the user's weight — SF falls back to
  **Hiragino Sans** (ja) and **PingFang SC/TC** (zh). Do not ship a bundled
  CJK font; the OS face is what the rest of the user's system speaks in.
- Clear space on all four sides equals the character's own height. `跡` is a
  dense 13-stroke glyph; crowding it turns it into a smudge.
- Minimum size 24pt. Below that the ⻊ radical fills in — use the stone mark
  instead.

### The stone mark

Two flat river stones and a lit crown. Base in `Brand.stoneLit → stoneShade`,
middle in jade, crown in `Brand.crownLit → crownShade` with a `Brand.beacon`
facet on its upper left. Light falls from the top-left on all three so the
stack reads as one object rather than three shapes.

**The crown is the third stone and the point of light at once.** It is not a
dot hovering above the stack — it rests on it, which is the whole claim the
product makes: a finished turn leaves something behind, on top of what came
before. A separate floating dot reads as a different layer that failed to get
turned off.

Three elements is the ceiling, not a style choice. At 16pt the gaps between
stones are barely two device pixels; a fourth element closes them and the mark
turns into a smudge. Anything that wants to be added to the mark has to
replace something.

Stone geometry is load-bearing. Each stone is a superellipse — `roundness`
2.7 for the two flat stones, 2.2 for the crown — carrying a small seeded
wobble, so no two outlines match and none of them reads as a capsule. That
last part matters: three equal capsules read as a hamburger menu, which is why
the flat stones taper and why the crown is round. Tilts alternate
(−2° / +4° / −8°) and centres sit within ±2 of the axis: enough to look
stacked by hand, not enough to look unaligned.

**Open and closed are told by the crown's light, not by the stack moving.**
Closed, the light is banked: the halo is tight and dim, the facet small and
dull. Open, it comes on — the halo blooms, the facet grows and goes
near-white, the crown's own faces brighten a step, and it sits up by a single
point. The two flat stones never move.

This is deliberate. Sliding the stones apart to mean "expanded" turns the mark
into a disclosure triangle wearing stone; it also animates the thing that
carries the brand — the silhouette — for a reason that has nothing to do with
the brand. Lighting the crown says the same thing with the one element that is
already about state: the trace. A cairn does not open. Its marker catches the
light or it doesn't.

All renderers use one 108×118 geometry contract, matching the website SVG.
Stones are placed by centre: base `(54,95,82×21)`, middle `(56,67,58×19)`,
crown `(52,38,24×23)`. `Cairn.Mark.outline` generates the silhouette; the
website bakes the same curve into path data and
`Scripts/generate_app_icon.swift` mirrors the generator, because neither can
import the app's Swift. **Change a seed, size or roundness in one and you must
regenerate all three.**

The crown is the one face that gets re-read for its ground. On the dark app
tile it is pale (`#DCEFBB → #7FBF86`); on the website's light ground it deepens
(`#B7DE93 → #45895A`) or the silhouette dissolves into near-white. Everything
else is identical across surfaces.

The full-colour mark appears on the website and floating control. The menu-bar
form uses the same silhouette as a monochrome template so macOS can tint it
correctly; the lit facet is dropped there, since a template image is one colour
and a highlight would only eat into the stone. The queue badge is interface
chrome; it must not change the mark itself. The floating control uses the
animated stones, hover treatment and cursor to communicate interaction—never a
`+`/`−` overlay.

### Application icon

The Finder icon places the official stone mark on a dark stone tile. It uses
the same geometry, gradients and crown as the in-product mark; it never adds
letters or a second symbol.

The tile follows the macOS grid: an **824×824** body centred on the 1024
canvas, corner radius **185.4**. The surrounding margin is where the system's
own shadow lands, so the tile must not fill it, and the asset carries exactly
one soft drop shadow — a second one, or a light hairline around the tile,
reads as a cut-out square against a light wallpaper. The source render is
`Resources/AppIcon-1024.png`, the packaged asset is `Resources/AppIcon.icns`,
and both are reproducible with:

```zsh
./Scripts/generate_app_icon.sh
```

---

## 2. Principles

These are the three tests any new surface has to pass.

**不打断 — Never interrupt.** Cairn has no Dock icon, no notification, no
window that takes focus. It reports that something finished; it does not ask
for anything. The single exception is the arrival pulse, which lasts 900ms and
then stops. If a design needs the user to respond, it does not belong here.

**可堆叠 — Everything stacks.** Notes are a queue, not a feed. Cards are one
fixed height so fifty of them are scannable at a glance and the panel height is
a pure function of the count. Nothing expands in place; nothing reflows.

**会消退 — Everything fades.** A note is a trace, and traces are meant to be
walked past. Dismissal is one click with no confirmation, the queue caps at 50,
and no state is precious enough to warrant a dialog.

---

## 3. Colour

### Stone — the neutral ramp

A cool green-grey read from wet river stone. Ten steps, monotonic in luminance.

| Token | Hex | Used for |
| --- | --- | --- |
| `Stone.s00` | `#F5F6F2` | — reserved for light-mode surfaces |
| `Stone.s10` | `#D4D6C2` | top pebble, lit face |
| `Stone.s20` | `#A8B0A4` | — |
| `Stone.s30` | `#738C82` | top pebble, shaded face |
| `Stone.s40` | `#638080` | base pebble, lit face |
| `Stone.s50` | `#476063` | — |
| `Stone.s60` | `#2B474A` | base pebble, shaded face |
| `Stone.s70` | `#1D373A` | — |
| `Stone.s80` | `#143638` | control body, top of gradient |
| `Stone.s90` | `#0D1F24` | control body, bottom of gradient |

### Brand — jade

Jade is the only hue Cairn speaks in. Every other colour on screen belongs to
an agent, not to the product. If a new element needs a colour and it is Cairn
talking about itself, it is jade.

| Token | Hex | Used for |
| --- | --- | --- |
| `Brand.jade` | `#1A9E8A` | count badge, listening status |
| `Brand.jadeLight` | `#2A9284` | middle pebble, lit face |
| `Brand.jadeDeep` | `#135B54` | middle pebble, shaded face |
| `Brand.jadeGlow` | `#1FB89E` | arrival glow |
| `Brand.stoneLit` | `#758D8E` | base pebble, lit face |
| `Brand.stoneShade` | `#3C5659` | base pebble, shaded face |
| `Brand.crownLit` | `#DCEFBB` | crown, lit face (dark grounds) |
| `Brand.crownShade` | `#7FBF86` | crown, shaded face (dark grounds) |
| `Brand.beacon` | `#F0FADD` | the lit facet on the crown |
| `Brand.beaconGlow` | `#8FDC8A` | its halo |

The mark's faces live in `Brand`, not in the `Stone` ramp: the ramp is a
neutral scale for interface chrome and retuning it to suit the mark would drag
every panel and hairline along with it.

### Agent tones

Five agents, five hues, plus a fallback for sources Cairn hasn't been taught.
A tone is not one colour — it is one **identity hue** plus the variants that
measure correctly on a card tinted with that same hue.

A tone is only half the identity — the other half is the agent's own mark. See
§3.1. Never a substitute SF Symbol: a metaphorical glyph adds noise and
misrepresents the product.

Two of these hues are the agent's own colour and two are Cairn's choice, for
reasons worth keeping straight:

- **Claude Code** is Anthropic's clay. Straightforwardly its own.
- **Codex** is graphite because OpenAI's mark has no colour to borrow. It also
  fixes an older mistake: Codex used to wear a teal within a few points of
  `Brand.jade`, so its notes read as messages from Cairn itself.
- **OpenClaw** is blue though its lobster is red. At wash strength that red is
  the same pink as Claude Code's clay, and telling four agents apart is the
  only job this colour has.
- **Hermes** is purple by choice: Nous Research brands it black and white, so
  there is nothing to match and a free hue to spend.
- **OpenCode** is moss green by choice. Its previous fallback amber sat too
  close to Claude Code's clay in a card wash; moss keeps it separate from
  Claude's orange, OpenClaw's blue, Hermes's purple, and Cairn's jade.

| Agent | Hue | Rail (light / dark) | Label (light / dark) |
| --- | --- | --- | --- |
| Codex | `#5A6B75` | `#4E5F6A` / `#8FA3AE` | `#3D4C55` / `#A8BAC4` |
| Hermes | `#8059DB` | `#7A4FD6` / `#9B78EE` | `#6541C4` / `#A98CF5` |
| Claude Code | `#D97757` | `#C2643E` / `#E08A66` | `#9E4C28` / `#F0A585` |
| OpenClaw | `#1F78BF` | `#1F78BF` / `#3E96D8` | `#1A5F97` / `#5CACE8` |
| OpenCode | `#7E9C3A` | `#657F28` / `#A8C95B` | `#4E651C` / `#BEDC78` |
| Unknown | `#D18529` | `#B5721E` / `#E09A38` | `#8A5410` / `#E8AC55` |

The card wash is the hue at **10% (light) / 16% (dark)**, so contrast is
self-referential: a label always sits on a tint of itself. That is why the raw
hue can never be used for text — at caption size it fails against its own wash.

**Measured** against a modelled card background (`#F0F2EF` light, `#23292C`
dark, composited with the wash):

| Agent | Label light | Label dark | Rail light | Rail dark |
| --- | --- | --- | --- | --- |
| Codex | 6.97 | 6.37 | 5.19 | 4.87 |
| Hermes | 5.31 | 4.67 | 4.21 | 3.80 |
| Claude Code | 4.83 | 5.84 | 3.27 | 4.48 |
| OpenClaw | 5.28 | 5.09 | 3.67 | 3.92 |
| OpenCode | 5.33 | 7.58 | 3.69 | 6.18 |
| Unknown | 5.08 | 5.79 | 3.17 | 4.90 |

Labels clear WCAG AA 4.5:1 for body text; rails clear 3:1 for non-text UI. The
card sits on `.ultraThinMaterial` over unknown wallpaper, so these are modelled
values, not device measurements — treat them as the floor the tokens were
designed to, and re-run the check in `Scripts/` terms if you change a hue.

### Agent marks

Each agent's own logo, in `Sources/Cairn/Resources/AgentIcons/`, drawn by
`AgentGlyph`. Three surfaces show one: the menu bar's connected count (13pt),
a note header (12pt), a connect window row (16pt).

Every file is a **silhouette**, loaded as a template image so only its alpha
survives, and tinted from the agent's own `Tone`. That is one file for light
and dark, and it is what stops a borrowed brand from bringing a fifth and sixth
colour into a palette whose hues already mean something. It also rules out any
mark whose meaning depends on its own colours or on overlaid detail — OpenClaw
ships two lobsters, and only the menu bar template one keeps its eyes when
flattened to alpha.

An agent with no usable vector mark falls back to a **lettermark**: a washed
tile in the agent's tone with its initial. Washed, not solid, because beside
line-art logos a filled chip is the heaviest thing in the row, and the agent
without a mark is the last one that should shout. Never invent or trace a logo
to fill the gap — the fallback is the honest answer.

Marks are third-party trademarks used to identify an integration.
`Resources/AgentIcons/ATTRIBUTION.md` records where each came from.

### Ink and stroke

Text uses the system semantic colours (`.primary`, `.secondary`) so Cairn
follows Increase Contrast and accent settings for free. `Ink.body` is
`.primary` at 86% — the agent's answer is the quietest thing on the card
because it is the thing you have already read.

Surfaces are separated with a **light** hairline, never a dark one. Panels
float over wallpaper nobody chose for them; a light edge reads on both a black
terminal and a white document.

The desktop control is the exception, and §6 explains why: it is the one
surface whose shadow has no room to spread, so on a light desktop its edge has
to be a hairline that is actually there.

---

## 4. Type

Six roles. Adding a seventh needs a reason.

| Token | Value | Role |
| --- | --- | --- |
| `Typo.title` | `.headline` | menu bar header |
| `Typo.noteTitle` | `.subheadline` semibold | the prompt that produced the note |
| `Typo.noteBody` | 13pt | the agent's answer |
| `Typo.menuRow` | 13pt | a menu row — the size macOS sets its own menus in |
| `Typo.label` | `.caption` semibold | agent name — always in a tone label colour |
| `Typo.meta` | `.caption` | workspace, status, secondary rows |
| `Typo.micro` | `.caption2` | relative time |

Plus two non-prose faces: `badge` (9pt bold rounded — it sits on the mark,
not in text) and `glyph` (9pt bold, for `×` inside circular targets).

Everything except `noteBody` maps to a Dynamic Type style, so the app tracks
the user's text size. `noteBody` is fixed because the card is fixed height.

Never hardcode a CJK face. SF resolves to PingFang and Hiragino by locale; a
bundled font would make `跡` look foreign inside its own OS.

---

## 5. Space, radius, dimension

**`Space`** is a 4pt grid: `xxs 2 · xs 4 · sm 6 · md 8 · lg 12 · xl 14 · xxl 24`.
Anything off the grid is a bug or a documented exception.

**`Radius`**: `sm 6 · md 10 · lg 14 · card 18 · control 22`. All continuous —
the product is made of river stones, and a circular corner reads machined next
to them.

**`Metrics`** holds dimensions that are tuned rather than derived, and they are
part of the system, not call-site details:

| Token | Value |
| --- | --- |
| `notePanelWidth` | 384 |
| `noteCardHeight` | 108 |
| `noteCardSpacing` | 8 |
| `noteRail` | 3 × 54 |
| `noteClearAllHeight` | 26 |
| `noteStackShoulder` / `noteStackInset` | 6 / 8 |
| `controlPanel` | 72 × 82 |
| `controlBody` | 58 × 66 |
| `controlMark` | 54 × 59 |
| `badgeSize` | 19 |
| `menuWidth` | 340 |
| `panelGap` / `screenMargin` | 10 / 8 |
| `firstRunInset` | 18 × 34 |
| `settingsWindow` | 520 × 664 |
| `settingsMarkScale` | 1.15 |

`noteCardHeight` is the one number everything else in the queue is derived
from: panel height is `count × (height + spacing) + padding`, which is why a
card must never grow to fit its content.

`noteStackShoulder` and `noteStackInset` describe a stack: notes from one agent
working in one project arrive as a single row, with the edges of the ones
underneath drawn 8pt in from each side and slid 6pt down. Two shoulders at
most — past two, a deeper pile only gets taller without saying anything more.
A closed stack therefore costs `noteCardHeight + 6 × min(count − 1, 2)`, and an
open one costs every card in it; `NoteQueue` owns that arithmetic because the
`NSPanel` has to be sized before SwiftUI draws a single card into it. Opening a
stack is a chip in the note's header rather than a click on the card, because
the card already has a job: it goes back to where the turn ran.

The four `control*` values describe the desktop control at rest. Settings
offers it in three sizes — `small 0.78 · regular 1 · large 1.34` — and each is
these numbers times `CairnControlSize.scale`: panel, body, mark, badge and the
radius that rounds them all move together, so the control never grows out of
the panel that has to hold it. Small stops where it does because that is the
last step at which the body still clears the 44pt pointer target; smaller is
not a discreet control, it is a missed click.

`Surface.windowGround(scheme)` is the ground a Cairn window stands on — wet
stone in the dark, dry sand in the light, always lit from the top — and
`Surface.card(scheme)` is the group of rows resting on it. The card is white at
low alpha in both schemes: light borrowed from above reads as a surface lifted
off the window, where a darker rectangle would read as a hole cut into it.

`Surface.eventVeil` is not a colour anyone is meant to see. macOS routes the
pointer through any pixel a borderless window leaves fully clear, so the note
panel — which paints only where its cards are — used to hand every scroll event
landing between two cards to the app behind it. One alpha step across the whole
panel makes the gaps part of the window again.

---

## 6. Elevation

Cairn owns no chrome, so depth is the only way a surface says it is above the
desktop. Four levels, all soft, all downward — except the attention glow, which
is centred so it reads as light rather than as height.

**A shadow may never be wider than the room it has.** This is the rule the rest
of the section follows from. Cairn draws into transparent panel windows fitted
tightly around their content: the control body has 7pt to either side of it
before the window ends, a note card has 12pt. A window does not fade a blur
that runs past its frame — it cuts it. A generous radius in a tight panel
therefore does not read as a soft shadow at all; it reads as a grey band with a
hard outer edge, obvious on white and invisible on black. Measured on white,
the old `controlResting` (black 22%, radius 9) was still 2.8% dark at the last
pixel inside the window and 0% at the next one: a step, all the way around the
control. That is what a dark ring around the control is. So each level's
extent — roughly `2 × radius + y` — stays inside `Metrics.controlShadowRoom`
(7 × 8) or `Metrics.noteShadowRoom` (12). Depth is bought with tone, never with
reach.

Within that budget every level is two passes, not one: an **ambient** wash that
says how far off the desktop the surface floats, and a shorter **contact** pass
that seats its lower edge. A single blur dark enough to be felt is also dark
enough to show its own rim.

| Token | Ambient (colour · radius · y) | Contact (colour · radius · y) |
| --- | --- | --- |
| `Shadow.note(scheme)` | ink 10% / 20% · 4 · 3 | ink 5.5% / 12% · 1.5 · 1 |
| `Shadow.controlResting(scheme)` | ink 12% / 26% · 3 · 2 | ink at half · 1 · 0.5 |
| `Shadow.controlHover(scheme)` | ink 16% / 32% · 3 · 2 | ink at half · 1 · 0.5 |
| `Shadow.controlAttention` | jade glow 62% · 3.5 · 0 | jade glow 38% · 1.5 · 0 |
| `Shadow.badge` | black 16% · 2 · 1 | — |

Percentage pairs are light / dark scheme. `Shadow.ink(scheme)` is the colour a
shadow is cast in: black on a dark desktop, but `Stone.s70` on a light one —
neutral black over cream or white greys everything it crosses and reads as dirt
on the wallpaper, where the mark's own cool green-grey reads as depth.

Hovering deepens the tone rather than widening the blur; the reach is fixed by
the window, and the lift is carried by `Motion.hover` scaling the control. The
badge is 19pt across, small enough that a second pass would only muddy it. The
attention glow gets the same 7pt as the shadow it replaces, so it is a bright
rim rather than a bloom — the reach that signal needs comes from the halo the
mark throws *inside* the control, which no window edge can cut.

Apply with `.cairnShadow(_:)`, never `.shadow(color:radius:y:)`.

A shadow this short only works if something else draws the edge, and on a light
desktop a borrowed-light hairline is invisible. So `Stroke.controlResting` and
`Stroke.controlHover` are scheme-aware: white 12% / 28% on dark, `Stone.s50` at
20% / 30% on light. This is the one place the light-edges-only rule in §3 bends,
and it is what lets the shadow go back to being depth instead of an outline.

The mark carries one more shadow of its own: `Surface.groundShadow`, the pool
the stack stands in. It is drawn blurred by `Surface.groundShadowBlur` (in mark
units, so it scales with the mark) — a crisp ellipse reads as a fourth stone
lying flat.

---

## 7. Motion

Nothing animates for longer than a third of a second, and nothing animates
unless the user caused it — except one arrival pulse.

| Token | Curve | Fires on |
| --- | --- | --- |
| `Motion.hover` | `easeOut 0.16` | pointer enters the control |
| `Motion.dismiss` | `easeOut 0.18` | a note is dismissed |
| `Motion.toggle` | `spring 0.28 / 0.78` | queue expands or collapses |
| `Motion.enqueue` | `spring 0.32 / 0.86` | a note joins or leaves the queue |
| `Motion.attention` | `spring 0.30 / 0.62` | a note arrives |

`attention` is deliberately the loosest damping in the system — the stack
should overshoot slightly, like a stone settling, rather than snap. It holds
for `attentionHold` (900ms) and then releases on its own. Nothing loops, and
nothing pulses twice.

Scale is capped: `hoverScale 1.045`, `attentionScale 1.075`. A floating control
that grows more than that stops being furniture and becomes an interruption.

---

## 8. Components

**Control** (`CairnControlView`) — 58 × 66 body in a 72 × 82 panel; the extra
14pt is the badge's overhang and the drag target's slop. Ultra-thin material
under a `Surface.controlBody` gradient, so it picks up a hint of whatever is
behind it. Click toggles, drag moves, and the two are told apart by a 5pt
threshold. Position persists across launches.

**Note card** (`CompletionNote`) — fixed 108pt, top-aligned, three bands:
identity row (agent, workspace, time, dismiss), prompt, answer. The answer takes
3 lines when there is no prompt and 2 when there is, so the card is always full
and never ragged. The tone rail is 3 × 54 at the leading edge — deliberately
shorter than the card, so it reads as a bookmark rather than a border.

**Menu bar control center** (`MenuBarQueueView`) — contains status and controls
only. Note contents and queue counts stay on the floating surface, keeping one
authoritative place to read, follow, and dismiss completed turns.

**Settings window** (`CairnSettingsView`) — the mark and the name at the top,
then two titled cards on `Surface.windowGround`, then one full-width Done. It
is the only window that is about Cairn rather than about a note, which is why
it is the only one that opens with the product's own face; nothing else is in
the header, because a line explaining what a settings window is for is a line
nobody reads twice. Rows are label-and-control; rows that open another window
(Connect, Access) are whole-row targets with a chevron, and Connect carries the
same agent marks the menu bar shows. Every Cairn window keeps close and nothing
else — these are fixed sheets, so zoom has nothing to do, and an app with no
Dock icon cannot get a minimised window back.

---

## 9. Adding an agent

The note `source` is the canonical key. Everything else maps onto it.

```swift
// DesignSystem.swift
static let newAgent = Tone(
    hue: Color(hex: 0x______),   // the identity hue — pick this first
    railLight: …, railDark: …,   // adjust until ≥ 3:1 on the wash
    labelLight: …, labelDark: …, // adjust until ≥ 4.5:1 on the wash
    washLight: 0.10, washDark: 0.16
)

case "new-agent":
    Agent(id: source, name: "New Agent", tone: .newAgent)
```

Pick the hue for separability against the four that exist — the queue's whole
job is telling four agents apart in peripheral vision. Prefer the agent's own
brand colour, but separability wins when the two conflict; say which you chose
and why, next to the tone. Then derive the four variants by moving lightness
until the ratios clear, and record them in the table in §3.

A mark is optional. To add one, drop a silhouette SVG in
`Resources/AgentIcons/`, name it in `AgentIconAsset`, and credit it in that
directory's `ATTRIBUTION.md`. Skip all three and the agent gets a lettermark —
which is the right outcome when no accurate vector mark exists.

If the agent also connects through the window, add an `AgentRuntimeIdentity`
whose `toneSource` is this `source`.

---

## 10. Open

- The wordmark is specified but not yet used in the product. Menu bar header,
  About, and the installer scripts still say only `Cairn`.
- `Stone.s00`, `s20`, `s50`, `s70` are defined for ramp completeness and are
  currently unused.
- Contrast values are modelled against an approximated material background.
  A real measurement pass over `.ultraThinMaterial` on light and dark
  wallpaper would let us tighten the washes.
