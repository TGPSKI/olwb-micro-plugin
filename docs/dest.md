# Destinations — `/dest`

A destination is a named shell command that olwb can pipe notes into. The
payload arrives on the command's stdin as markdown (liner title, message
content, timestamps, labels), so anything that reads stdin works: an AI CLI,
`xclip`, `tee`, a script of your own.

Sending itself is covered in [send.md](send.md); this guide is about defining
and managing the targets.

## The basics

```
/dest                          list destinations (overlay)
/dest add <name> <cmd…>        add one
/dest rm <name>                remove one
```

The command is everything after the name — no quoting needed for simple
cases:

```
/dest add oc-review opencode run --agent review
/dest add jrnl tee -a ~/journal.md
```

## Presets

First run seeds six destinations: `claude`, `codex`, `opencode` (all three
route responses into the `inbox` liner), `leather`, `clipboard`, and `file`.
They're ordinary entries — edit or remove them freely; olwb does not re-seed.

## Where responses land: `/dest into`

```
/dest into <name> <liner|->
```

Command output is captured and appended as a message to the named liner
(created on first use), labeled `#<name>` so you can always tell which
destination produced it. `-` discards output. Responses landing outside the
active liner bump a badge in the bar; see [send.md](send.md#the-inbox).

```
/dest into oc-review reviews     responses → the `reviews` liner
```

## CLI adapters: `/dest kind`

Destinations whose command starts with `claude`, `codex`, or `opencode` get
an adapter kind automatically. An adapter changes how the send runs:

- the command is invoked with that CLI's JSON output flag,
- the response *text* is extracted from the JSON before landing as a message,
- the CLI's session id is remembered **per destination, per liner**, so the
  next `/send` from the same liner resumes the same conversation.

A stale session (the CLI no longer recognizes the id) is retried fresh
exactly once, and the new id replaces the old one.

```
/dest kind <name> <kind|->     override the inferred kind (- = plain pipe)
/dest session list             stored dest|liner → session mappings
/dest session clear <name>     forget this liner's session for a dest
```

Inference only looks at the first word of the command, so a wrapper script
named `claude-wrapper.sh` won't get an adapter — set it with `/dest kind` if
you want one.

olwb has no agent registry of its own. An "agent preset" is just a
destination whose command names an agent the CLI already knows:

```
/dest add reviewer opencode run --agent review
/dest add planner claude --agent planner
```

## Worked example

```
/dest add oc-review opencode run --agent review
/dest into oc-review reviews
/send oc-review
```

First send starts a conversation and drops the response in `reviews`;
every later `/send oc-review` from the same liner continues it.
