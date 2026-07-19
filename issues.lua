-- issues.lua -- pure: the notes → agent-work-issues pipeline's data layer.
--
-- No micro/Go imports. Prompt assembly, model-response validation, and
-- deterministic rendering of the gh filing script + review summary. The model
-- only ever produces strict JSON (title/body/labels per issue); THIS module
-- renders the executable script from that JSON, so model output is data and
-- the script generator is code we control. A malformed or malicious response
-- can at worst produce a bad issue body — which the review gate catches —
-- never a bad command.

local M = {}

local TITLE_MAX = 90

-- POSIX single-quote escaping (duplicated from dest.lua so each pure module
-- stays standalone-loadable in any order).
local function shq(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function has_line(text, wanted)
  local hay = tostring(text) .. "\n"
  for line in hay:gmatch("(.-)\n") do
    if line == wanted then return true end
  end
  return false
end

-------------------------------------------------------------------------------
-- Prompt assembly
-------------------------------------------------------------------------------

-- opts: template (instruction text), repo ("owner/name"),
--       repo_context (router/context excerpt or nil), payload (selection md).
-- Sections are delimited so the template can reference them by name.
function M.build_prompt(opts)
  opts = opts or {}
  local parts = {}
  parts[#parts + 1] = opts.template or ""
  parts[#parts + 1] = "## Target repository\n\n" .. (opts.repo or "")
  parts[#parts + 1] = "## Repository context\n\n"
    .. (opts.repo_context
        or "(none — issue Context bullets should cite AGENTS.md)")
  parts[#parts + 1] = "## Notes to process\n\n" .. (opts.payload or "")
  return table.concat(parts, "\n\n") .. "\n"
end

-- Best-effort context excerpt for a local checkout: the root AGENTS.md
-- (truncated) and, for directed-contexts adopters, .subagents/README.md plus
-- the router's first routing table so the model can cite the matching
-- AGENTS-{DOMAIN}.md. read_file is injected (path -> string|nil) to keep
-- this module pure and mockable.
function M.build_repo_context(read_file, repo_path)
  local out = {}
  local agents = read_file(repo_path .. "/AGENTS.md")
  if agents then
    local lines, truncated = {}, false
    for line in (agents .. "\n"):gmatch("(.-)\n") do
      if #lines >= 120 then truncated = true break end
      lines[#lines + 1] = line
    end
    out[#out + 1] = "### Root AGENTS.md" .. (truncated and " (truncated)" or "")
      .. "\n\n" .. table.concat(lines, "\n")
  end
  local sub = read_file(repo_path .. "/.subagents/README.md")
  if sub then
    out[#out + 1] = "### .subagents/README.md (directed contexts)\n\n" .. sub
    -- The router's primary routing table (first markdown table in AGENTS.md),
    -- in case the truncation above cut it off.
    if agents then
      local table_lines, in_table = {}, false
      for line in (agents .. "\n"):gmatch("(.-)\n") do
        if line:match("^%s*|") then
          in_table = true
          table_lines[#table_lines + 1] = line
        elseif in_table then
          break
        end
      end
      if #table_lines > 0 then
        out[#out + 1] = "### Context routing table\n\n"
          .. table.concat(table_lines, "\n")
      end
    end
  end
  if #out == 0 then return nil end
  return table.concat(out, "\n\n")
end

-------------------------------------------------------------------------------
-- Response validation
-------------------------------------------------------------------------------

-- Model text -> drafts array, or nil + a list of human-readable problems.
-- Tolerates a fenced ```json block or bare JSON. No partial acceptance: any
-- invalid element rejects the whole response (re-draft or hand-edit).
function M.parse_response(text)
  text = tostring(text or "")
  local fenced = text:match("```json%s*\n(.-)```")
    or text:match("```%s*\n(.-)```")
  local body = (fenced or text):match("^%s*(.-)%s*$")
  local ok, data = pcall(olwb_json.decode, body)
  if not ok then
    return nil, { "response is not valid JSON (prose? save/rerun)" }
  end
  if type(data) ~= "table" or data[1] == nil then
    return nil, { "response is not a non-empty JSON array of issues" }
  end

  local errs = {}
  for i, d in ipairs(data) do
    local pre = "issue " .. i .. ": "
    if type(d) ~= "table" then
      errs[#errs + 1] = pre .. "not an object"
    else
      local t = d.title
      if type(t) ~= "string" or t:match("^%s*$") then
        errs[#errs + 1] = pre .. "missing title"
      else
        if #t > TITLE_MAX then
          errs[#errs + 1] = pre .. "title longer than " .. TITLE_MAX .. " chars"
        end
        if t:find("\n", 1, true) then
          errs[#errs + 1] = pre .. "title contains a newline"
        end
      end
      local b = d.body
      if type(b) ~= "string" or b == "" then
        errs[#errs + 1] = pre .. "missing body"
      else
        if not b:find("## Context", 1, true) then
          errs[#errs + 1] = pre .. "body missing '## Context' section"
        end
        if not b:find("## Work", 1, true) then
          errs[#errs + 1] = pre .. "body missing '## Work' section"
        end
        if not b:find("- [ ]", 1, true) then
          errs[#errs + 1] = pre .. "body has no '- [ ]' checkbox"
        end
      end
      if d.labels ~= nil and type(d.labels) ~= "table" then
        errs[#errs + 1] = pre .. "labels is not an array"
      end
    end
  end
  if #errs > 0 then return nil, errs end

  local drafts = {}
  for _, d in ipairs(data) do
    local labels = {}
    for _, l in ipairs(d.labels or {}) do
      if type(l) == "string" and l ~= "" then labels[#labels + 1] = l end
    end
    -- The template's one non-negotiable: agent-work is always present.
    local has_aw = false
    for _, l in ipairs(labels) do
      if l == "agent-work" then has_aw = true end
    end
    if not has_aw then table.insert(labels, 1, "agent-work") end
    drafts[#drafts + 1] = { title = d.title, body = d.body, labels = labels }
  end
  return drafts
end

-------------------------------------------------------------------------------
-- Script + summary rendering (deterministic, unit-tested)
-------------------------------------------------------------------------------

-- The reviewable filing script, in the file-v0.4.0-config-issues.sh mold.
-- opts: id (draft id), source (liner name) — header provenance only.
function M.render_script(repo, drafts, opts)
  opts = opts or {}
  local lines = {}
  lines[#lines + 1] = "#!/usr/bin/env bash"
  lines[#lines + 1] = "# olwb issues draft " .. (opts.id or "?")
    .. (opts.source and (" — from liner '" .. opts.source .. "'") or "")
  lines[#lines + 1] = "# Review before running: files " .. #drafts
    .. " issue(s) on " .. repo .. "."
  lines[#lines + 1] = "set -euo pipefail"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "if ! command -v gh >/dev/null 2>&1; then"
  lines[#lines + 1] = "  echo \"error: gh CLI not found\" >&2"
  lines[#lines + 1] = "  exit 1"
  lines[#lines + 1] = "fi"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "REPO=" .. shq(repo)

  -- Preflight: every referenced label must exist or `gh issue create` aborts
  -- (and with set -e, the whole run). Create-if-absent per label; `|| true`
  -- swallows the already-exists failure without touching an existing label's
  -- color or description (which --force would overwrite).
  local seen, labels = {}, {}
  for _, d in ipairs(drafts) do
    for _, l in ipairs(d.labels) do
      if not seen[l] then
        seen[l] = true
        labels[#labels + 1] = shq(l)
      end
    end
  end
  if #labels > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "for L in " .. table.concat(labels, " ") .. "; do"
    lines[#lines + 1] = "  gh label create \"$L\" --repo \"$REPO\" >/dev/null 2>&1 || true"
    lines[#lines + 1] = "done"
  end

  for i, d in ipairs(drafts) do
    -- Collision-free heredoc marker, per issue: EOF unless the body contains
    -- a literal EOF line, then OLWB_EOF_1, OLWB_EOF_2, … until free.
    local body = tostring(d.body):gsub("\n+$", "")
    local marker = "EOF"
    local n = 0
    while has_line(body, marker) do
      n = n + 1
      marker = "OLWB_EOF_" .. n
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "echo "
      .. shq(string.format("[%d/%d] %s", i, #drafts, d.title))
    local create = "gh issue create --repo \"$REPO\""
    for _, l in ipairs(d.labels) do
      create = create .. " --label " .. shq(l)
    end
    create = create .. " --title " .. shq(d.title)
    -- Quoted heredoc: the body is inert data, nothing expands.
    create = create .. " --body \"$(cat <<" .. shq(marker) .. "\n"
      .. body .. "\n" .. marker .. "\n)\""
    lines[#lines + 1] = create
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "echo \"done: " .. #drafts .. " issue(s) filed on $REPO\""
  lines[#lines + 1] = ""
  return table.concat(lines, "\n")
end

-- The review summary appended to the drafts liner: what got drafted, where
-- the script lives, and the follow-up command. Ends with an instruction,
-- never an action — that's the review gate.
function M.render_draft_md(id, repo, drafts, script_path)
  local lines = {}
  lines[#lines + 1] = "issues draft " .. id .. " → " .. repo
  lines[#lines + 1] = "script: " .. script_path
  for i, d in ipairs(drafts) do
    lines[#lines + 1] = i .. ". " .. d.title
    local first_box = tostring(d.body):match("%- %[ %] ([^\n]+)")
    if first_box then
      lines[#lines + 1] = "   - [ ] " .. first_box
    end
  end
  lines[#lines + 1] = "review: /issues open " .. id
    .. " — then file: /issues file " .. id
  return table.concat(lines, "\n")
end

olwb_issues = M

return M
