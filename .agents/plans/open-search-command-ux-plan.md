# Open/search command ergonomics (#17, #18, #19)

## Baseline

- `/open <name|id>` resolves only an exact registry key or name in
  `olwb.lua:open_liner`; its live candidates come from
  `cmd.lua:M.candidates`, which prefix-matches the final token against every
  liner name/id.
- Bare compose input always reaches `olwb.lua:submit_message`; with no active
  liner it creates `notes`, starts a session, and stores the input there.
- `cmd.lua` registers full command names directly in `H`. `/?` is the only
  shorthand, and aliases have no collision check or help-menu field.

## Scope and decisions

### 1. Query the live `/open` candidate list (#17)

Add a pure `cmd.parse_open_query` helper that separates repeated
`label:<name>` tokens from the remaining free text. Search liner metadata at
the `olwb.lua` boundary because labels and descriptions require loading liner
files:

- every requested label must occur on the liner metadata (AND semantics);
- free text is a case-insensitive substring of the liner's offered key, name,
  id, or description;
- an unknown label produces no candidates;
- an empty query preserves the current all-liners candidate list.

`cmd.candidates` receives the already-filtered liner pool and replaces the
whole `/open` query when Tab selects a result. Exact `/open <name|id>` dispatch
continues through the existing handler.

### 2. Route bare no-liner input into that search (#18)

At the compose Enter boundary, before clearing the buffer:

- `/`-prefixed input still dispatches normally;
- plain input with an active liner still creates a message there;
- plain input with no active liner becomes `/open <input>` in place, leaving
  the live candidate list visible for Tab selection and Enter.

Blank input keeps its current no-op behavior.

### 3. Register checked single-letter aliases (#19)

Represent aliases as ordered `{letter, command}` rows and register them only
after every full handler exists. Registration asserts that the target exists
and that neither a full command nor an earlier alias owns the letter.

| Alias | Command | Collision decision |
|---|---|---|
| `/n` | `/new` | unique first letter |
| `/o` | `/open` | unique first letter |
| `/c` | `/close` | unique first letter |
| `/v` | `/save` | save (`v`) |
| `/r` | `/liner` | liner (`r`) |
| `/u` | `/session` | session (`u`) |
| `/l` | `/label` | primary label action |
| `/k` | `/labels` | known labels |
| `/f` | `/filter` | unique first letter |
| `/q` | `/search` | query |
| `/e` | `/export` | unique first letter |
| `/s` | `/send` | primary send action |
| `/d` | `/dest` | unique first letter |
| `/i` | `/issues` | unique first letter |
| `/a` | `/list` | all liners |
| `/t` | `/set` | settings (`t`) |
| `/h` | `/help` | unique first letter; `/?` remains valid |

Show each alias beside its full command in the live help menu and document the
mapping in the embedded help/README. Aliases dispatch to the same function
object; they do not copy handler logic.

## Verification

- Pure tests: query parsing, one/two labels, label plus free text, unknown
  label, candidate replacement, alias coverage, handler identity, and
  collision rejection.
- Harness: bare no-liner input becomes open search; slash input remains a
  command; active-liner input remains a stored message.
- `make check`, then run the harness two more times.
- Regenerate `help/olwb.md` from `assets.lua` and verify it is identical to
  the embedded help body.
