# OLWB → micro: Implementation Plan

**Target:** Reimplement one-line-with-benefits as a micro editor plugin. Kill Electron. Preserve the domain model (Liner → Session → Message), descending-time feed, timestamps, label inheritance, slash commands, and one-line input semantics.

**Sources reviewed:** README.md, design/design.md, docs/STORAGE_REFACTORING.md, docs/IPC-API.md, src/utils/commands.ts, src/utils/state.ts, src/render/* (MainPage, Forms, Label), src/background/* (storage, migration, ipc handlers), schemas.json, and micro `runtime/help/plugins.md` @ master.

---

## 0. Architecture decision: plugin, not fork

Three candidates were on the table. Verdict:

| Option | Verdict | Why |
|---|---|---|
| **Fork micro** | Rejected | You inherit a Go TUI editor's entire maintenance surface to add a notepad. Rebase tax forever. Everything OLWB needs is reachable from the plugin API. |
| **Pure Lua plugin** | **Selected (v1)** | Zero install friction (`micro -plugin install` or drop in `~/.config/micro/plug/olwb`). micro exposes enough Go stdlib (`os`, `io/ioutil`, `filepath`, `time`, `strings`, `regexp`, `math/rand`) to do file-per-liner persistence without any external process. |
| **Lua shim + Go sidecar (`olwb` CLI)** | Deferred to v2 | Right answer for operation mode (search, pipelines, exports) — a stdlib-only Go binary that joins the pate stack, with the Lua plugin as thin UI. Premature for v1; the v1 storage format is designed so the sidecar can adopt it without migration. |

One real gap in pure Lua: micro does **not** expose `encoding/json` to plugins. Resolution: vendor `json.lua` (rxi, single file, ~280 LOC, MIT) inside the plugin directory. One auditable file; the closest available analog to your zero-dependency posture in a Lua runtime. If that's unacceptable, the fallback is pulling the Go sidecar forward from v2 — noted as an open decision in §10, but the plan proceeds with vendored json.lua.

---

## 1. Concept mapping: Electron → micro

| OLWB concept | Electron implementation | micro implementation |
|---|---|---|
| Feed (descending messages) | React `MessageList`, push via IPC `onMessagesUpdate` | Read-only **scratch buffer** (`buffer.BTScratch`) in the main pane, re-rendered on every mutation. Custom `olwb` filetype + in-memory syntax file for timestamp/label/ID highlighting |
| One-line input | Fluent `Textarea` + tanstack form | Dedicated 2-line **compose pane** (horizontal split at bottom). `preInsertNewline` callback intercepts Enter → submit; buffer never grows |
| Slash commands (`/new`, `/save`, `/open`, `/close` — stubbed in commands.ts) | `handleCommand` switch (commented out) | Parsed in the submit path: any compose line starting with `/` routes to the command table instead of creating a message. Full set in §5. Also mirrored as native `>olwb <cmd>` micro commands via `config.MakeCommand` |
| Start/End Liner buttons | Header buttons + Active Liner ID text | `/liner start`, `/liner end`; active IDs shown in the **statusline** via `micro.SetStatusInfoFn` and in the feed header block |
| Start/End Session buttons | Same | `/session start`, `/session end`; sessions also auto-start on first message when none active (preserves `getOrCreateActive` semantics from IPC-API.md) |
| Label picker (TagPicker + trie autocomplete) | `useTrie`/`useAutocomplete` hooks | `/label <name>` toggles a label into the **active label set** (applied to subsequent messages); `/labels` lists; tab-completion via a custom `buffer.Completer` on the `>olwb` command, and prefix-match hints in the infobar for slash commands |
| Command feedback banner | `feedbackMessage` div | `micro.InfoBar():Message()` / `:Error()` |
| Push updates | IPC event listeners | Unnecessary — single process. Mutate store → re-render feed buffer synchronously |
| Theme (#1e1e1e / #a370f7 / #3da9fc / #7ef4b9) | Fluent theme tokens | Optional `olwb` colorscheme + syntax groups mapped to those hexes via `AddRuntimeFileFromMemory(RTColorscheme/RTSyntax)`. Respect the user's colorscheme by default; theme is opt-in |

Dropped, deliberately: the `natural`-based InvertedIndex (Porter stemmer + tokenizer). At notepad scale a linear scan over loaded liners is instant; stemmed search is v2 sidecar territory (and overlaps micromem's BM25 work if you ever want it).

---

## 2. Data model & on-disk format

Adopt the **target format from STORAGE_REFACTORING.md verbatim** — file-per-liner, nested sessions/messages, `directMessages` escape hatch. That doc's Phase 2+ was never finished in Electron; this project completes it in a different host.

```
~/.local/share/olwb/            (XDG_DATA_HOME fallback; option olwb.datadir)
├── liners/
│   ├── <liner-id>.json         # exact STORAGE_REFACTORING.md schema
│   └── ...
├── state.json                  # { activeLinerId, activeSessionId, activeLabels[], filter{} }
└── backups/                    # timestamped copies written before destructive ops
```

Liner file schema (unchanged from the refactor doc):

```json
{
  "id": "...",
  "metadata": { "name": "...", "description": "...", "labels": ["..."] },
  "sessions": [
    { "id": "...", "startTime": 0, "endTime": 0,
      "metadata": { "name": "...", "labels": [] },
      "messages": [
        { "id": "...", "content": "...", "timestamp": 0,
          "metadata": { "labels": [] } } ] }
  ],
  "directMessages": []
}
```

Rules carried over from the README, enforced in code not convention:

- **Timestamps**: epoch milliseconds at write; rendered local at display. Never mutated after creation.
- **Ordering**: feed renders strictly descending by `timestamp` across all sessions in the visible scope. Storage order within a session is append (ascending); sort happens at render.
- **Label inheritance**: resolved at query/render time as `liner.labels ∪ session.labels ∪ message.labels`. Stored labels stay minimal at each level — no denormalization into children (matches "labels applied to a message are unique to that message").
- **Edit vs operation context**: messages attach to the active session in normal flow; `directMessages` is only reachable via explicit command (`/msg --direct`), preserving the README's context split.
- **IDs**: micro's Lua runtime has no UUID lib. Use `ULID-lite`: `<epoch-ms base32><10 chars from math/rand seeded via time+pid>`. Sortable, collision-safe at single-user scale, greppable. (Sidecar can upgrade to real UUIDv7 later without breaking anything — IDs are opaque strings everywhere.)
- **Atomic writes**: write `<file>.tmp`, then `os.Rename`. Backup copy into `backups/` before `/liner end` and before migration. This delivers the "atomic operations" benefit the refactor doc wanted and Electron never shipped.

---

## 3. Plugin layout

```
~/.config/micro/plug/olwb/
├── olwb.lua          # entry: init(), callbacks, command registration, keybinds
├── model.lua         # pure: liner/session/message constructors, label resolution, sort
├── store.lua         # persistence: load/save liner files, state.json, atomic write, backup
├── render.lua        # pure: model → feed buffer text; header block; timestamp fmt
├── cmd.lua           # slash-command table: parse, dispatch, completion vocab
├── migrate.lua       # Electron userData → olwb datadir (both old flat & new nested formats)
├── json.lua          # vendored rxi/json.lua (only third-party file)
├── help/olwb.md      # in-editor help (> help olwb) via AddRuntimeFile RTHelp
└── repo.json / plugin metadata
```

`model.lua`, `render.lua`, `cmd.lua` are **pure Lua with zero micro imports** — testable under plain `lua5.1`/`luajit` outside the editor (§8). Only `olwb.lua` and `store.lua` touch micro/Go APIs.

---

## 4. UI composition

**Startup** (`>olwb open`, or auto if `olwb.autostart=true` and micro launched with no file args):

1. Create feed buffer: `buffer.NewBuffer(rendered, "olwb://feed")`, `Type = BTScratch`, filetype `olwb`, readonly.
2. `micro.CurPane():HSplitBuf(compose)` → compose pane pinned bottom, resized to 2 lines via the pane `ResizePane` action.
3. Register statusline fn: `[olwb  L:4f9f  S:8bb4  ⬤ one-line-with-benefits +2]` (short IDs, active label count, unsaved marker).

**Feed rendering** (`render.lua`), per message, newest first:

```
────────────────────────────────────────────
I GOT THE ROOT CAUSE
2024-08-31 01:13:38  ·  #one-line-with-benefits #debug
```

Header block above the feed shows active liner name/description, active session window, and the current filter expression when one is applied. Syntax file highlights: rule line → `comment`, timestamp → `constant.number`, `#labels` → `identifier`, header → `preproc`. With the optional colorscheme those map to `#a370f7` (focus), `#3da9fc` (alt1), `#7ef4b9` (alt2) on `#1e1e1e`.

**Compose semantics** (in `preInsertNewline(bp)`, only when `bp.Buf.Path == "olwb://compose"`):

- Line starts with `/` → dispatch to `cmd.lua`; feedback via InfoBar; clear line; return `false` (cancel newline).
- Otherwise → trim (port of `removeTrailingNewlines`), reject empty, create message on active session (auto-creating liner/session as needed, mirroring `getOrCreateActive`), persist liner file, re-render feed, clear line, return `false`.
- `preRune` guard on the feed pane keeps it effectively read-only even if micro's readonly option is toggled.

**Navigation**: feed is a normal micro buffer — search (`Ctrl-f`), selection, copy all work for free. That alone retires ~80% of the React surface (MessageList, virtual scrolling concerns, focus management).

---

## 5. Command surface

Slash commands in compose (the concept preserved from `commands.ts`, superset of the four stubs), each mirrored as `>olwb <verb> ...` with a custom completer:

```
/new [name]              create + activate a new liner        (was /new)
/open <name|id>          load + activate a liner              (was /open)
/close                   deactivate liner (ends session too)  (was /close)
/save                    force persist (normally automatic)   (was /save)

/liner start|end|name <s>|desc <s>|label <l>
/session start|end|name <s>|label <l>
/msg --direct <text>     attach to liner.directMessages (operation-context path)

/label <name>            toggle label in active set (applied to new messages)
/labels                  list known labels w/ counts

/filter label:<l> [since:<date>] [until:<date>]
/filter clear
/search <term>           substring/regexp scan over visible scope
/export [md|json] [path] render current scope to file

/list                    liners w/ message counts + last-activity
/help                    open > help olwb
```

Autocomplete: `cmd.lua` exposes the verb vocabulary; the `>olwb` completer returns it (plus liner names / labels contextually). In-compose, a prefix hint for `/` lines goes to the InfoBar — trie unnecessary at this vocabulary size; the `useTrie`/`useAutocomplete` machinery does not port.

Keybinds (via `config.TryBindKey`, all under `Alt-o` prefix to stay out of micro's way, overridable): `Alt-o l` liner toggle, `Alt-o s` session toggle, `Alt-o f` jump to feed, `Alt-o c` jump to compose, `Alt-o /` focus compose with `/` pre-typed.

Options (`config.RegisterCommonOption("olwb", ...)`): `datadir`, `autostart`, `timefmt`, `theme` (off by default), `composesize`.

---

## 6. State handling

Port of `state.ts` (which is a 29-line KV store) → a Lua table in `store.lua`, persisted to `state.json` on every transition. Active liner/session survive editor restarts — matching the Electron behavior where active IDs displayed in the header persisted across sessions. `deinit()` flushes state; `init()` restores and re-renders.

---

## 7. Migration from Electron data

`migrate.lua`, run via `>olwb migrate <path-to-electron-userData>`:

1. Detect format: new-style `liners/*.json` (if the refactor branch ever wrote any) → straight copy. Old flat `messages.json` + `sessions.json` + `liners.json` → reconstruct nested files by resolving `messageReferences`/`sessionReferences`, exactly the algorithm STORAGE_REFACTORING.md specified for its Phase 3.
2. Orphans (messages referenced by nothing — likely given the screenshot's pre-liner 2008/2021 entries) → synthesized `recovered` liner, original timestamps intact.
3. Back up source files untouched; write into `datadir/liners/`; report counts to InfoBar + a migration log message buffer.
4. Idempotent: existing target IDs are skipped, not overwritten.

---

## 8. Testing

- **Pure-module tests**: `model.lua` (label inheritance resolution, descending sort stability across sessions, ID generation), `render.lua` (golden-file feed output), `cmd.lua` (parse table) — run under plain lua + busted, or a dependency-free `make test` runner script. No editor required.
- **Round-trip**: encode→write→read→decode equality on liner files, including unicode content and empty-metadata edges (the refactor doc's stated test matrix).
- **Migration fixtures**: synthesize old-format triples covering orphans, direct messages, label layering; assert nested output.
- **In-editor smoke**: `>olwb selftest` command that exercises create/submit/filter/export against a temp datadir and prints pass/fail to the log buffer.

---

## 9. Phasing (dependency order)

```
P0  scaffold: plugin skeleton, json.lua vendored, datadir bootstrap, options
P1  model.lua + store.lua + tests            ← everything depends on this
P2  render.lua + feed buffer + syntax file   ← P1
P3  compose pane + preInsertNewline submit   ← P1  (parallel-safe with P2)
P4  cmd.lua: liner/session/label/new/open/close/save   ← P2+P3 fan-in
P5  filter/search/export + statusline        ← P4
P6  migrate.lua + fixtures                   ← P1 only (parallelizable from P2 on)
P7  help file, colorscheme, keybinds, README, repo.json, plugin-channel entry
```

P1–P4 is the MVP that replaces the Electron app for daily capture. P5–P7 is completeness. Nothing here blocks on upstream micro changes — the whole plan sits on stable public plugin API (verified against master's plugins.md).

---

## 10. Open decisions (flagging, not deciding)

1. **json.lua vendoring vs Go sidecar now.** Plan assumes vendoring. If one MIT Lua file in-tree violates the zero-dep line for you, pull the `olwb` stdlib-only Go CLI forward from v2 and make `store.lua` shell to it via `shell.ExecCommand` — cleaner dependency story, worse install story (two artifacts).
2. **Repo placement.** Standalone `TGPSKI/olwb-micro` vs a `micro/` dir inside the existing OLWB repo. Standalone fits your flagship-domain taxonomy if this ever gets an `olwb.sh`.
3. **Compose height**: fixed 2 lines vs auto-grow. Electron auto-resized; in a TUI, fixed is calmer. Defaulting fixed.
4. **Operation mode scope for v1**: plan ships filter/search/export only. Pipelines and liner-from-liner generation stay conceptual, as they were in the README.

---

## Appendix: what does not port, and why

- `useTrie`, `useAutocomplete`, `InvertedIndex` (natural) — replaced by micro completers + linear scan; complexity unjustified at this scale.
- IPC layer entirely (`preload.ts`, `ipcHandlers.ts`, `global.d.ts`, all `ipc/*`) — single-process; the four handler modules collapse into `model.lua` + `store.lua`.
- Fluent UI, vite, forge, eslint, vitest toolchain — ~566KB of package-lock.json becomes one vendored Lua file.
- Push-update subscription model — synchronous re-render after mutation.
