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
local mock_env = {}

mock["os"] = {
  O_CREATE = 1, O_EXCL = 2, O_WRONLY = 4,
  Getenv = function(k)
    if k == "XDG_DATA_HOME" then return datadir end
    if mock_env[k] ~= nil then return mock_env[k] end
    return os.getenv(k) or ""
  end,
  MkdirAll = function(path, _) os.execute("mkdir -p " .. sh_quote(path)); return nil end,
  Stat = function(path)
    local f = io.open(path, "r")
    if f then f:close(); return {}, nil end
    return nil, "not found"
  end,
  Rename = function(a, b)
    local renamed, err = os.rename(a, b)
    if renamed then return nil end
    return err or "rename failed"
  end,
  Remove = function(path) os.remove(path); return nil end,
  OpenFile = function(path)
    local existing = io.open(path, "r")
    if existing then existing:close(); return nil, "exists" end
    local f = io.open(path, "w")
    if not f then return nil, "cannot open" end
    return { Close = function() f:close(); return nil end }, nil
  end,
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
local bind_log = {}
mock["micro/config"] = {
  RegisterCommonOption = function(pl, name, def) opts[pl .. "." .. name] = def end,
  GetGlobalOption = function(name) return opts[name] end,
  SetGlobalOption = function() return nil end,
  MakeCommand = function() end,
  TryBindKey = function(key, action, overwrite)
    bind_log[#bind_log + 1] = { key, action, overwrite }
    return true, nil
  end,
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

local split_count = 0
local function new_mock_pane(buf)
  local p
  p = {
    Buf = buf,
    Cursor = { GotoLoc = function() end, ResetSelection = function() end },
    OpenBuffer = function(self, b) self.Buf = b end,
    HSplitBuf = function(self, b)
      split_count = split_count + 1
      return new_mock_pane(b)
    end,
    VSplitBuf = function(self, b)
      split_count = split_count + 1
      return new_mock_pane(b)
    end,
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
  Millisecond = 1000000,
  Second = 1000000000,
  Sleep = function() end,
  Since = function(t) return (os.clock() - t._clock) * 1000000000 end,
  Now = function()
    local clock = os.clock()
    return {
      _clock = clock,
      UnixMilli = function() return math.floor(clock * 1000) + os.time() * 1000 end,
    }
  end,
}

-- micro/shell: capture jobs so the harness can finish them deterministically.
-- ExecCommand pretends nothing is installed so destination seeding takes its
-- fallback branches.
local job_log = {}
mock["micro/shell"] = {
  JobStart = function(cmd, _, _, on_exit)
    local stdin_path = cmd:match("< '([^']+)'")
    local payload
    if stdin_path then
      local f = io.open(stdin_path, "rb")
      if f then payload = f:read("*a"); f:close() end
    end
    job_log[#job_log + 1] = {
      cmd = cmd,
      on_exit = on_exit,
      out = cmd:match("> '([^']+%.out)'"),
      err = cmd:match("2> '([^']+%.err)'"),
      payload = payload,
    }
    return {}
  end,
  JobSpawn = function() return {} end,
  ExecCommand = function() return "", "not found" end,
  RunCommand = function() return "", "not found" end,
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

local files = { "json", "assets", "model", "render", "cmd", "dest", "issues",
  "store", "migrate", "olwb" }
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

local binds = {}
for _, row in ipairs(bind_log) do binds[row[1]] = row end
ok(binds["Alt-o"] and binds["Alt-o"][2] == "lua:olwb.launch"
  and binds["Alt-o"][3] == false, "Alt-o binds launch without overwrite")
ok(binds["Alt-O"] and binds["Alt-O"][2] == "lua:olwb.resume"
  and binds["Alt-O"][3] == false, "Alt-Shift-o binds resume without overwrite")
ok(binds["Alt-I"] and binds["Alt-I"][2] == "lua:olwb.instant"
  and binds["Alt-I"][3] == false, "Alt-Shift-i binds instant without overwrite")
ok(binds["Alt-i"] and binds["Alt-i"][2] == "lua:olwb.key_inbox",
  "Alt-i remains the inbox binding")

-- Cold launch and repeated entry use the named public functions without
-- creating duplicate pane stacks.
local okopen, erropen = xpcall(function() ENV.launch(nil) end, debug.traceback)
ok(okopen, "cold lua:olwb.launch runs without error")
if not okopen then io.write("  open error: " .. tostring(erropen) .. "\n") end
local launched_splits = split_count
ok(pcall(ENV.launch, nil), "launch runs when the UI is already open")
ok(split_count == launched_splits, "repeated launch creates no duplicate panes")
ok(pcall(ENV.resume, nil), "resume without history falls back to launch")
ok(ENV.statusinfo() == "no liner", "resume fallback leaves no active liner")

-- Native instant entry captures in memory and /close discards without a file.
ok(pcall(ENV.olwb_command, nil, { "-i" }), ">olwb -i enters instant mode")
local instant_buf = new_mock_buffer("discard this", "olwb://compose")
ok(pcall(ENV.preInsertNewline, new_mock_pane(instant_buf)),
  "instant capture runs")
ok(#ENV.olwb_store.list_liner_ids() == 0,
  "instant capture creates no liner file")
ok(pcall(ENV.preInsertNewline,
  new_mock_pane(new_mock_buffer("/close", "olwb://compose"))),
  "instant /close runs")
ok(#ENV.olwb_store.list_liner_ids() == 0,
  "discarded instant liner leaves no liner file")

-- Promotion gives the same in-memory liner a durable name and file.
ok(pcall(ENV.instant, nil), "lua:olwb.instant enters instant mode")
ok(pcall(ENV.instant, nil), "instant entry is idempotent while active")
local promote_buf = new_mock_buffer("keep this", "olwb://compose")
ok(pcall(ENV.preInsertNewline, new_mock_pane(promote_buf)),
  "promoted instant capture runs")
ok(pcall(ENV.preInsertNewline,
  new_mock_pane(new_mock_buffer("/save quick", "olwb://compose"))),
  "instant /save <name> promotes")
local promoted_blob = ""
local promoted_pipe = io.popen("cat " .. datadir .. "/olwb/liners/*.json 2>/dev/null")
if promoted_pipe then promoted_blob = promoted_pipe:read("*a"); promoted_pipe:close() end
ok(promoted_blob:find("keep this", 1, true)
  and promoted_blob:find('"name":"quick"', 1, true),
  "promotion persists the instant content and name")
ok(pcall(ENV.preInsertNewline,
  new_mock_pane(new_mock_buffer("/close", "olwb://compose"))),
  "promoted liner closes through the durable path")
ok(pcall(ENV.instant, nil), "instant entry before direct resume runs")
local resume_discard_buf = new_mock_buffer("resume discards this", "olwb://compose")
ok(pcall(ENV.preInsertNewline, new_mock_pane(resume_discard_buf)),
  "capture before direct resume runs")
ok(pcall(ENV.resume, nil), "resume discards instant and activates durable history")
local resume_pipe = io.popen("cat " .. datadir .. "/olwb/liners/*.json 2>/dev/null")
local resume_blob = resume_pipe and resume_pipe:read("*a") or ""
if resume_pipe then resume_pipe:close() end
ok(not resume_blob:find("resume discards this", 1, true),
  "resume does not persist the discarded instant liner")
ok(ENV.statusinfo():find("quick", 1, true) ~= nil,
  "resume activates durable history after instant discard")

-- Create a liner, then route a capture through preInsertNewline. Bare input
-- without a liner is tested separately below as the open-search path.
local created = pcall(ENV.preInsertNewline,
  new_mock_pane(new_mock_buffer("/new notes", "olwb://compose")))
ok(created, "/new creates the harness liner")
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

local function submit_command(line)
  return pcall(ENV.preInsertNewline,
    new_mock_pane(new_mock_buffer(line, "olwb://compose")))
end

ok(submit_command("/close"), "/close prepares the no-liner dispatch case")
local search_buf = new_mock_buffer("first captured", "olwb://compose")
ok(pcall(ENV.preInsertNewline, new_mock_pane(search_buf)),
  "bare no-liner input runs")
ok(search_buf:Line(0) == "/open first captured",
  "bare no-liner input becomes a live /open search")

local slash_buf = new_mock_buffer("/list", "olwb://compose")
ok(pcall(ENV.preInsertNewline, new_mock_pane(slash_buf)),
  "slash input still dispatches without a liner")
ok(slash_buf:Line(0) == "", "slash input is not converted to open search")

ok(submit_command("/open notes"), "/open restores the active liner")

local function last_executor_job()
  for i = #job_log, 1, -1 do
    if job_log[i].out then return job_log[i] end
  end
end

local function finish_job(job, stdout, stderr)
  local out = assert(io.open(job.out, "wb")); out:write(stdout or ""); out:close()
  local err = assert(io.open(job.err, "wb")); err:write(stderr or ""); err:close()
  job.on_exit()
  ENV.onAnyEvent()
end

local function fixture(name)
  local f = assert(io.open(root .. "tests/fixtures/" .. name, "rb"))
  local s = f:read("*a"); f:close(); return s
end

-- A benefit snapshots instant content before /close discards its liner.
local durable_before_instant = #ENV.olwb_store.list_liner_ids()
local durable_state = ENV.olwb_json.decode(
  ENV.olwb_store.read_file(ENV.olwb_store.state_path()))
ok(pcall(ENV.instant, nil), "instant entry before benefit send runs")
local benefit_buf = new_mock_buffer("temporary benefit", "olwb://compose")
ok(pcall(ENV.preInsertNewline, new_mock_pane(benefit_buf)),
  "instant benefit capture runs")
local state_during_instant = ENV.olwb_json.decode(
  ENV.olwb_store.read_file(ENV.olwb_store.state_path()))
ok(state_during_instant.activeLinerId == durable_state.activeLinerId
  and state_during_instant.activeSessionId == durable_state.activeSessionId,
  "instant capture leaves durable active ids unchanged")
ok(submit_command("/send file"), "instant content starts a destination send")
local instant_job = last_executor_job()
ok(instant_job and instant_job.payload
  and instant_job.payload:find("temporary benefit", 1, true),
  "instant destination payload contains the captured line")
ok(submit_command("/close"), "instant liner can close while send runs")
ok(#ENV.olwb_store.list_liner_ids() == durable_before_instant,
  "instant send and discard add no liner file")
local after_discard_pipe = io.popen("cat " .. datadir .. "/olwb/liners/*.json 2>/dev/null")
local after_discard_blob = after_discard_pipe and after_discard_pipe:read("*a") or ""
if after_discard_pipe then after_discard_pipe:close() end
ok(not after_discard_blob:find("temporary benefit", 1, true),
  "discarded instant content is absent from durable liners")
finish_job(instant_job, "", "")
ok(pcall(ENV.resume, nil), "resume returns to a durable liner after discard")
ok(ENV.statusinfo():find("notes", 1, true) ~= nil,
  "resume activates the most recently updated durable liner")

-- A successful adapted send seeds a resumable destination session.
ok(submit_command("/send claude"), "first adapted send starts")
local seed_job = last_executor_job()
assert(seed_job, job_log[#job_log] and job_log[#job_log].cmd
  or (err_log[#err_log] or "no jobs"))
finish_job(seed_job, fixture("claude-response.json"), "")

-- A stale-session retry must reuse the first attempt's bytes. A message and
-- selection created during the async gap must survive its eventual success.
ok(submit_command("/send claude"), "resumed send starts")
local stale_job = last_executor_job()
local late = new_mock_buffer("late captured line", "olwb://compose")
ok(pcall(ENV.preInsertNewline, new_mock_pane(late)),
  "message can be captured while send is pending")
ENV.preOutdentSelection(new_mock_pane(new_mock_buffer("", "olwb://compose")))
ENV.preRune(new_mock_pane(new_mock_buffer("", "olwb://feed")), " ")
finish_job(stale_job, "", "stale session\nolwb-job-failed\n")
local retry_job = last_executor_job()
ok(retry_job ~= stale_job, "stale session starts one fresh retry")
ok(retry_job.payload == stale_job.payload,
  "fresh retry reuses the original payload bytes")
finish_job(retry_job, fixture("claude-response.json"), "")

ok(submit_command("/send file"), "post-completion selection can be sent")
local selection_job = last_executor_job()
ok(selection_job.payload and selection_job.payload:find("late captured line", 1, true),
  "selection made during send survives completion")
ok(selection_job.payload and not selection_job.payload:find("first captured line", 1, true),
  "surviving selection scopes the next send")

-- Filing is single-flight: a second command starts no executor, but a failed
-- first run releases the guard and leaves the draft retryable.
local issue_id = "guard-test"
local issue_script = datadir .. "/olwb/issues/" .. issue_id .. ".sh"
ENV.olwb_store.write_file_atomic(issue_script, "#!/bin/sh\n")
ENV.olwb_store.write_file_atomic(datadir .. "/olwb/issues/" .. issue_id .. ".json",
  ENV.olwb_json.encode({ id = issue_id, status = "drafted", count = 1,
    repo = "owner/repo", script = issue_script, message_ids = {} }))
local before_file = #job_log
ok(submit_command("/issues file " .. issue_id), "first issue filing starts")
local file_job = last_executor_job()
local after_first_file = #job_log
ok(submit_command("/issues file " .. issue_id), "duplicate filing is handled")
ok(#job_log == after_first_file, "duplicate filing starts no second job")
ok(after_first_file > before_file, "first filing created a job")
finish_job(file_job, "", "filing failed\nolwb-job-failed\n")
ok(submit_command("/issues file " .. issue_id), "filing can retry after completion")
ok(#job_log > after_first_file, "completed filing releases the in-flight guard")

-- Simulate another micro instance changing the on-disk session map between
-- saves. Local additions and deletions must apply without dropping its keys.
local stale_state = ENV.olwb_store.load_state()
stale_state.dest_sessions.local_a = "a"
ok(ENV.olwb_store.save_state(stale_state), "local session state saves")
local disk = ENV.olwb_json.decode(ENV.olwb_store.read_file(ENV.olwb_store.state_path()))
disk.dest_sessions.remote_b = "b"
ENV.olwb_store.write_file_atomic(ENV.olwb_store.state_path(), ENV.olwb_json.encode(disk))
stale_state.dest_sessions.local_c = "c"
ok(ENV.olwb_store.save_state(stale_state), "stale state merges remote session additions")
disk = ENV.olwb_json.decode(ENV.olwb_store.read_file(ENV.olwb_store.state_path()))
ok(disk.dest_sessions.local_a == "a" and disk.dest_sessions.local_c == "c"
  and disk.dest_sessions.remote_b == "b", "all concurrent session ids survive")
disk.dest_sessions.remote_d = "d"
ENV.olwb_store.write_file_atomic(ENV.olwb_store.state_path(), ENV.olwb_json.encode(disk))
stale_state.dest_sessions.local_a = nil
ok(ENV.olwb_store.save_state(stale_state), "local session deletion saves")
disk = ENV.olwb_json.decode(ENV.olwb_store.read_file(ENV.olwb_store.state_path()))
ok(disk.dest_sessions.local_a == nil and disk.dest_sessions.remote_b == "b"
  and disk.dest_sessions.remote_d == "d", "session deletion preserves remote keys")

local before_exit_count = #ENV.olwb_store.list_liner_ids()
ok(pcall(ENV.instant, nil), "instant entry before deinit runs")
local exit_buf = new_mock_buffer("discard on exit", "olwb://compose")
ok(pcall(ENV.preInsertNewline, new_mock_pane(exit_buf)),
  "instant capture before deinit runs")
ok(pcall(ENV.deinit), "deinit discards instant state")
ok(#ENV.olwb_store.list_liner_ids() == before_exit_count,
  "editor exit creates no instant liner file")

io.write(string.format("\nharness: %d passed, %d failed\n", passed, failed))
io.write("datadir: " .. datadir .. "/olwb\n")
os.execute("ls -R " .. datadir .. "/olwb 2>/dev/null | head -20")
os.exit(failed == 0 and 0 or 1)
