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
├── olwb.lua              # plugin entry: panes, callbacks, commands, keybinds
├── store.lua             # file-per-liner persistence, atomic writes, state
├── model.lua             # constructors, ids, labels, flatten, filter (pure)
├── render.lua            # model → feed text, md export (pure)
├── cmd.lua               # slash-command parse/dispatch/completion (pure)
├── migrate.lua           # Electron flat-file → nested import (pure)
├── json.lua              # vendored rxi/json.lua (MIT)
├── assets.lua            # embedded syntax, colorscheme, help strings
├── help/olwb.md          # generated mirror of assets.lua OLWB_HELP
├── tests/
│   ├── run_tests.lua     # unit tests for the pure modules
│   └── harness.lua       # whole-plugin load under a mocked micro API
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

Design plans live in `.agents/plans/` and are tracked in git. The next
planned feature set is `.agents/plans/olwb-benefits-plan.md` (per-message
navigation, multi-select, send-to-destination).
