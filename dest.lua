-- dest.lua -- pure destination adapters for /send.
--
-- No micro/Go imports. One adapter per CLI "kind" (claude / codex / opencode),
-- three responsibilities each:
--   wrap(cmd, session_id)   -> the shell command actually run headlessly
--                              (JSON output flag + resume mechanism appended)
--   parse(stdout)           -> { session_id, text }, err
--   tui(session_id, path)   -> the interactive command for /send <dest> tui
--
-- kind = nil destinations never reach this module: they are plain stdin pipes.
-- Only olwb-generated values (session ids, datadir paths) are ever appended to
-- command strings — user text travels via stdin/payload files exclusively.
--
-- Flag survey (verified on this machine at implementation time):
--   claude   -p …            --output-format json   --resume <id>   claude --resume <id>
--   codex    exec …          --json                 exec resume <id>   codex resume <id>
--   opencode run …           --format json          -s <id>   opencode run -i [-s <id>]
--
-- The NDJSON event shapes parsed below are tolerant by design; pin the real
-- shapes into tests/fixtures/ after one cheap real run per CLI.

local M = {}

M.kinds = { "claude", "codex", "opencode" }

-- POSIX single-quote escaping for values appended to command strings.
function M.shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- A session id is only ever interpolated after this gate: strictly
-- alphanumeric plus -, _ and . (ULIDs, UUIDs, and friends all pass).
local function safe_id(id)
  return type(id) == "string" and id ~= "" and id:match("^[%w%-_%.]+$") ~= nil
end

-- Infer the adapter kind from a destination command's leading token.
function M.infer_kind(cmd)
  local head = tostring(cmd or ""):match("^%s*(%S+)")
  if not head then return nil end
  head = head:gsub(".*/", "") -- tolerate absolute paths
  for _, k in ipairs(M.kinds) do
    if head == k then return k end
  end
  return nil
end

-------------------------------------------------------------------------------
-- NDJSON helpers (codex / opencode emit one JSON event per line)
-------------------------------------------------------------------------------

-- pcall-decode every line that looks like JSON; the vendored json.lua errors()
-- on bad input and CLIs interleave plain-log noise lines.
local function ndjson_events(stdout)
  local events = {}
  for line in (tostring(stdout or "") .. "\n"):gmatch("(.-)\n") do
    local t = line:match("^%s*(.-)%s*$")
    if t:sub(1, 1) == "{" then
      local ok, ev = pcall(olwb_json.decode, t)
      if ok and type(ev) == "table" then events[#events + 1] = ev end
    end
  end
  return events
end

-------------------------------------------------------------------------------
-- Adapters
-------------------------------------------------------------------------------

local A = {}

A.claude = {
  -- claude -p "<prompt>"; payload arrives on stdin.
  wrap = function(cmd, sid)
    local out = cmd .. " --output-format json"
    if sid then
      if not safe_id(sid) then return nil, "unusable session id" end
      out = out .. " --resume " .. sid
    end
    return out
  end,
  -- Single JSON result object: { "type":"result", "result": …, "session_id": … }.
  parse = function(stdout)
    local t = tostring(stdout or ""):match("^%s*(.-)%s*$")
    local ok, obj = pcall(olwb_json.decode, t)
    if not ok or type(obj) ~= "table" then
      return nil, "claude: response is not a JSON object"
    end
    local text = obj.result
    if type(text) ~= "string" then
      return nil, "claude: no result field in response"
    end
    return { session_id = obj.session_id, text = text }
  end,
  tui = function(sid, payload_path)
    if sid and safe_id(sid) then return "claude --resume " .. sid end
    return "claude " .. M.shell_quote("Process the notes in " .. payload_path)
  end,
}

A.codex = {
  -- Documented constraint: codex-kind destination cmds must start with
  -- "codex exec" — resume is a subcommand, so the prefix is rewritten.
  wrap = function(cmd, sid)
    local out = cmd
    if sid then
      if not safe_id(sid) then return nil, "unusable session id" end
      local rewritten, n = out:gsub("^(%s*)codex%s+exec", "%1codex exec resume " .. sid, 1)
      if n == 0 then
        return nil, "codex destinations must start with 'codex exec'"
      end
      out = rewritten
    end
    return out .. " --json"
  end,
  -- NDJSON: {"type":"thread.started","thread_id":…} then
  -- {"type":"item.completed","item":{"type":"agent_message","text":…}}.
  parse = function(stdout)
    local sid, parts = nil, {}
    for _, ev in ipairs(ndjson_events(stdout)) do
      if type(ev.thread_id) == "string" then sid = ev.thread_id end
      if type(ev.session_id) == "string" then sid = ev.session_id end
      local item = ev.item
      if type(item) == "table" and item.type == "agent_message"
         and type(item.text) == "string" then
        parts[#parts + 1] = item.text
      end
    end
    if #parts == 0 then return nil, "codex: no agent message in output" end
    return { session_id = sid, text = table.concat(parts, "\n") }
  end,
  tui = function(sid, payload_path)
    if sid and safe_id(sid) then return "codex resume " .. sid end
    return "codex " .. M.shell_quote("Process the notes in " .. payload_path)
  end,
}

A.opencode = {
  -- opencode run "<prompt>"; payload arrives on stdin.
  wrap = function(cmd, sid)
    local out = cmd .. " --format json"
    if sid then
      if not safe_id(sid) then return nil, "unusable session id" end
      out = out .. " -s " .. sid
    end
    return out
  end,
  -- Raw JSON events (NDJSON). Session ids appear as sessionID (camelCase);
  -- assistant text as parts/part objects of type "text".
  parse = function(stdout)
    local sid, parts = nil, {}
    local function absorb_part(p)
      if type(p) == "table" and p.type == "text" and type(p.text) == "string" then
        parts[#parts + 1] = p.text
      end
    end
    for _, ev in ipairs(ndjson_events(stdout)) do
      sid = (type(ev.sessionID) == "string" and ev.sessionID)
        or (type(ev.session_id) == "string" and ev.session_id)
        or (type(ev.info) == "table" and type(ev.info.sessionID) == "string"
            and ev.info.sessionID)
        or sid
      absorb_part(ev.part)
      if type(ev.parts) == "table" then
        for _, p in ipairs(ev.parts) do absorb_part(p) end
      end
    end
    if #parts == 0 then return nil, "opencode: no text parts in output" end
    return { session_id = sid, text = table.concat(parts, "\n") }
  end,
  -- opencode's interactive resume is `opencode run -i` (direct interactive
  -- split-footer mode) with the same -s session flag.
  tui = function(sid, payload_path)
    if sid and safe_id(sid) then return "opencode run -i -s " .. sid end
    return "opencode run -i "
      .. M.shell_quote("Process the notes in " .. payload_path)
  end,
}

M.adapters = A

function M.wrap(kind, cmd, sid)
  local a = A[kind]
  if not a then return nil, "no adapter for kind '" .. tostring(kind) .. "'" end
  return a.wrap(cmd, sid)
end

function M.parse(kind, stdout)
  local a = A[kind]
  if not a then return nil, "no adapter for kind '" .. tostring(kind) .. "'" end
  return a.parse(stdout)
end

function M.tui(kind, sid, payload_path)
  local a = A[kind]
  if not a then return nil, "no adapter for kind '" .. tostring(kind) .. "'" end
  return a.tui(sid, payload_path)
end

olwb_dest = M

return M
