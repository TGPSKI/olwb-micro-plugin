# olwb: selection → agent-work GitHub issues ("the pipeline")

## Context

Extension of `.agents/plans/olwb-benefits-plan.md`. That plan gives olwb
message navigation, multi-select, and a generic send-to-destination executor.
This plan builds the first *structured* consumer of a selection: take a set of
parking-lot messages, send them to a model that transforms them into GitHub
issues following the **agent-work** template, review the result, file them
with `gh`, and hand them off for implementation by subagents following the
**directed-contexts** pattern.

The source request (captured, fittingly, as an olwb message in
`#olwb-parking-lot`):

> i want to be able to take a selection of messages in a liner and send them
> to a model for processing into github issues following the agent-work
> template for implementation by subagents following the directed-contexts
> pattern

### Conventions this plan inherits (do not reinvent)

1. **agent-work issue template**
   (`.github/ISSUE_TEMPLATE/agent-work-item.md` in directed-contexts and
   leather): label `agent-work`; body is `## Context` (bulleted pointers —
   `AGENTS.md` or a specific directed context — plus session-note provenance)
   followed by `## Work` (bounded `- [ ]` checkboxes). See
   `leather/.agents/plans/file-v0.4.0-config-issues.sh` for four real filed
   examples with the Context-bullets-carry-the-evidence style.
2. **gh-script filing convention** (same file): issues are filed by a
   reviewable `#!/usr/bin/env bash` script — `set -euo pipefail`, `gh` CLI
   presence check, one `gh issue create --repo … --label agent-work --title …
   --body "$(cat <<'EOF' … EOF)"` block per issue, progress echoes. The
   script IS the review artifact; nothing is filed until a human runs it (or
   explicitly asks olwb to).
3. **directed-contexts pattern** (`directed-contexts/PATTERN.md`): a target
   repo's root `AGENTS.md` is the Context Router; `.subagents/AGENTS-*.md`
   are bounded ownership contexts. An agent-work issue's `## Context` section
   should cite the *matching directed context* when the target repo has a
   context set, or plain `AGENTS.md` when it doesn't (olwb itself is a
   one-`AGENTS.md` repo per pattern invariant 7). Subagents then load inline
   or spawn scoped per the router's execution table.
4. **DAG dispatch downstream**
   (`leather/.agents/plans/leather-v0.4.0-agentic-dag-metaplan.md`): once
   filed, a batch of agent-work issues gets sequenced with plan-dag into a
   fan-out/fan-in metaplan. That is the consumer side of the handoff and is
   **out of olwb's scope** — this plan only guarantees the issues it files
   are well-formed inputs to it.

### Dependencies on the benefits plan

Hard prerequisites (must land first):

- **A. Feed index + selection** — `selected` set, `render_selection_md`
  payload builder.
- **C. Destinations state pattern** — `state.*` persistence shape,
  overlay-list UI pattern, `extra.*` Tab-cycle candidate wiring.
- **D. Async executor** — `micro/shell` `JobStart` flow, tmp-file payload via
  `olwb_store.write_file_atomic`, response-into-a-liner append helper, the
  "never disturb the active liner" rule.

Soft prerequisite: **B. Browse keys** — nicer UX, but `/issues draft` works
against the whole filtered scope when nothing is selected (same fallback rule
as `/send`), so B is not blocking.

## Pipeline shape

Three stages, one mandatory review gate in the middle:

```text
[select messages]                                (benefits plan)
      │  /issues draft <repo>
      ▼
[model: notes → issues JSON] → validate → gh script + draft summary   (stage 1)
      │  human reads script / draft summary                (REVIEW GATE)
      │  /issues file <id>
      ▼
[gh issue create × N] → URLs recorded, sources labeled #filed          (stage 2)
      │
      ▼
[subagents: plan-dag → directed-contexts routed implementation]        (stage 3,
                                                            out of olwb scope)
```

Key safety decision: **the model never produces executable shell.** It
outputs strict JSON (title/body/labels per issue); olwb *deterministically*
renders the gh script from that JSON with pure, unit-tested Lua. Model output
is data, the script generator is code we control. A malformed or malicious
model response can at worst produce a bad issue body — which the review gate
catches — never a bad command.

## Design

### A. New pure module `issues.lua`

Pure (no micro/Go imports), loadable under plain `lua`, mirroring
`cmd.lua`/`render.lua` discipline. Registered as `olwb_issues` in the shared
namespace (same prefixed-global convention as the other modules — remember
micro wraps everything in `module("olwb", package.seeall)`).

- `M.build_prompt(opts)` → string. Assembles the full model prompt from:
  `opts.template` (the instruction text, section B), `opts.repo`
  (`owner/name`), `opts.repo_context` (router/context excerpt or nil),
  `opts.payload` (the `render_selection_md` markdown of the selected
  messages). Clearly delimited sections so the template can reference them
  (`## Target repository`, `## Repository context`, `## Notes to process`).
- `M.parse_response(text)` → `drafts, errs`. Tolerates a fenced ```json
  block or bare JSON (models do both); decodes with the vendored `json.lua`.
  Validates each element of the array:
  - `title`: non-empty string, ≤ 90 chars, no newlines.
  - `body`: string containing a `## Context` section and a `## Work` section
    with at least one `- [ ]` checkbox.
  - `labels`: optional array of strings; `agent-work` is force-added if
    missing (the template's one non-negotiable).
  Returns `nil, errs` (list of human-readable problems, indexed by element)
  on any failure — no partial acceptance, the whole response is re-drafted or
  hand-edited.
- `M.render_script(repo, drafts)` → string. Deterministic bash in the
  `file-v0.4.0-config-issues.sh` mold: shebang, header comment naming the
  source liner + draft id, `set -euo pipefail`, `command -v gh` check,
  `[N/total]` progress echoes, one `gh issue create --repo "$REPO" --label
  agent-work` block per draft with the body in a **quoted** heredoc.
  Heredoc safety: default marker `EOF`; if any body line *is* `EOF`, walk
  `OLWB_EOF_1`, `OLWB_EOF_2`, … until collision-free (per issue). Extra
  labels become additional `--label` flags, shell-quoted.
- `M.render_draft_md(id, repo, drafts, script_path)` → string. The review
  summary appended to the drafts liner: draft id, target repo, script path,
  one line per issue (`1. <title>` + first Work checkbox), and the follow-up
  command (`/issues file <id>`).
- `M.render_manifest(...)` / plain-table manifest helpers for stage-2
  bookkeeping (section E).

### B. Prompt template (assets.lua, user-overridable)

New `OLWB_ISSUES_PROMPT` string in `assets.lua`. On first `/issues draft`,
seed it to `<datadir>/issues-prompt.md` (only when absent — same
seed-once rule as destinations); at run time the file wins over the embedded
copy, so the user can tune the prompt without touching the plugin.

Template content contract:

- **Role**: "You transform terse parking-lot notes into agent-consumable
  GitHub issues."
- **Clustering rules**: one issue per coherent unit of work; merge duplicate
  notes into one issue; split compound notes ("X, also Y") into separate
  issues; a note too vague to act on becomes a checkbox inside a single
  `triage: clarify parked notes` issue rather than being silently dropped —
  every input note must be traceable to exactly one output issue.
- **Title convention**: `area: imperative summary` (matching the leather
  examples: `config: auto-discover ./config.yaml…`, `doctor: fix incorrect
  source attribution…`).
- **Body contract** (the agent-work template):
  - `## Context` — bullets. First bullet cites the context an implementing
    subagent should load: the specific `.subagents/AGENTS-*.md` when the
    repository-context section of the prompt includes a routing table whose
    domain matches, otherwise `AGENTS.md`. Then provenance bullets: each
    source note **verbatim** with its timestamp and labels (`Session note
    (2026-07-17 13:37): "label inheritance is broken, …"`), plus any inferred
    cost/severity framing.
  - `## Work` — 2–5 bounded, independently verifiable `- [ ]` checkboxes.
    Confirm-before-fix framing where the note reports a suspicion rather
    than a verified fact (the leather issue #4 pattern).
- **Output contract**: respond with **only** a JSON array,
  `[{"title": …, "body": …, "labels": [ … ]}]`, `agent-work` always present
  in labels. No prose, no fences (fences tolerated by the parser anyway).

### C. Repo targets + context enrichment

Persisted as `state.issue_repos` — array of
`{ alias, repo = "owner/name", path = "<local checkout, optional>" }` —
seeded empty, managed via `/issues repo …` (section D). `cmd.candidates`
gains `extra.repos` so `/issues draft ` Tab-cycles aliases.

Target resolution for `/issues draft [<alias>]`: explicit alias wins; with
exactly one configured repo it's the default; otherwise error listing the
aliases ("configure with /issues repo add"). No label→repo inference magic
in v1 — explicit beats clever, and Tab-cycle makes explicit cheap.

Context enrichment (best-effort, never fatal): when the target has a `path`
and it's readable, build `repo_context` from:

1. root `AGENTS.md`, truncated to the first ~120 lines;
2. if `.subagents/README.md` exists (directed-contexts adopter): its content
   plus the router's primary routing table, so the model can cite the right
   `AGENTS-{DOMAIN}.md` per convention 3.

When there's no path or no readable router, `repo_context` is nil and the
template's fallback ("cite AGENTS.md") applies. File reads go through a
small `ctx.read_file` injected from olwb.lua (wrapping the same ioutil-based
helper family as `olwb_store`), keeping `issues.lua` pure and mockable.

### D. `/issues` command surface (cmd.lua)

- `M.verbs` += `"issues"`;
  `M.subverbs.issues = { "draft", "file", "list", "repo", "model" }`.
- `/issues draft [<alias>]` — stage 1. Payload = selected messages in feed
  order, else whole current scope (respecting active filter) — identical
  fallback to `/send`. Dispatches to `ctx.issues_draft(alias)`.
- `/issues file <id|latest>` — stage 2, `ctx.issues_file(id)`.
- `/issues list` — overlay (existing `options_text` pattern) listing drafts
  from the manifest dir: id, repo, issue count, status (`drafted` /
  `filed`), script path.
- `/issues repo add <alias> <owner/repo> [path]` / `repo rm <alias>` /
  `repo list` — manage `state.issue_repos`.
- `/issues model [<cmd…>]` — show or set `state.issues_model_cmd`, the shell
  command the payload is piped to. Default: `claude -p` (verified on this
  machine in the benefits-plan session); `codex exec` and `opencode run`
  work as drop-in alternatives (plain one-shot, no session resume — the
  issues pipeline's strict-JSON contract stays stateless and does its own
  parsing, independent of the benefits plan's destination adapters). Stored
  as a plain template string, same editability philosophy as destinations.
- `help_entries` rows for `draft`, `file`, `list`, `repo`, `model`.

All handlers stay pure-dispatch: they validate arguments and call `ctx.*`;
the executor lives in olwb.lua.

### E. Executor wiring (olwb.lua)

Reuses the benefits-plan send machinery wholesale (tmp file +
`shell.JobStart` + accumulate stdout + onExit), with a two-hop flow.

**Draft** (`ctx.issues_draft`):

1. Build payload with `render_selection_md`; resolve repo; load prompt
   template (datadir file, else embedded); best-effort `repo_context`;
   `olwb_issues.build_prompt(...)`.
2. Write prompt to `<datadir>/issues/tmp-<id>-prompt.md` (atomic write);
   `JobStart(state.issues_model_cmd .. " < " .. tmpfile, …)` async — micro
   never blocks; bar shows `drafting issues via <cmd>…`.
3. `onExit`: delete tmp. `olwb_issues.parse_response(stdout)`:
   - **failure** → save raw response to `<datadir>/issues/<id>.raw.txt`,
     info-bar error with the validation problems and the raw path. Nothing
     else changes; the user re-runs or hand-fixes.
   - **success** → write `<datadir>/issues/<id>.sh` (render_script, then
     chmod +x via the executor), write manifest
     `<datadir>/issues/<id>.json` — `{ id, repo, alias, script, status =
     "drafted", created_ms, source_liner_id, message_ids }` (message ids
     captured *at draft time* so stage 2 can label the right sources even if
     the liner has since grown). Append `render_draft_md` output as a
     message to the **`issues` liner** (load-or-create, append, save, drop —
     the benefits-plan response-liner rule: never disturb `active_liner`
     unless `issues` IS active, then mutate in place + rerender). Clear
     `selected`. Bar: `drafted N issue(s) → review <id>.sh, then /issues
     file <id>`.

**File** (`ctx.issues_file`):

1. Look up manifest; refuse if `status ~= "drafted"` (`already filed
   2026-…`). `latest` = newest by `created_ms`.
2. `JobStart("sh <script>", …)`; gh prints one issue URL per create —
   accumulate.
3. `onExit`: non-zero exit / empty output → error bar with stderr tail,
   status stays `drafted` (gh script is `set -e`, so partial filing is
   possible — record any URLs already captured in the manifest as
   `filed_urls` so a re-run can be reasoned about manually; do NOT auto-
   retry). Success → manifest `status = "filed"`, `filed_urls`, append a
   result message (URLs list) to the `issues` liner, and add label `#filed`
   to each source message id in the origin liner (load, `add_label`, save —
   same don't-disturb rule). Bar: `filed N issue(s) on <repo>`.

**Never auto-file.** `/issues draft` ending with an instruction, not an
action, is the review gate that makes a model-in-the-loop pipeline safe.

### F. Docs & help

- `help_entries` + `assets.lua` `OLWB_HELP` + regenerate `help/olwb.md`
  (awk one-liner in AGENTS.md — edit assets, never the generated file).
- README: "The pipeline — notes to agent-work issues" section under Usage:
  the three stages, the review gate, a sample generated script snippet, and
  a pointer to the directed-contexts pattern for the consumer side.
- AGENTS.md: update the "next planned feature set" pointer (currently names
  the benefits plan) to list both plans and their dependency order.

## Handoff contract (stage 3 — documented, not built)

What olwb guarantees about every issue it files, so downstream tooling can
rely on it:

- label `agent-work` (plus any model-proposed domain labels);
- `## Context` first bullet names the context to load (`AGENTS.md` or a
  specific `.subagents/AGENTS-*.md`), remaining bullets carry verbatim note
  provenance with timestamps;
- `## Work` is a bounded checkbox list, one verifiable outcome per box.

Consumption path (existing tooling, zero olwb code): plan-dag sequences a
batch of filed issues into a fan-out/fan-in metaplan (the
leather-v0.4.0 convention — parallel-safe leaves dispatch immediately,
sequential chains stay one agent, a fan-in verification gate before
release); implementing subagents route per the target repo's Context Router
execution table (inline load for narrow changes, isolated spawn for
independent work); checkbox updates and PR links follow the gh-issues
lifecycle (`leather/plans/01-gh-issues.md`).

## Files touched

- `issues.lua` — **new** pure module: prompt assembly, response validation,
  script/draft/manifest rendering
- `cmd.lua` — `issues` verb + subverbs, handlers, `extra.repos` candidates
- `olwb.lua` — `ctx.issues_draft` / `ctx.issues_file` executors, repo state,
  `read_file` injection, seed logic, build_ctx wiring
- `assets.lua` — `OLWB_ISSUES_PROMPT`, help text; regen `help/olwb.md`
- `tests/run_tests.lua` — issues.lua unit tests, dispatch tests (mock ctx)
- `tests/harness.lua` — extend mocks if olwb.lua grows new top-level imports
- `tests/fixtures/` — **new**: canned model responses (good, fenced, broken)
- `README.md`, `AGENTS.md`

## Sequencing

1. Benefits plan phases A, C, D land (B whenever).
2. `issues.lua` + fixtures + unit tests (pure, no editor needed).
3. `/issues` cmd surface + dispatch tests.
4. Draft executor (E) end-to-end with a fake model.
5. File executor + manifest + source labeling.
6. Docs, help regen, e2e sweep.

## Micro API landmines

All of the benefits plan's landmine list applies (focus via
`tab:SetActive(i)`, path-guarded callbacks, rerender cursor parking,
non-isolated `~/.config/micro/settings.json` in tmux tests). New ones
specific to this plan:

- `JobStart` command strings run through `sh -c` — the script path and
  model cmd interpolations must be quoted; only olwb-generated paths (no
  user text) may appear in the command string. User-influenced content
  travels via stdin tmp files exclusively.
- `chmod +x` needs a shell hop or Go os import — do it in the same JobStart
  chain (`sh -c 'cat > f && chmod +x f'`-style) or accept `sh <script>`
  invocation and skip the +x bit entirely (simpler; the manifest records
  the script path either way). Decide at impl time; `sh <script>` is the
  fallback that needs nothing.
- The vendored `json.lua` errors (via `error()`) on bad input —
  `parse_response` must pcall the decode.

## Verification

1. `make check` — unit tests:
   - `parse_response`: bare JSON, ```json fenced, prose-wrapped (reject),
     missing `## Work` (reject with per-element error), missing `agent-work`
     label (force-added), body containing a literal `EOF` line (accepted —
     script renderer picks `OLWB_EOF_1`), non-array JSON (reject).
   - `render_script`: golden test against a checked-in expected script;
     assert `set -euo pipefail`, quoted heredocs, one create per draft,
     `--label agent-work` on every create, collision-free markers.
   - `build_prompt`: with and without `repo_context`; payload passthrough.
   - dispatch: `/issues draft|file|list|repo|model` argument validation
     against mock ctx.
2. tmux end-to-end (isolated `XDG_DATA_HOME`), fully fake externals:
   - fake model: `state.issues_model_cmd = "cat tests/fixtures/
     issues-response.json"` (ignores stdin — deterministic);
   - fake gh: PATH-shim script logging its argv to a file and echoing
     `https://github.com/t/t/issues/N`;
   - flow: capture 4 messages → select 3 → `/issues draft t` → script +
     manifest exist on disk, draft summary in `issues` liner, selection
     cleared, active liner untouched → `/issues file latest` → gh log shows
     N create calls each with `--label agent-work`, URLs in result message,
     manifest `status = "filed"`, source messages carry `#filed`, the
     unselected 4th message doesn't → second `/issues file` refused.
   - failure path: fake model emitting prose → raw saved, clean error bar,
     no script, no liner writes.
3. One real dogfood run, manually (user-triggered — spends tokens and files
   real issues): draft from the actual `#olwb-parking-lot` liner (the
   screenshot backlog: label inheritance bug, padding overflow, liner tabs,
   delete-with-confirmation, …) against `TGPSKI/olwb-micro-plugin`, read the
   generated script, then file. The parking lot that requested this feature
   becomes its first test data.
