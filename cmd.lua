-- cmd.lua -- pure slash-command parsing and dispatch.
--
-- No micro/Go imports. Handlers operate exclusively through an injected `ctx`
-- table (wired in olwb.lua), so this module is fully unit-testable with a mock
-- ctx. Uses only the standard `os` library (for date parsing), which is present
-- in both GopherLua and standalone lua.

local M = {}

-- Top-level verbs, for command completion.
M.verbs = {
  "new", "open", "close", "save",
  "liner", "session",
  "label", "labels",
  "filter", "search", "export",
  "send", "dest", "issues",
  "list", "set", "help",
}

-- Subcommand vocabularies (for contextual completion).
M.subverbs = {
  liner = { "start", "end", "name", "desc", "label" },
  session = { "start", "end", "name", "label" },
  filter = { "label:", "since:", "until:", "term:", "clear" },
  export = { "md", "json" },
  dest = { "add", "rm", "into", "kind", "session" },
  issues = { "draft", "file", "list", "repo", "model" },
  set = { "autostart", "composesize", "datadir", "rulewidth", "termcmd",
          "theme", "timefmt" },
}

M.dest_kinds = { "claude", "codex", "opencode" }

-- One row per command for the /? help menu: { usage, description }.
M.help_entries = {
  { "/new [name]",            "create + activate a new liner" },
  { "/open <name|id>",        "load + activate an existing liner" },
  { "/close",                 "deactivate the liner (ends its session)" },
  { "/save",                  "force a save (saves are automatic)" },
  { "/liner name|desc|label|start|end",  "manage the active liner" },
  { "/session name|label|start|end",     "manage the active session" },
  { "/label <name>",          "toggle a label applied to new messages" },
  { "/labels",                "list known labels with counts" },
  { "/filter label: since: until: term:", "narrow the feed" },
  { "/filter clear",          "remove the active filter" },
  { "/search <term>",         "substring search over the feed" },
  { "/export [md|json] [path]", "write the feed to a file" },
  { "/send <dest> [tui]",     "send selection (or scope) to a destination" },
  { "/dest add|rm|into|kind|session", "manage send destinations" },
  { "/issues draft|file|list|repo|model", "notes → agent-work GitHub issues" },
  { "/list",                  "list liners with message counts" },
  { "/set [option] [value]",  "view / change olwb options" },
  { "/help",                  "this menu (also /?)" },
}

-------------------------------------------------------------------------------
-- Parsing
-------------------------------------------------------------------------------

local function split_ws(s)
  local out = {}
  for tok in s:gmatch("%S+") do out[#out + 1] = tok end
  return out
end

-- Remainder of a string after its first whitespace-delimited token.
local function strip_first_token(s)
  return (s:gsub("^%s*%S+%s*", ""))
end

-- Parse a compose line into cmd, args[], rest. Accepts an optional leading "/".
-- Returns nil if the line is not a command (no leading slash and no cmd).
function M.parse(line)
  local trimmed = (line:gsub("^%s+", ""):gsub("%s+$", ""))
  if trimmed:sub(1, 1) == "/" then
    trimmed = trimmed:sub(2)
  end
  if trimmed == "" then return nil end
  local args = split_ws(trimmed)
  local cmd = args[1]
  table.remove(args, 1)
  local rest = strip_first_token(trimmed)
  return cmd, args, rest
end

-- Is this compose line a slash command?
function M.is_command(line)
  return (line:gsub("^%s+", "")):sub(1, 1) == "/"
end

-------------------------------------------------------------------------------
-- Completion (pure; drives Tab in the compose line and the live /? menu)
-------------------------------------------------------------------------------

local function common_prefix(list)
  local p = list[1]
  for i = 2, #list do
    local s = list[i]
    local j = 0
    local maxj = math.min(#p, #s)
    while j < maxj and p:sub(j + 1, j + 1) == s:sub(j + 1, j + 1) do j = j + 1 end
    p = p:sub(1, j)
  end
  return p
end

-- Candidates for the token currently being typed. extra supplies dynamic
-- pools: extra.liners (names for /open), extra.dests (destination names for
-- /send and /dest …), extra.repos (issue-repo aliases for /issues draft).
-- Returns candidates[], the partial token, and the line prefix to keep in
-- front of a completed token.
function M.candidates(line, extra)
  if not M.is_command(line) then return {}, "", "" end
  extra = extra or {}
  local body = line:gsub("^%s*/", "")
  local trailing = body:match("%s$") ~= nil
  local toks = split_ws(body)
  -- 1-based index of the token being completed.
  local n = #toks + (trailing and 1 or 0)
  if n == 0 then n = 1 end
  local part = trailing and "" or (toks[n] or "")
  local pool, kept
  if n == 1 then
    pool = M.verbs
    kept = "/"
  else
    local verb, sub = toks[1], toks[2]
    if n == 2 then
      if M.subverbs[verb] then
        pool = M.subverbs[verb]
      elseif verb == "open" then
        pool = extra.liners
      elseif verb == "send" then
        pool = extra.dests
      end
    elseif n == 3 then
      if verb == "dest" and (sub == "rm" or sub == "into" or sub == "kind") then
        pool = extra.dests
      elseif verb == "dest" and sub == "session" then
        pool = { "list", "clear" }
      elseif verb == "send" then
        pool = { "tui" }
      elseif verb == "issues" and sub == "draft" then
        pool = extra.repos
      elseif verb == "issues" and sub == "repo" then
        pool = { "add", "rm", "list" }
      elseif verb == "issues" and sub == "file" then
        pool = { "latest" }
      end
    elseif n == 4 then
      if verb == "dest" and sub == "kind" then
        pool = M.dest_kinds
      elseif verb == "dest" and sub == "into" then
        pool = extra.liners
      elseif verb == "dest" and sub == "session" and toks[3] == "clear" then
        pool = extra.dests
      elseif verb == "issues" and sub == "repo" and toks[3] == "rm" then
        pool = extra.repos
      end
    end
    if not pool then return {}, "", "" end
    kept = "/" .. table.concat(toks, " ", 1, n - 1) .. " "
  end
  local out = {}
  for _, v in ipairs(pool) do
    if v:sub(1, #part) == part then out[#out + 1] = v end
  end
  return out, part, kept
end

-- Tab completion: extend the line to the longest unambiguous prefix (plus a
-- trailing space when the match is unique). Returns the new line, or nil.
function M.complete(line, extra)
  local cands, part, kept = M.candidates(line, extra)
  if #cands == 0 then return nil end
  local cp = common_prefix(cands)
  if cp == "" or (cp == part and #cands > 1) then return nil end
  local out = kept .. cp
  if #cands == 1 and not cp:match(":$") then out = out .. " " end
  if out == line then return nil end
  return out
end

-------------------------------------------------------------------------------
-- Date parsing (YYYY-MM-DD [HH:MM[:SS]]) -> epoch ms (local time)
-------------------------------------------------------------------------------

function M.parse_date(str)
  if not str then return nil end
  local y, mo, d = str:match("^(%d%d%d%d)%-(%d%d?)%-(%d%d?)")
  if not y then return nil end
  local h, mi, s = str:match("(%d%d?):(%d%d?):?(%d?%d?)")
  local t = {
    year = tonumber(y), month = tonumber(mo), day = tonumber(d),
    hour = tonumber(h) or 0, min = tonumber(mi) or 0,
    sec = tonumber(s ~= "" and s or nil) or 0,
    isdst = false,
  }
  local secs = os.time(t)
  if not secs then return nil end
  return secs * 1000
end

-------------------------------------------------------------------------------
-- Handlers -- each: function(ctx, args, rest)
-------------------------------------------------------------------------------

local H = {}

H["new"] = function(ctx, args, rest)
  local name = ctx.model.trim(rest)
  local liner = ctx.create_liner(name)
  ctx.info("created liner " .. (liner.metadata.name ~= "" and liner.metadata.name
    or ctx.render.short_id(liner.id)))
  ctx.rerender()
end

H["open"] = function(ctx, args, rest)
  local key = ctx.model.trim(rest)
  if key == "" then ctx.error("usage: /open <name|id>") return end
  local liner = ctx.open_liner(key)
  if liner then
    ctx.info("opened " .. (liner.metadata.name ~= "" and liner.metadata.name
      or ctx.render.short_id(liner.id)))
    ctx.rerender()
  else
    ctx.error("no liner matching '" .. key .. "'")
  end
end

H["close"] = function(ctx)
  if not ctx.get_active_liner() then ctx.error("no active liner") return end
  ctx.close_liner()
  ctx.info("closed liner")
  ctx.rerender()
end

H["save"] = function(ctx)
  if not ctx.get_active_liner() then ctx.error("no active liner") return end
  ctx.save_active()
  ctx.info("saved")
end

H["liner"] = function(ctx, args, rest)
  local sub = args[1]
  local subrest = ctx.model.trim(strip_first_token(rest))
  if sub == "start" then
    local name = subrest ~= "" and subrest or ""
    local liner = ctx.create_liner(name)
    ctx.info("started liner " .. ctx.render.short_id(liner.id))
    ctx.rerender()
  elseif sub == "end" then
    if not ctx.get_active_liner() then ctx.error("no active liner") return end
    ctx.close_liner()
    ctx.info("ended liner")
    ctx.rerender()
  elseif sub == "name" then
    local liner = ctx.require_active_liner(); if not liner then return end
    liner.metadata.name = subrest
    ctx.save_active(); ctx.info("liner name set"); ctx.rerender()
  elseif sub == "desc" then
    local liner = ctx.require_active_liner(); if not liner then return end
    liner.metadata.description = subrest
    ctx.save_active(); ctx.info("liner description set"); ctx.rerender()
  elseif sub == "label" then
    local liner = ctx.require_active_liner(); if not liner then return end
    if subrest == "" then ctx.error("usage: /liner label <name>") return end
    local now = ctx.model.toggle_label(liner.metadata.labels, subrest)
    ctx.save_active()
    ctx.info((now and "added" or "removed") .. " liner label #" .. subrest)
    ctx.rerender()
  else
    ctx.error("usage: /liner start|end|name <s>|desc <s>|label <l>")
  end
end

H["session"] = function(ctx, args, rest)
  local sub = args[1]
  local subrest = ctx.model.trim(strip_first_token(rest))
  local liner = ctx.require_active_liner(); if not liner then return end
  if sub == "start" then
    local s = ctx.start_session(liner)
    if subrest ~= "" then s.metadata.name = subrest end
    ctx.save_active(); ctx.info("started session " .. ctx.render.short_id(s.id))
    ctx.rerender()
  elseif sub == "end" then
    ctx.end_session(liner)
    ctx.save_active(); ctx.info("ended session"); ctx.rerender()
  elseif sub == "name" then
    local s = ctx.model.active_session(liner, ctx.state)
    if not s then ctx.error("no active session") return end
    s.metadata.name = subrest
    ctx.save_active(); ctx.info("session name set"); ctx.rerender()
  elseif sub == "label" then
    local s = ctx.model.active_session(liner, ctx.state)
    if not s then ctx.error("no active session") return end
    if subrest == "" then ctx.error("usage: /session label <name>") return end
    local now = ctx.model.toggle_label(s.metadata.labels, subrest)
    ctx.save_active()
    ctx.info((now and "added" or "removed") .. " session label #" .. subrest)
    ctx.rerender()
  else
    ctx.error("usage: /session start|end|name <s>|label <l>")
  end
end

H["label"] = function(ctx, args, rest)
  local name = ctx.model.trim(rest)
  if name == "" then ctx.error("usage: /label <name>") return end
  name = name:gsub("^#", "")
  local now = ctx.model.toggle_label(ctx.state.activeLabels, name)
  ctx.save_state()
  ctx.info((now and "activated" or "deactivated") .. " label #" .. name)
  ctx.rerender()
end

H["labels"] = function(ctx)
  local liner = ctx.get_active_liner()
  local counts, names = ctx.model.label_counts(liner)
  if #names == 0 then ctx.info("no labels yet") return end
  local parts = {}
  for _, n in ipairs(names) do
    parts[#parts + 1] = "#" .. n .. "(" .. counts[n] .. ")"
  end
  ctx.info(table.concat(parts, " "))
end

H["filter"] = function(ctx, args, rest)
  if args[1] == "clear" or ctx.model.trim(rest) == "clear" then
    ctx.clear_filter()
    ctx.info("filter cleared")
    ctx.rerender()
    return
  end
  local filter = {}
  local any = false
  for _, tok in ipairs(args) do
    local k, v = tok:match("^(%w+):(.*)$")
    if k == "label" then filter.label = v:gsub("^#", ""); any = true
    elseif k == "since" then filter.since = M.parse_date(v); any = true
    elseif k == "until" then filter.until_ = M.parse_date(v); any = true
    elseif k == "term" then filter.term = v; any = true
    end
  end
  if not any then
    ctx.error("usage: /filter label:<l> [since:<date>] [until:<date>] | /filter clear")
    return
  end
  ctx.set_filter(filter)
  ctx.info("filter applied")
  ctx.rerender()
end

H["search"] = function(ctx, args, rest)
  local term = ctx.model.trim(rest)
  if term == "" then ctx.error("usage: /search <term>") return end
  local cur = ctx.state.filter or {}
  cur.term = term
  ctx.set_filter(cur)
  ctx.info("searching for '" .. term .. "' (/filter clear to reset)")
  ctx.rerender()
end

H["export"] = function(ctx, args, rest)
  local fmt = "md"
  local path = nil
  if args[1] == "md" or args[1] == "json" then
    fmt = args[1]
    path = ctx.model.trim(strip_first_token(rest))
  else
    path = ctx.model.trim(rest)
  end
  if path == "" then path = nil end
  local ok, msg = ctx.export(fmt, path)
  if ok then ctx.info(msg) else ctx.error(msg) end
end

-- Find a destination by name in a state.destinations-shaped array.
local function find_dest(list, name)
  for i, d in ipairs(list or {}) do
    if d.name == name then return d, i end
  end
  return nil
end

H["send"] = function(ctx, args, rest)
  local name = args[1]
  local mode = args[2]
  if not name or (mode and mode ~= "tui") or args[3] then
    ctx.error("usage: /send <dest> [tui]")
    return
  end
  ctx.send_to(name, mode)
end

local DEST_USAGE = "usage: /dest add <name> <cmd…> | rm <name> | "
  .. "into <name> <liner|-> | kind <name> <claude|codex|opencode|-> | "
  .. "session list|clear <name>"

H["dest"] = function(ctx, args, rest)
  ctx.state.destinations = ctx.state.destinations or {}
  local dests = ctx.state.destinations
  local sub = args[1]
  if not sub then
    ctx.show_dests()
    return
  end
  local name = args[2]
  if sub == "add" then
    -- rest = "add <name> <cmd…>": strip the two leading tokens.
    local cmdstr = ctx.model.trim(strip_first_token(strip_first_token(rest)))
    if not name or cmdstr == "" then
      ctx.error("usage: /dest add <name> <shell command…>")
      return
    end
    local d = find_dest(dests, name)
    local verb = "updated"
    if not d then
      d = { name = name, into = "" }
      dests[#dests + 1] = d
      verb = "added"
    end
    d.cmd = cmdstr
    d.kind = ctx.dest.infer_kind(cmdstr)
    ctx.save_state()
    ctx.info(verb .. " destination " .. name
      .. (d.kind and (" (kind " .. d.kind .. ")") or ""))
    ctx.rerender()
  elseif sub == "rm" then
    local _, i = find_dest(dests, name)
    if not i then ctx.error("no destination '" .. tostring(name) .. "'") return end
    table.remove(dests, i)
    ctx.save_state()
    ctx.info("removed destination " .. name)
    ctx.rerender()
  elseif sub == "into" then
    local d = find_dest(dests, name)
    if not d then ctx.error("no destination '" .. tostring(name) .. "'") return end
    local liner = args[3]
    if not liner then ctx.error("usage: /dest into <name> <liner|->") return end
    d.into = liner == "-" and "" or liner
    ctx.save_state()
    ctx.info(name .. (d.into == "" and " responses discarded"
      or (" responses → " .. d.into)))
    ctx.rerender()
  elseif sub == "kind" then
    local d = find_dest(dests, name)
    if not d then ctx.error("no destination '" .. tostring(name) .. "'") return end
    local k = args[3]
    local valid = k == "-"
    for _, known in ipairs(M.dest_kinds) do
      if k == known then valid = true end
    end
    if not valid then
      ctx.error("usage: /dest kind <name> <claude|codex|opencode|->")
      return
    end
    d.kind = k ~= "-" and k or nil
    ctx.save_state()
    ctx.info(name .. " kind = " .. (d.kind or "plain pipe"))
    ctx.rerender()
  elseif sub == "session" then
    if name == "list" then
      ctx.show_sessions()
    elseif name == "clear" then
      local dname = args[3]
      if not dname then ctx.error("usage: /dest session clear <name>") return end
      local liner = ctx.require_active_liner(); if not liner then return end
      local key = dname .. "|" .. liner.id
      ctx.state.dest_sessions = ctx.state.dest_sessions or {}
      if ctx.state.dest_sessions[key] then
        ctx.state.dest_sessions[key] = nil
        ctx.save_state()
        ctx.info("cleared " .. dname .. " session for this liner")
      else
        ctx.info("no stored " .. dname .. " session for this liner")
      end
    else
      ctx.error("usage: /dest session list | clear <name>")
    end
  else
    ctx.error(DEST_USAGE)
  end
end

H["issues"] = function(ctx, args, rest)
  local sub = args[1]
  if sub == "draft" then
    ctx.issues_draft(args[2])
  elseif sub == "file" then
    if not args[2] then ctx.error("usage: /issues file <id|latest>") return end
    ctx.issues_file(args[2])
  elseif sub == "list" then
    ctx.show_issues_list()
  elseif sub == "repo" then
    ctx.state.issue_repos = ctx.state.issue_repos or {}
    local repos = ctx.state.issue_repos
    local op = args[2]
    if op == "add" then
      local alias, repo, path = args[3], args[4], args[5]
      if not alias or not repo or not repo:match("^[%w%.%-_]+/[%w%.%-_]+$") then
        ctx.error("usage: /issues repo add <alias> <owner/repo> [path]")
        return
      end
      for i = #repos, 1, -1 do
        if repos[i].alias == alias then table.remove(repos, i) end
      end
      repos[#repos + 1] = { alias = alias, repo = repo, path = path }
      ctx.save_state()
      ctx.info("repo " .. alias .. " → " .. repo .. (path and (" (" .. path .. ")") or ""))
    elseif op == "rm" then
      local alias = args[3]
      local removed = false
      for i = #repos, 1, -1 do
        if repos[i].alias == alias then table.remove(repos, i); removed = true end
      end
      if removed then
        ctx.save_state()
        ctx.info("removed repo " .. alias)
      else
        ctx.error("no repo alias '" .. tostring(alias) .. "'")
      end
    elseif op == "list" then
      if #repos == 0 then
        ctx.info("no repos — /issues repo add <alias> <owner/repo> [path]")
        return
      end
      local parts = {}
      for _, r in ipairs(repos) do
        parts[#parts + 1] = r.alias .. "→" .. r.repo
      end
      ctx.info(table.concat(parts, "  "))
    else
      ctx.error("usage: /issues repo add <alias> <owner/repo> [path] | rm <alias> | list")
    end
  elseif sub == "model" then
    local cmdstr = ctx.model.trim(strip_first_token(rest))
    if cmdstr == "" then
      ctx.info("issues model: " .. (ctx.state.issues_model_cmd or "claude -p"))
      return
    end
    ctx.state.issues_model_cmd = cmdstr
    ctx.save_state()
    ctx.info("issues model = " .. cmdstr)
  else
    ctx.error("usage: /issues draft [<repo>] | file <id|latest> | list | repo … | model [<cmd…>]")
  end
end

H["list"] = function(ctx)
  local liners = ctx.list_liners()
  if #liners == 0 then ctx.info("no liners yet — /new to create one") return end
  local parts = {}
  for _, l in ipairs(liners) do
    local nm = l.name ~= "" and l.name or ctx.render.short_id(l.id)
    parts[#parts + 1] = nm .. "(" .. (l.count or 0) .. ")"
  end
  ctx.info(table.concat(parts, "  "))
end

H["set"] = function(ctx, args, rest)
  local name = args[1]
  local value = ctx.model.trim(strip_first_token(rest))
  if not name or value == "" then
    ctx.show_options() -- bare /set (or /set <name>): show the options panel
    return
  end
  local ok, msg = ctx.set_option(name, value)
  if ok then
    ctx.info("olwb." .. name .. " = " .. value)
  else
    ctx.error(msg)
  end
end

H["help"] = function(ctx)
  ctx.open_help()
end
H["?"] = H["help"]

M.handlers = H

-- Dispatch a raw compose line. Returns true if a command handler ran (even on
-- usage error), false if the verb was unknown.
function M.dispatch(ctx, line)
  local cmd, args, rest = M.parse(line)
  if not cmd then return false end
  local h = H[cmd]
  if not h then
    ctx.error("unknown command: /" .. cmd)
    return true
  end
  h(ctx, args, rest)
  return true
end

olwb_cmd = M

return M
