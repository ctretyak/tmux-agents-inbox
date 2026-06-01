# tmux-agents-inbox

See which Claude Code agents are waiting on you — **done** or **needing input** — across every tmux
session, window, and pane. A status-line summary gives you the count at a glance, one key opens a
popup listing all your Claude sessions with live, auto-refreshing status, and Enter jumps you straight
to that exact pane (even in another tmux session). One more key jumps to the next waiting agent without
opening the popup.

```
prefix + I  → popup                                            status-right
┌─────────────────────────────────────────────────────────┐    ⚡2 ⏳1 ✢1 ✓3
│ agents>                                                 │    (working/waiting/background/done)
│ ── Needs input (1) ──                                   │
│  ✻ my-app       feature-x      power-up design     1m   │    prefix + N → next waiting
│ ── Completed (1) ──                                     │    ctrl-s    → regroup
│  ✻ my-app                      title screen        9m   │    (state · session · flat)
│ ── Background (1) ──                                    │
│  ✢ my-app                      data export         2m   │
│ ── Working (1) ──                                       │
│  ✽ my-app                      collision system    5s   │
│                                                         │
│ enter: jump   ctrl-s: regroup   esc: close              │
└─────────────────────────────────────────────────────────┘
 columns: status icon · project · subfolder · description · age
```

## How it works

**Which sessions show up:** every tmux pane currently running an interactive `claude` process —
detected by mapping live Claude processes to their pane (a process-tree walk). So a session never
vanishes while it's still alive, and sessions started *before* the hooks were installed still appear.
(Background `claude --bg` sessions, the `claude agents` TUI, and the supervisor are deliberately
excluded — those are agent view's job; see [Background sessions](#background-sessions).)

**Status** is recorded by a small Claude Code hook that runs inside each pane and writes a one-line
state file keyed by the pane id (`~/.cache/tmux-agents-inbox/pane-<id>`). State mapping:
`SessionStart` → idle (but `source: compact` keeps it **working** since the session is still active),
`UserPromptSubmit` / `PreToolUse` → working, `Notification` → waiting (`idle_prompt` reminders are
ignored so a finished session stays Completed), `Stop` → done (or **background** if a `background_tasks`
entry is still running), `SessionEnd` → removed. A live pane with no state file yet shows as **idle**.

When a hook record goes stale (after `/compact`, or for sessions that predate the install), the
popup reconciles with **live transcript activity**: if the session's transcript was written in the
last ~12 s the row is shown as working; otherwise the most recent transcript mtime drives the **age**
column.

**Description** is the session's `ai-title` (the same auto-generated title Claude shows in
`--resume`), read from the **tail** of the transcript so the cost is constant regardless of session
length. Falls back to the tmux window name when no title has been generated yet.

Everything is computed **on demand** (no daemon): the popup rebuilds every 1 s while open
(`@agents-inbox-refresh-interval`), the status line on tmux's `status-interval`. Jumping uses
`switch-client` + `select-window` + `select-pane` on the pane id.

> **Done vs needs-input is best-effort.** Claude Code's hooks fire `Stop` both when a turn finishes and
> when the agent asks a plain-text question, and `Notification` covers permission prompts *and* idle
> reminders. The inbox treats **waiting and done together** as "needs me" — which is what you actually
> want to act on.

## Requirements

- tmux ≥ 3.2 (uses `display-popup`)
- [fzf](https://github.com/junegunn/fzf)
- bash (3.2+; macOS system bash is fine)
- jq (only for `install-hooks.sh`; the hook itself has a jq-free fallback)

## Install

### 1. The plugin (TPM)

```tmux
set -g @plugin 'ctretyak/tmux-agents-inbox'
```

Then `prefix + I` to install. Or clone manually and add
`run-shell ~/path/to/tmux-agents-inbox/tmux-agents-inbox.tmux` to `~/.tmux.conf`.

### 2. The Claude Code hooks

Run the installer (backs up `settings.json`, preserves your existing hooks, idempotent):

```sh
bash ~/.tmux/plugins/tmux-agents-inbox/install-hooks.sh
```

Restart any running Claude Code sessions afterward. If you prefer to edit `settings.json` by hand, see
[Manual hook setup](#manual-hook-setup) below.

### 3. The status-line summary (optional)

Add the summary to your own `status-right` (recommended — it won't clobber your config):

```tmux
set -g status-right '#(~/.tmux/plugins/tmux-agents-inbox/scripts/inbox-status.sh) %H:%M'
```

Or let the plugin append it for you:

```tmux
set -g @agents-inbox-auto-status 'on'
```

## Options

| Option | Default | Meaning |
|---|---|---|
| `@agents-inbox-popup-key` | `I` | Key (after prefix) to open the inbox popup. |
| `@agents-inbox-next-key` | `N` | Key (after prefix) to jump to the next waiting agent. |
| `@agents-inbox-popup-min-width` | `50%` | Floor for the auto-sized popup width. Accepts `<N>%` (percent of client) or `<N>` (cells). |
| `@agents-inbox-popup-min-height` | `60%` | Floor for the auto-sized popup height. Same format. |
| `@agents-inbox-popup-width` | *(unset)* | Optional **fixed** width — if set, replaces auto-fit + min. Same format. |
| `@agents-inbox-popup-height` | *(unset)* | Optional **fixed** height — if set, replaces auto-fit + min. Same format. |
| `@agents-inbox-refresh-interval` | `1` | Seconds between auto-rebuilds of the open popup. |
| `@agents-inbox-auto-status` | `off` | If `on`, append the summary to `status-right` (idempotent; preserves your existing value). |
| `@agents-inbox-preview` | `off` | Show a preview pane in the popup with the agent's live tmux output + transcript-derived header. Toggling with `?` rewrites this option globally for the current tmux server, so the choice persists across popup opens until you change it again. |
| `@agents-inbox-preview-position` | `right:55%` | Passed straight to fzf `--preview-window`. Accepts e.g. `right:50%`, `bottom:40%`, `left:60%`. |

> **Heads-up for TPM users:** the default popup key `prefix + I` is the same key TPM binds to "install
> plugins". This plugin will override it. Pick another key if you want to keep TPM's shortcut, e.g.
> `set -g @agents-inbox-popup-key 'g'`.

In the popup: **Enter** jumps, **Ctrl-X** kills the agent in that pane, **?** toggles the preview pane, **Ctrl-S** switches grouping (state → session → flat), **Esc** closes. Type to fuzzy-filter. The list **auto-refreshes** every 1 s by default (`@agents-inbox-refresh-interval` to change). Group headers (the `── Needs input (N) ──` lines) are **non-selectable** — Enter on them is a no-op, and Up/Down skip past them.

Rows are grouped under headers with counts — **Needs input / Completed / Background / Working / Idle** —
most-urgent first, newest-first within each group. (**Background** is a finished turn with a still-running
`background_tasks` entry — monitors, watches, long-running shells.) Each row shows: a colored status icon, project,
subfolder (the worktree name or path within the repo, blank at the repo root), the session's
`ai-title` description, and how long ago the session was last active.

The popup is **sized to fit its content**, floored by `@agents-inbox-popup-min-width` /
`-min-height` (defaults `50%` / `60%` of the client) and capped at `client − 2`. Set
`@agents-inbox-popup-width` / `-height` for a fixed size that overrides the auto-fit entirely.

With `@agents-inbox-preview` set to `on`, the popup reserves additional width (or, on narrow clients, additional height at the bottom) for a preview pane. The preview shows for the currently-highlighted row: a header with project / subfolder / `ai-title` and the row's state / age / most-recent user prompt, then a live tail of the agent's tmux pane. Press `?` inside the popup to toggle the preview on or off for that session.

## Background sessions

This plugin only tracks **interactive** Claude sessions running in tmux panes. For **background**
sessions (`claude --bg`, or anything you've sent to the background), use Claude Code's built-in agent
view, which already groups them by state with live summaries:

```sh
claude agents          # full-screen TUI: peek, reply, attach
claude agents --json   # scriptable list of background sessions
```

## Manual hook setup

Merge these into the `hooks` object of `~/.claude/settings.json` (append to existing event arrays
rather than replacing them). Replace the path with your actual plugin path — the install script writes
the correct absolute path automatically, so the script is recommended.

```json
{
  "hooks": {
    "SessionStart":     [ { "hooks": [ { "type": "command", "command": "bash ~/.tmux/plugins/tmux-agents-inbox/hooks/inbox-hook.sh SessionStart" } ] } ],
    "UserPromptSubmit": [ { "hooks": [ { "type": "command", "command": "bash ~/.tmux/plugins/tmux-agents-inbox/hooks/inbox-hook.sh UserPromptSubmit" } ] } ],
    "PreToolUse":       [ { "hooks": [ { "type": "command", "command": "bash ~/.tmux/plugins/tmux-agents-inbox/hooks/inbox-hook.sh PreToolUse" } ] } ],
    "PreCompact":       [ { "hooks": [ { "type": "command", "command": "bash ~/.tmux/plugins/tmux-agents-inbox/hooks/inbox-hook.sh PreCompact" } ] } ],
    "Notification":     [ { "hooks": [ { "type": "command", "command": "bash ~/.tmux/plugins/tmux-agents-inbox/hooks/inbox-hook.sh Notification" } ] } ],
    "Stop":             [ { "hooks": [ { "type": "command", "command": "bash ~/.tmux/plugins/tmux-agents-inbox/hooks/inbox-hook.sh Stop" } ] } ],
    "SessionEnd":       [ { "hooks": [ { "type": "command", "command": "bash ~/.tmux/plugins/tmux-agents-inbox/hooks/inbox-hook.sh SessionEnd" } ] } ]
  }
}
```

## Caveats

- **Only tracks Claude running inside a real tmux pane** on the current tmux server. An agent in a
  `display-popup`, a detached non-tmux terminal, or over plain SSH is invisible and can't be jumped to.
- **Single tmux server.** Pane ids can collide across separate tmux servers; the cache isn't namespaced
  per server yet.
- A row drops as soon as its `claude` process exits (membership is process-based), so a crashed or
  quit agent disappears on the next refresh even if it never fired `SessionEnd`. A still-running agent
  whose hooks have gone silent (e.g. background-only work) reconciles against the transcript: if the
  transcript hasn't been touched, the row may show as Completed even though work is happening — the
  transcript is our ground truth and pure background shells don't write to it.
- Reading the `ai-title` description tails the last ~256 KB of the session transcript on each
  refresh — constant time regardless of session length.

## Uninstall

Remove the `@plugin` line, delete the `inbox-hook.sh` entries from `~/.claude/settings.json` (or restore
a `settings.json.bak.*` backup), and `rm -rf ~/.cache/tmux-agents-inbox`.
