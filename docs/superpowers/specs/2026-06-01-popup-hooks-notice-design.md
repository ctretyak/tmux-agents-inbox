# Popup notice when hooks are not detected — design

**Date:** 2026-06-01
**Status:** Approved (design) — refined by a 3-round cross-review debate (Opus/Sonnet/Gemini/Codex)

One small convenience: when the inbox can't detect the Claude Code hooks in your user settings, show a
non-selectable warning **inside the popup** so you understand why states look approximate (or why the
list is empty) and how to fix it. The notice appears only while the hooks aren't detected and
disappears once they are. Nothing else about the tool changes.

> Earlier ideas were considered and **dropped** to keep the tool minimal: OS/push notifications, a
> setup keybinding + popup installer, a `doctor` self-check, and a fire-once load-time hint. The popup
> is the right place — it's exactly where the user notices something's off.

## Goal

Surface a clear, non-selectable, honestly-worded banner at the top of the popup when the hooks aren't
detected, pointing the user at the existing `install-hooks.sh`. Persistent (shown every open /
refresh) until fixed — not a one-time message.

## Non-goals

- No keybinding, no popup installer, no automatic or silent edits to `~/.claude/settings.json`.
- No `doctor` self-check, no notifications, no daemon.
- No dismiss / "don't show again" state (rejected: reintroduces a config surface and silent state).
- The notice does not block or change anything in the list; rows still render below it.

## Detection: honest and cheap (debate outcome)

The check is a **detection heuristic, not an installation proof** — named accordingly.

- New helper **`_hooks_detected()`** in `common.sh`. Returns true when the **resolved absolute hook
  path** appears in the user settings file.
  - Settings file: `$CLAUDE_SETTINGS` if set, else `~/.claude/settings.json`. **User scope only**
    (Option A) — this is exactly what `install-hooks.sh` writes, so the check validates the state the
    installer creates without re-implementing Claude Code's multi-location settings precedence.
  - Needle: the **resolved `<plugin-dir>/hooks/inbox-hook.sh` absolute path** (derived from
    `common.sh`'s own location), **not** the bare basename. Matching the full installed path catches a
    relocated/renamed plugin that a basename grep would miss, and stays a single cheap `grep` — no
    `jq`, honoring the project's deliberate jq-free hook stance.
- **Wording — never claim "installed".** Banner text:
  `⚠ hooks not detected in ~/.claude/settings.json — status may be approximate — run: bash <plugin-dir>/install-hooks.sh`
  This states exactly what was checked, so the documented blind spots below are *true statements*, not
  false alarms.

### Accepted, documented blind spots

These are deliberately not handled (the proper fix is the `doctor` we dropped):

1. **Project-scope / `settings.local.json` install.** Hooks wired in a project `.claude/settings.json`
   instead of user settings → banner still shows. True per the scoped wording; rare (there is no
   project-scope installer). Documented in README.
2. **Partial / stale install.** A wrong/old path that doesn't match the resolved needle → banner shows
   (acceptable — that *is* a broken install). A correct path present but only some of the 7 events
   wired → detected as present, no banner, even though states may be incomplete. Accepted: detecting
   this requires per-event JSON validation (doctor-grade, dropped). Transcript reconciliation still
   yields usable states.
3. **Wrapper / symlink install.** A custom wrapper invoking the hook indirectly won't match the
   resolved path → false banner. Same rare, sophisticated user; can set `$CLAUDE_SETTINGS` or ignore
   the non-selectable line.

## Rendering

- **`build_list`** (in `common.sh`) emits the banner line **before** its normal pipeline output when
  `_hooks_detected` is false:
  - First field is `__hdr__` → **non-selectable for free** (inbox-popup.sh:35-37 makes Enter a no-op
    on `__hdr__` lines and skips them with Up/Down).
  - Rendered in a **distinct warning color** (e.g. `$C_WAIT`), not the default header color, so it
    reads as a warning rather than a group header.
- **Shown even when there are zero panes** — that empty-popup-on-first-run case is precisely when the
  banner is most useful (debate: unanimous after Sonnet conceded "suppress when empty").
- `build_list` is the genuine single source: both the first-paint snapshot (`inbox-open.sh` →
  `build_list`) and the ~1 s refresh (`_build.sh` → `build_list`) flow through it, so the banner shows
  in both with no extra wiring.
- When the hooks **are** detected, `build_list` emits nothing extra and the popup is unchanged.

## Cost

One small-file `grep` per `build_list` call (~1/s while the popup is open). Negligible next to the
existing `claude_panes` + per-pane transcript reads. No caching (debate: caching a sub-ms grep only
adds an invalidation bug).

## Error handling

- Missing or unreadable settings file → treated as "not detected" → banner shown (that's exactly when
  the user needs it).
- Banner is just another `__hdr__` row; it cannot break list rendering, sizing, or navigation.

## Testing

Uses the existing `tests/` harness; `$CLAUDE_SETTINGS` points at fixtures.

- `build_list` emits the banner when the settings fixture lacks the resolved hook path.
- `build_list` emits **no** banner when the fixture contains the resolved hook path.
- **Resolved-path specificity:** a fixture containing a *different* path that merely ends in
  `inbox-hook.sh` (relocated/stale) → banner still shows (guards against bare-basename matching).
- Missing settings file → banner emitted.
- Unreadable / malformed-JSON settings → banner emitted (treated as not detected; grep, no parse).
- **Zero-pane popup + hooks not detected → banner is the sole line** (not suppressed).
- Banner line's first field is `__hdr__` (non-selectable) — and remains so **across a reload**.

## Files

- **Edited:** `lib/common.sh` (`_hooks_detected` helper + warning-colored banner emission in
  `build_list`).
- **Edited:** `README.md` — one line on the popup hook-detection notice + the user-settings-only /
  project-scope caveat.

No new scripts.

## Debate provenance

Refined via `/octo:debate` (3 rounds, cross-review). Converged: honest "not detected" wording, rename
to `_hooks_detected`, no interactive/dismissible banner, show even with zero panes, keep in
`build_list`, no mandatory jq, distinct color, expanded tests. Standing dissent: Codex preferred
multi-location grep (Option B); Opus/Sonnet/Gemini chose user-scope grep (Option A) because B needs
per-pane cwd resolution at 1 Hz for a global banner. Adopted Codex's strongest sub-point
(resolved-path match over basename). Full transcript:
`~/.claude-octopus/debates/local/001-popup-hooks-notice/`.
