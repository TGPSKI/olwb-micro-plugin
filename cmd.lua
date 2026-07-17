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
  "list", "set", "help",
}

-- Subcommand vocabularies (for contextual completion).
M.subverbs = {
  liner = { "start", "end", "name", "desc", "label" },
  session = { "start", "end", "name", "label" },
  filter = { "label:", "since:", "until:", "term:", "clear" },
  export = { "md", "json" },
  set = { "autostart", "composesize", "datadir", "rulewidth", "theme", "timefmt" },
}

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

-- Candidates for the token currently being typed. extra.liners supplies liner
-- names for /open. Returns candidates[], the partial token, and the line
-- prefix to keep in front of a completed token.
function M.candidates(line, extra)
  if not M.is_command(line) then return {}, "", "" end
  local body = line:gsub("^%s*/", "")
  local trailing = body:match("%s$") ~= nil
  local toks = split_ws(body)
  local part, pool, kept
  if #toks == 0 or (#toks == 1 and not trailing) then
    part = toks[1] or ""
    pool = M.verbs
    kept = "/"
  elseif #toks == 1 or (#toks == 2 and not trailing) then
    local verb = toks[1]
    part = trailing and "" or (toks[2] or "")
    if M.subverbs[verb] then
      pool = M.subverbs[verb]
    elseif verb == "open" and extra and extra.liners then
      pool = extra.liners
    else
      return {}, "", ""
    end
    kept = "/" .. verb .. " "
  else
    return {}, "", ""
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
