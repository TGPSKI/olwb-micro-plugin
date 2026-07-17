-- render.lua -- pure: model -> feed buffer text.
--
-- No micro/Go imports. Timestamp formatting is injected via opts.fmt_time so
-- the module is deterministic under test (inject a UTC formatter) while the
-- editor injects a local-time one honouring the olwb.timefmt option.

local M = {}

local RULE_CHAR = "─"
local DEFAULT_WIDTH = 48

-- Short, human-scannable id: the random suffix is the distinctive part
-- (the time prefix is near-identical for entries created close together).
function M.short_id(id)
  if not id or id == "" then return "--------" end
  if #id <= 8 then return id end
  return id:sub(-8)
end

local function fill(char, n)
  if n < 0 then n = 0 end
  return string.rep(char, n)
end

local function labels_str(labels)
  if not labels or #labels == 0 then return "" end
  local parts = {}
  for _, l in ipairs(labels) do parts[#parts + 1] = "#" .. l end
  return table.concat(parts, " ")
end

-- Render one flattened entry into an array of lines (rule, content, meta).
function M.entry_lines(entry, opts)
  local width = opts.rule_width or DEFAULT_WIDTH
  local fmt_time = opts.fmt_time
  local lines = {}
  lines[#lines + 1] = fill(RULE_CHAR, width)
  -- Content may span multiple physical lines; emit each verbatim.
  local content = entry.message.content or ""
  for line in (content .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  local meta = fmt_time(entry.message.timestamp)
  local ls = labels_str(entry.labels)
  if ls ~= "" then
    meta = meta .. "  ·  " .. ls
  end
  if entry.direct then
    meta = meta .. "  ·  [direct]"
  end
  lines[#lines + 1] = meta
  return lines
end

-- Full feed text for a liner: newest first, so a freshly captured line enters
-- at the top (directly under the compose line) and pushes older entries down.
-- Liner/session identity is shown on the statusline, not here. opts:
--   fmt_time    : function(ms) -> string   (required)
--   rule_width  : int (default 48)
--   filter      : filter table or nil
--   include_direct : bool
function M.render_feed(liner, state, opts)
  opts = opts or {}
  assert(opts.fmt_time, "render_feed requires opts.fmt_time")
  local out = {}

  local entries = olwb_model.flatten_desc(liner, {
    include_direct = opts.include_direct,
    filter = opts.filter,
  })

  if #entries == 0 then
    out[#out + 1] = "(no messages yet — type above and press Enter)"
  else
    for _, entry in ipairs(entries) do
      for _, l in ipairs(M.entry_lines(entry, opts)) do
        out[#out + 1] = l
      end
    end
  end

  return table.concat(out, "\n")
end

-- Plain-text export (same as feed but without the live header chrome; used by
-- /export md). Markdown-ish: content as a bullet with an italic timestamp line.
function M.render_export_md(liner, opts)
  opts = opts or {}
  assert(opts.fmt_time, "render_export_md requires opts.fmt_time")
  local out = {}
  local name = (liner and liner.metadata and liner.metadata.name) or "olwb"
  out[#out + 1] = "# " .. name
  if liner and liner.metadata and liner.metadata.description ~= ""
     and liner.metadata.description ~= nil then
    out[#out + 1] = ""
    out[#out + 1] = liner.metadata.description
  end
  out[#out + 1] = ""

  local entries = olwb_model.flatten_desc(liner, {
    include_direct = opts.include_direct,
    filter = opts.filter,
  })
  for _, entry in ipairs(entries) do
    local ls = labels_str(entry.labels)
    out[#out + 1] = "- " .. (entry.message.content or "")
    local meta = "  _" .. opts.fmt_time(entry.message.timestamp) .. "_"
    if ls ~= "" then meta = meta .. " " .. ls end
    out[#out + 1] = meta
  end
  out[#out + 1] = ""
  return table.concat(out, "\n")
end

olwb_render = M

return M
