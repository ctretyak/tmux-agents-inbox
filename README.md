# tmux-agents-inbox

See which Claude Code agents are waiting on you — **done** or **needing input** — across every tmux
session, window, and pane. A status-line summary gives you the count at a glance, one key opens a
popup listing all your Claude sessions with live, auto-refreshing status, and Enter jumps you straight
to that exact pane (even in another tmux session). One more key jumps to the next waiting agent without
opening the popup.

```
prefix + I  → popup                                  status-right
┌──────────────────────────────────────────────┐      ⚡2 ⏳1 ✓3
│ agents>                                        │   (working/waiting/done)
│ ── Needs input (1) ──                          │
│  ✻ power-up design   my-app [feature-x]   1m   │   prefix + N → next waiting
│ ── Working (1) ──                              │   ctrl-s    → regroup
│  ✽ collision system  my-app               5s   │   (state · session · flat)
│ ── Completed (1) ──                            │
│  ✻ title screen      my-app               9m   │
└──────────────────────────────────────────────┘
 icon = state (color too) · description · folder [worktree] · session:win.pane · age
```

## How it works

**Which sessions show up:** every tmux pane currently running an interactive `claude` process —
detected by mapping live Claude processes to their pane (a process-tree walk). So a session never
vanishes while it's still alive, and sessions started *before* the hooks were installed still appear.
(Background `claude --bg` sessions, the `claude agents` TUI, and the supervisor are deliberately
excluded — those are agent view's job; see [Background sessions](#background-sessions).)

**Status** comes from a small Claude Code hook that runs inside each pane and writes a one-line state
file keyed by the pane id (`~/.cache/tmux-agents-inbox/pane-<id>`). State mapping: `SessionStart` →
idle, `UserPromptSubmit`/`PreToolUse` → working, `Notification` → waiting, `Stop` → done (stays working
if a background task is still running), `SessionEnd` → removed. A live pane with no state file yet
shows as **idle**.

**Description** is the session's `ai-title` (the same auto-generated title Claude shows in `--resume`),
read from the transcript; it falls back to the tmux window name.

Everything is computed **on demand** (no daemon): the popup rebuilds ~once a second while open, the
status line on tmux's `status-interval`. Jumping uses `switch-client` + `select-window` +
`select-pane` on the pane id.

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
| `@agents-inbox-popup-key` | `I` | Key (after prefix) to open the inbox popup |
| `@agents-inbox-next-key` | `N` | Key (after prefix) to jump to the next waiting agent |
| `@agents-inbox-popup-width` | `80%` | Popup width |
| `@agents-inbox-popup-height` | `70%` | Popup height |
| `@agents-inbox-auto-status` | `off` | If `on`, append the summary to `status-right` |

> **Heads-up for TPM users:** the default popup key `prefix + I` is the same key TPM binds to "install
> plugins". This plugin will override it. Pick another key if you want to keep TPM's shortcut, e.g.
> `set -g @agents-inbox-popup-key 'g'`.

In the popup: **Enter** jumps, **Ctrl-S** switches grouping (by state → by session → flat), **Esc**
closes. Type to fuzzy-filter. The list **auto-refreshes** about once a second.

Rows are grouped under headers with counts — **Needs input / Working / Completed / Idle** — most-urgent
first; each row shows a status icon, the session's description, its `session:window.pane`, and how long
ago it last changed.

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
  whose last hook was missed may show a stale *status* (e.g. `working`) until the next hook fires.
- Reading the `ai-title` description greps the session transcript on each refresh — negligible for
  normal use, but very large transcripts add a little cost.

## Uninstall

Remove the `@plugin` line, delete the `inbox-hook.sh` entries from `~/.claude/settings.json` (or restore
a `settings.json.bak.*` backup), and `rm -rf ~/.cache/tmux-agents-inbox`.
