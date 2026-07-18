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

### C. Destinations (olwb.lua, cmd.lua, store, dest.lua)

Persisted as `state.destinations` (array of `{ name, cmd, into, kind }`) in
the existing state.json (store.save_state serializes whatever is in `state`).
`kind = nil | "claude" | "codex" | "opencode"` — a non-nil kind opts the
destination into the adapter machinery (JSON output parsing, session resume,
TUI mode; C2–C4). `kind = nil` destinations are plain stdin pipes exactly as
before.

**Agent-config concept**: olwb defines no agents and stores no agent
definitions. Each CLI has its own registry (`claude --agent` from
`~/.claude/agents`, `opencode --agent` from opencode.json — e.g. the
review/verify/gh-issues pack in opencode-config, codex `--profile` from
`~/.codex/config.toml`). An "agent-flavored preset" is just a destination
whose `cmd` names one of those agents; the destination binds CLI kind +
agent flag + response liner + its own session scope (sessions key on the
destination name, so `oc-review` and plain `opencode` hold separate
conversations per liner).

**Kind inference**: `/dest add` infers `kind` from the cmd's leading token
(`claude` / `codex` / `opencode` → that kind; anything else → nil), so an
agent preset is one command — `/dest add oc-review "opencode run --agent
review"` is immediately session-aware. `/dest kind` overrides the inference.

Seeded on first run only when the key is absent:

| name | cmd (stdin = payload) | into | kind |
|---|---|---|---|
| `claude` | `claude -p "Summarize these notes: group brainstormed ideas, extract action items and open questions."` | `inbox` | `claude` |
| `codex` | `codex exec` (reads stdin natively) | `inbox` | `codex` |
| `opencode` | `opencode run "Summarize these notes: group brainstormed ideas, extract action items and open questions."` | `inbox` | `opencode` |
| `leather` | `leather ingest …` (flags confirmed at impl time) | `""` (fire-and-forget) | — |
| `clipboard` | `wl-copy` / `xclip -selection clipboard` (detect at seed time) | `""` | — |
| `file` | `cat >> <datadir>/outbox.md` | `""` | — |

`/dest` command (cmd.lua handler +
`subverbs.dest = {add, rm, into, kind, session}`):
- `/dest` — overlay listing destinations (pattern: existing `options_text`)
- `/dest add <name> <shell command…>` (kind inferred, see above)
- `/dest rm <name>`
- `/dest into <name> <liner-name|->` (where responses go; `-` = nowhere)
- `/dest kind <name> <claude|codex|opencode|->` (override inference; `-` =
  plain pipe)
- `/dest session list` — overlay of stored `dest|liner → session` mappings
- `/dest session clear <name>` — forget the active liner's session for that
  destination (next send starts fresh)

`cmd.candidates` gains `extra.dests` (like `extra.liners`) so `/send ` and
`/dest rm|into|kind|session clear ` Tab-cycle destination names.

### C2. Adapters — new pure module `dest.lua` (`olwb_dest`)

Pure (no micro/Go imports, plain-lua loadable, same discipline as cmd.lua).
One adapter per kind, three responsibilities each:

- `wrap(cmd, session_id|nil)` → the shell command actually run: appends the
  JSON output flag (`--output-format json` / `--json` / `--format json`)
  and the resume mechanism (`--resume <id>` / `-s <id>`). Codex quirk:
  resume is a *subcommand*, so the adapter rewrites the `codex exec` prefix
  to `codex exec resume <id>` — documented constraint: codex-kind cmds must
  start with `codex exec`.
- `parse(stdout)` → `{ session_id, text }, err`. claude: single JSON object
  (`session_id`, `result`). codex/opencode: tolerant NDJSON — pcall-decode
  each line with the vendored `json.lua` (it `error()`s on bad input),
  collect the session/thread id and concatenate assistant text parts. Exact
  event shapes to be pinned as test fixtures after one cheap real run per
  CLI at impl time.
- `tui(session_id|nil, payload_path)` → the interactive command for C4:
  `claude --resume <id>` / `codex resume <id>` / opencode equivalent
  (resume flag confirmed at impl time; `opencode attach` as fallback
  candidate). With no session: fresh TUI with initial prompt
  `Process the notes in <payload_path>` (all three accept an initial prompt
  argument).

Only olwb-generated values (session ids, datadir paths) are ever appended
to command strings — user text travels via stdin/payload files exclusively.

### C3. Sessions — multi-send continuity

- `state.dest_sessions["<dest>|<liner_id>"] = session_id`, persisted in
  state.json.
- Headless send with kind set: `wrap()` with the stored id (nil on first
  send); on success store the parsed id and append the parsed *text* (never
  raw JSON) to the `into` liner.
- Stale session: a resumed run exiting non-zero clears the stored id and
  retries **once** fresh; second failure surfaces stderr in the bar.
- TUI sends (C4) resume the same session — headless context carries into
  the interactive window. Limitation, documented: a TUI-created *fresh*
  session can't be captured (interactive stdout isn't ours).

### C4. TUI send mode — `/send <dest> tui`

- Optional trailing `tui` arg on `/send` (picker unchanged; headless stays
  the default).
- Executor: write payload to `<datadir>/tui-<id>.md`
  (`write_file_atomic`), build the command via the adapter's `tui()`, spawn
  detached in a **new terminal window**:
  `sh -c 'setsid <term> <cmd> >/dev/null 2>&1 &'`. micro keeps running; no
  job tracking beyond the spawn succeeding.
- Terminal autodetect at seed time — `$TERMINAL` first, then
  konsole/foot/alacritty/kitty/xterm via `command -v`; stored as
  `state.termcmd`, overridable with `/set termcmd "<cmd>"` (new entry in
  the `set` subverb table). Clean error if nothing found.
- `kind = nil` destinations reject `tui` with a clear bar error.

### D. /send (cmd.lua handler + olwb.lua executor)

`/send <dest> [tui]`: payload = selected messages in feed order (from
`flatten_desc` filtered to `selected`); **if nothing is selected, the whole
current scope** (respecting the active filter) is sent. Rendered with
`render_selection_md`. The `tui` arg branches to C4; the rest of this
section is the headless path.

Execution in olwb.lua (`ctx.send_to` wired via build_ctx, same pattern as
`set_option`):
1. Write payload to `<datadir>/tmp-send-<id>` via existing
   `olwb_store.write_file_atomic`. Command = `dest.cmd` for kind-nil
   destinations, else `olwb_dest.wrap(dest.cmd, stored_session_id)` (C2/C3).
2. `local shell = import("micro/shell")` (new import) —
   `shell.JobStart("sh -c '<cmd> < <tmpfile>'", onStdout, onStderr, onExit)`
   async so micro never blocks. Accumulate stdout in a closure. Increment
   `pending_jobs[dest.name]` (B2 indicator).
   (Verify exact JobStart signature against micro 2.0.15 during impl; the
   sync `shell.ExecCommand` is the fallback if job callbacks misbehave.)
3. `onExit`: delete temp file, decrement `pending_jobs`. Kind destinations:
   non-zero exit on a *resumed* run → clear the stored session id and retry
   once fresh (C3) before reporting; on success `olwb_dest.parse(stdout)`
   yields `{ session_id, text }` — store the id, response text = `text`
   (kind-nil: response text = raw stdout). If `dest.into` non-empty:
   load-or-create that liner, append the response as a message labeled
   `#<dest>` with provenance first line `↩ N notes from <source-liner>`
   (existing `new_message`/`save_liner` helpers), `persist_registry`, and
   bump `state.unread[into_liner_id]` when it isn't the active liner (B2).
   Info bar: `sent N message(s) to <dest>` / error on non-empty stderr +
   empty stdout.
4. Clear `selected`, rerender.

Note: sending must NOT disturb the active liner — the response liner is
loaded, appended, saved, and dropped without touching `active_liner`/state
(unless `into` IS the active liner, then mutate in place + rerender).

### D2. Inbox UX — badge, working indicator, Alt-i toggle

The inbox is deliberately just a liner — responses are ordinary messages,
so the whole feed/filter/label/export surface applies for free. What's
added is noticing and reaching it:

- `state.unread` map `liner_id → count` (persisted): incremented in D step
  3 when a response lands in a non-active liner; cleared when that liner
  becomes active (any open path, including Alt-i).
- Module-local `pending_jobs` (dest name → in-flight count).
- `bar_text` appends, when applicable:
  `·  <dest> working…` (any pending job) and `·  <liner>: N new` per liner
  with unread > 0 (named per liner since destinations may target liners
  other than `inbox`).
- **Alt-i**: toggle active liner ↔ the default `inbox` liner, remembering
  the previous liner so a second Alt-i returns (same keybind registration
  pattern as the existing Alt-m). Creates `inbox` on first use if absent.

### E. Docs & help

- `help_entries` += `/send <dest> [tui]`, `/dest …` (incl. kind/session),
  `/set termcmd` rows; browse-mode keys; Alt-i.
- assets.lua OLWB_HELP + regenerate help/olwb.md (awk one-liner used before).
- README: new "The benefits — sending" section under Usage — headless vs
  TUI mode, sessions, agent-flavored presets (one `/dest add` example per
  CLI), the inbox badge/toggle.

## Files touched

- `render.lua` — feed index, `▌` selection markers, `render_selection_md`
- `dest.lua` — **new** pure module: per-kind adapters (`wrap`/`parse`/`tui`)
- `olwb.lua` — browse state, key branches (preRune/preCursorUp/Down/
  preInsertNewline/preOutdentSelection), destinations seed + send executor
  (`micro/shell`), session store, unread/pending bar state, Alt-i keybind,
  TUI spawn + terminal autodetect, build_ctx wiring
- `cmd.lua` — `send` (+`tui` arg) + `dest` verbs, handlers, subverbs
  (add/rm/into/kind/session), `set termcmd`, `extra.dests`
- `assets.lua` — syntax rule, help text; regen `help/olwb.md`
- `tests/run_tests.lua` — render index/markers, payload builder, adapter
  `wrap`/`parse`/`tui` (fixtures per CLI), `/send` + `/dest` dispatch
  against mock ctx (mock `ctx.send_to`, `ctx.dests`)
- `tests/fixtures/` — **new**: canned JSON/NDJSON outputs per CLI
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

1. `make check` — unit tests for index, markers, payload, dispatch, and the
   adapters: `wrap` (all kinds × new/resume, codex `exec → exec resume <id>`
   prefix rewrite), `parse` against per-CLI fixtures (well-formed,
   interleaved noise lines, missing session id, empty output), `tui`
   command building (resume vs fresh-with-payload-pointer), kind inference
   in `/dest add`.
2. tmux end-to-end (pattern used throughout this project — isolated
   `XDG_DATA_HOME`, capture-pane):
   - capture 6+ messages → Shift-Tab → ↑↓ jumps land on entry starts
     (capture cursor row), Space marks (`▌` + highlight via `capture -e`),
     `a` selects all, bar shows `N selected`.
   - Enter → picker appears with destination candidates; cycle to a test
     destination defined as `sed 's/^/RE: /'` with `into=inbox` (deterministic
     fake LLM) → send → `inbox` liner exists on disk with the `RE:` response,
     labeled; selection cleared; active liner untouched.
   - `/dest add`/`rm`/`into`/`kind` overlay round-trip; `/send clipboard`
     with `wl-copy` absent shows a clean error, not a hang.
   - **Sessions**: PATH-shim fakes for `claude`/`codex`/`opencode` (record
     argv to a log, print canned JSON/NDJSON with a fixed session id) —
     first `/send` stores the id (state.json), second send's recorded argv
     carries the resume flag/subcommand; shim exiting 1 on resume triggers
     exactly one fresh retry; `/dest session list`/`clear` round-trip.
   - **Inbox UX**: response landing while in another liner shows
     `inbox: 1 new` in the bar; Alt-i jumps to inbox (badge clears), second
     Alt-i returns to the previous liner.
   - **TUI mode**: fake `$TERMINAL` shim recording its command line —
     `/send claude tui` writes the payload file and the recorded command
     contains the resume id + payload path, micro not blocked; `tui` on a
     kind-nil destination shows a clean bar error.
3. Real destination smoke test once per CLI, manually (user-triggered — it
   spends tokens); pin the real JSON/NDJSON event shapes into
   `tests/fixtures/` at that point.
