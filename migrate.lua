-- migrate.lua -- pure reconstruction of nested liner files from the old flat
-- Electron format (messages.json + sessions.json + liners.json joined by
-- reference arrays). No micro/Go imports; file IO lives in olwb.lua/store.lua.
-- This implements the join algorithm STORAGE_REFACTORING.md specified for its
-- (never-shipped) Phase 3, plus orphan recovery.

local M = {}

-- Read a reference-id list from an object under any of several field names,
-- tolerating either an array of ids or an array of {id=...} objects.
local function ref_ids(obj, ...)
  for _, field in ipairs({ ... }) do
    local v = obj[field]
    if type(v) == "table" then
      local ids = {}
      for _, item in ipairs(v) do
        if type(item) == "table" then
          if item.id then ids[#ids + 1] = item.id end
        else
          ids[#ids + 1] = item
        end
      end
      if #ids > 0 then return ids end
    end
  end
  return {}
end

local function index_by_id(list)
  local idx = {}
  for _, item in ipairs(list or {}) do
    if item.id then idx[item.id] = item end
  end
  return idx
end

local function norm_message(m)
  return {
    id = m.id,
    content = m.content or "",
    timestamp = m.timestamp or 0,
    metadata = { labels = (m.metadata and m.metadata.labels) or m.labels or {} },
  }
end

local function norm_session(s)
  return {
    id = s.id,
    startTime = s.startTime or 0,
    endTime = s.endTime or 0,
    metadata = {
      name = (s.metadata and s.metadata.name) or s.name or "",
      labels = (s.metadata and s.metadata.labels) or s.labels or {},
    },
    messages = {},
  }
end

local function norm_liner(l)
  return {
    id = l.id,
    metadata = {
      name = (l.metadata and l.metadata.name) or l.name or "",
      description = (l.metadata and l.metadata.description) or l.description or "",
      labels = (l.metadata and l.metadata.labels) or l.labels or {},
    },
    sessions = {},
    directMessages = {},
  }
end

-- Reconstruct nested liners from flat tables.
--   flat = { liners = [...], sessions = [...], messages = [...] }
--   opts = { now = ms, new_id = function()->id }  (for the recovered liner)
-- Returns { liners = { nested... }, stats = { liners, sessions, messages, orphans } }
function M.reconstruct(flat, opts)
  opts = opts or {}
  local now = opts.now or 0
  local new_id = opts.new_id or function() return "recovered" end

  local msg_idx = index_by_id(flat.messages)
  local sess_idx = index_by_id(flat.sessions)

  local consumed = {}   -- message ids placed into some liner
  local out_liners = {}
  local stats = { liners = 0, sessions = 0, messages = 0, orphans = 0 }

  for _, rawliner in ipairs(flat.liners or {}) do
    local liner = norm_liner(rawliner)
    stats.liners = stats.liners + 1

    -- Sessions referenced by this liner (or inline).
    for _, sid in ipairs(ref_ids(rawliner, "sessionReferences", "sessions", "sessionIds")) do
      local rawsess = sess_idx[sid]
      if rawsess then
        local session = norm_session(rawsess)
        stats.sessions = stats.sessions + 1
        for _, mid in ipairs(ref_ids(rawsess, "messageReferences", "messages", "messageIds")) do
          local rawmsg = msg_idx[mid]
          if rawmsg and not consumed[mid] then
            session.messages[#session.messages + 1] = norm_message(rawmsg)
            consumed[mid] = true
            stats.messages = stats.messages + 1
          end
        end
        liner.sessions[#liner.sessions + 1] = session
      end
    end

    -- Messages attached directly to the liner (no session) -> directMessages.
    for _, mid in ipairs(ref_ids(rawliner, "messageReferences", "directMessages", "messageIds")) do
      local rawmsg = msg_idx[mid]
      if rawmsg and not consumed[mid] then
        liner.directMessages[#liner.directMessages + 1] = norm_message(rawmsg)
        consumed[mid] = true
        stats.messages = stats.messages + 1
      end
    end

    out_liners[#out_liners + 1] = liner
  end

  -- Orphan messages: referenced by nothing. Preserve original timestamps in a
  -- synthesized "recovered" liner with a single catch-all session.
  local orphans = {}
  for _, m in ipairs(flat.messages or {}) do
    if m.id and not consumed[m.id] then
      orphans[#orphans + 1] = norm_message(m)
    end
  end
  if #orphans > 0 then
    table.sort(orphans, function(a, b) return a.timestamp < b.timestamp end)
    local recovered = norm_liner({
      id = new_id(),
      metadata = { name = "recovered", description = "orphaned messages recovered during migration", labels = {} },
    })
    local session = norm_session({ id = new_id(), startTime = now, endTime = now })
    session.metadata.name = "recovered"
    for _, m in ipairs(orphans) do
      session.messages[#session.messages + 1] = m
      stats.messages = stats.messages + 1
    end
    recovered.sessions[1] = session
    out_liners[#out_liners + 1] = recovered
    stats.orphans = #orphans
    stats.liners = stats.liners + 1
    stats.sessions = stats.sessions + 1
  end

  return { liners = out_liners, stats = stats }
end

olwb_migrate = M

return M
