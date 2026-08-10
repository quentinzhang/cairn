# Returning to a conversation inside VS Code — design note

How a note whose turn ran under a VS Code extension (Claude Code, Codex) can
follow its trail back to the **exact conversation**, not merely the app or the
window.

This is a design note, not a frozen contract. It records what was learned by
reverse-engineering the two extensions, what was confirmed by hand, what Cairn
already has, and the shape of the work — so the implementation can start from
evidence. The deep links it describes are private, undocumented extension
surfaces; every use of them must degrade quietly to today's window-level trail.

Extensions inspected: `anthropic.claude-code` 2.1.209, `openai.chatgpt`
26.715.61943 (VS Code Insiders, darwin-arm64). Behaviour confirmed by hand on
2026-08-08.

---

## 1. Where the trail stops today

Standalone clients already return at conversation level: Codex Desktop through
`codex://threads/<session_id>`, Claude Desktop through
`claude://claude.ai/claude-code-desktop/<id>`. Terminal and iTerm return to the
exact session by tty / session UUID.

VS Code stops one level short. The current path in
[`TrailFinder.followTrail`](../Sources/Cairn/TrailFinder.swift#L385-L413) is
**window-level**:

1. Take the captured extension-host pid (`locator.hostAppPID`) and run
   `code --status` at click time.
2. Parse `<pid> extension-host [windowId]` → `window [id] (title)` to learn that
   window's exact title.
3. Raise only an unambiguous single AX title match, then `activate()`.

Its ceiling and its fragility: it targets a *window*, not a conversation; it
needs the extension host still alive, needs Accessibility, needs the `--status`
text format to hold, and needs the title to be unique — and on any miss it
degrades to `revealInFinder(cwd:)`, the "returned me to my home folder"
failure.

The goal of this note is a conversation-level layer above that window step,
using the same kind of deep link the desktop clients already enjoy.

---

## 2. The mechanism — both extensions expose a conversation deep link

Both extensions register a `vscode://` URI handler
(`window.registerUriHandler`) that can address a specific conversation — the
same class of mechanism as `codex://` / `claude://`, spoken in VS Code's own
deep-link protocol.

| Extension | Deep link (scheme per §4) | Addressing | Internal landing |
|---|---|---|---|
| Claude Code (`anthropic.claude-code`) | `<scheme>://anthropic.claude-code/open?session=<uuid>` | `session` query param | `primaryEditor.open` → `createPanel(session)` → reveal, else spawn `claude --resume=<uuid>` |
| Codex (`openai.chatgpt`) | `<scheme>://openai.chatgpt/local/<uuid>` | URI **path** = webview route | `handleUri` → `navigateToRoute(path)` → resume thread |

Confirmed routes:

- **Codex** — `/local/<uuid>` ✅ and `/hotkey-window/thread/<uuid>` ✅ both
  resume the thread; `/chatgpt/quick-chat/<uuid>` ✗ opens a blank tab. Thread
  resume is **workspace-agnostic** — it works in whichever window receives the
  URI. Use `/local/<uuid>` as canonical.
- **Claude** — `createPanel(id)` reveals an already-open panel for that id, else
  builds and spawns `claude --resume=<id>` (also `--session-id`,
  `--fork-session`, `--resume-session-at` exist) in the receiving window's
  **workspace folder**. Because a Claude Code session is bound to its project
  directory (`~/.claude/projects/<encoded-cwd>/<uuid>.jsonl`), resume is
  **workspace-scoped**: routed to a window whose workspace matches the
  session's cwd it resumes the real conversation ✅; routed elsewhere
  `--resume` finds nothing and a **new conversation** opens.

### The routing fact (the load-bearing discovery)

VS Code dispatches a `vscode://` URI to the **last-focused window**, not to the
window that owns the conversation. Confirmed by hand: with the conversation
originating in one Cairn window, focusing a *different* Cairn window and firing
the link opened the panel in the **focused** window. This is why the first
Claude test opened a new conversation — the link was cross-workspace — and why
Codex could land in the wrong project's window.

Everything below follows from this: **raise the right window first (making it
last-focused), then fire the link.**

### Activation caveat

Codex declares `onUri` in `activationEvents`; Claude does not (only
`onStartupFinished`). With VS Code already running — the normal trail-back case
— Claude's handler is already registered. It only races on a full cold start of
the editor, an acceptable edge for a "return to where I was" gesture.

---

## 3. The ids line up — and Cairn already captures them

The deep links key on a UUID, and Cairn already records exactly that UUID as
`completion.sessionID`, verified against each producer's store:

- **Claude Code** — the session id is the CLI transcript's own name,
  `~/.claude/projects/**/<uuid>.jsonl`. The Stop hook Cairn installs fires for
  these turns (`~/.claude/settings.json` carries it) and reports that same
  uuid; `?session=<uuid>` spawns `claude --resume=<uuid>` against the same
  store. Confirmed: `?session=602e35…` resumed the exact prior conversation.
- **Codex** — sessions live at
  `~/.codex/sessions/**/rollout-<ts>-<uuid>.jsonl`, indexed by that `id` in
  `~/.codex/session_index.jsonl`. This is the same id already spent on
  `codex://threads/<session_id>`
  ([`ConversationTrail.codexThreadURL`](../Sources/Cairn/TrailFinder.swift#L26-L40)),
  and the webview's `conversationId` is a UUID from that same store. Confirmed:
  `/local/<uuid>` resumed the matching thread.

**Consequence: the capture side (`cairn_locator.py`, the hooks) needs no
change.** A VS Code conversation deep link is buildable today from
`completion.source` (`claude-code` / `codex`), `completion.sessionID`, and the
host bundle Cairn already resolves.

---

## 4. The design — raise the right window, then reveal the conversation

Keep today's window-level precision and add a conversation-level reveal on top,
ordered by the routing fact. The integration point is the existing VS Code
branch ([`TrailFinder.swift:392`](../Sources/Cairn/TrailFinder.swift#L392)).

```
VS Code branch (source ∈ {claude-code, codex}, host ∈ VS Code family):
  1. Identify the turn's exact window and raise it
       (existing extension-host-pid → code --status → AX focus + activate)
     — raising makes it VS Code's last-focused window, the URI's destination.
  2. Build the plugin deep link, scheme chosen by host build:
       claude-code → <scheme>://anthropic.claude-code/open?session=<uuid>
       codex       → <scheme>://openai.chatgpt/local/<uuid>
  3. NSWorkspace.open(deep link).
  4. Degrade (see per-plugin rules) → today's window-level → revealInFinder.
```

**Scheme must match the host build** (Cairn already knows the bundle):

| Host bundle | Scheme |
|---|---|
| `com.microsoft.vscode` | `vscode://` |
| `com.microsoft.vscodeinsiders` | `vscode-insiders://` |
| Cursor (`com.todesktop.230313mzl4w4u92`) | `cursor://` |
| VSCodium | `vscodium://` |

Getting this wrong means the link silently does not open — and this repo is
developed against **Insiders**, so `vscode://` is the wrong scheme for local
testing.

### Per-plugin degradation rules (from the workspace-scope asymmetry)

- **Claude** — resume is workspace-scoped, so a link landing in the wrong window
  creates a **stray new conversation** (harmful). Therefore fire
  `?session=<uuid>` **only after the exact-window raise succeeds** (the
  extension-host-pid match guarantees the workspace matches). If exact-window
  targeting fails, do **not** fire the link — fall back to today's behaviour.
  Raising the exact window also lands the reveal on the panel that is already
  open there, avoiding a duplicate resume.
- **Codex** — thread resume is workspace-agnostic and harmless in any window, so
  firing `/local/<uuid>` is a **strictly better fallback than Finder** even when
  the exact window can't be identified. Prefer raise-then-link for the right
  window; if the raise fails but a VS Code family window exists, still fire the
  link rather than revealing the cwd.

---

## 5. Risks and remaining verification

1. **AX focus vs. VS Code's URI routing (the one open question).** The design
   assumes Cairn's `focusWindow` + `activate()` sets the *same* "last-active
   window" that VS Code's URI dispatcher reads. A human click does; AX
   focus+activate should approximate it but **must be verified during build**.
   If it doesn't, an alternative is needed (e.g. fire the link, then raise — but
   Codex navigates immediately, so ordering options are limited).
2. **Private contracts.** `/open?session=` and Codex's internal routes are
   undocumented and may shift between extension versions. The deep link is only
   ever an additional, more precise layer; any failure falls back and never does
   worse than today. Claude's query contract is steadier than Codex's route
   path — pin the Codex route behind a small, easily-updated constant.
3. **Terminal vs. panel surface.** A Claude turn run in the integrated terminal
   resolves to the same VS Code host as a panel turn; firing `?session=` brings
   it back as a *panel* rather than the terminal. That is arguably an upgrade,
   but it is a surface change — decide deliberately, and consider gating on
   whether the turn actually ran under the extension host.
4. **Codex webview readiness** with the sidebar closed — the handler `await`s a
   readiness step; confirm it opens the sidebar rather than no-opping.

---

## 6. Status of the open questions

| Question | Status |
|---|---|
| Claude `?session=<uuid>` resumes the real conversation, id = Cairn's `sessionID` | ✅ confirmed (workspace-matched, focused window) |
| Codex thread route + `conversationId` = `sessionID` | ✅ `/local/<uuid>` confirmed |
| VS Code routes the URI to the focused window | ✅ confirmed |
| Cairn's AX raise makes that window the URI destination | ⏳ verify during Phase 1 |
| Hermes Desktop/CLI conversation-level scheme | ⏳ separate investigation |

---

## 7. Rollout

- **Phase 1 — Claude first** (steadiest contract). Add "raise exact window → deep
  link" to the VS Code branch, scheme-by-bundle, with the Claude gate (fire only
  after an exact-window raise). This is also where risk 1 (AX → routing) is
  proven or disproven.
- **Phase 2 — Codex**, using `/local/<uuid>`, with the harmless-fallback rule.
- **Phase 3** — "already on this conversation → only raise"; extend
  [`ConversationTrailTests`](../Tests/CairnTests/ConversationTrailTests.swift)
  with deep-link construction cases (scheme-by-bundle, source→link mapping).
- **Phase 4** (optional) — Hermes Desktop conversation-level, investigated
  separately.
