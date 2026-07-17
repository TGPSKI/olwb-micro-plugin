# olwb: message navigation, multi-select, and send-to-destination ("the benefits")

## Context

olwb currently captures one-line notes into a Liner → Session → Message feed.
The user's total concept is a *parking lot for a wild graph mind*: capture now,
process later. The missing half is the "benefits" — shipping captured lines to
processors (LLMs like `claude`, the local `leather` agent orchestrator,
clipboard, files) for summaries, idea tracking, and task extraction.

Three features, chosen via Q&A with the user (all "recommended" options):
1. **Per-message navigation** in feed browse mode (Shift-Tab): ↑/↓ jump
   message-to-message, not line-to-line.
2. **Multi-select**: Space toggles the message under the cursor, `a` selects
   all in scope; selected entries get a marker + background highlight.
3. **Send**: Enter in browse mode opens the destination picker (reusing the
   existing Tab-cycle menu); `/send <dest>` also works from the one line.
   Payload = **markdown with metadata** (timestamps/labels, liner title).
   Destinations = **user-editable shell command templates** (stdin pipe) with
   seeded presets. LLM **responses land in a dedicated liner** per destination.

Verified on this machine: `claude` CLI (`claude -p` one-shot) and `leather`
(`leather ingest` stores stdin as a "hide" and can enqueue for curing) both
exist. Exact `leather ingest` flags to be confirmed with `--help` during
implementation.

## Design

### A. Feed index — foundation (render.lua, olwb.lua)

`olwb_render.render_feed` gains a second return value: an index array, one row
per rendered entry:

```lua
{ start = <0-based first buffer line>, stop = <last line>,
  id = msg.id, entry = <flattened entry> }
```

Line numbers are unaffected by `pad_lines` (it only prefixes columns).
`rerender` (olwb.lua) stores it in a new module-local `feed_index` when the
feed is displayed, `nil` when an overlay (menu/options) is shown.

`render_feed` also takes `opts.selected` (set of message ids): each line of a
selected entry is prefixed with `"▌ "`. New syntax rule in `OLWB_SYNTAX`
(assets.lua): `- olwb.selection: "^\\s*▌.*$"` — reuses the existing
`olwb.selection` colorscheme group (`#e0e0e0,#32374d`).

New pure helper `render.render_selection_md(liner, entries, opts)` — the
payload builder. Extract the entry-loop body of the existing
`render_export_md` (render.lua:~140) so both share it; selection version takes
an explicit entry list (feed order).

### B. Browse mode, message-granular (olwb.lua)

New module-locals: `browsing` (bool), `browse_pos` (index into feed_index),
`selected` (set of message ids — persists until sent or cleared).

- **Enter browse** (existing Shift-Tab path in `preOutdentSelection`):
  `browsing = true`, `browse_pos = 1`, cursor → `feed_index[1].start`,
  `fbuf:SetOption("cursorline", "true")` so the current message's first line
  is highlighted.
- **↑/↓** (`preCursorUp`/`preCursorDown`, new FEED_PATH branch): move
  `browse_pos` ∓1 (clamped), `GotoLoc(feed_index[pos].start)`, `Relocate()`.
  Return false.
- **Space** (`preRune` FEED_PATH branch, before the focus-bounce): toggle
  `selected[id]` for the entry at `browse_pos`, rerender. Return false.
- **`a`** (same branch): select all entries in current scope (or clear all if
  all already selected). Return false. All other runes keep the existing
  bounce-to-compose behaviour.
- **Enter** (`preInsertNewline` FEED_PATH branch): if `feed_index` non-empty,
  open the destination picker — focus compose, `set_buffer_text("/send ")`,
  and invoke `cycle_step` so the Tab-cycle machinery immediately presents
  destination candidates. Falls back to plain return-to-line when there are
  no destinations/messages.
- **Leave browse** (Shift-Tab/Tab/typing/Alt-m — all existing paths that call
  `reset_feed_scroll`): `browsing = false`, cursorline off. Selection
  *persists* (so `/send` from the line works); it is cleared by a successful
  send or by `a` on a fully-selected feed.
- **rerender while browsing**: instead of pinning scroll to top, restore
  cursor to `feed_index[browse_pos].start` + Relocate so Space doesn't yank
  the view.
- **Bar** (`bar_text`): append `·  N selected` when selection non-empty; in
  browse mode the shortcut line swaps to
  `↑↓ jump · Space select · a all · Enter send · Shift-Tab back`.

### C. Destinations (olwb.lua, cmd.lua, store)

Persisted as `state.destinations` (array of `{ name, cmd, into }`) in the
existing state.json (store.save_state serializes whatever is in `state`).
Seeded on first run only when the key is absent:

| name | cmd (stdin = payload) | into |
|---|---|---|
| `claude` | `claude -p "Summarize these notes: group brainstormed ideas, extract action items and open questions."` | `inbox` |
| `leather` | `leather ingest …` (flags confirmed at impl time) | `""` (fire-and-forget) |
| `clipboard` | `wl-copy` / `xclip -selection clipboard` (detect at seed time) | `""` |
| `file` | `cat >> <datadir>/outbox.md` | `""` |

`/dest` command (cmd.lua handler + `subverbs.dest = {add, rm, into}`):
- `/dest` — overlay listing destinations (pattern: existing `options_text`)
- `/dest add <name> <shell command…>`
- `/dest rm <name>`
- `/dest into <name> <liner-name|->` (where responses go; `-` = nowhere)

`cmd.candidates` gains `extra.dests` (like `extra.liners`) so `/send ` and
`/dest rm|into ` Tab-cycle destination names.

### D. /send (cmd.lua handler + olwb.lua executor)

`/send <dest>`: payload = selected messages in feed order (from
`flatten_desc` filtered to `selected`); **if nothing is selected, the whole
current scope** (respecting the active filter) is sent. Rendered with
`render_selection_md`.

Execution in olwb.lua (`ctx.send_to` wired via build_ctx, same pattern as
`set_option`):
1. Write payload to `<datadir>/tmp-send-<id>` via existing
   `olwb_store.write_file_atomic`.
2. `local shell = import("micro/shell")` (new import) —
   `shell.JobStart("sh -c '<cmd> < <tmpfile>'", onStdout, onStderr, onExit)`
   async so micro never blocks. Accumulate stdout in a closure.
   (Verify exact JobStart signature against micro 2.0.15 during impl; the
   sync `shell.ExecCommand` is the fallback if job callbacks misbehave.)
3. `onExit`: delete temp file. If `dest.into` non-empty: load-or-create that
   liner, append the response as a message labeled `#<dest>` (existing
   `new_message`/`save_liner` helpers), `persist_registry`. Info bar:
   `sent N message(s) to <dest>` / error on non-empty stderr + empty stdout.
4. Clear `selected`, rerender.

Note: sending must NOT disturb the active liner — the response liner is
loaded, appended, saved, and dropped without touching `active_liner`/state
(unless `into` IS the active liner, then mutate in place + rerender).

### E. Docs & help

- `help_entries` += `/send <dest>`, `/dest …` rows; browse-mode keys.
- assets.lua OLWB_HELP + regenerate help/olwb.md (awk one-liner used before).
- README: new "The benefits — sending" section under Usage.

## Files touched

- `render.lua` — feed index, `▌` selection markers, `render_selection_md`
- `olwb.lua` — browse state, key branches (preRune/preCursorUp/Down/
  preInsertNewline/preOutdentSelection), destinations seed + send executor
  (`micro/shell`), bar text, build_ctx wiring
- `cmd.lua` — `send` + `dest` verbs, handlers, subverbs, `extra.dests`
- `assets.lua` — syntax rule, help text; regen `help/olwb.md`
- `tests/run_tests.lua` — render index/markers, payload builder, `/send` +
  `/dest` dispatch against mock ctx (mock `ctx.send_to`, `ctx.dests`)
- `tests/harness.lua` — mock `micro/shell` (JobStart no-op) if olwb.lua
  imports it at top level
- `README.md`

## Micro API landmines (from this session, in memory notes)

- Focus changes need `tab:SetActive(i)` via the `focus()` helper, never bare
  `SetActive(true)`.
- rerender must park buffer cursors (bar drift bug) — keep the browse-aware
  cursor restore inside the same pcall.
- `preRune`/`preCursorUp`/`preCursorDown`/`preInsertNewline` callback
  branches must stay path-guarded (`bp.Buf.Path`) exactly like today.
- User's real `~/.config/micro/settings.json` is not isolated in tmux tests.

## Verification

1. `make check` — unit tests for index, markers, payload, dispatch.
2. tmux end-to-end (pattern used throughout this project — isolated
   `XDG_DATA_HOME`, capture-pane):
   - capture 6+ messages → Shift-Tab → ↑↓ jumps land on entry starts
     (capture cursor row), Space marks (`▌` + highlight via `capture -e`),
     `a` selects all, bar shows `N selected`.
   - Enter → picker appears with destination candidates; cycle to a test
     destination defined as `sed 's/^/RE: /'` with `into=inbox` (deterministic
     fake LLM) → send → `inbox` liner exists on disk with the `RE:` response,
     labeled; selection cleared; active liner untouched.
   - `/dest add`/`rm`/`into` overlay round-trip; `/send clipboard` with
     `wl-copy` absent shows a clean error, not a hang.
3. Real `claude` destination smoke test once, manually (user-triggered — it
   spends tokens).
