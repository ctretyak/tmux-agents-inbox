# Inbox preview pane — design

**Date:** 2026-05-28
**Status:** approved (brainstorming) — pending implementation plan
**Scope:** add a per-row preview pane to the `prefix + I` popup so users can triage Claude sessions (what is it asking, what is it working on, where is it stuck) without jumping to the pane.

## Motivation

State detection in `tmux-agents-inbox` is already good — recent commits (`1706187`, `09231dd`, `7232f8c`) have hardened the working / waiting / done classification. What the popup still doesn't tell you is **why** a session is in a given state:

- For *Needs input* rows, the description column is the `ai-title`, not the actual question text.
- For *Working* rows, there's no signal at all about what the agent is doing — you have to jump to find out.
- For *Completed* rows, the title hints at the overall topic but not the final result.

The pain: you press `prefix + I`, see 3–6 sessions, and still have to jump into each one to decide which deserves your attention. The popup is a triage view that doesn't currently support triage.

A preview pane that shows (a) a header derived from the transcript and (b) a live tail of the agent's tmux pane closes that gap with zero new state and no daemon.

## Non-goals

- Replying / sending text from the popup. (That's the deferred "act from inbox" direction.)
- Showing preview from `prefix + N` (`inbox-next.sh` has no popup).
- Custom user-defined preview formatters.
- Caching capture-pane output between refreshes.
- Covering `claude --bg` background sessions (deferred to `claude agents` per the README).

## UX

### Layout

Preview lives on the **right** of the popup at `right:55%` by default (passed straight to fzf `--preview-window`). The list keeps its existing aligned-column layout on the left.

Rationale: claude TUI content is mostly vertical text (code blocks, tool output, prompts). Right-side preview gives both the list and the preview their natural axis. The list columns are short and aligned; the preview carries the long content.

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ agents>                              │ my-app · feature-x · "power-up grid"  │
│ ── Needs input (1) ──                │ ✻ Needs input · 32s · last prompt:    │
│  ✻ my-app feature-x  power-up   32s  │   "build the power-up grid…"          │
│ ── Working (1) ──                    │ ──────────────────────────────────    │
│  ✽ my-app           collision   5s   │ <last ~30 lines of `tmux capture-     │
│ ── Completed (1) ──                  │  pane -p -e -t %42`>                  │
│  ✻ my-app           title       9m   │                                       │
│                                      │                                       │
│ enter: jump · ctrl-s: regroup        │                                       │
│ ctrl-x: kill · ?: preview · esc      │                                       │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Default state

Preview defaults to **off**. The popup retains its current minimal look until the user opts in.

### Toggle

Inside the popup, **`?`** toggles preview visibility (fzf `change-preview-window(hidden|<configured-position>)`). State is per-popup-session (not persisted) — the next `prefix + I` reverts to the configured default.

### Group-header rows

When the cursor is on a `__hdr__` row, the preview shows a single placeholder line (`—`). There is no pane to capture. Up/Down already skip these rows in normal navigation, so this is a flicker case only during cursor traversal.

## Configuration

Two new tmux options (read at popup-open time):

| Option | Default | Meaning |
|---|---|---|
| `@agents-inbox-preview` | `off` | Initial preview visibility (`on` / `off`). Inside the popup, `?` toggles per-session. |
| `@agents-inbox-preview-position` | `right:55%` | Passed straight to fzf `--preview-window`. Power users can set `bottom:50%`, `right:65%`, `down:40%`, etc. |

Both are read by `tmux-agents-inbox.tmux` and passed to `inbox-popup.sh` via environment variables (`AGENTS_INBOX_PREVIEW`, `AGENTS_INBOX_PREVIEW_POS`). Same pattern as existing options.

## Data sources

### Preview header — line 1

`<project> · <sub> · "<ai-title>"`

- Re-derived in `inbox-preview.sh` from the pane id using `tmux display -p '#{pane_current_path}'` + the existing `_proj_sub` and `_title_of` helpers in `lib/common.sh`.
- No new field is threaded through the fzf row — the hot `build_list` path stays unchanged.

### Preview header — line 2

`<icon> <state-label> · <ago> · last prompt: "<first 60 chars>…"`

- `<icon>` and `<state-label>`: derived from `$CACHE/pane-<id>` (one-line read, no parse).
- `<ago>`: same `_ago` helper used by `build_list`.
- `<last prompt>`: tail the transcript JSONL (using the existing `_TITLE_TAIL = 256 KB` cap), pick the most recent `.type == "user"` record, take `.message.content` as a string, collapse whitespace, truncate to 60 chars with `…`.
  - **Requires jq.** Without jq, the line degrades to `<icon> <state> · <ago>` (no `last prompt:` suffix). Consistent with existing fallbacks in `inbox-hook.sh` and `_last_assistant_ends_with_question`.

### Preview body

```
tmux capture-pane -p -e -t <paneid> -S -200 | tail -n <FZF_PREVIEW_LINES - 4>
```

- `-p` — print to stdout.
- `-e` — preserve ANSI escape sequences (color, bold).
- `-S -200` — read up to 200 lines of scrollback as an upper bound (cheap).
- `tail -n` — fit to the preview window's actual line count. fzf exposes `$FZF_PREVIEW_LINES` to the preview command; subtract 4 to leave room for the two header lines + separator + trailing margin.
- If `capture-pane` fails (pane disappeared between list refresh and preview render), body is the single line `(pane closed)`.

## Refresh model

- **On cursor change**: fzf re-runs `--preview` natively. Free.
- **On list reload (every 1 s)**: add `+refresh-preview` to the existing `load` reload bind in `inbox-popup.sh`. So a "working" agent's tail stays current while the user watches it — same cadence as the list itself.

No new timers, no new processes.

## Files touched

| File | Change |
|---|---|
| `scripts/inbox-popup.sh` | Add `--preview` / `--preview-window` flags; add `?` toggle bind; add `+refresh-preview` to the existing `load` bind; update the `--footer` string to include `?: preview`. |
| `scripts/inbox-open.sh` | When preview is on, raise the min-width floor by `preview_cells` (60) so the popup is wide enough for list + preview. Narrow-client fallback: if `list_width + 60 > client_width - 2`, fall back to `bottom:40%` for this open. |
| `tmux-agents-inbox.tmux` | Read `@agents-inbox-preview` / `@agents-inbox-preview-position`; export as `AGENTS_INBOX_PREVIEW` / `AGENTS_INBOX_PREVIEW_POS` for the popup. |
| `scripts/inbox-preview.sh` | **NEW.** Takes `$1 = <pane_id>`. Prints header + separator + body. Pure read, no state writes. Header rows (`{1} == __hdr__`) short-circuit to `—`. |
| `lib/common.sh` | Extract `_last_user_prompt` helper next to `_last_assistant_ends_with_question` (same tail-of-transcript pattern). Used only by `inbox-preview.sh`. |
| `README.md` | Document the two new options, the `?` toggle, the footer change, refresh the ASCII diagram. |

## Risks & mitigations

1. **Popup width on narrow clients.** If `client_width - 2 < list_width + 60`, the popup can't fit both side by side. Fall back to `bottom:40%` for that open. One conditional in `inbox-open.sh`. Does not fail, just degrades.
2. **ANSI bleed.** `capture-pane -e` can include partial escape sequences if the agent is mid-render. fzf preview generally handles partial ANSI fine. If manual testing shows visible artifacts, gate the body through a strip filter (`sed $'s/\x1b\[[0-9;]*m//g'`) behind a future option. Not part of this scope.
3. **jq absence.** The "last prompt" snippet silently degrades to no-snippet. Consistent with existing fallbacks.
4. **Header-row preview flicker.** As the cursor moves across `__hdr__` rows, preview flashes `—`. Acceptable — same UX as fzf preview elsewhere with empty rows. Up/Down skip headers in normal navigation.
5. **Stale pane id.** Between list refresh and preview render, a pane can disappear. `capture-pane` returns empty → `(pane closed)` placeholder.

## Verification plan (manual)

- Open popup with preview off (default). Press `?` to toggle on. Confirm preview appears on the right at 55%.
- Cycle cursor through one row in each of the 5 states (waiting / done / background / working / idle) and a group-header row. Confirm:
  - Header line 1 shows project / sub / title.
  - Header line 2 shows correct icon + state + age. With jq installed, shows last-prompt snippet.
  - Body shows the live tail of the corresponding pane.
- Resize tmux client to < 80 cols and re-open the popup. Confirm preview drops to `bottom:40%` instead of breaking.
- With a pane currently `/compact`-ing: confirm preview still renders sensibly (or shows a graceful empty body).
- `mv $(which jq) $(which jq).bak`, reopen popup with preview on, confirm header line 2 drops the prompt suffix but otherwise renders. Restore jq.
- Kill a pane while popup is open and preview is on that row. Confirm body becomes `(pane closed)` on next refresh, then the row vanishes on the following `load` reload (existing prune behavior).
- Confirm `prefix + N` (`inbox-next.sh`) is unaffected.
