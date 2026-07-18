-- store.lua -- persistence layer. The only olwb module besides olwb.lua that
-- touches micro/Go APIs, so it is exercised in-editor (>olwb selftest) rather
-- than in the standalone lua test suite.
--
-- On-disk layout (datadir defaults to $XDG_DATA_HOME/olwb or ~/.local/share/olwb):
--   <datadir>/liners/<liner-id>.json
--   <datadir>/state.json
--   <datadir>/backups/<liner-id>-<ts>.json

local goos = import("os")            -- Go os (Stat/Rename/MkdirAll/Getenv)
local ioutil = import("io/ioutil")
local filepath = import("filepath")
local util = import("micro/util")
-- NOTE: the standard Lua `os` global (os.date/os.time) is still reachable via
-- micro's package.seeall; we deliberately do NOT shadow it with the Go import.

local M = {}

local DIR_PERM = tonumber("755", 8)
local FILE_PERM = tonumber("644", 8)

-------------------------------------------------------------------------------
-- Directory resolution
-------------------------------------------------------------------------------

-- Resolve the default datadir from XDG, falling back to ~/.local/share/olwb.
function M.default_datadir()
  local xdg = goos.Getenv("XDG_DATA_HOME")
  if xdg ~= nil and xdg ~= "" then
    return filepath.Join(xdg, "olwb")
  end
  local home = goos.Getenv("HOME")
  if home == nil or home == "" then home = "." end
  return filepath.Join(home, ".local", "share", "olwb")
end

-- Configure the datadir and create the directory tree. Call once from init().
function M.setup(datadir)
  if datadir == nil or datadir == "" then
    datadir = M.default_datadir()
  end
  M.dir = datadir
  goos.MkdirAll(M.liners_dir(), DIR_PERM)
  goos.MkdirAll(M.backups_dir(), DIR_PERM)
  goos.MkdirAll(M.issues_dir(), DIR_PERM)
  return M.dir
end

function M.liners_dir()  return filepath.Join(M.dir, "liners") end
function M.backups_dir() return filepath.Join(M.dir, "backups") end
function M.issues_dir()  return filepath.Join(M.dir, "issues") end
function M.state_path()  return filepath.Join(M.dir, "state.json") end
function M.liner_path(id) return filepath.Join(M.liners_dir(), id .. ".json") end

-------------------------------------------------------------------------------
-- Raw file IO
-------------------------------------------------------------------------------

function M.exists(path)
  local _, err = goos.Stat(path)
  return err == nil
end

function M.read_file(path)
  local data, err = ioutil.ReadFile(path)
  if err ~= nil then return nil, err end
  return util.String(data)
end

-- Atomic write: write <path>.tmp then rename over <path>.
function M.write_file_atomic(path, data)
  local tmp = path .. ".tmp"
  local err = ioutil.WriteFile(tmp, data, FILE_PERM)
  if err ~= nil then return false, err end
  err = goos.Rename(tmp, path)
  if err ~= nil then return false, err end
  return true
end

-------------------------------------------------------------------------------
-- Liners
-------------------------------------------------------------------------------

function M.load_liner(id)
  local path = M.liner_path(id)
  local str, err = M.read_file(path)
  if not str then return nil, err end
  local ok, liner = pcall(olwb_json.decode, str)
  if not ok then return nil, liner end
  return liner
end

function M.save_liner(liner)
  local data = olwb_json.encode(liner)
  return M.write_file_atomic(M.liner_path(liner.id), data)
end

function M.remove_liner(id)
  local err = goos.Remove(M.liner_path(id))
  return err == nil
end

-- Copy the current on-disk liner file into backups/ before a destructive op.
function M.backup_liner(id)
  local path = M.liner_path(id)
  if not M.exists(path) then return true end
  local str = M.read_file(path)
  if not str then return false end
  local ts = os.date("!%Y%m%dT%H%M%SZ")
  local dest = filepath.Join(M.backups_dir(), id .. "-" .. ts .. ".json")
  return M.write_file_atomic(dest, str)
end

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

function M.default_state()
  return {
    activeLinerId = nil,
    activeSessionId = nil,
    activeLabels = {},
    filter = nil,
    liners = {}, -- registry: { [id] = { name=, count=, updated= } }
  }
end

function M.load_state()
  local path = M.state_path()
  local str = M.read_file(path)
  if not str then return M.default_state() end
  local ok, state = pcall(olwb_json.decode, str)
  if not ok or type(state) ~= "table" then return M.default_state() end
  -- Backfill any missing fields so callers can rely on shape.
  if type(state.activeLabels) ~= "table" then state.activeLabels = {} end
  if type(state.liners) ~= "table" then state.liners = {} end
  return state
end

function M.save_state(state)
  return M.write_file_atomic(M.state_path(), olwb_json.encode(state))
end

-------------------------------------------------------------------------------
-- Directory scan (best-effort; core paths use the state registry instead)
-------------------------------------------------------------------------------

-- Glob as a plain Lua array (gopher-luar exposes the Go slice as a callable
-- iterator; this flattens it for pure-Lua callers).
function M.glob(pattern)
  local out = {}
  local matches, err = filepath.Glob(pattern)
  if err ~= nil or matches == nil then return out end
  for _, path in matches() do out[#out + 1] = path end
  return out
end

-- Returns an array of liner ids discovered on disk. Used only to rebuild a
-- lost registry.
function M.list_liner_ids()
  local ids = {}
  for _, path in ipairs(M.glob(filepath.Join(M.liners_dir(), "*.json"))) do
    local base = filepath.Base(path)
    local id = base:gsub("%.json$", "")
    ids[#ids + 1] = id
  end
  return ids
end

olwb_store = M

return M
