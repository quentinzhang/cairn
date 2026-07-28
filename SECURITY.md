# Security and privacy

Cairn sits in an unusually sensitive position: it runs inside your coding
agents' processes and reads what they say. This document states exactly what it
touches, so you can verify the claims rather than trust them.

## Reporting a vulnerability

Do not open a public issue. Use GitHub's private vulnerability reporting:

**[Report a vulnerability](https://github.com/quentinzhang/cairn/security/advisories/new)**

Include what you did, what happened, and the affected version
(`Cairn.app` → menu bar → version, or `CFBundleShortVersionString` in
`Contents/Info.plist`). Expect a first response within a week. Cairn is a
personal project, not a company with an on-call rotation — please size your
expectations accordingly, and say so if you have a disclosure deadline.

Things worth reporting: anything that gets note contents off the machine,
anything that escalates the privacy grants Cairn asks for, any way a crafted
payload in the inbox causes code execution or makes Cairn act on it, any way a
bridge can be induced to break or hang the agent it runs inside.

## What Cairn reads

Each bridge extracts exactly two things from a completed turn — the final
assistant message and the most recent user prompt — and discards everything
else. Specifically:

- **Claude Code** — the `Stop` hook payload's `last_assistant_message`. The
  transcript at `transcript_path` is read only to recover the latest user prompt,
  or as a compatibility fallback when `last_assistant_message` is absent.
- **Codex** — the final assistant message from the JSONL transcript passed to the
  `Stop` hook.
- **Hermes** — the `assistant_response` and `user_message` arguments handed to
  the `post_llm_call` hook.
- **OpenClaw** — the last assistant and last user message from `agent_end`.
  Newer OpenClaw builds gate this behind `allowConversationAccess`, which the
  installer explains and asks about before enabling.

Reasoning traces, tool calls, tool output, file contents, and intermediate
messages are never copied into a note.

Alongside the text, a bridge records a **locator**: terminal session environment
variables (`TERM_PROGRAM`, `TERM_SESSION_ID`, `ITERM_SESSION_ID`, `TMUX_PANE`),
the controlling tty, the process ancestry's `.app` bundle paths and pids, and the
working directory. This is what makes clicking a note return you to where the
turn ran. It is paths and identifiers, not content.

## Where it goes

Two places on your disk, both mode `0700`:

```
~/Library/Application Support/Cairn/inbox/            one JSON file per turn, deleted on read
~/Library/Application Support/Cairn/completions.json  the 50 most recent sessions
```

Both are **plaintext and unencrypted**, protected by nothing more than file
permissions and macOS's own protections on your home directory. Treat them as
you would treat your shell history: anything with local access to your account
can read them. If your agent output routinely contains secrets, that is a
reason to be deliberate about installing Cairn.

Notes are also held in memory by the running app and drawn on screen — a note is
visible to anyone looking at your display or recording it.

## What leaves the machine

One request, automatically once a day or when the user chooses **Check for
Updates**:

```
GET https://api.github.com/repos/quentinzhang/cairn/releases/latest
```

It sends no identifiers beyond what any HTTPS request implies and carries no
note data. Automatic failures stay silent; a user-initiated failure produces
only an in-app retry state. Nothing else in Cairn opens a network connection.
There is no account, no server, no telemetry, no analytics, no crash reporting.

## macOS privacy grants

The core queue needs **no** privacy permission. Cairn draws its own
non-activating floating panels, so it does not request notification access and
does not take keyboard focus.

Two optional grants, requested one application at a time from **Access** in the
menu bar, upgrade the precision of trail-back:

- **Accessibility** — raise and focus a specific window.
- **Automation**, per application — return to an exact Apple Terminal tab, an
  exact iTerm2 session, or a specific browser tab.

Without them, a click activates the app and, failing that, opens Finder. The
one prompt a note click can raise is the Automation consent for the app the
note leads back into — Terminal, iTerm2, or your browser — the first time and
at most once per click. Declining just means the fuzzier fallback, and a
recorded denial is never re-asked. Every grant stays visible and revocable
from the same Access panel.

## Trust boundaries you should know about

- **The inbox is a local trust boundary.** Cairn treats a payload as data, not
  instructions: `result` is displayed as text, never executed or interpreted as a
  command. But any process running as your user can write to the inbox and
  therefore put arbitrary text on your screen attributed to any source. It cannot
  make Cairn run anything.
- **Hooks run as you.** Installing a bridge means an agent runtime executes
  `/usr/bin/python3 <path>/cairn_*_hook.py` at the end of every turn, with your
  full user privileges. That path is written into your runtime's config, so
  moving or replacing the checkout changes what runs. `cairn_doctor.py` reports
  the exact path each runtime is configured to execute — check it if you are
  unsure.
- **Codex will not run an untrusted hook** and requires you to approve it through
  `/hooks`. That is a feature; Cairn depends on it.
- **Releases are signed and notarized.** A release build uses hardened runtime
  signing, is notarized and stapled, and passes Gatekeeper validation before
  publication. A build you compile yourself falls back to ad-hoc signing, which
  is fine locally but means macOS treats each rebuild as a new application and
  discards its privacy grants.

## Starting over

To go back to a first-run state without uninstalling anything — every agent
disconnected, the queue emptied, the preferences cleared, the app left in
place:

```bash
python3 Scripts/cairn_reset.py          # prints its plan, changes nothing
python3 Scripts/cairn_reset.py --yes    # does it
```

`--keep-notes` spares the queue; `--keep-permissions` spares the Accessibility
and Automation grants, which are otherwise revoked so macOS asks for them
again. Everything it touches belongs to Cairn: its own handler in each agent's
config, its own directory under Application Support, its own preference
domain, and its own TCC rows.

## Removing Cairn completely

Disconnect every agent from Cairn's **Connect** window, or from a terminal —
these work from a checkout and from inside an installed app alike:

```bash
for agent in codex claude openclaw hermes skills; do
  python3 Scripts/cairn_connect.py disconnect "$agent"
done
rm -rf ~/Library/Application\ Support/Cairn
rm -rf /Applications/Cairn.app
```

Inside an installed app the scripts live in
`/Applications/Cairn.app/Contents/Resources/`, so uninstalling that way means
removing the handlers *before* deleting the app.

Disconnecting removes only Cairn's own handler and leaves every other hook and
setting in your config files untouched. It also refuses to delete anything it
did not create: a real directory in Cairn's plugin slot is reported, never
replaced. Revoke any Accessibility or Automation grants in System Settings →
Privacy & Security.
