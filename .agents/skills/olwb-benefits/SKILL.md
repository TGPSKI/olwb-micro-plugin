---
name: olwb-benefits
description: "Create, configure, and troubleshoot olwb's benefits features: destinations (/dest), sending (/send), and the notes → agent-work issues pipeline (/issues). USE FOR: adding or wiring a destination or agent preset; diagnosing stale CLI sessions, missing inbox responses, tui terminal problems, or rejected issue drafts; setting up the issues pipeline for a target repo. DO NOT USE FOR: core capture/liner/session usage (see README.md) or modifying olwb's Lua source."
compatibility: Designed for Claude Code and similar coding agents helping a user of the olwb micro plugin.
metadata:
  argument-hint: 'What to set up or the symptom, e.g. "add an opencode review dest" or "responses not landing in inbox".'
  user-invocable: "true"
---

# olwb-benefits

Helps a user create, configure, and debug olwb's sending and issues
features. Authoritative references, in order: `docs/dest.md`,
`docs/send.md`, `docs/issues.md`, then `help/olwb.md` for exact command
syntax. Read the relevant doc before answering; don't work from memory.

All commands below are typed in olwb's one line. Every one is also
reachable as `> olwb <verb> [args]` without the leading `/`.

---

## Where state lives

Nearly every question here is answerable from two files under the data
directory (default `$XDG_DATA_HOME/olwb`, overridable via `olwb.datadir`):

- `state.json` — destinations (command, `into` liner, kind), stored
  dest×liner CLI session ids, unread counts, active liner/filter.
- `issues/` — issue drafts: `<id>.sh` (the filing script), `<id>.json`
  (manifest with sources/repo/status), `<id>.raw.txt` (only when a model
  response was rejected).

When troubleshooting, read `state.json` first; it is the ground truth the
overlays (`/dest`, `/issues list`) render from.

## Creation recipes

Destination piping to a plain command:

```
/dest add jrnl tee -a ~/journal.md
```

Agent preset (adapter kind inferred from the first word; responses to a
dedicated liner, conversation resumed per liner):

```
/dest add oc-review opencode run --agent review
/dest into oc-review reviews
```

Issues pipeline for a repo (always set the local path when one exists —
it enriches drafts with the repo's AGENTS.md):

```
/issues repo add olwb TGPSKI/olwb-micro-plugin ~/git/TGPSKI/olwb-micro-plugin
```

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Response never lands anywhere | destination's `into` is `-`, or the command failed silently | `/dest` overlay to check `into`; run the command manually with a small stdin payload |
| Response lands but no badge | it landed in the *active* liner — badges only fire for non-active liners | working as designed; `Alt-i` is only for the inbox case |
| Raw JSON appears as the message | adapter kind missing (wrapper script, renamed binary) | `/dest kind <name> claude\|codex\|opencode` |
| Conversation doesn't continue across sends | session stored per destination **and** liner — a different liner is a different conversation | `/dest session list` to see mappings |
| Send hangs or repeats fresh | stale session id (CLI purged it); olwb retries fresh exactly once per send | `/dest session clear <name>` from the affected liner |
| `tui` opens nothing | no terminal auto-detected | `/set termcmd "<terminal cmd>"` (stored in state.json, not micro settings) |
| Draft rejected | model response wasn't strict JSON per the template | read `issues/<id>.raw.txt`; if the model fenced or chatted, tighten `<datadir>/issues-prompt.md` or switch `/issues model` |
| `/issues file` refuses | draft already filed — refiling is deliberately blocked | check `/issues list` status; re-draft if the sources changed |
| Drafts cite no repo context | repo registered without a local `path` | `/issues repo rm` + re-`add` with the path |

## Guidance defaults

- Prefer editing seeded presets over adding near-duplicates; they never
  re-seed, so changes stick.
- For a new agent workflow, wire the destination and its `into` liner
  before the first send — retroactively moving responses means manual
  copying.
- The `<id>.sh` review step in the issues pipeline is load-bearing: never
  advise skipping the read-before-file step, and never file on the user's
  behalf without showing the script.
