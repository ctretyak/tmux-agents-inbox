# Default popup key `I` → `g` — design

**Date:** 2026-06-02
**Status:** Approved (design)

Change the plugin's default popup key from `prefix + I` to `prefix + g`. `prefix + I` collides with
TPM's own "install plugins" binding — the README already flags this and recommends `g`. Making `g`
the default removes the collision out of the box. Nothing else about the tool changes.

## Goal

Ship `g` as the default for `@agents-inbox-popup-key`, and update the docs to match, removing the
now-obsolete TPM-collision heads-up.

## Non-goals

- The `@agents-inbox-next-key` default stays `N` — unchanged.
- No new option, no key-table / sub-prefix leader, no migration shim. Users who set
  `@agents-inbox-popup-key` explicitly are unaffected.
- `README.md` line about "Then `prefix + I` to install" stays as-is — that is *TPM's* install key,
  not this plugin's.

## Changes

| # | File | Location | Change |
|---|---|---|---|
| 1 | `tmux-agents-inbox.tmux` | line 12 | `get_opt '@agents-inbox-popup-key' 'I'` → `'g'` |
| 2 | `tmux-agents-inbox.tmux` | line 16 | comment `# prefix + I` → `# prefix + g` |
| 3 | `README.md` | line 10 | ASCII diagram `prefix + I  → popup` → `prefix + g  → popup` |
| 4 | `README.md` | line 107 | options-table default cell `I` → `g` |
| 5 | `README.md` | lines 119–121 | **remove** the TPM heads-up note (its reason — the collision — is gone) |

## Verified

- `prefix + g` is **not** a default tmux key binding, so no new collision is introduced.
- No test references the popup-key default (`grep` across `tests/`), so nothing breaks.

## Note

This is a behavior change for existing users relying on the default `I`. The README already steered
users toward `g`, so the change aligns docs and default. There is no CHANGELOG in the repo; worth a
mention in the next release notes.
