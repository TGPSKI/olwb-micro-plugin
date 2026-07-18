# olwb — one line with benefits, for [micro](https://micro-editor.github.io/)

A one-line-input notepad living inside the micro editor. You type one line,
press Enter, and it drops into the feed directly beneath the input with a
timestamp and any active labels — new lines enter at the top of the stack and
push the older ones down. That's the whole ritual.

> **Origins** — olwb is inspired by (and is a full reimplementation of) the
> original *one-line-with-benefits* Electron app from 2024: same domain model
> (**Liner → Session → Message**), same append-only feed, timestamps, label
> inheritance, and slash-command language — with the Electron runtime replaced
> by a ~zero-dependency Lua plugin that lives where the writing already
> happens.

## The interface

```
  olwb — one line with benefits                     title

  ───────────────────────────────────────────────
  █ the one line (highlighted, auto-grows)          capture happens here
  ───────────────────────────────────────────────
    ─────────────────────────────
    HEY THIS LOOKS GREAT MAN                        newest message
    2026-07-17 01:16:42
    ─────────────────────────────
    so i can go to this level                       …older ones pushed down
    2026-07-17 01:08:02                          █  (scrollbar when overflowing)
  ───────────────────────────────────────────────
    Enter submits · /? commands · Tab/↑↓ cycle      shortcut reference
    Liner: first demo
    Session: 6H2X8NEH
```

Typing `/` swaps the feed for a live command menu (filtered as you type;
Tab/Shift-Tab/↑/↓ cycle through verbs, subcommands, and liner names with the
selection highlighted — Enter runs the filled-in line, Space expands a liner's
details during `/open`). `/?` toggles the menu. The one line grows
automatically when its text wraps, typing from any pane bounces focus back to
the input, and nothing is loaded on open — the line comes pre-filled with
`/open <your most recent liner>`, ready for Enter.

## Install

Requires micro ≥ 2.0.

```sh
# from a clone
make install          # symlinks this repo into ~/.config/micro/plug/olwb

# or by hand
ln -s "$PWD" ~/.config/micro/plug/olwb
```

Restart micro (or `> reload`). Then:

```
> olwb                 open the olwb layout
```

Type a line, press **Enter**. That's it — a `notes` liner and a session are
created automatically on the first message.

## Usage

| Key / command | Effect |
|---|---|
| `> olwb` | open / focus the olwb layout |
| `Alt-o` | open / focus olwb (overridable) |
| `Alt-m` | jump to the one line |
| *type + Enter* | capture the line as a message (appears just below the input) |
| `/…` + Enter | run a slash command instead of capturing |
| `/?` | toggle the command menu in the feed area |
| `Tab` / `Shift-Tab` | cycle through the menu's options (Enter runs the line) |
| `Up` / `Down` | also cycle options while typing a /command |
| `Space` | during `/open` cycling: expand the selection's details |
| `Shift-Tab` (plain line) | browse the feed message by message (see below); Shift-Tab or typing returns |
| `Alt-i` | toggle between the active liner and the inbox (responses land there); a second Alt-i returns |

### Browse mode — navigate, select, send

`Shift-Tab` on an empty (or plain) line drops you into the feed with the
current message's first line highlighted:

| Key | Effect |
|---|---|
| `↑` / `↓` | jump message-to-message (not line-by-line) |
| `Space` | toggle the message in the selection (`▌` marker + highlight) |
| `a` | select everything in scope — or clear a full selection |
| `Enter` | open the destination picker (`/send ` pre-filled, Tab-cycling) |
| `Shift-Tab` | back to the one line (selection survives) |

The bar shows `N selected` while a selection exists; it clears on a
successful send.

### Slash commands (typed in the one line)

```
/new [name]                    create + activate a new liner
/open <name|id>                load + activate an existing liner
/close                         deactivate liner (ends its session)
/save                          force a save (saves are automatic)

/liner start|end               start / end the active liner
/liner name <s> | desc <s>     set liner name / description
/liner label <l>               toggle a liner-level label

/session start|end             start / end a session
/session name <s>              name the active session
/session label <l>             toggle a session-level label

/label <name>                  toggle a label applied to new messages
/labels                        list known labels with counts

/filter label:<l> [since:<d>] [until:<d>] [term:<t>]
/filter clear                  remove the active filter
/search <term>                 substring search over the current scope
/export [md|json] [path]       write the current scope to a file
/list                          list liners with message counts
/set [option] [value]          view / change olwb options (no micro >set needed)
/help  (or /?)                 toggle the command menu

/send <dest> [tui]             send the selection (or whole scope) to a destination
/dest [add|rm|into|kind|session …]   manage destinations
/issues [draft|file|list|repo|model …]   notes → agent-work GitHub issues
```

Dates are `YYYY-MM-DD` (optionally `HH:MM[:SS]`). Every slash command is also
reachable natively as `> olwb <verb> [args]` (without the leading `/`), which is
handy for keybindings and macros.

### The benefits — sending

Destinations are **user-editable shell command templates**: the selection (or,
with nothing selected, the whole current scope, respecting the active filter)
is rendered as markdown — liner title, content, timestamps, labels — and piped
to the command's stdin. Presets are seeded on first run: `claude`, `codex`,
`opencode` (responses land in the `inbox` liner), `leather`, `clipboard`, and
`file` — edit or remove them freely, they never re-seed.

```
/dest add oc-review "opencode run --agent review"    an agent-flavored preset
/dest into oc-review reviews                          responses → `reviews` liner
/send oc-review                                       pipe the selection to it
```

Destinations whose command starts with `claude` / `codex` / `opencode` get an
**adapter kind** (inferred, overridable with `/dest kind`): the send runs with
the CLI's JSON output flag, the response text (never raw JSON) lands as a
message labeled `#<dest>` in the destination's `into` liner, and the CLI's
**session id is stored per destination × liner** — the next `/send` resumes
the same conversation. A stale session retries fresh exactly once;
`/dest session list|clear` manages the stored ids. olwb defines no agents of
its own: an "agent preset" is just a destination whose command names an agent
from the CLI's own registry (`--agent`, `--profile`, …).

`/send <dest> tui` opens the CLI **interactively in a new terminal window**
instead — resuming the stored session when one exists, otherwise starting
fresh with a pointer to the payload file. The terminal is auto-detected
(`$TERMINAL`, then konsole/foot/alacritty/kitty/xterm); override with
`/set termcmd "<cmd>"`.

Responses landing in a non-active liner bump a bar badge (`inbox: 2 new`);
`Alt-i` toggles to the inbox and back. While a send is in flight the bar shows
`<dest> working…` — micro never blocks.

### The pipeline — notes to agent-work issues

`/issues` turns parked notes into GitHub issues an agent can implement,
with a **mandatory human review gate** in the middle:

```
/issues repo add olwb TGPSKI/olwb-micro-plugin ~/git/TGPSKI/olwb-micro-plugin
(select messages in browse mode)
/issues draft olwb        stage 1: model → validated drafts → gh script
(read the script)         the review gate — nothing is filed yet
/issues file latest       stage 2: run the script, record URLs, label sources
```

Stage 1 sends the selection to a model (`/issues model`, default `claude -p`)
that must answer with **strict JSON** — title, body, labels per issue,
following the agent-work template (`## Context` bullets citing the context an
implementing subagent should load plus verbatim note provenance, `## Work` as
bounded checkboxes, label `agent-work` enforced). The model never produces
shell: olwb validates the JSON and **deterministically renders** the `gh`
filing script from it, e.g.:

```bash
echo '[1/2] render: fix label inheritance on filtered feeds'
gh issue create --repo "$REPO" --label 'agent-work' --label 'bug' \
  --title 'render: fix label inheritance on filtered feeds' --body "$(cat <<'EOF'
## Context
…
EOF
)"
```

A malformed response is rejected whole (raw output saved for inspection) — it
can at worst produce a bad issue body, never a bad command. After filing, the
sources are labeled `#filed`, URLs land in the `issues` liner, and refiling is
refused. When a repo target has a local `path`, the draft prompt is enriched
with its `AGENTS.md` (and `.subagents/` routing table for directed-contexts
adopters) so issues cite the right context; the prompt template itself is
seeded to
`<datadir>/issues-prompt.md` and yours to tune. Downstream — sequencing filed
issues into a DAG and dispatching subagents — is deliberately out of olwb's
scope; the issues it files are well-formed inputs to that tooling.

### Native-only commands

```
> olwb rescan            rebuild the liner registry from disk
> olwb selftest          run built-in storage self-tests (writes a report buffer)
```

### Options

Managed from inside olwb: bare `/set` shows every option with its current
value, `/set <name> <value>` changes one (validated, applied live, persisted
by micro). micro's own `> set olwb.<name> <value>` and `settings.json` still
work if you prefer them.

| Option | Default | Meaning |
|---|---|---|
| `olwb.datadir` | `""` | storage directory (empty ⇒ `$XDG_DATA_HOME/olwb`) |
| `olwb.autostart` | `false` | open olwb on launch when micro is started with no file |
| `olwb.timefmt` | `%Y-%m-%d %H:%M:%S` | `strftime` format for timestamps |
| `olwb.composesize` | `1` | minimum one-line height, in rows (auto-grows to 8) |
| `olwb.rulewidth` | `48` | width of the feed separator rules |
| `olwb.termcmd` | *(auto)* | terminal for `/send <dest> tui` (lives in state.json) |
| `olwb.theme` | `false` | apply the bundled `olwb` colorscheme |

The feed uses the `olwb` filetype, so its rule lines, timestamps and `#labels`
pick up colours from **your** colorscheme by default. An optional `olwb`
colorscheme (dark, `#1e1e1e`/`#a370f7`/`#3da9fc`/`#7ef4b9`) ships with the
plugin — opt in with `olwb.theme=true` or `> set colorscheme olwb`.

## Data model & storage

Labels are **inherited** and resolved at render time as
`liner ∪ session ∪ message` — storage stays minimal at each level. The feed
renders strictly newest-first across every session in scope (newest at the
top, next to the input); storage order within a session stays append-order.

```
$XDG_DATA_HOME/olwb/
├── liners/<liner-id>.json     one file per liner (atomic write via tmp+rename)
├── state.json                 active liner/session, labels, filter, registry,
│                              destinations, per-liner CLI sessions, unread
├── backups/                   timestamped copies taken before destructive ops
├── issues/                    issue drafts: <id>.sh + <id>.json manifest
│                              (+ <id>.raw.txt when a response is rejected)
└── issues-prompt.md           the drafting prompt (seeded once, user-editable)
```

A liner file:

```json
{
  "id": "01KXPS…",
  "metadata": { "name": "…", "description": "…", "labels": ["…"] },
  "sessions": [
    { "id": "…", "startTime": 0, "endTime": 0,
      "metadata": { "name": "…", "labels": [] },
      "messages": [
        { "id": "…", "content": "…", "timestamp": 0,
          "metadata": { "labels": [] } } ] }
  ],
  "directMessages": []
}
```

- **Timestamps** are epoch milliseconds at write, rendered in local time, never
  mutated after creation.
- **IDs** are ULID-lite: `<epoch-ms base32, 10><random base32, 10>`, uppercase
  Crockford — lexicographically sortable by creation time and greppable.
- **Atomic writes**: every save goes to `<file>.tmp` then `os.Rename`s into
  place; a backup is taken before `/close` and before migration.

## Architecture

Pure Lua, single process. The one third-party file is vendored
[`rxi/json.lua`](https://github.com/rxi/json.lua) (MIT), because micro does not
expose `encoding/json` to plugins.

| File | Responsibility | micro/Go imports |
|---|---|---|
| `model.lua` | constructors, ids, label resolution, descending flatten, filter | none (pure) |
| `render.lua` | model → feed text + entry index, selection markers, md export/payload | none (pure) |
| `cmd.lua` | slash-command parse + dispatch (against an injected context) | none (pure) |
| `dest.lua` | destination adapters: wrap/parse/tui per CLI kind, session flags | none (pure) |
| `issues.lua` | issues pipeline: prompt assembly, response validation, gh-script rendering | none (pure) |
| `migrate.lua` | flat → nested reconstruction, orphan recovery | none (pure) |
| `json.lua` | vendored JSON encode/decode | none |
| `assets.lua` | embedded syntax / colorscheme / help / issues-prompt strings | none |
| `store.lua` | file-per-liner persistence, atomic write, state, backups | os, ioutil, filepath, util |
| `olwb.lua` | plugin entry: panes, callbacks, commands, keybinds, send/issues executors | micro, config, buffer, util, shell, os, time |

The six pure modules have zero editor dependencies, so they run — and are
tested — under a plain `lua` interpreter outside micro.

## Testing

No test framework required, just `lua`:

```sh
make test       # unit-test the pure modules (~200 assertions, incl. canned
                # CLI-response fixtures in tests/fixtures/)
make harness    # load the whole plugin under a mocked micro API and drive a
                # real capture → persist flow (store.lua does real file IO)
make check      # both
```

Inside the editor, `> olwb selftest` exercises id generation, save/load,
unicode round-trips, descending order and label resolution against a temp file
and prints a pass/fail report buffer.

## Design plans

The tracked design documents behind the implemented feature sets live in
[`.agents/plans/`](.agents/plans/):
[`olwb-micro-plan.md`](.agents/plans/olwb-micro-plan.md) (the core plugin),
[`olwb-benefits-plan.md`](.agents/plans/olwb-benefits-plan.md) (browse,
multi-select, send, sessions, inbox), and
[`olwb-issues-plan.md`](.agents/plans/olwb-issues-plan.md) (the notes →
agent-work issues pipeline).

## License

[MIT](LICENSE) © 2026 Tyler Pate. Vendored `json.lua` is MIT © rxi.
