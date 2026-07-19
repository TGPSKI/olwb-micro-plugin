# The issues pipeline — `/issues`

`/issues` turns parked notes into GitHub issues an agent can pick up and
implement. It runs in two stages with a review step between them: a model
drafts the issues, olwb renders a `gh` filing script from the drafts, and
nothing reaches GitHub until you have read the script and run stage 2
yourself.

## Setup

Register at least one target repository:

```
/issues repo add <alias> <owner/repo> [local-path]
/issues repo list
/issues repo rm <alias>
```

The `local-path` is optional but worth setting: when present, the drafting
prompt is enriched with that repo's `AGENTS.md` (and `.subagents/` routing
table, if the repo has one), so drafted issues cite the right context for an
implementing agent.

The drafting model defaults to `claude -p`; view or change it with:

```
/issues model                  show the current command
/issues model <cmd…>           set it (e.g. /issues model codex exec)
```

## Stage 1 — draft

Select the source notes in browse mode (see [send.md](send.md)), then:

```
/issues draft <alias>
```

The selection goes to the model, which must answer with strict JSON: title,
body, and labels per issue, following the agent-work template (`## Context`
bullets citing context to load plus verbatim note provenance, `## Work` as
bounded checkboxes, the `agent-work` label enforced). The model produces no
shell. olwb validates the JSON and renders the `gh issue create` script
from it deterministically — a malformed response is rejected whole, with
the raw output saved for inspection, so at worst you get a bad issue body,
not a bad command.

The draft lands on disk under the data directory:

```
<datadir>/issues/<id>.sh          the filing script — read this
<datadir>/issues/<id>.json        manifest (sources, repo, status)
<datadir>/issues/<id>.raw.txt     only on a rejected response
```

`/issues list` shows all drafts with their status.

## The review step

Open `<id>.sh` and read it. This is the whole point of the two-stage design:
the script is plain `gh issue create` calls, one per issue, and you are the
gate between drafting and filing. Edit it if an issue needs adjusting, or
delete it and re-draft.

## Stage 2 — file

```
/issues file latest        run the most recent reviewed script
/issues file <id>          or a specific one
```

Filing records the issue URLs as messages in the `issues` liner, labels the
source messages `#filed`, and marks the draft done — refiling the same
draft is refused.

## Tuning the prompt

The drafting prompt template is seeded once to `<datadir>/issues-prompt.md`
and never overwritten; edit it to change how the model structures issues.
