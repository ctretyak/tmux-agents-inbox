# Default popup key `I` → `g` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Change the plugin's default popup key from `prefix + I` to `prefix + g` and update the docs to match.

**Architecture:** A single default-value change in the TPM entry point plus four doc edits. The option name and behavior are unchanged; only the fallback value passed to `get_opt` and the documentation differ. Users who set `@agents-inbox-popup-key` explicitly are unaffected.

**Tech Stack:** bash, tmux, Markdown. No test framework touches the popup-key default (verified via `grep` across `tests/`), so this is a docs-and-default change with manual verification.

**Spec:** `docs/superpowers/specs/2026-06-02-default-popup-key-g-design.md`

---

### Task 1: Change the default in the TPM entry point

**Files:**
- Modify: `tmux-agents-inbox.tmux:12` and `tmux-agents-inbox.tmux:16`

- [ ] **Step 1: Change the default value**

In `tmux-agents-inbox.tmux`, line 12, change the fallback from `'I'` to `'g'`:

```bash
popup_key="$(get_opt '@agents-inbox-popup-key' 'g')"
```

- [ ] **Step 2: Update the binding comment**

In `tmux-agents-inbox.tmux`, line 16, change the comment to match:

```bash
# prefix + g  -> open the inbox popup (launcher sizes it to fit the content)
```

- [ ] **Step 3: Verify the file still sources cleanly**

Run: `bash -n tmux-agents-inbox.tmux`
Expected: no output, exit code 0 (no syntax error).

- [ ] **Step 4: Verify the default resolves to `g`**

Run (simulates the option being unset):

```bash
bash -c 'get_opt() { local v; v="$(tmux show -gqv "$1" 2>/dev/null)"; if [ -n "$v" ]; then printf "%s" "$v"; else printf "%s" "$2"; fi; }; tmux() { return 1; }; export -f tmux; echo "$(get_opt "@agents-inbox-popup-key" "g")"'
```

Expected: prints `g`.

- [ ] **Step 5: Commit**

```bash
git add tmux-agents-inbox.tmux
git commit -m "feat: default popup key to prefix + g (avoids TPM collision)"
```

---

### Task 2: Update the README

**Files:**
- Modify: `README.md:10`, `README.md:107`, `README.md:119-121`

- [ ] **Step 1: Update the ASCII diagram**

In `README.md`, line 10, change:

```
prefix + I  → popup                                            status-right
```

to:

```
prefix + g  → popup                                            status-right
```

Keep the surrounding spacing/alignment of the ASCII box intact.

- [ ] **Step 2: Update the options table default**

In `README.md`, line 107, change the default cell from `I` to `g`:

```
| `@agents-inbox-popup-key` | `g` | Key (after prefix) to open the inbox popup. |
```

- [ ] **Step 3: Remove the obsolete TPM heads-up note**

In `README.md`, delete the three-line blockquote at lines 119–121 (and the blank line that follows it if it leaves a double blank):

```
> **Heads-up for TPM users:** the default popup key `prefix + I` is the same key TPM binds to "install
> plugins". This plugin will override it. Pick another key if you want to keep TPM's shortcut, e.g.
> `set -g @agents-inbox-popup-key 'g'`.
```

The collision it warns about no longer exists once `g` is the default, so the note is removed entirely.

- [ ] **Step 4: Verify no stray `prefix + I` references for our plugin remain**

Run: `grep -n "prefix + I\|popup-key.*\`I\`\|→ popup" README.md`
Expected: the only remaining `prefix + I` is line 75 ("Then `prefix + I` to install") — that is **TPM's** install key, not this plugin's, and must stay. The `→ popup` line now reads `prefix + g`.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: update README for default popup key prefix + g"
```

---

### Task 3: Manual end-to-end verification

**Files:** none (manual check)

- [ ] **Step 1: Reload the plugin in a live tmux with the option unset**

Ensure `@agents-inbox-popup-key` is not set, then source the entry point:

Run: `tmux source-file tmux-agents-inbox.tmux` (or restart tmux / re-run TPM install)

- [ ] **Step 2: Confirm the binding landed on `g`**

Run: `tmux list-keys | grep inbox-open`
Expected: a line binding key `g` to `run-shell ... inbox-open.sh` (prefix table).

- [ ] **Step 3: Confirm the popup opens on `prefix + g`**

In tmux, press `prefix` then `g`.
Expected: the inbox popup opens.

---

## Self-Review

- **Spec coverage:** All five changes in the spec table map to steps — change #1 (line 12) → Task 1 Step 1; #2 (line 16) → Task 1 Step 2; #3 (README:10) → Task 2 Step 1; #4 (README:107) → Task 2 Step 2; #5 (README:119–121) → Task 2 Step 3. Verified-facts and the `next-key` non-goal need no code. ✓
- **Placeholder scan:** No TBD/TODO; every code step shows the exact line. ✓
- **Type consistency:** Option name `@agents-inbox-popup-key` used identically everywhere; `next-key` untouched. ✓
- **Left-alone guard:** Task 2 Step 4 explicitly protects `README.md:75` (TPM's install key). ✓
