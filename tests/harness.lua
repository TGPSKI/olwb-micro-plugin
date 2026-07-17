-- harness.lua -- headless integration harness. Loads every plugin file into a
-- single shared environment (replicating micro's module("olwb", package.seeall)
-- namespace) with a mocked import() that maps Go packages onto real Lua IO, so
-- store.lua actually reads/writes files. Then drives init() and a capture flow.
--
--   lua tests/harness.lua        (or: make harness)

local here = (arg and arg[0] or "tests/harness.lua"):gsub("[^/]*$", "")
local root = here .. "../"

local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1
  else failed = failed + 1; io.write("  FAIL  " .. name .. "\n") end
end

-- Temp datadir for this run.
local datadir = os.tmpname()
os.remove(datadir)
os.execute("mkdir -p '" .. datadir .. "'")

-------------------------------------------------------------------------------
-- Mocked micro/Go API surface
-------------------------------------------------------------------------------

local function sh_quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

local mock = {}

mock["os"] = {
  Getenv = function(k)
    if k == "XDG_DATA_HOME" then return datadir end
    return os.getenv(k) or ""
  end,
  MkdirAll = function(path, _) os.execute("mkdir -p " .. sh_quote(path)); return nil end,
  Stat = function(path)
    local f = io.open(path, "r")
    if f then f:close(); return {}, nil end
    return nil, "not found"
  end,
  Rename = function(a, b) return os.rename(a, b) and nil or "rename failed" end,
  Remove = function(path) os.remove(path); return nil end,
  Getpid = function() return 4242 end,
}

mock["io/ioutil"] = {
  ReadFile = function(path)
    local f = io.open(path, "rb")
    if not f then return nil, "no such file" end
    local d = f:read("*a"); f:close(); return d, nil
  end,
  WriteFile = function(path, data, _)
    local f = io.open(path, "wb")
    if not f then return "cannot open" end
    f:write(data); f:close(); return nil
  end,
}

mock["filepath"] = {
  Join = function(...)
    local parts = { ... }
    return table.concat(parts, "/")
  end,
  Base = function(p) return (p:gsub(".*/", "")) end,
  Glob = function(pattern)
    local out = {}
    local pipe = io.popen("ls -1 " .. pattern .. " 2>/dev/null")
    if pipe then
      for line in pipe:lines() do out[#out + 1] = line end
      pipe:close()
    end
    -- emulate gopher-luar slice: callable iterator + # length
    return setmetatable(out, {
      __call = function(self)
        local i = 0
        return function()
          i = i + 1
          if out[i] then return i, out[i] end
        end
      end,
    }), nil
  end,
}

mock["micro/util"] = {
  String = function(x) return tostring(x) end,
  CharacterCountInString = function(s) return #s end,
  RuneStr = function(r) return r end,
}

local info_log, err_log = {}, {}
mock["micro"] = {
  InfoBar = function()
    return { Message = function(_, m) info_log[#info_log + 1] = m end,
             Error = function(_, m) err_log[#err_log + 1] = m end }
  end,
  Log = function() end,
  SetStatusInfoFn = function() end,
  CurPane = function() return mock._curpane end,
  TermMessage = function() end,
}

local opts = {}
mock["micro/config"] = {
  RegisterCommonOption = function(pl, name, def) opts[pl .. "." .. name] = def end,
  GetGlobalOption = function(name) return opts[name] end,
  SetGlobalOption = function() return nil end,
  MakeCommand = function() end,
  TryBindKey = function() return true, nil end,
  AddRuntimeFileFromMemory = function() end,
  SetStatusInfoFn = function() end,
  NoComplete = nil,
  RTSyntax = "syntax", RTColorscheme = "colorscheme", RTHelp = "help",
}

-- Mock buffer with just enough behaviour for feed/compose manipulation.
local function new_mock_buffer(text, path)
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  if #lines == 0 then lines = { "" } end
  local b
  b = {
    Path = path,
    Type = { Scratch = false, Readonly = false, Kind = 0 },
    SetOption = function(_, k, v) end,
    LinesNum = function(_) return #lines end,
    Line = function(_, i) return lines[i + 1] or "" end,
    Modified = function(_) return false end,
    Remove = function(_, a, b2)
      if b.Type.Readonly then return end
      lines = { "" }
    end,
    Insert = function(_, loc, txt)
      if b.Type.Readonly then return end
      lines = {}
      for line in (txt .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
      if #lines == 0 then lines = { "" } end
    end,
    _lines = function() return lines end,
    _settext = function(t)
      lines = {}
      for line in (t .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
    end,
  }
  return b
end

local function new_mock_pane(buf)
  local p
  p = {
    Buf = buf,
    Cursor = { GotoLoc = function() end, ResetSelection = function() end },
    OpenBuffer = function(self, b) self.Buf = b end,
    HSplitBuf = function(self, b) return new_mock_pane(b) end,
    VSplitBuf = function(self, b) return new_mock_pane(b) end,
    ResizePane = function() end,
    GetView = function() return { X = 0, Y = 0, Width = 80, Height = 22 } end,
    Relocate = function() end,
    SetActive = function() end,
  }
  return p
end

mock["micro/buffer"] = {
  NewBuffer = function(text, path) return new_mock_buffer(text, path) end,
  Loc = function(x, y) return { X = x, Y = y } end,
  BTScratch = 3, BTDefault = 0,
}

mock["time"] = {
  Now = function()
    return { UnixMilli = function() return math.floor(os.clock() * 1000) + os.time() * 1000 end }
  end,
}

-- The mocked global import().
local function mock_import(pkg)
  local m = mock[pkg]
  if m == nil then error("harness: unmocked import(\"" .. pkg .. "\")") end
  return m
end

-------------------------------------------------------------------------------
-- Load all plugin files into a shared environment (like micro's module()).
-------------------------------------------------------------------------------

local ENV = setmetatable({}, { __index = _G })
ENV.import = mock_import

local files = { "json", "assets", "model", "render", "cmd", "store", "migrate", "olwb" }
for _, name in ipairs(files) do
  local path = root .. name .. ".lua"
  local fh = assert(io.open(path, "r"))
  local src = fh:read("*a"); fh:close()
  local chunk, e
  if setfenv then
    chunk = assert(loadstring(src, name))
    setfenv(chunk, ENV)
  else
    chunk, e = load(src, name, "t", ENV)
    assert(chunk, e)
  end
  local okc, err = pcall(chunk)
  if not okc then
    io.write("LOAD ERROR in " .. name .. ".lua: " .. tostring(err) .. "\n")
    os.exit(1)
  end
end

-------------------------------------------------------------------------------
-- Drive it
-------------------------------------------------------------------------------

-- Set up the current pane as an empty, unmodified buffer (like startup).
mock._curpane = new_mock_pane(new_mock_buffer("", ""))

local okinit, errinit = pcall(ENV.init)
ok(okinit, "init() runs without error")
if not okinit then io.write("  init error: " .. tostring(errinit) .. "\n") end

-- The datadir tree should now exist.
local function exists(p) local f = io.open(p, "r"); if f then f:close(); return true end return false end
ok(exists(datadir .. "/olwb/liners"), "datadir/liners created by setup()")

-- Open the UI via the public entry point (>olwb with no args). open_olwb is a
-- file-local reached through this closure, exactly as micro invokes it.
local okopen, erropen = xpcall(function() ENV.olwb_command(nil, {}) end, debug.traceback)
ok(okopen, "open UI via olwb_command runs without error")
if not okopen then io.write("  open error: " .. tostring(erropen) .. "\n") end

-- Build a compose buffer/pane and route Enter through preInsertNewline.
local compose = new_mock_buffer("first captured line", "olwb://compose")
local cpane = new_mock_pane(compose)
-- olwb.lua holds its own feed_pane ref from open_olwb; reuse the real callback.
local okcb, errcb = pcall(ENV.preInsertNewline, cpane)
ok(okcb == true or okcb, "preInsertNewline runs")
if not okcb then io.write("  cb error: " .. tostring(errcb) .. "\n") end

-- A liner file should have been written with our content.
local found_content = false
local pipe = io.popen("cat " .. datadir .. "/olwb/liners/*.json 2>/dev/null")
local blob = pipe and pipe:read("*a") or ""
if pipe then pipe:close() end
found_content = blob:find("first captured line", 1, true) ~= nil
ok(found_content, "captured message persisted to a liner file")

-- state.json should record the active liner.
ok(exists(datadir .. "/olwb/state.json"), "state.json written")

-- Now a slash command through the same path: toggle a label.
local c2 = new_mock_buffer("/label debug", "olwb://compose")
local okc2 = pcall(ENV.preInsertNewline, new_mock_pane(c2))
ok(okc2, "slash command via preInsertNewline runs")

-- selftest should pass internally (writes a scratch buffer; just ensure no error)
local oksel = pcall(ENV.olwb_command, nil, {})   -- bare >olwb opens UI
ok(oksel, ">olwb (bare) runs")

io.write(string.format("\nharness: %d passed, %d failed\n", passed, failed))
io.write("datadir: " .. datadir .. "/olwb\n")
os.execute("ls -R " .. datadir .. "/olwb 2>/dev/null | head -20")
os.exit(failed == 0 and 0 or 1)
