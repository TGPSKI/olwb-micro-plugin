-- model.lua -- pure domain model for olwb.
--
-- No micro/Go imports. Loadable both inside micro (wrapped in
-- module("olwb", package.seeall), so `olwb_model` lands in the shared plugin
-- table) and standalone under plain lua for testing (`olwb_model` becomes a
-- real global; the trailing `return` also supports require/dofile).
--
-- Everything time- and randomness-dependent takes those as arguments so the
-- module stays deterministic and testable.

local M = {}

local unpack = table.unpack or unpack

-- Crockford base32 (excludes I, L, O, U); yields sortable, greppable ids.
local B32 = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

local TIME_LEN = 10 -- 48-bit ms timestamp -> 10 base32 chars (ULID-compatible)
local RAND_LEN = 10

-- Encode a non-negative integer to a fixed-width base32 string (big-endian).
local function encode_base32(value, width)
  local chars = {}
  local v = math.floor(value)
  for i = width, 1, -1 do
    local rem = v % 32
    chars[i] = B32:sub(rem + 1, rem + 1)
    v = math.floor(v / 32)
  end
  return table.concat(chars)
end

-- ULID-lite: <epoch-ms base32, 10><random base32, 10>. Lexicographically
-- sortable by creation time. `rand` is a function returning a float in [0, 1);
-- defaults to math.random for convenience but should be injected in tests.
function M.new_id(now_ms, rand)
  rand = rand or math.random
  local time_part = encode_base32(now_ms or 0, TIME_LEN)
  local rand_chars = {}
  for i = 1, RAND_LEN do
    local x = math.floor(rand() * 32)
    if x > 31 then x = 31 end
    if x < 0 then x = 0 end
    rand_chars[i] = B32:sub(x + 1, x + 1)
  end
  return time_part .. table.concat(rand_chars)
end

M.encode_base32 = encode_base32

-------------------------------------------------------------------------------
-- Constructors (match STORAGE_REFACTORING.md schema exactly)
-------------------------------------------------------------------------------

function M.new_liner(id, name, description, labels)
  return {
    id = id,
    metadata = {
      name = name or "",
      description = description or "",
      labels = labels or {},
    },
    sessions = {},
    directMessages = {},
  }
end

function M.new_session(id, now_ms, name, labels)
  return {
    id = id,
    startTime = now_ms or 0,
    endTime = 0,
    metadata = {
      name = name or "",
      labels = labels or {},
    },
    messages = {},
  }
end

function M.new_message(id, content, now_ms, labels)
  return {
    id = id,
    content = content or "",
    timestamp = now_ms or 0,
    metadata = {
      labels = labels or {},
    },
  }
end

-------------------------------------------------------------------------------
-- Text helpers
-------------------------------------------------------------------------------

-- Port of removeTrailingNewlines: strip surrounding whitespace (incl newlines).
function M.trim(s)
  if s == nil then return "" end
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.is_blank(s)
  return M.trim(s or "") == ""
end

-------------------------------------------------------------------------------
-- Labels
-------------------------------------------------------------------------------

function M.has_label(list, name)
  if not list then return false end
  for _, v in ipairs(list) do
    if v == name then return true end
  end
  return false
end

-- Append if absent. Mutates and returns the list.
function M.add_label(list, name)
  if not M.has_label(list, name) then
    list[#list + 1] = name
  end
  return list
end

function M.remove_label(list, name)
  for i = #list, 1, -1 do
    if list[i] == name then table.remove(list, i) end
  end
  return list
end

-- Toggle presence; returns true if the label is now present, false if removed.
function M.toggle_label(list, name)
  if M.has_label(list, name) then
    M.remove_label(list, name)
    return false
  else
    M.add_label(list, name)
    return true
  end
end

-- Resolve inherited labels as liner ∪ session ∪ message, order-preserving and
-- deduplicated. Storage stays minimal at each level; union happens here.
function M.resolve_labels(liner, session, message)
  local out, seen = {}, {}
  local function absorb(list)
    if not list then return end
    for _, v in ipairs(list) do
      if not seen[v] then
        seen[v] = true
        out[#out + 1] = v
      end
    end
  end
  if liner and liner.metadata then absorb(liner.metadata.labels) end
  if session and session.metadata then absorb(session.metadata.labels) end
  if message and message.metadata then absorb(message.metadata.labels) end
  return out
end

-------------------------------------------------------------------------------
-- Lookups
-------------------------------------------------------------------------------

function M.find_session(liner, session_id)
  if not liner or not session_id then return nil end
  for _, s in ipairs(liner.sessions) do
    if s.id == session_id then return s end
  end
  return nil
end

-- The currently-active session for a liner given the state's activeSessionId,
-- but only if it is still open (endTime == 0). Mirrors getOrCreateActive intent.
function M.active_session(liner, state)
  if not liner or not state or not state.activeSessionId then return nil end
  local s = M.find_session(liner, state.activeSessionId)
  if s and (s.endTime == nil or s.endTime == 0) then
    return s
  end
  return nil
end

-------------------------------------------------------------------------------
-- Feed flattening (descending by timestamp, stable on ties)
-------------------------------------------------------------------------------

local function content_matches(content, term)
  if not term or term == "" then return true end
  return string.find(content:lower(), term:lower(), 1, true) ~= nil
end

-- Does a flattened entry pass the filter? filter fields (all optional):
--   label  : string  -- resolved labels must include it
--   since  : ms      -- timestamp >= since
--   until_ : ms      -- timestamp <= until_
--   term   : string  -- case-insensitive substring of content
function M.passes_filter(entry, filter)
  if not filter then return true end
  if filter.label and not M.has_label(entry.labels, filter.label) then
    return false
  end
  if filter.since and entry.message.timestamp < filter.since then
    return false
  end
  if filter.until_ and entry.message.timestamp > filter.until_ then
    return false
  end
  if filter.term and not content_matches(entry.message.content, filter.term) then
    return false
  end
  return true
end

-- Flatten all messages across a liner's sessions (and optionally its
-- directMessages) into a list sorted strictly descending by timestamp. Ties
-- keep original append order (stable). Each entry: { message, session, labels }.
-- opts: { include_direct = bool, filter = {...} }
function M.flatten_desc(liner, opts)
  opts = opts or {}
  local entries = {}
  local seq = 0
  if liner then
    for _, session in ipairs(liner.sessions) do
      for _, message in ipairs(session.messages) do
        seq = seq + 1
        entries[#entries + 1] = {
          message = message,
          session = session,
          labels = M.resolve_labels(liner, session, message),
          _seq = seq,
        }
      end
    end
    if opts.include_direct and liner.directMessages then
      for _, message in ipairs(liner.directMessages) do
        seq = seq + 1
        entries[#entries + 1] = {
          message = message,
          session = nil,
          labels = M.resolve_labels(liner, nil, message),
          _seq = seq,
          direct = true,
        }
      end
    end
  end

  if opts.filter then
    local kept = {}
    for _, e in ipairs(entries) do
      if M.passes_filter(e, opts.filter) then kept[#kept + 1] = e end
    end
    entries = kept
  end

  table.sort(entries, function(a, b)
    if a.message.timestamp ~= b.message.timestamp then
      return a.message.timestamp > b.message.timestamp
    end
    -- Equal timestamps: preserve original append order (stable descending).
    return a._seq < b._seq
  end)

  return entries
end

-- Count of messages carrying each label (post-resolution), across sessions and
-- direct messages. Returns { [label] = count } plus a sorted name list.
function M.label_counts(liner)
  local counts = {}
  local entries = M.flatten_desc(liner, { include_direct = true })
  for _, e in ipairs(entries) do
    for _, lbl in ipairs(e.labels) do
      counts[lbl] = (counts[lbl] or 0) + 1
    end
  end
  local names = {}
  for name in pairs(counts) do names[#names + 1] = name end
  table.sort(names)
  return counts, names
end

-- Shallow-ish copy of a plain array of strings (used for snapshotting the
-- active-label set onto a new message so later mutation doesn't leak in).
function M.copy_list(list)
  local out = {}
  if list then
    for i, v in ipairs(list) do out[i] = v end
  end
  return out
end

-- Expose under micro's shared "olwb" plugin namespace (and as a global when
-- loaded standalone for tests). See json.lua header for the mechanism.
olwb_model = M

return M
