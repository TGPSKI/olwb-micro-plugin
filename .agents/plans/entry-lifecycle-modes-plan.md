# Entry and lifecycle modes (#11, #13, #14)

## Baseline

- `init()` opens olwb only when persisted `olwb.autostart` is true and the
  current buffer has no path or modifications. Plugin options cannot be passed
  as micro CLI flags because micro parses flags before plugins load.
- `create_liner`, `submit_message`, and `close_liner` always write liner and
  state files. There is no temporary-liner state or promotion path.
- The public binding functions are `key_open`, `key_compose`, and `key_inbox`.
  Defaults are Alt-o, Alt-m, and Alt-i, registered with `overwrite=false`.

## Design

### 1. Per-invocation autostart (#11)

Add a pure launch-policy helper and read `OLWB_AUTOSTART` through the existing
Go `os` import. Any non-empty value is an explicit request for this process:

- environment activation opens olwb even when micro also opened a file;
- persisted `olwb.autostart` retains the current empty, unmodified-buffer
  requirement;
- neither path writes the environment choice into settings or state;
- document `OLWB_AUTOSTART=1 micro [file]` and that
  `micro -olwb.autostart true` cannot work.

### 2. Memory-only instant liner (#13)

Track instant mode and its session id in module-local runtime state. Entering
instant mode creates an in-memory liner without calling `create_liner`, changing
persisted active-liner/session ids, or adding a registry entry.

- `>olwb -i` and `lua:olwb.instant` open/focus the UI and enter instant mode.
- Captures and session/liner metadata changes update only the in-memory liner.
- `/send`, `/issues draft`, and `/export` read the same active-liner object as
  durable mode, so routing occurs before any later discard.
- `/close` discards the liner. It creates no liner file, backup, registry row,
  or open/close record; temporary destination-session keys are removed.
- `/save <name>` promotes it in place: set the name, restore its runtime session
  id to persisted state, then use the ordinary save/registry path. Bare `/save`
  in instant mode reports `usage: /save <name>`.
- Resuming a durable liner discards an unsaved instant liner first. Exiting
  micro saves persistent state but never the instant liner.
- The bar/status surfaces identify the active liner as `(instant)`.

All active-session lookups in editor wiring and `cmd.lua` route through one
injected helper so the instant session id never leaks into `state.json`.

### 3. Public entry points and chords (#14)

Expose module-scope functions:

- `launch`: open/focus olwb without selecting a liner;
- `resume`: open the current or most recently updated durable liner, falling
  back to `launch` when the registry is empty;
- `instant`: enter or refocus instant mode.

Register them with `config.TryBindKey(..., false)`:

| User chord | micro key | Function |
|---|---|---|
| Alt-o | `Alt-o` | `lua:olwb.launch` |
| Alt-Shift-o | `Alt-O` | `lua:olwb.resume` |
| Alt-Shift-i | `Alt-I` | `lua:olwb.instant` |

Keep Alt-m compose and Alt-i inbox unchanged. Keep `key_open` as a compatibility
wrapper around `launch`; user bindings always win because overwrite remains
false.

## Verification

- Pure tests: configured/environment launch policy, including a file argument.
- Command tests: durable `/save`, instant save-name requirement, and promotion.
- Harness: registered chords/functions, cold and already-open entry points,
  instant discard, promotion, durable resume fallback, and `/send` payload
  capture before discard.
- Real micro/tmux matrix with isolated config/data:
  `OLWB_AUTOSTART=1 micro`, `OLWB_AUTOSTART=1 micro FILE`, `>olwb -i`, discard,
  promotion, and the three public functions.
- `make check`, two additional harness runs, generated-help comparison, and
  `git diff --check`.
