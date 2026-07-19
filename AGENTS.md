# olwb - Agent Instructions

## Project Purpose

olwb ("one line with benefits") is a plugin for the [micro](https://micro-editor.github.io/)
terminal editor: a one-line-input notepad with a Liner → Session → Message
domain model, newest-first feed, inherited labels, filters/search/export, and
a slash-command language with Tab-cycling completion. It reimplements the 2024
one-line-with-benefits Electron app as a ~zero-dependency Lua plugin.

## Repository Layout

```text
olwb-micro-plugin/
├── olwb.lua              # plugin entry: panes, callbacks, commands, keybinds,
│                         #   browse/selection state, send + issues executors
├── store.lua             # file-per-liner persistence, atomic writes, state
├── model.lua             # constructors, ids, labels, flatten, filter (pure)
├── render.lua            # model → feed text + entry index, md export (pure)
├── cmd.lua               # slash-command parse/dispatch/completion (pure)
├── dest.lua              # /send destination adapters per CLI kind (pure)
├── issues.lua            # issues pipeline: prompt/validate/render (pure)
├── migrate.lua           # Electron flat-file → nested import (pure)
├── json.lua              # vendored rxi/json.lua (MIT)
├── assets.lua            # embedded syntax, colorscheme, help, issues prompt
├── help/olwb.md          # generated mirror of assets.lua OLWB_HELP
├── tests/
│   ├── run_tests.lua     # unit tests for the pure modules
│   ├── harness.lua       # whole-plugin load under a mocked micro API
│   └── fixtures/         # canned CLI/model responses (claude/codex/opencode,
│                         #   issues drafts: good / fenced / broken)
├── .agents/plans/        # design plans (tracked)
├── Makefile              # test / harness / check / install
└── repo.json             # micro plugin-channel manifest
```

## Working Principles

- micro wraps every plugin file in `module("olwb", package.seeall)`: all files
  share ONE namespace. Cross-file access is via prefixed globals
  (`olwb_model`, `olwb_render`, …), never `require`. Callback entry points
  (`init`, `preRune`, `preInsertNewline`, …) must be module-scope functions;
  internal helpers stay `local` with forward declarations.
- `model.lua`, `render.lua`, `cmd.lua`, `migrate.lua`, `json.lua` are pure:
  no micro/Go imports, loadable under plain `lua`. Keep them that way — new
  domain logic goes in a pure module, editor wiring goes in `olwb.lua`.
- Every pre-callback branch in `olwb.lua` is guarded by `bp.Buf.Path`
  (`olwb://feed|compose|title|bar`). Keep new key handling behind the same
  guards or it leaks into the user's regular buffers.
- micro API landmines are catalogued in the project memory and in code
  comments where they bit: pane focus needs `tab:SetActive(i)` (not
  `pane:SetActive(true)`), `ResizePane` only trades rows with the immediate
  next sibling (last-sibling resizes the pane above), statusline-off panes
  spend their last row on a divider, and cursor-line colors use the group's
  *foreground* as the row background.
- `shell.JobStart` invokes each Lua callback on a fresh gopher-luar thread,
  and running real Lua there crashes micro 2.0.15 nondeterministically
  (Go-level nil deref in GopherLua's concat path; reproduced in the wild
  with real CLI runs streaming stderr — every chunk is one such callback).
  Hence the job architecture in olwb.lua (`start_job`/`drain_jobs`): all job
  output is redirected to files (no chunk callbacks at all), the onExit
  callback is push-only (queue a record, `buffer.NewBuffer` a throwaway
  `olwb://job-done` buffer), and the real completion logic runs on the MAIN
  Lua state via the `onBufferOpen` trampoline (buffer.NewBuffer fires it
  synchronously through RunPluginFn), with `onAnyEvent` draining as a safety
  net. Never put string building, parsing, or editor calls directly in a
  JobStart callback — route new jobs through `start_job`. Exit codes are
  unavailable to callbacks, hence the `|| echo olwb-job-failed >> <errfile>`
  marker. Re-run the tmux e2e several times after touching an executor.
  The loading spinner rides the same trampoline: while any `job_begin` topic
  is pending, a `sleep 0.25` ticker job loops, its onExit opening an
  `olwb://tick` buffer whose `onBufferOpen` branch advances the frame and
  rerenders on the main state. Register background work via
  `job_begin(topic, note)`/`job_end(topic)`, never by touching
  `pending_jobs` directly, or the spinner and bar note go stale.
- Workflow errors go through `report_error(into_name, headline, detail)`:
  info-bar flash plus a persistent `error`-labeled feed message (in the
  destination's `into` liner, the `issues` liner, or the fallback
  `olwb-errors` liner). Full stderr evidence is kept on disk for the issues
  pipeline (`<datadir>/issues/<id>.err.log`) and the failure is recorded on
  the manifest (`last_error`/`last_error_ms`, cleared on a later success).
  Don't add new user-facing failure paths that only call `err()` — the bar
  truncates and evaporates.
- User text must never be interpolated into a `JobStart` command string —
  payloads travel via stdin tmp files; only olwb-generated values (datadir
  paths, validated session ids) may appear on a command line, shell-quoted.
- `help/olwb.md` is generated from `assets.lua` `OLWB_HELP`:
  `awk '/^OLWB_HELP = \[\[$/{flag=1;next}/^\]\]$/{flag=0}flag' assets.lua > help/olwb.md`
  Edit `assets.lua`, then regenerate — never edit `help/olwb.md` directly.

## Development Workflow

```sh
make check      # unit tests + mocked-micro harness (plain lua, no framework)
make install    # symlink the repo into ~/.config/micro/plug/olwb
```

End-to-end verification drives real micro inside tmux with an isolated data
dir (`~/.config/micro/settings.json` is NOT isolated — stale plugin options
there can masquerade as bugs):

```sh
tmux new-session -d -s t -x 80 -y 30 "env XDG_DATA_HOME=/tmp/olwb-test micro"
tmux send-keys -t t C-e; tmux send-keys -t t "olwb" Enter
tmux capture-pane -t t -p          # add -e to inspect colors
```

(`micro -config-dir <dir>` fully isolates settings/plugins too, without
touching `$HOME` — use it over the settings.json caveat above when you need
a pristine config *and* still want `claude`/`codex`/`opencode` credentials,
which live under the real `$HOME`.)

Design plans live in `.agents/plans/` and are tracked in git, in dependency
order: `olwb-micro-plan.md` (the core plugin), `olwb-benefits-plan.md`
(per-message navigation, multi-select, send-to-destination, sessions, inbox),
and `olwb-issues-plan.md` (selection → agent-work GitHub issues pipeline,
which builds on the benefits plan's selection/destination/executor machinery).
All three are implemented.
