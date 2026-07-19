# Changelog

All notable changes to olwb are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- **Errors in the feed**: workflow failures (`/send`, `/issues draft`,
  `/issues file`) now land as persistent `⚠ error`-labeled messages — in the
  destination's `into` liner, the `issues` liner, or a fallback `olwb-errors`
  liner — carrying full stderr, kept evidence paths, any partially-filed
  issue URLs, and the retry command. The info bar still flashes the short
  version.
- **Failure evidence kept**: failed issues jobs save full stderr to
  `<datadir>/issues/<id>.err.log` and record `last_error`/`last_error_ms` on
  the manifest (cleared on a later success); `/issues list` shows the last
  error under each draft.
- **Progress indicator**: background jobs show an animated spinner in the
  bottom bar (and the `/issues list` overlay) with what is running and
  elapsed time, e.g. `⠹ filing 7 issue(s) on o/r  12s`, driven by a
  main-state-safe sleep ticker.
- **Label preflight**: generated filing scripts create any missing labels
  (create-if-absent, never `--force`) before the first `gh issue create`,
  so a label the drafting model invented no longer aborts the whole run.

## [1.1.0] - 2026-07-18

### Added

- **Browse mode**: `Shift-Tab` on a plain/empty line drops into the feed with
  per-message navigation (`↑`/`↓`), multi-select (`Space`, `a` for all/none),
  and a live `N selected` bar indicator that clears on send.
- **Destinations and `/send`**: user-editable shell command templates that
  the selection (or whole scope) is rendered to markdown and piped into.
  Seeded on first run: `claude`, `codex`, `opencode`, `leather`, `clipboard`,
  `file`. Managed with `/dest [add|rm|into|kind|session …]`; `/send <dest>
  [tui]` fires a send, `tui` instead opens the CLI interactively in a new
  terminal window (`$TERMINAL`, then konsole/foot/alacritty/kitty/xterm, or
  `olwb.termcmd`).
- **CLI adapters** (new `dest.lua`): destinations whose command starts with
  `claude` / `codex` / `opencode` get JSON-output parsing, response text
  routed to the destination's `into` liner as a `#<dest>`-labeled message,
  and a per-destination-per-liner session id that later sends resume
  automatically (stale sessions retry fresh once). `/dest session
  list|clear` manages stored ids.
- **Inbox**: destination responses landing outside the active liner bump a
  bar badge (`inbox: 2 new`); `Alt-i` toggles between the active liner and
  the inbox.
- **Notes → agent-work issues pipeline** (new `issues.lua`, `/issues`):
  turns a selection into GitHub issues an agent can implement, with a
  mandatory human review gate between drafting and filing.
  - `/issues repo add <name> <owner/repo> [path]` registers a target repo;
    a local `path` enriches the draft prompt with that repo's `AGENTS.md`
    (and `.subagents/` routing table, if present).
  - `/issues draft <repo>` sends the selection to a model (`/issues model`,
    default `claude -p`), validates its response as strict JSON, and
    deterministically renders a `gh issue create` filing script — the model
    never produces shell, and a malformed response is rejected whole (raw
    output saved for inspection) rather than risking a bad command.
  - `/issues file latest` runs the reviewed script, records issue URLs in
    the `issues` liner, and labels the source messages `#filed` (refiling
    is refused).
  - The drafting prompt template is seeded once to
    `<datadir>/issues-prompt.md` and is user-editable thereafter.
- New `olwb.termcmd` option (state.json-backed) for the `/send <dest> tui`
  terminal command.
- `tests/fixtures/`: canned CLI/model responses (claude, codex, opencode,
  and good/fenced/broken issues drafts) backing the new adapter and issues
  unit tests.

### Changed

- `render.lua` now also produces a feed entry index and selection markers
  (`▌`) alongside the existing feed-text/markdown-export rendering.
- `store.lua` gained a plain-Lua `glob()` helper and an `issues/` data
  directory (issue drafts as `<id>.sh` + `<id>.json` manifest, plus
  `<id>.raw.txt` when a response is rejected).
- Job handling in `olwb.lua` (`start_job`/`drain_jobs`) routes all
  destination/issues subprocess output through files rather than
  `JobStart` chunk callbacks, working around a gopher-luar/GopherLua crash
  triggered by running real Lua on the job's callback thread.

### Documentation

- README: new "Browse mode", "The benefits — sending", and "The pipeline —
  notes to agent-work issues" sections; updated data-directory and module
  tables.
- New user guides: `docs/dest.md` (destinations, adapters, sessions),
  `docs/send.md` (browse mode, sending, tui, inbox), and `docs/issues.md`
  (the notes → issues pipeline).
- AGENTS.md: documents the `dest.lua`/`issues.lua` modules, the
  `JobStart`-callback crash and the file-redirected job architecture that
  works around it, and the completed status of the benefits and issues
  plans.

## [1.0.0] - 2026-07-17

Initial release: the core plugin — one-line capture feed, Liner → Session →
Message model with label inheritance, slash commands with the live menu and
Tab completion, filtering/search/export, and file-per-liner JSON storage
with atomic writes.
