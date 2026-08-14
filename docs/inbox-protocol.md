# Cairn Inbox Protocol — version 1

How anything that finishes work tells Cairn about it.

Cairn does not integrate with agents. It reads a directory. Any program that can
write a file can publish a note: the five bundled bridges (Codex, Claude Code,
Hermes, OpenClaw, OpenCode) have no privileged path, and a shell one-liner is a
first-class producer. This document is the contract between producers and the
app, and it is the part of Cairn intended to outlive this particular macOS
implementation.

**Stability.** Version 1 is frozen. New optional fields may be added; existing
fields will not change meaning, type, or nullability. A change that would break
a version-1 producer gets a new `version` number, and Cairn will accept both.

---

## 1. The inbox

```
~/Library/Application Support/Cairn/inbox/
```

Created on demand by whichever side gets there first — the app on launch or a
producer on its first publish. A producer must never require the app to exist
or broaden access to an existing inbox. The Cairn support directory, inbox, and
payload files must remain accessible only to the current user; bundled
producers repair that boundary on every publish. Notes written while Cairn is
closed wait on disk and are picked up at next launch; that is the point of
using a directory rather than a socket.

One file is one completed unit of work. Files are consumed and deleted by the
app, so the inbox is a queue, not a log. Cairn's own durable store lives beside
it (`../completions.json`) and is not part of this protocol.

## 2. Publishing a note

Two steps, in this order:

1. Write the complete JSON to a **dot-prefixed** temporary file in the inbox
   directory: `.<nonce>.pending`.
2. `rename(2)` it to its final name: `<stamp>-<nonce>.json`.

```python
tmp = inbox / f".{nonce}.pending"
tmp.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
os.replace(tmp, inbox / f"{stamp}-{nonce}.json")   # atomic, same volume
```

Both steps matter:

- **Dot-prefix during the write.** Cairn enumerates with `skipsHiddenFiles`, so
  a partially written `.pending` file is invisible to it. Writing directly to
  `*.json` races the 400 ms poll and can expose a truncated file.
- **Rename, not copy.** The temporary file must be in the inbox directory so the
  rename stays on one volume and is therefore atomic. A cross-volume "rename"
  degrades to a copy and reintroduces the race.

### Filename

```
<stamp>-<nonce>.json
    stamp  UTC, %Y%m%dT%H%M%S%fZ   e.g. 20260727T164512338410Z
    nonce  random hex, ≥16 chars    e.g. uuid4().hex
```

Cairn processes files **sorted lexicographically by filename**, so a
timestamp-first name is what preserves arrival order. The nonce prevents
collisions between concurrent producers. Neither part is parsed for data — the
authoritative time is the `timestamp` field inside the payload.

### Encoding

UTF-8, no BOM. A single JSON object. Do not escape non-ASCII (`ensure_ascii=False`);
Cairn's notes are frequently CJK. Pretty-printing is allowed but pointless.

## 3. Payload

```json
{
  "id": "01H8XYZ:turn-42",
  "version": 1,
  "event": "codex.turn.completed",
  "session_id": "01H8XYZ",
  "turn_id": "turn-42",
  "cwd": "/Users/you/src/project",
  "title": "Codex completed · project",
  "result": "The final assistant message, as plain text.",
  "status": "completed",
  "source": "codex",
  "timestamp": "2026-07-27T16:45:12.338410Z",

  "user_message": "make the trail-back work in iTerm",
  "model": "gpt-5-codex",
  "platform": "cli",
  "locator": { "term_program": "iTerm.app", "tty": "ttys004" }
}
```

### Required fields

A payload missing any of these, or with the wrong type, **fails to decode**. See
§6 for what happens then.

| Field | Type | Meaning |
| --- | --- | --- |
| `id` | string | Globally unique for this note. Cairn ignores a second note with an `id` it has already accepted, which makes publishing idempotent under retry. Convention: `<session_id>:<turn_id>`. |
| `version` | integer | Protocol version. Send `1`. |
| `event` | string | `<source>.<subject>.<verb>`, e.g. `codex.turn.completed`, `claude-code.turn.completed`, `note.saved`. Used for display grouping and as the fallback source (§4). |
| `session_id` | string | The conversation this note belongs to. **This is the field that controls queue behaviour** — see §5. |
| `cwd` | string | Absolute working directory of the turn. May be `""` when there is none (a chat surface with no filesystem context). Used for the workspace name shown on the note. |
| `title` | string | One line, already formatted for display. Cairn does not rewrite it. Convention: `<Source> completed · <context>`. |
| `result` | string | The body of the note: plain text, the final output and nothing else. No streaming deltas, no tool logs, no reasoning traces. Markdown is rendered lightly. |
| `status` | string | `"completed"`. Reserved for future states; only completed work should be published today. |
| `timestamp` | string | RFC 3339 / ISO 8601 UTC. Fractional seconds optional, `Z` or `+00:00` both accepted — prefer `Z` with microseconds. |

### Optional fields

Omit rather than sending `null`, and omit rather than sending `""`.

| Field | Type | Meaning |
| --- | --- | --- |
| `turn_id` | string | The individual turn within the session. |
| `source` | string | Lowercase producer id (§4). Strongly recommended. |
| `user_message` | string | The prompt that produced this result. Shown as the note's bold headline, collapsed to one line. Keep it short; this is a topic, not a transcript. |
| `model` | string | Model that produced the result, for display only. |
| `platform` | string | The surface the turn ran on: `cli`, `desktop`, `gateway`, `whatsapp`, … For `hermes` and `openclaw` this replaces the workspace name in the note's context line. |
| `locator` | object | Where the turn ran, so a click can return there (§7). |

Unknown fields are ignored, not rejected. That is the extension point: a
producer may include extra keys, and a future Cairn may start reading them.

### Size

Keep `result` at or below **50 000 characters**. Every bundled bridge truncates
at that limit and appends a one-line marker (`… Result shortened by Cairn's
<source> relay.`). Cairn does not enforce a cap on read, but the note UI is a
floating panel, not a document viewer — a megabyte of `result` is a producer
bug, not a feature.

## 4. `source`

`source` is normalized by trimming and lowercasing. When it is absent, Cairn
falls back to the first dot-component of `event`. Sending it explicitly is
strongly preferred.

Registered sources get a name, an SF Symbol, and a colour:

| `source` | Display | Tone |
| --- | --- | --- |
| `codex` | Codex | teal |
| `hermes` | Hermes | violet |
| `claude-code` | Claude Code | terracotta |
| `openclaw` | OpenClaw | blue |
| `opencode` | OpenCode | neutral |

Any other value is accepted and rendered generically: the source string
capitalized with a neutral tone. Compact note headers use explicit source names
rather than proxy glyphs. **An unregistered source is a supported, permanent
state, not a degraded one** — you do not need a change to Cairn to ship a
producer. Adding a row to that table is a cosmetic upgrade; open a PR with your
source id if you want one.

Reserve a source id that names your producer (`aider`, `my-ci`), not the model
behind it.

## 5. Queue semantics: one note per session

Cairn keeps the **50 most recent distinct sessions**, keyed by

```
<normalized source> : <session_id>
```

For each key it keeps exactly one note — the newest. This is the single most
important behavioural consequence of the protocol, and it is controlled entirely
by what you put in `session_id`:

- **Same `session_id`** on a later note *replaces* the earlier one in place. A
  ten-turn conversation occupies one slot in the queue and shows its latest
  state. This is what you want for a live agent session.
- **New `session_id`** adds a note and evicts the 51st-oldest session. Use a
  fresh id when the notes are genuinely independent results.

Two examples from the bundled producers:

- The Stop hooks pass the agent's own session id straight through, so a long
  session updates one note instead of burying the queue.
- `cairn_save.py` defaults to `save:<directory-leaf>:<path-fingerprint>`.
  The readable leaf keeps the session recognizable while a stable, shortened
  SHA-256 fingerprint of the normalized full path prevents same-named projects
  from collapsing together. Repeated saves from one path still update one
  note; `--new` forces a fresh uuid.

A note with an `id` Cairn has already seen is dropped entirely, so retrying a
failed publish is safe.

## 6. How Cairn consumes the inbox

- Polls the directory every **400 ms** (no FSEvents; a poll is simpler and the
  latency is invisible next to an LLM turn).
- Considers only visible files with a `.json` extension, sorted by filename.
- Decodes each one. On success: **deletes the file, then presents the note.**
- On decode failure: **skips the file and leaves it in place.** There is no
  quarantine directory. A malformed payload therefore stays in the inbox and is
  re-attempted every poll, forever.

That last point is the failure mode worth designing against: a producer that
emits an invalid payload leaves permanent litter that a user has to find. Run
`Scripts/cairn_doctor.py` to detect it — it reports stale files and names the
first validation error in each. Validate against this document before shipping a
producer, and note that a producer must be correct on the *first* write; there
is no negotiation, no error channel, and no acknowledgement.

## 7. `locator` — trailing back to where work happened

Optional, and best-effort by nature. A locator is captured **inside the agent's
process at the moment the turn completes**, which is the only time this
information exists: the terminal session ids are in the environment, and the
process ancestry leads up to whichever GUI app hosts the session. Cairn replays
it when a note is clicked.

| Field | Type | Source |
| --- | --- | --- |
| `term_program` | string | `$TERM_PROGRAM` |
| `term_session_id` | string | `$TERM_SESSION_ID` (Apple Terminal) |
| `iterm_session_id` | string | `$ITERM_SESSION_ID` |
| `tmux_pane` | string | `$TMUX_PANE` |
| `tty` | string | Nearest ancestor's controlling tty, e.g. `ttys004` |
| `agent_pid` | integer | The agent process |
| `host_app_path` | string | Innermost `.app` bundle in the process ancestry |
| `host_app_pid` | integer | Its pid |
| `host_apps` | array of `{path, pid}` | **Every** `.app` ancestor, innermost first |
| `web_url` | string | For browser-hosted surfaces: the URL to reopen instead of a local window |
| `browser_bundle_id` | string | Optional browser hint, e.g. `com.google.Chrome`; Cairn remembers the browser after a successful tab match when omitted |

Notes for producers:

- `host_apps` exists because bundles stack — a headless harness bundle can sit
  under a desktop app — and only the resolver at click time can tell which layer
  is a real, activatable GUI app. Send the whole chain; do not pre-pick. The
  chain also decides whether a conversation-level deep link is safe to follow:
  a link that *imports* a session — Claude Code's `claude://resume` does — has
  to be withheld from a turn whose host app already holds that conversation,
  or one conversation becomes two entries there.
- Cut each path at the **first** `.app/` boundary so Electron helper bundles
  resolve to their outer application, and skip anything with `.framework/`
  before that boundary.
- Exclude your own hook process: an interpreter living inside `Xcode.app` or
  `Python.app` is not a window anyone can return to.
- Building a locator must never fail a turn. Degrade to whatever you did manage
  to observe, or to `{}`, and omit the key entirely if empty.

`Scripts/cairn_locator.py` is a working reference implementation (~100 lines,
standard library only) and is copied into the app bundle; import it rather than
reimplementing it if you are writing a Python producer.

OpenCode plugins run in OpenCode's server process. A TUI that starts its own
server inherits the terminal environment and ancestry, so its locator can
activate that terminal normally. With `opencode serve` followed by an external
attach, the same fields identify the server process rather than the attached
TUI; a click therefore degrades to activating the server host (or Finder).

Precise return needs optional macOS privacy access (Accessibility, per-app
Automation), granted from **Access** in the menu bar. Without it, a click
degrades to activating the app, then to Finder. Cairn never raises a permission
prompt from an ordinary note click.

For a captured VS Code/Cursor host, a stale extension-host PID, an unreadable
editor status report, or a failed exact Accessibility match stays on the editor
route: Cairn falls back to the recorded app and workspace-title hints. Finder is
used only after no GUI host can be resolved, never as the fallback for a known
running editor.

### 7.1 DeepSeek Harness Web

The bundled DeepSeek Harness producer is the prebuilt Cordis bundle in
`DeepSeekHarnessPlugin/`. It supports the verified `0.1.0-rc.5` and
`0.1.0-rc.6` event contract and mounts only in the selected `web` profile. A
future or otherwise unknown version is shown as unverified rather than
connected.

It observes committed `session/event` records but publishes only a top-level
`turn/end` whose reason is `completed`. From that turn it keeps the latest
real user-source text and final non-empty assistant text. Subagents, aborted or
failed turns, reasoning blocks, tool arguments/results, and the full trajectory
never enter Cairn. Publishing is queued, atomic, private (directory `0700`,
file `0600`), and fail-open so a missing Cairn inbox cannot fail the Harness
turn.

`locator.web_url` records `http://127.0.0.1:<actual-port>/` from the injected
live Web server, including OS-assigned ports. This is a best-effort return to
the Harness root, not a conversation deep link or panel synchronization. A
note made before a dynamic-port restart may retain an old URL.

Connect/Disconnect manages only Cairn's local bundle and the explicitly
selected `web` profile. It does not install, upgrade, build, stop, or restart
Harness and does not touch another profile. Profile changes do not hot-load:
the UI distinguishes restart-to-connect and restart-to-disconnect using the
profile manifest plus a process-owned runtime marker.

## 8. Reliability rules for producers

These are non-negotiable, and every bundled bridge follows them:

1. **Never fail the host.** A publish error — missing directory, full disk,
   permission denied, no Cairn installed — must be swallowed. Exit `0`. Wrapping
   the entire publish in a catch-all is correct here, not lazy.
2. **Never block.** Budget a few hundred milliseconds. The bundled hooks declare
   a 3-second timeout and normally finish in well under one.
3. **Publish only finished, successful work.** Interrupted turns, API failures,
   and empty results produce no note. An empty `result` is not a note.
4. **Publish only the final answer.** Not tool calls, not reasoning, not partial
   output. Cairn is a queue of conclusions.
5. **Send only what the note shows.** A producer reading a transcript should
   extract the last user prompt and the final reply and discard the rest. Cairn
   is a local, unencrypted, plaintext queue on the user's disk; treat everything
   you put in it as something the user will see and might screenshot.
6. **No network.** A producer publishes to the local filesystem. Nothing in this
   protocol involves a server or an account.

## 9. Minimal producers

Shell:

```bash
inbox="$HOME/Library/Application Support/Cairn/inbox"
support="${inbox%/inbox}"
nonce=$(uuidgen | tr -d - | tr 'A-Z' 'a-z')
stamp=$(date -u +%Y%m%dT%H%M%S000000Z)
mkdir -p "$inbox"
chmod u=rwx,go= "$support" "$inbox"
cat > "$inbox/.$nonce.pending" <<JSON
{"id":"build:$nonce","version":1,"event":"ci.build.completed",
 "session_id":"build:myproject","cwd":"$PWD",
 "title":"Build finished · myproject","result":"Build completed successfully.",
 "status":"completed","source":"ci",
 "timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
JSON
chmod u=rw,go= "$inbox/.$nonce.pending"
mv "$inbox/.$nonce.pending" "$inbox/$stamp-$nonce.json"
```

Python, using the bundled helper — the shortest correct path for any local tool:

```bash
echo "Build completed successfully." | python3 Scripts/cairn_save.py --source ci --prompt "nightly build"
```

Node: see [`OpenClawPlugin/index.js`](../OpenClawPlugin/index.js) for a complete
implementation in ~40 lines of publish logic.

## 10. Versioning

`version` is an integer, currently `1`. Cairn requires the field to be present
and numeric; it does not currently reject unfamiliar values, but do not rely on
that — a future release will.

Within version 1: fields are only added, and only as optional. If you depend on
a field, the guarantee above covers you.

A version 2 would mean a required field changed shape. It will be introduced
alongside continued acceptance of version 1, announced in the repository, and
documented here rather than replacing this document.

Changes to this protocol are proposed as pull requests against this file.
Discussion of a new field belongs here before it belongs in the app.
