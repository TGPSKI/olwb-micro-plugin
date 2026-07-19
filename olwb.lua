VERSION = "1.0.0"

-- olwb.lua -- one-line-with-benefits for micro.
--
-- The only file (besides store.lua) that touches micro/Go APIs. Wiring only:
-- the domain logic lives in the pure modules model/render/cmd/migrate, reached
-- through micro's shared "olwb" plugin namespace (olwb_model, olwb_render, ...).

local micro = import("micro")
local config = import("micro/config")
local buffer = import("micro/buffer")
local util = import("micro/util")
local shell = import("micro/shell")
local goos = import("os") -- Go os: Getenv/Remove (Lua's os stays untouched)
local time = import("time")

local FEED_PATH = "olwb://feed"
local COMPOSE_PATH = "olwb://compose"
local TITLE_PATH = "olwb://title"
local BAR_PATH = "olwb://bar"

local TITLE_ROWS = 4 -- padding blank + "olwb" line + blank + divider
local BAR_ROWS = 5   -- blank + shortcut reference + blank + Liner / Session
local MAX_COMPOSE_ROWS = 8
local PAD = "  "     -- horizontal padding applied to every rendered line

-- Options manageable from inside the UI via /set (kept in sync with the
-- RegisterCommonOption calls in init and cmd.lua's subverbs.set).
local OPTION_DOCS = {
  { "autostart",   "open olwb when micro starts with no file" },
  { "composesize", "minimum one-line height in rows" },
  { "datadir",     "storage dir (empty = $XDG_DATA_HOME/olwb)" },
  { "rulewidth",   "feed separator width" },
  { "termcmd",     "terminal command for /send <dest> tui (state, not settings)" },
  { "theme",       "apply the bundled olwb colorscheme" },
  { "timefmt",     "strftime timestamp format" },
}

-- Runtime state (module-local; not in the shared plugin table).
local state          -- the persisted state table (see store.default_state)
local active_liner   -- currently loaded liner table, or nil
local title_pane     -- one-row branding line at the very top
local compose_pane   -- BufPane holding the compose line
local feed_pane      -- BufPane showing the feed (or the /? menu overlay)
local bar_pane       -- two-row Liner/Session bar at the bottom
local ui_open = false
local overlay_kind         -- nil | "help" | "options" | "dests" | "sessions" | "issues"
local compose_rows = 1     -- current input height (auto-grows with wrapping)
local last_input           -- last seen compose text, to detect typing
local cycle                -- Tab-cycling state: { cands, kept, idx } or nil

-- Browse mode (message-granular feed navigation) + selection.
local browsing = false     -- Shift-Tab entered the feed in browse mode
local browse_pos = 1       -- index into feed_index of the current entry
local selected = {}        -- set of message ids; persists until sent/cleared
local feed_index           -- render_feed's entry index (nil while an overlay shows)

-- Send machinery.
local pending_jobs = {}    -- topic (dest name | "issues") -> in-flight count
local job_notes = {}       -- topic -> { text, started_ms } for the indicator
local prev_liner_key       -- liner to return to on the second Alt-i
local job_queue = {}       -- finished jobs awaiting main-state processing

-- Forward declarations so mutually-recursive helpers bind to these locals
-- (function foo() assigns to the in-scope local, not a new global).
local rerender, submit_message, build_ctx, save_active, feed_text
local create_liner, open_liner, close_liner, start_session, end_session
local load_liner, persist_registry, list_liners, do_export, open_help
local open_olwb, do_migrate, rescan, selftest
local compose_input, menu_text, bar_text, liner_names, layout_panes
local sync_compose_size, show_options, set_option
local cmd_extra, send_to, send_tui, deliver_response, selection_entries
local issues_draft, issues_file, list_issue_manifests, reset_feed_scroll
local cycle_step, show_overlay, start_job, drain_jobs

-------------------------------------------------------------------------------
-- Options / time / ids / feedback
-------------------------------------------------------------------------------

local function opt(name) return config.GetGlobalOption("olwb." .. name) end

local function timefmt()
  local v = opt("timefmt")
  if not v or v == "" then v = "%Y-%m-%d %H:%M:%S" end
  return v
end

local function rule_width()
  return math.floor(tonumber(opt("rulewidth")) or 48)
end

local function now_ms()
  local t = time.Now()
  return t:UnixMilli()
end

local function new_id()
  return olwb_model.new_id(now_ms(), math.random)
end

local function fmt_time(ms)
  return os.date(timefmt(), math.floor((ms or 0) / 1000))
end

local function info(msg) micro.InfoBar():Message("olwb: " .. msg) end
local function err(msg) micro.InfoBar():Error("olwb: " .. msg) end

-------------------------------------------------------------------------------
-- Persistence helpers
-------------------------------------------------------------------------------

function persist_registry(liner)
  if not liner or not liner.id then return end
  local n = 0
  for _, s in ipairs(liner.sessions) do n = n + #s.messages end
  n = n + #(liner.directMessages or {})
  state.liners[liner.id] = {
    name = liner.metadata.name or "",
    count = n,
    updated = now_ms(),
  }
end

function save_active()
  if not active_liner then return end
  olwb_store.save_liner(active_liner)
  persist_registry(active_liner)
  olwb_store.save_state(state)
end

function load_liner(id)
  return olwb_store.load_liner(id)
end

function create_liner(name, desc)
  local liner = olwb_model.new_liner(new_id(), name or "", desc or "")
  active_liner = liner
  state.activeLinerId = liner.id
  state.activeSessionId = nil
  olwb_store.save_liner(liner)
  persist_registry(liner)
  olwb_store.save_state(state)
  return liner
end

function open_liner(key)
  local id = nil
  if state.liners[key] then
    id = key
  else
    for lid, meta in pairs(state.liners) do
      if meta.name == key then id = lid break end
    end
  end
  if not id and olwb_store.exists(olwb_store.liner_path(key)) then id = key end
  if not id then return nil end
  local liner = load_liner(id)
  if not liner then return nil end
  active_liner = liner
  state.activeLinerId = id
  -- Opening a liner clears its unread badge (responses have been "seen").
  if state.unread then state.unread[id] = nil end
  -- Resume the most recent still-open session, if any.
  state.activeSessionId = nil
  for _, s in ipairs(liner.sessions) do
    if s.endTime == 0 then state.activeSessionId = s.id end
  end
  persist_registry(liner)
  olwb_store.save_state(state)
  return liner
end

function start_session(liner)
  local cur = olwb_model.active_session(liner, state)
  if cur then cur.endTime = now_ms() end
  local s = olwb_model.new_session(new_id(), now_ms())
  liner.sessions[#liner.sessions + 1] = s
  state.activeSessionId = s.id
  return s
end

function end_session(liner)
  local s = olwb_model.active_session(liner, state)
  if s then s.endTime = now_ms() end
  state.activeSessionId = nil
end

function close_liner()
  if active_liner then
    olwb_store.backup_liner(active_liner.id)
    end_session(active_liner)
    save_active()
  end
  active_liner = nil
  state.activeLinerId = nil
  state.activeSessionId = nil
  olwb_store.save_state(state)
end

function submit_message(text)
  text = olwb_model.trim(text)
  if text == "" then return end
  if not active_liner then create_liner("notes", "") end
  local liner = active_liner
  local sess = olwb_model.active_session(liner, state)
  if not sess then sess = start_session(liner) end
  local msg = olwb_model.new_message(new_id(), text, now_ms(),
    olwb_model.copy_list(state.activeLabels))
  sess.messages[#sess.messages + 1] = msg
  save_active()
  rerender()
end

function list_liners()
  local out = {}
  for id, meta in pairs(state.liners) do
    out[#out + 1] = {
      id = id, name = meta.name or "",
      count = meta.count or 0, updated = meta.updated or 0,
    }
  end
  table.sort(out, function(a, b) return (a.updated or 0) > (b.updated or 0) end)
  return out
end

function do_export(fmt, path)
  if not active_liner then return false, "no active liner" end
  fmt = fmt or "md"
  local data
  if fmt == "json" then
    data = olwb_json.encode(active_liner)
  elseif fmt == "md" then
    data = olwb_render.render_export_md(active_liner, {
      fmt_time = fmt_time, filter = state.filter, include_direct = true,
    })
  else
    return false, "unknown export format '" .. fmt .. "' (md|json)"
  end
  if not path then
    local base = active_liner.metadata.name
    if not base or base == "" then base = olwb_render.short_id(active_liner.id) end
    base = base:gsub("%s+", "_")
    path = olwb_store.dir .. "/" .. base .. "-"
      .. os.date("!%Y%m%dT%H%M%SZ") .. "." .. fmt
  end
  local ok = olwb_store.write_file_atomic(path, data)
  if ok then return true, "exported to " .. path end
  return false, "export failed writing " .. path
end

-------------------------------------------------------------------------------
-- Send executor (destinations, sessions, TUI mode) + issues pipeline
-------------------------------------------------------------------------------

local function noop() end

-- Every job command ends with this marker trick: JobStart's onExit callback
-- carries no exit code, so a shell-level `|| echo` turns non-zero exits
-- (including command-not-found) into a detectable stderr marker.
local FAIL_MARKER = "olwb-job-failed"

local function job_failed(stderr_text)
  return stderr_text:find(FAIL_MARKER, 1, true) ~= nil
end

-- Job architecture, hard-learned: micro invokes Lua job callbacks on a fresh
-- gopher-luar thread per invocation, and running real Lua there crashes
-- micro 2.0.15 nondeterministically (Go-level nil deref in GopherLua's
-- concat path — hit in the wild with real CLI runs). So jobs here:
--   1. redirect stdout/stderr to files (no per-chunk callbacks at all);
--   2. run a push-only onExit (two statements, no string work) that queues
--      the record and opens a throwaway buffer;
--   3. rely on buffer.NewBuffer synchronously firing onBufferOpen on the
--      MAIN Lua state — where drain_jobs runs the real completion logic.
-- onAnyEvent also drains as a safety net.
local JOB_DONE_PATH = "olwb://job-done"

-- Start `cmdstr` (optionally with a stdin file that is deleted afterwards)
-- and hand (stdout, stderr) to `done` on the main state when it finishes.
function start_job(cmdstr, stdin_path, done)
  local q = olwb_dest.shell_quote
  local id = new_id()
  local outf = olwb_store.dir .. "/job-" .. id .. ".out"
  local errf = olwb_store.dir .. "/job-" .. id .. ".err"
  local full = "( " .. cmdstr
    .. (stdin_path and (" < " .. q(stdin_path)) or "")
    .. " > " .. q(outf) .. " ) 2> " .. q(errf)
    .. " || echo " .. FAIL_MARKER .. " >> " .. q(errf)
  local rec = { out = outf, err = errf, stdin = stdin_path, done = done }
  shell.JobStart(full, noop, noop, function()
    job_queue[#job_queue + 1] = rec
    buffer.NewBuffer("", JOB_DONE_PATH) -- fires onBufferOpen on the main state
  end)
end

function drain_jobs()
  while #job_queue > 0 do
    local rec = table.remove(job_queue, 1)
    local stdout = olwb_store.read_file(rec.out) or ""
    local stderr_text = olwb_store.read_file(rec.err) or ""
    pcall(function() goos.Remove(rec.out) end)
    pcall(function() goos.Remove(rec.err) end)
    if rec.stdin then pcall(function() goos.Remove(rec.stdin) end) end
    rec.done(stdout, stderr_text)
  end
end

-- Background-job progress: every job registers under a topic via job_begin,
-- which notes what is running; the bar and the /issues overlay render a
-- spinner + note + elapsed seconds via progress_line. Terminals only repaint
-- on events, so while anything is pending a `sleep` job loops as a ticker,
-- each lap hopping to the main Lua state through the same buffer trampoline
-- real jobs use (see start_job) before advancing the frame.
local SPIN = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local TICK_PATH = "olwb://tick"
local spin_frame = 1
local ticker_live = false

local function jobs_pending()
  for _, n in pairs(pending_jobs) do
    if n > 0 then return true end
  end
  return false
end

local function start_ticker()
  if ticker_live then return end
  ticker_live = true
  shell.JobStart("sleep 0.5", noop, noop, function()
    buffer.NewBuffer("", TICK_PATH) -- fires onBufferOpen on the main state
  end)
end

local function job_begin(topic, note)
  pending_jobs[topic] = (pending_jobs[topic] or 0) + 1
  job_notes[topic] = { text = note, started_ms = now_ms() }
  start_ticker()
end

local function job_end(topic)
  pending_jobs[topic] = math.max(0, (pending_jobs[topic] or 1) - 1)
  if pending_jobs[topic] == 0 then job_notes[topic] = nil end
end

-- "⠹ filing 7 issue(s) on o/r  12s" for a topic with work in flight, or nil.
local function progress_line(topic)
  local n = pending_jobs[topic]
  if not n or n == 0 then return nil end
  local note = job_notes[topic]
  local txt = (note and note.text) or (topic .. " working…")
  local secs = note and math.floor((now_ms() - note.started_ms) / 1000)
  return SPIN[spin_frame] .. " " .. txt .. (secs and ("  " .. secs .. "s") or "")
end

-- The job-completion and ticker trampoline target (see start_job). Must be
-- module-scope so micro finds it; ignores every buffer except the throwaway
-- ones.
function onBufferOpen(buf)
  local ok, path = pcall(function() return buf.Path end)
  if not ok then return end
  if path == TICK_PATH then
    pcall(function() buf:Close() end)
    ticker_live = false
    if jobs_pending() then
      spin_frame = spin_frame % #SPIN + 1
      start_ticker()
    end
    rerender() -- advance the spinner, or clear it after the last job
    return
  end
  if path ~= JOB_DONE_PATH then return end
  pcall(function() buf:Close() end)
  drain_jobs()
end

-- Last few stderr lines for an error bar message (the marker itself is
-- filtered with a plain find — it contains pattern-magic hyphens).
local function stderr_tail(text)
  local lines = {}
  for line in ((text or "") .. "\n"):gmatch("(.-)\n") do
    if line:match("%S") and not line:find(FAIL_MARKER, 1, true) then
      lines[#lines + 1] = line
    end
  end
  local from = math.max(1, #lines - 2)
  local out = table.concat(lines, " | ", from)
  if out == "" then out = "(no stderr)" end
  if #out > 160 then out = out:sub(1, 157) .. "…" end
  return out
end

-- The whole stderr (marker stripped, clipped) for feed error messages, where
-- there is room to act on it — stderr_tail is only the info-bar teaser.
local function stderr_detail(text)
  local lines = {}
  for line in ((text or "") .. "\n"):gmatch("(.-)\n") do
    if not line:find(FAIL_MARKER, 1, true) then lines[#lines + 1] = line end
  end
  local out = table.concat(lines, "\n"):gsub("%s+$", "")
  if out == "" then out = "(no stderr)" end
  if #out > 4000 then out = out:sub(1, 4000) .. "\n…(clipped)" end
  return out
end

local function find_dest_state(name)
  for _, d in ipairs(state.destinations or {}) do
    if d.name == name then return d end
  end
  return nil
end

local function selection_count()
  local n = 0
  for _ in pairs(selected) do n = n + 1 end
  return n
end

-- The entries a send/draft operates on: the selected messages in feed order,
-- or — when nothing is selected — the whole current scope (respecting the
-- active filter).
function selection_entries()
  if not active_liner then return nil, "no active liner (use /new or /open)" end
  local entries = olwb_model.flatten_desc(active_liner, {
    include_direct = true,
    filter = state.filter,
  })
  if selection_count() == 0 then return entries end
  local chosen = {}
  for _, e in ipairs(entries) do
    if selected[e.message.id] then chosen[#chosen + 1] = e end
  end
  return chosen
end

-- Land a response in a liner by name (load-or-create) WITHOUT disturbing the
-- active liner — unless the target IS active, then mutate in place. Appends
-- as a direct message so no session state is touched. Bumps the unread badge
-- for non-active targets. Returns the target liner id.
function deliver_response(into_name, content, label)
  if not into_name or into_name == "" then return nil end
  local id = nil
  for lid, meta in pairs(state.liners) do
    if meta.name == into_name then id = lid break end
  end
  local target, is_active
  if active_liner and (active_liner.id == id
      or (not id and active_liner.metadata.name == into_name)) then
    target = active_liner
    is_active = true
  elseif id then
    target = load_liner(id)
  end
  if not target then
    target = olwb_model.new_liner(new_id(), into_name, "")
  end
  local msg = olwb_model.new_message(new_id(), content, now_ms(),
    label and { label } or {})
  target.directMessages = target.directMessages or {}
  target.directMessages[#target.directMessages + 1] = msg
  olwb_store.save_liner(target)
  persist_registry(target)
  if not is_active then
    state.unread = state.unread or {}
    state.unread[target.id] = (state.unread[target.id] or 0) + 1
  end
  olwb_store.save_state(state)
  rerender() -- feed (if target is active) and the bar badge/count
  return target.id
end

-- Workflow errors the user must act on land twice: the info bar flash for
-- immediacy, and — with the detail the bar can't fit — as an 'error'-labeled
-- feed message in `into_name` (default: an "olwb-errors" liner), persistent,
-- full-width, and badged like any other delivered response.
local function report_error(into_name, headline, detail)
  err(headline)
  if not into_name or into_name == "" then into_name = "olwb-errors" end
  local body = "⚠ " .. headline
  if detail and detail ~= "" then body = body .. "\n\n" .. detail end
  deliver_response(into_name, body, "error")
end

-- Auto-detect a terminal for TUI sends: $TERMINAL first, then common
-- emulators (with their exec flag where one is needed).
local function detect_terminal()
  local t = goos.Getenv("TERMINAL")
  if t ~= nil and t ~= "" then return t end
  local cands = {
    { "konsole", "konsole -e" },
    { "foot", "foot" },
    { "alacritty", "alacritty -e" },
    { "kitty", "kitty" },
    { "xterm", "xterm -e" },
  }
  for _, c in ipairs(cands) do
    local _, e = shell.ExecCommand("sh", "-c", "command -v " .. c[1])
    if e == nil then return c[2] end
  end
  return nil
end

-- /send <dest> tui: payload to a file, adapter builds the interactive
-- command, spawned detached in a new terminal window. micro keeps running.
function send_tui(d, payload, skey, n)
  if not state.termcmd or state.termcmd == "" then
    local t = detect_terminal()
    if not t then
      err('no terminal found — /set termcmd "<cmd>"')
      return
    end
    state.termcmd = t
    olwb_store.save_state(state)
  end
  local id = new_id()
  local ppath = olwb_store.dir .. "/tui-" .. id .. ".md"
  if not olwb_store.write_file_atomic(ppath, payload) then
    err("could not write payload file")
    return
  end
  local sid = (state.dest_sessions or {})[skey]
  local tcmd, terr = olwb_dest.tui(d.kind, sid, ppath)
  if not tcmd then err(tostring(terr)) return end
  -- A launcher script sidesteps quote-nesting through the terminal emulator;
  -- only olwb-generated paths appear on the spawn command line.
  local lpath = olwb_store.dir .. "/tui-" .. id .. ".sh"
  olwb_store.write_file_atomic(lpath, "#!/bin/sh\nexec " .. tcmd .. "\n")
  local spawn = "setsid " .. state.termcmd .. " sh "
    .. olwb_dest.shell_quote(lpath) .. " >/dev/null 2>&1 &"
  shell.JobStart(spawn, noop, noop, noop)
  selected = {}
  rerender()
  info("opened " .. d.name .. " in a terminal ("
    .. (sid and "resumed session" or "fresh session") .. ")")
end

-- Headless /send. is_retry guards the one automatic fresh retry after a
-- resumed session fails (C3's stale-session rule).
function send_to(name, mode, is_retry)
  local d = find_dest_state(name)
  if not d then
    err("no destination '" .. tostring(name) .. "' (/dest add, /dest lists)")
    return
  end
  local entries, serr = selection_entries()
  if not entries then err(serr) return end
  if #entries == 0 then err("nothing to send (empty scope)") return end
  local payload = olwb_render.render_selection_md(active_liner, entries,
    { fmt_time = fmt_time })
  local n = #entries
  local source_name = active_liner.metadata.name
  if source_name == "" then source_name = olwb_render.short_id(active_liner.id) end
  local skey = d.name .. "|" .. active_liner.id

  if mode == "tui" then
    if not d.kind then
      err("destination '" .. name .. "' is a plain pipe — tui needs kind claude|codex|opencode (/dest kind)")
      return
    end
    send_tui(d, payload, skey, n)
    return
  end

  local cmdstr = d.cmd
  local had_session = false
  if d.kind then
    local sid = (state.dest_sessions or {})[skey]
    had_session = sid ~= nil
    local wrapped, werr = olwb_dest.wrap(d.kind, d.cmd, sid)
    if not wrapped then err(tostring(werr)) return end
    cmdstr = wrapped
  end

  local tmp = olwb_store.dir .. "/tmp-send-" .. new_id()
  if not olwb_store.write_file_atomic(tmp, payload) then
    err("could not write payload file")
    return
  end

  job_begin(d.name, "sending " .. n .. " note" .. (n == 1 and "" or "s")
    .. " → " .. d.name)
  start_job(cmdstr, tmp,
    function(stdout, stderr_text)
      job_end(d.name)
      local failed = job_failed(stderr_text)
      local response_text
      if d.kind then
        if failed and had_session and not is_retry then
          -- Stale session: forget it and retry exactly once, fresh.
          state.dest_sessions[skey] = nil
          olwb_store.save_state(state)
          info(d.name .. ": stored session failed, retrying fresh…")
          send_to(name, mode, true)
          return
        end
        if failed then
          report_error(d.into, d.name .. " failed: " .. stderr_tail(stderr_text),
            "sending " .. n .. " note(s) from " .. source_name
            .. " via " .. d.name .. " (" .. d.kind .. ")\n\nstderr:\n"
            .. stderr_detail(stderr_text))
          rerender()
          return
        end
        local parsed, perr = olwb_dest.parse(d.kind, stdout)
        if not parsed then
          report_error(d.into, d.name .. ": " .. tostring(perr),
            "the " .. d.kind .. " response could not be parsed.\n\nstdout (head):\n"
            .. tostring(stdout or ""):sub(1, 2000))
          rerender()
          return
        end
        if parsed.session_id then
          state.dest_sessions = state.dest_sessions or {}
          state.dest_sessions[skey] = parsed.session_id
          olwb_store.save_state(state)
        end
        response_text = parsed.text
      else
        if failed then
          report_error(d.into, d.name .. " failed: " .. stderr_tail(stderr_text),
            "sending " .. n .. " note(s) from " .. source_name
            .. " via " .. d.name .. "\n\nstderr:\n" .. stderr_detail(stderr_text))
          rerender()
          return
        end
        response_text = stdout
      end
      if d.into and d.into ~= "" then
        local prov = "↩ " .. n .. " note" .. (n == 1 and "" or "s")
          .. " from " .. source_name
        deliver_response(d.into, prov .. "\n" .. response_text, d.name)
      end
      selected = {}
      rerender()
      info("sent " .. n .. " message(s) to " .. d.name)
    end)
  rerender() -- bar shows the spinner + "sending n → dest"
  info("sending " .. n .. " message(s) to " .. d.name .. "…")
end

-------------------------------------------------------------------------------
-- Issues pipeline (stage 1 draft, stage 2 file; stage 3 is out of scope)
-------------------------------------------------------------------------------

function list_issue_manifests()
  local out = {}
  for _, p in ipairs(olwb_store.glob(olwb_store.issues_dir() .. "/*.json")) do
    local s = olwb_store.read_file(p)
    if s then
      local ok, m = pcall(olwb_json.decode, s)
      if ok and type(m) == "table" and m.id then out[#out + 1] = m end
    end
  end
  table.sort(out, function(a, b)
    return (a.created_ms or 0) > (b.created_ms or 0)
  end)
  return out
end

local function manifest_path(id)
  return olwb_store.issues_dir() .. "/" .. id .. ".json"
end

local function save_manifest(m)
  return olwb_store.write_file_atomic(manifest_path(m.id), olwb_json.encode(m))
end

-- Resolve /issues draft's target: explicit alias wins; a single configured
-- repo is the default; otherwise the aliases are listed. No inference magic.
local function resolve_issue_repo(alias)
  local repos = state.issue_repos or {}
  if alias and alias ~= "" then
    for _, r in ipairs(repos) do
      if r.alias == alias then return r end
    end
    return nil, "no repo alias '" .. alias .. "' (/issues repo add)"
  end
  if #repos == 1 then return repos[1] end
  if #repos == 0 then
    return nil, "no repos configured — /issues repo add <alias> <owner/repo> [path]"
  end
  local names = {}
  for _, r in ipairs(repos) do names[#names + 1] = r.alias end
  return nil, "several repos configured — /issues draft <"
    .. table.concat(names, "|") .. ">"
end

-- Add a label to specific messages in a (possibly non-active) liner — the
-- stage-2 #filed marking. Same don't-disturb rule as deliver_response.
local function label_messages(liner_id, message_ids, label)
  if not liner_id or not message_ids then return end
  local target, is_active
  if active_liner and active_liner.id == liner_id then
    target = active_liner
    is_active = true
  else
    target = load_liner(liner_id)
  end
  if not target then return end
  local want = {}
  for _, id in ipairs(message_ids) do want[id] = true end
  local function mark(msgs)
    for _, m in ipairs(msgs or {}) do
      if want[m.id] then
        m.metadata = m.metadata or {}
        m.metadata.labels = m.metadata.labels or {}
        olwb_model.add_label(m.metadata.labels, label)
      end
    end
  end
  for _, s in ipairs(target.sessions or {}) do mark(s.messages) end
  mark(target.directMessages)
  olwb_store.save_liner(target)
  persist_registry(target)
  olwb_store.save_state(state)
  if is_active then rerender() end
end

-- Stage 1: selection → model → validated drafts → gh script + manifest +
-- review summary. Ends with an instruction, never an action: the review gate.
function issues_draft(alias)
  local target, rerr = resolve_issue_repo(alias)
  if not target then err(rerr) return end
  local entries, serr = selection_entries()
  if not entries then err(serr) return end
  if #entries == 0 then err("nothing to draft from (empty scope)") return end

  local payload = olwb_render.render_selection_md(active_liner, entries,
    { fmt_time = fmt_time })
  local source_name = active_liner.metadata.name
  if source_name == "" then source_name = olwb_render.short_id(active_liner.id) end
  local source_liner_id = active_liner.id
  local message_ids = {}
  for _, e in ipairs(entries) do message_ids[#message_ids + 1] = e.message.id end

  -- Prompt template: seed the embedded copy to the datadir once; from then on
  -- the file wins, so the user can tune it without touching the plugin.
  local tpath = olwb_store.dir .. "/issues-prompt.md"
  if not olwb_store.exists(tpath) then
    olwb_store.write_file_atomic(tpath, OLWB_ISSUES_PROMPT)
  end
  local template = olwb_store.read_file(tpath) or OLWB_ISSUES_PROMPT

  -- Best-effort repo context from a local checkout; never fatal.
  local repo_context = nil
  if target.path and target.path ~= "" then
    pcall(function()
      repo_context = olwb_issues.build_repo_context(function(p)
        return olwb_store.read_file(p)
      end, target.path)
    end)
  end

  local prompt = olwb_issues.build_prompt({
    template = template,
    repo = target.repo,
    repo_context = repo_context,
    payload = payload,
  })

  local draft_id = os.date("%Y%m%d-%H%M%S")
  local tmp = olwb_store.issues_dir() .. "/tmp-" .. draft_id .. "-prompt.md"
  if not olwb_store.write_file_atomic(tmp, prompt) then
    err("could not write prompt file")
    return
  end
  local mcmd = state.issues_model_cmd or "claude -p"

  job_begin("issues", "drafting issues from " .. #entries .. " note(s) via "
    .. mcmd)
  start_job(mcmd, tmp,
    function(stdout, stderr_text)
      job_end("issues")
      if job_failed(stderr_text) then
        local logp = olwb_store.issues_dir() .. "/" .. draft_id .. ".err.log"
        olwb_store.write_file_atomic(logp, stderr_text or "")
        report_error("issues",
          "issues draft failed: " .. stderr_tail(stderr_text),
          "draft " .. draft_id .. " — model command: " .. mcmd
          .. "\nfull stderr kept: " .. logp
          .. "\n\nstderr:\n" .. stderr_detail(stderr_text))
        rerender()
        return
      end
      local drafts, perrs = olwb_issues.parse_response(stdout)
      if not drafts then
        local rawpath = olwb_store.issues_dir() .. "/" .. draft_id .. ".raw.txt"
        olwb_store.write_file_atomic(rawpath, stdout or "")
        report_error("issues",
          "draft rejected: " .. table.concat(perrs or {}, "; "),
          "draft " .. draft_id .. " — the model response failed validation:\n- "
          .. table.concat(perrs or {}, "\n- ")
          .. "\n\nraw response kept: " .. rawpath
          .. "\nadjust the notes or " .. olwb_store.dir
          .. "/issues-prompt.md, then re-run /issues draft")
        rerender()
        return
      end
      local script = olwb_issues.render_script(target.repo, drafts,
        { id = draft_id, source = source_name })
      local spath = olwb_store.issues_dir() .. "/" .. draft_id .. ".sh"
      olwb_store.write_file_atomic(spath, script)
      save_manifest({
        id = draft_id,
        repo = target.repo,
        alias = target.alias,
        script = spath,
        count = #drafts,
        status = "drafted",
        created_ms = now_ms(),
        source_liner_id = source_liner_id,
        message_ids = message_ids,
      })
      local summary = olwb_issues.render_draft_md(draft_id, target.repo,
        drafts, spath)
      deliver_response("issues", summary, "draft")
      selected = {}
      rerender()
      info("drafted " .. #drafts .. " issue(s) → review " .. draft_id
        .. ".sh, then /issues file " .. draft_id)
    end)
  rerender()
  info("drafting issues via " .. mcmd .. "…")
end

-- Stage 2: run the reviewed gh script. Never called automatically.
function issues_file(id)
  local manifest
  if id == "latest" then
    manifest = list_issue_manifests()[1]
    if not manifest then err("no drafts yet — /issues draft") return end
  else
    local s = olwb_store.read_file(manifest_path(id))
    if s then
      local ok, m = pcall(olwb_json.decode, s)
      if ok and type(m) == "table" then manifest = m end
    end
    if not manifest then
      err("no draft '" .. tostring(id) .. "' (/issues list)")
      return
    end
  end
  if manifest.status ~= "drafted" then
    err("draft " .. manifest.id .. " already filed"
      .. (manifest.filed_ms and (" " .. fmt_time(manifest.filed_ms)) or ""))
    return
  end
  job_begin("issues", "filing " .. (manifest.count or "?") .. " issue(s) on "
    .. manifest.repo)
  start_job("sh " .. olwb_dest.shell_quote(manifest.script), nil,
    function(stdout, stderr_text)
      job_end("issues")
      local urls = {}
      for line in ((stdout or "") .. "\n"):gmatch("(.-)\n") do
        local url = line:match("^%s*(https?://%S+)%s*$")
        if url then urls[#urls + 1] = url end
      end
      if job_failed(stderr_text) or #urls == 0 then
        -- set -e means partial filing is possible; record what got through
        -- so a manual re-run can be reasoned about. Status stays drafted;
        -- never auto-retry (that could double-file).
        if #urls > 0 then manifest.filed_urls = urls end
        local logp = olwb_store.issues_dir() .. "/" .. manifest.id .. ".err.log"
        olwb_store.write_file_atomic(logp, stderr_text or "")
        manifest.last_error = stderr_tail(stderr_text)
        manifest.last_error_ms = now_ms()
        save_manifest(manifest)
        report_error("issues",
          "filing failed (" .. #urls .. " issue(s) got through, status stays drafted): "
            .. stderr_tail(stderr_text),
          "draft " .. manifest.id .. " on " .. manifest.repo
          .. "\nscript: " .. manifest.script
          .. "\nfull stderr kept: " .. logp
          .. (#urls > 0
              and ("\nfiled before the failure (a re-run would double-file these):\n"
                   .. table.concat(urls, "\n"))
              or "")
          .. "\n\nstderr:\n" .. stderr_detail(stderr_text)
          .. "\n\nfix the cause, then: /issues file " .. manifest.id)
        rerender()
        return
      end
      manifest.status = "filed"
      manifest.last_error = nil
      manifest.last_error_ms = nil
      manifest.filed_ms = now_ms()
      manifest.filed_urls = urls
      save_manifest(manifest)
      deliver_response("issues",
        "filed " .. #urls .. " issue(s) on " .. manifest.repo .. "\n"
        .. table.concat(urls, "\n"), "filed")
      label_messages(manifest.source_liner_id, manifest.message_ids, "filed")
      rerender()
      info("filed " .. #urls .. " issue(s) on " .. manifest.repo)
    end)
  rerender()
  info("filing " .. (manifest.count or "?") .. " issue(s) on " .. manifest.repo .. "…")
end

-------------------------------------------------------------------------------
-- Rendering into the feed buffer
-------------------------------------------------------------------------------

-- Left-pad every line; the panes themselves have no padding concept.
local function pad_lines(text)
  return PAD .. text:gsub("\n", "\n" .. PAD)
end

function feed_text()
  -- Clamp entry rules to the pane so they never softwrap into ragged stubs.
  local w = rule_width()
  pcall(function()
    local pw = feed_pane:GetView().Width - 1 - 2 * #PAD
    if pw > 0 and pw < w then w = pw end
  end)
  -- Second return: the entry index browse mode navigates by.
  return olwb_render.render_feed(active_liner, state, {
    fmt_time = fmt_time,
    rule_width = w,
    filter = state.filter,
    include_direct = true,
    selected = selected,
  })
end

-- The whole compose buffer as one string ("" when unavailable).
function compose_input()
  local out = ""
  pcall(function()
    local buf = compose_pane.Buf
    if buf.Path ~= COMPOSE_PATH then return end
    local parts = {}
    for i = 0, buf:LinesNum() - 1 do parts[#parts + 1] = buf:Line(i) end
    out = table.concat(parts, "\n")
  end)
  return out
end

function liner_names()
  local liners = list_liners()
  -- A name shared by several liners is ambiguous for /open; offer those (and
  -- unnamed liners) as ids instead.
  local counts = {}
  for _, l in ipairs(liners) do
    if l.name ~= "" then counts[l.name] = (counts[l.name] or 0) + 1 end
  end
  local out = {}
  for _, l in ipairs(liners) do
    if l.name ~= "" and counts[l.name] == 1 then
      out[#out + 1] = l.name
    else
      out[#out + 1] = l.id
    end
  end
  return out
end

-- Dynamic completion pools handed to olwb_cmd.candidates everywhere.
function cmd_extra()
  local dests = {}
  for _, d in ipairs(state and state.destinations or {}) do
    dests[#dests + 1] = d.name
  end
  local repos = {}
  for _, r in ipairs(state and state.issue_repos or {}) do
    repos[#repos + 1] = r.alias
  end
  return { liners = liner_names(), dests = dests, repos = repos }
end

-- The /? help menu, filtered live by the verb being typed. Shown in the feed
-- pane whenever the compose line holds a slash command (or /? toggled it on).
-- Layout is width-aware: a description goes next to its usage only when the
-- whole line fits, otherwise on its own indented line — never split mid-way.
function menu_text(input)
  local verb = (input or ""):gsub("^%s*/", ""):match("^(%S*)") or ""
  if verb == "?" then verb = "" end

  local width = 76
  pcall(function() width = feed_pane:GetView().Width - 2 * #PAD - 2 end)
  if width < 24 then width = 24 end

  -- While Tab-cycling top-level verbs, show the full list and mark the
  -- selected verb's rows inline instead of a separate candidate block.
  local selverb = nil
  if cycle and cycle.kept == "/" then
    selverb = cycle.cands[cycle.idx]
    verb = ""
  end

  local shown = {}
  for _, e in ipairs(olwb_cmd.help_entries) do
    local v = e[1]:match("^/(%a+)") or ""
    if verb == "" or v:sub(1, #verb) == verb then
      shown[#shown + 1] = { usage = e[1], desc = e[2], verb = v }
    end
  end

  local lines = {}
  lines[#lines + 1] = "commands — Tab cycles, Enter runs"
  lines[#lines + 1] = ""
  if #shown == 0 then
    lines[#lines + 1] = "  no command matches '/" .. verb .. "'"
  end
  -- All entries share one shape: aligned two-column when every row fits the
  -- pane, otherwise usage + indented description on the next line. Uniform
  -- either way — no per-row mixing, no mid-text splits.
  local maxu, maxd = 0, 0
  for _, e in ipairs(shown) do
    if #e.usage > maxu then maxu = #e.usage end
    if #e.desc > maxd then maxd = #e.desc end
  end
  local ucol = maxu + 3
  local inline = (2 + ucol + maxd) <= width
  for _, e in ipairs(shown) do
    local mark = (selverb == e.verb) and "▶ " or "  "
    if inline then
      lines[#lines + 1] = mark .. e.usage
        .. string.rep(" ", ucol - #e.usage) .. e.desc
    else
      lines[#lines + 1] = mark .. e.usage
      lines[#lines + 1] = "      " .. e.desc
    end
  end

  -- Argument options (subverbs, liner names), marked while Tab-cycling.
  -- Liner rows carry registry metadata; Space expands the selected one into
  -- a detail card (closed again by Space, Tab, or Up/Down).
  local cands, sel, kept
  if cycle and cycle.kept ~= "/" then
    cands, sel, kept = cycle.cands, cycle.idx, cycle.kept
  elseif not cycle then
    local c, _, k = olwb_cmd.candidates(input or "", cmd_extra())
    if k ~= "/" then cands, kept = c, k end
  end
  if cands and #cands > 0 then
    lines[#lines + 1] = ""
    local isliner = (kept == "/open ")
    for i, c in ipairs(cands) do
      local disp = c
      if isliner then
        local meta = liner_registry_meta(c)
        if meta then
          disp = c .. "  ·  " .. fmt_time(meta.updated or 0)
            .. "  ·  " .. (meta.count or 0)
            .. " msg" .. ((meta.count or 0) == 1 and "" or "s")
        end
      end
      lines[#lines + 1] = (i == sel) and ("  ▶ " .. disp) or ("    " .. disp)
      if isliner and cycle and cycle.detail and i == sel then
        for _, dl in ipairs(liner_detail_lines(c)) do
          lines[#lines + 1] = dl
        end
      end
    end
    if isliner and cycle and not cycle.detail then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "  (Space shows details)"
    end
  end
  return table.concat(lines, "\n")
end

-- Registry entry for a candidate as offered by liner_names() (name or id).
function liner_registry_meta(key)
  if state.liners[key] then return state.liners[key], key end
  for id, meta in pairs(state.liners) do
    if meta.name == key then return meta, id end
  end
  return nil, nil
end

-- Detail card for the Space toggle: loads the liner file for description,
-- labels, and counts the registry doesn't carry.
function liner_detail_lines(key)
  local meta, id = liner_registry_meta(key)
  if not id then return { "      (no details)" } end
  local out = {}
  local function add(k, v)
    if v and v ~= "" then
      out[#out + 1] = string.format("      %-13s %s", k, v)
    end
  end
  local liner = load_liner(id)
  add("id:", id)
  if liner then
    add("name:", liner.metadata.name)
    add("description:", liner.metadata.description)
    local ls = {}
    for _, l in ipairs(liner.metadata.labels or {}) do ls[#ls + 1] = "#" .. l end
    add("labels:", table.concat(ls, " "))
    local msgs = 0
    for _, s in ipairs(liner.sessions) do msgs = msgs + #s.messages end
    add("content:", msgs .. " message" .. (msgs == 1 and "" or "s")
      .. " in " .. #liner.sessions .. " session" .. (#liner.sessions == 1 and "" or "s"))
  elseif meta then
    add("name:", meta.name)
  end
  if meta then add("updated:", fmt_time(meta.updated or 0)) end
  return out
end

-- One-line shortcut reference, trimmed to the pane width segment by segment.
-- Browse mode swaps in its own key list.
local function shortcuts_line()
  local width = 76
  pcall(function() width = bar_pane:GetView().Width - 2 * #PAD end)
  local segs
  if browsing then
    segs = {
      "↑↓ jump", "Space select", "a all", "Enter send", "Shift-Tab back",
    }
  else
    segs = {
      "Enter submits", "/? commands", "Tab/↑↓ cycle",
      "Space details", "Alt-m input",
    }
  end
  local out = segs[1]
  for i = 2, #segs do
    local trial = out .. "  ·  " .. segs[i]
    if #trial > width then break end
    out = trial
  end
  return out
end

function bar_text()
  local ln = "(none — /new or /open)"
  local sn = "(none)"
  if active_liner then
    ln = active_liner.metadata.name
    if ln == "" then ln = olwb_render.short_id(active_liner.id) end
    local s = olwb_model.active_session(active_liner, state)
    if s then
      sn = s.metadata.name
      if sn == "" then sn = olwb_render.short_id(s.id) end
    end
  end
  local extras = {}
  if state and state.activeLabels and #state.activeLabels > 0 then
    extras[#extras + 1] = "+" .. #state.activeLabels .. " label"
      .. (#state.activeLabels == 1 and "" or "s")
  end
  if state and state.filter then extras[#extras + 1] = "filtered" end
  local selcount = 0
  for _ in pairs(selected) do selcount = selcount + 1 end
  if selcount > 0 then extras[#extras + 1] = selcount .. " selected" end
  for name in pairs(pending_jobs) do
    local pl = progress_line(name)
    if pl then extras[#extras + 1] = pl end
  end
  if state and state.unread then
    for lid, n in pairs(state.unread) do
      if type(n) == "number" and n > 0 then
        local meta = state.liners[lid]
        local nm = (meta and meta.name ~= "" and meta.name)
          or olwb_render.short_id(lid)
        extras[#extras + 1] = nm .. ": " .. n .. " new"
      end
    end
  end
  if #extras > 0 then ln = ln .. "  ·  " .. table.concat(extras, " · ") end
  return "\n" .. pad_lines(shortcuts_line()
    .. "\n\nLiner: " .. ln .. "\nSession: " .. sn)
end

-- The /set overlay: every olwb option with its current value.
local function options_text()
  local width = 76
  pcall(function() width = feed_pane:GetView().Width - 2 * #PAD - 2 end)
  if width < 24 then width = 24 end
  local rows = {}
  local maxu, maxd = 0, 0
  for _, o in ipairs(OPTION_DOCS) do
    -- termcmd lives in state.json (it's per-datadir), not micro settings.
    local v = o[1] == "termcmd"
      and (state and state.termcmd or "(auto-detected on first tui send)")
      or tostring(opt(o[1]))
    local u = o[1] .. " = " .. v
    rows[#rows + 1] = { u = u, d = o[2] }
    if #u > maxu then maxu = #u end
    if #o[2] > maxd then maxd = #o[2] end
  end
  local ucol = maxu + 3
  local inline = (2 + ucol + maxd) <= width
  local lines = {}
  lines[#lines + 1] = "olwb options — /set <name> <value> to change"
  lines[#lines + 1] = ""
  for _, r in ipairs(rows) do
    if inline then
      lines[#lines + 1] = "  " .. r.u .. string.rep(" ", ucol - #r.u) .. r.d
    else
      lines[#lines + 1] = "  " .. r.u
      lines[#lines + 1] = "      " .. r.d
    end
  end
  return table.concat(lines, "\n")
end

-- The /dest overlay: configured destinations and how to manage them.
local function dests_text()
  local lines = {
    "destinations — /send <name> sends the selection (or current scope)", "",
  }
  local ds = (state and state.destinations) or {}
  if #ds == 0 then
    lines[#lines + 1] = "  (none — /dest add <name> <shell command…>)"
  end
  local maxn = 0
  for _, d in ipairs(ds) do if #d.name > maxn then maxn = #d.name end end
  for _, d in ipairs(ds) do
    local bits = { d.cmd }
    if d.kind then bits[#bits + 1] = "kind=" .. d.kind end
    if d.into and d.into ~= "" then bits[#bits + 1] = "→ " .. d.into end
    lines[#lines + 1] = "  " .. d.name
      .. string.rep(" ", maxn - #d.name + 3) .. table.concat(bits, "  ·  ")
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "  /dest add <name> <cmd…> · rm <name> · into <name> <liner|->"
  lines[#lines + 1] = "  /dest kind <name> <claude|codex|opencode|-> · session list|clear <name>"
  return table.concat(lines, "\n")
end

-- The /dest session list overlay: stored dest|liner → session mappings.
local function sessions_text()
  local lines = {
    "destination sessions — /dest session clear <name> forgets one", "",
  }
  local any = false
  for key, sid in pairs((state and state.dest_sessions) or {}) do
    any = true
    local dname, lid = key:match("^(.-)|(.*)$")
    local meta = lid and state.liners[lid]
    local lname = (meta and meta.name ~= "" and meta.name)
      or olwb_render.short_id(lid or "")
    lines[#lines + 1] = string.format("  %-14s %-18s %s",
      dname or key, lname, tostring(sid))
  end
  if not any then lines[#lines + 1] = "  (no stored sessions yet)" end
  return table.concat(lines, "\n")
end

-- The /issues list overlay: drafts from the manifest dir, newest first, with
-- the in-flight job (if any) on top and each draft's last failure beneath it.
local function issues_list_text()
  local lines = {
    "issue drafts — review the script, then /issues file <id|latest>", "",
  }
  local pl = progress_line("issues")
  if pl then
    lines[#lines + 1] = "  " .. pl
    lines[#lines + 1] = ""
  end
  local ms = list_issue_manifests()
  if #ms == 0 and not pl then
    lines[#lines + 1] = "  (none — select messages, then /issues draft [<repo>])"
  end
  for _, m in ipairs(ms) do
    local status = tostring(m.status)
    if m.status == "filed" and m.filed_urls then
      status = "filed:" .. #m.filed_urls
    end
    lines[#lines + 1] = string.format("  %-16s %-24s %2d issue(s)  %-8s %s",
      tostring(m.id), tostring(m.repo), m.count or 0, status,
      tostring(m.script))
    if m.status ~= "filed" and m.last_error then
      lines[#lines + 1] = "      ⚠ " .. tostring(m.last_error)
        .. (m.filed_urls
            and (" — " .. #m.filed_urls .. " already filed; a re-run double-files those")
            or "")
      if m.last_error_ms then
        lines[#lines] = lines[#lines] .. "  (" .. fmt_time(m.last_error_ms) .. ")"
      end
    end
  end
  return table.concat(lines, "\n")
end

-- Replace a scratch buffer's entire content.
local function set_buffer_text(buf, text)
  local readonly = buf.Type.Readonly
  buf.Type.Readonly = false
  local n = buf:LinesNum()
  local last = buf:Line(n - 1)
  buf:Remove(buffer.Loc(0, 0), buffer.Loc(util.CharacterCountInString(last), n - 1))
  buf:Insert(buffer.Loc(0, 0), text)
  buf.Type.Readonly = readonly
end

function rerender()
  if not ui_open or not feed_pane then return end
  pcall(function()
    local buf = feed_pane.Buf
    if not buf or buf.Path ~= FEED_PATH then return end

    local input = compose_input()
    local text
    feed_index = nil
    if olwb_cmd.is_command(input) then
      text = menu_text(input)   -- live command menu while typing /…
    elseif overlay_kind == "options" then
      text = options_text()
    elseif overlay_kind == "help" then
      text = menu_text("")
    elseif overlay_kind == "dests" then
      text = dests_text()
    elseif overlay_kind == "sessions" then
      text = sessions_text()
    elseif overlay_kind == "issues" then
      text = issues_list_text()
    else
      text, feed_index = feed_text()
    end
    set_buffer_text(buf, pad_lines(text))

    -- While browsing, restore the cursor to the current entry (so Space
    -- doesn't yank the view); otherwise pin the view to the top, where new
    -- entries appear (right under the compose line).
    if browsing and feed_index and #feed_index > 0 then
      if browse_pos > #feed_index then browse_pos = #feed_index end
      if browse_pos < 1 then browse_pos = 1 end
      feed_pane.Cursor:GotoLoc(buffer.Loc(0, feed_index[browse_pos].start))
    else
      feed_pane.Cursor:GotoLoc(buffer.Loc(0, 0))
    end
    pcall(function() feed_pane:Relocate() end)
  end)
  pcall(function()
    local buf = bar_pane and bar_pane.Buf
    if not buf or buf.Path ~= BAR_PATH then return end
    set_buffer_text(buf, bar_text())
    -- Park the cursor at the origin so the bar never scrolls horizontally
    -- (Insert leaves it at the end of the text, dragging the view along).
    bar_pane.Cursor:GotoLoc(buffer.Loc(0, 0))
    pcall(function() bar_pane:Relocate() end)
  end)
end

-------------------------------------------------------------------------------
-- Command context (bridges pure cmd.lua handlers to this file's helpers)
-------------------------------------------------------------------------------

function build_ctx()
  return {
    model = olwb_model,
    render = olwb_render,
    state = state,
    now = now_ms,
    new_id = new_id,
    info = info,
    error = err,
    get_active_liner = function() return active_liner end,
    require_active_liner = function()
      if not active_liner then err("no active liner (use /new)"); return nil end
      return active_liner
    end,
    create_liner = create_liner,
    open_liner = open_liner,
    close_liner = close_liner,
    save_active = save_active,
    save_state = function() olwb_store.save_state(state) end,
    start_session = start_session,
    end_session = end_session,
    submit_message = submit_message,
    rerender = rerender,
    set_filter = function(f) state.filter = f; olwb_store.save_state(state) end,
    clear_filter = function() state.filter = nil; olwb_store.save_state(state) end,
    export = do_export,
    list_liners = list_liners,
    open_help = open_help,
    show_options = function() show_options() end,
    set_option = function(n, v) return set_option(n, v) end,
    dest = olwb_dest,
    send_to = function(name, mode) send_to(name, mode) end,
    show_dests = function() show_overlay("dests") end,
    show_sessions = function() show_overlay("sessions") end,
    show_issues_list = function() show_overlay("issues") end,
    issues_draft = function(alias) issues_draft(alias) end,
    issues_file = function(id) issues_file(id) end,
  }
end

-------------------------------------------------------------------------------
-- UI construction
-------------------------------------------------------------------------------

local function make_scratch(text, path)
  local b = buffer.NewBuffer(text, path)
  b.Type.Scratch = true
  return b
end

-- Focus a pane for real: SetActive(true) only flags the pane; the tab keeps
-- routing input to its own active index until told otherwise.
local function focus(pane)
  if not pane then return end
  pcall(function()
    local t = micro.CurTab()
    for i = 1, #t.Panes do
      if t.Panes[i]:ID() == pane:ID() then
        t:SetActive(i - 1)
        break
      end
    end
  end)
  pcall(function() pane:SetActive(true) end)
end

-- /? and /help: toggle the in-feed command menu (no extra panes, nothing to
-- close — it clears as soon as you start typing a normal line).
function open_help()
  overlay_kind = overlay_kind ~= "help" and "help" or nil
  rerender()
end

-- /set with no value (and /dest, /dest session list, /issues list): show an
-- overlay in the feed pane the same way.
function show_options()
  overlay_kind = "options"
  rerender()
end

function show_overlay(kind)
  overlay_kind = kind
  rerender()
end

-- /set <name> <value>: validate, hand to micro's option machinery (which
-- parses per type and persists to settings.json), and apply live.
function set_option(name, value)
  local known = false
  for _, o in ipairs(OPTION_DOCS) do
    if o[1] == name then known = true break end
  end
  if not known then
    return false, "unknown option '" .. tostring(name) .. "' (bare /set lists them)"
  end
  if name == "termcmd" then
    -- Lives in state.json, not micro's settings machinery; strip the quotes
    -- the usage line suggests around multi-word commands.
    state.termcmd = tostring(value):gsub('^"(.*)"$', "%1")
    olwb_store.save_state(state)
    rerender()
    return true
  end
  local ok, e = pcall(function()
    local err = config.SetGlobalOption("olwb." .. name, value)
    if err ~= nil then error(tostring(err)) end
  end)
  if not ok then
    return false, "could not set olwb." .. name .. ": " .. tostring(e)
  end
  if name == "composesize" then sync_compose_size(); layout_panes() end
  if name == "theme" and opt("theme") == true then
    pcall(function() config.SetGlobalOption("colorscheme", "olwb") end)
  end
  rerender()
  return true
end

-- Size the stack: title (fixed), compose (auto-grows), bar (fixed 2 rows),
-- feed soaks up the rest. Resizing a non-last split sets its own height, so
-- everything but the bar is set explicitly and the bar keeps the remainder.
function layout_panes()
  pcall(function()
    local function h(p) return p:GetView().Height end
    local total = h(title_pane) + h(compose_pane) + h(feed_pane) + h(bar_pane)
    local ct = compose_rows + 1 -- +1: micro's divider row
    local ft = total - TITLE_ROWS - ct - BAR_ROWS
    if ft < 1 then ft = 1 end
    -- micro's ResizeSplit only trades rows with the immediate next sibling
    -- and refuses when the pair can't cover the request, so surplus has to be
    -- walked up the stack: bar → feed → compose → title. Two passes converge
    -- even when a terminal resize crushed several panes at once.
    for _ = 1, 2 do
      feed_pane:ResizePane(h(feed_pane) + h(bar_pane) - BAR_ROWS)
      compose_pane:ResizePane(total - h(title_pane) - ft - BAR_ROWS)
      title_pane:ResizePane(TITLE_ROWS)
    end
  end)
end

-- Grow (or shrink) the compose pane so wrapped or pasted input stays fully
-- visible: rows = display lines the text needs, capped at MAX_COMPOSE_ROWS.
function sync_compose_size()
  pcall(function()
    local buf = compose_pane.Buf
    if buf.Path ~= COMPOSE_PATH then return end
    local w = compose_pane:GetView().Width
    if w < 10 then w = 80 end
    local minrows = math.floor(tonumber(opt("composesize")) or 1)
    if minrows < 1 then minrows = 1 end
    local rows = 0
    for i = 0, buf:LinesNum() - 1 do
      local n = util.CharacterCountInString(buf:Line(i))
      local r = math.ceil((n + 1) / w)
      if r < 1 then r = 1 end
      rows = rows + r
    end
    if rows < minrows then rows = minrows end
    if rows > MAX_COMPOSE_ROWS then rows = MAX_COMPOSE_ROWS end
    if rows == compose_rows then return end
    compose_rows = rows
    layout_panes()
    -- The view may have scrolled while the pane was still small; with the new
    -- height the whole input fits, so snap the scroll back to the top.
    pcall(function()
      local v = compose_pane:GetView()
      v.StartLine.Line = 0
      v.StartLine.Row = 0
    end)
    pcall(function() compose_pane:Relocate() end)
  end)
end

-- Nothing is auto-loaded on open; instead the compose line is pre-populated
-- with the command that would resume the most recent liner, ready for Enter
-- (or for clearing and typing something else).
local function prefill_resume()
  if active_liner then return end
  local key = nil
  if state.activeLinerId and state.liners[state.activeLinerId] then
    local meta = state.liners[state.activeLinerId]
    key = meta.name ~= "" and meta.name or state.activeLinerId
  else
    local recent = list_liners()
    if recent[1] then
      key = recent[1].name ~= "" and recent[1].name or recent[1].id
    end
  end
  if not key then return end
  pcall(function()
    local buf = compose_pane.Buf
    set_buffer_text(buf, "/open " .. key)
    compose_pane.Cursor:GotoLoc(
      buffer.Loc(util.CharacterCountInString(buf:Line(0)), 0))
  end)
end

function open_olwb()
  -- Already open? Just focus the compose line.
  if ui_open and feed_pane then
    local ok, path = pcall(function() return feed_pane.Buf.Path end)
    if ok and path == FEED_PATH then
      focus(compose_pane)
      return
    end
  end

  -- Subtle split dividers: continuous box-drawing lines in the colorscheme's
  -- divider colours on the window background, instead of reverse-video dashes.
  pcall(function() config.SetGlobalOption("divreverse", "false") end)
  pcall(function() config.SetGlobalOption("divchars", "│─") end)

  -- Layout, top to bottom: the olwb title line, the compose line (the "one
  -- line", auto-growing), the feed (newest entry first, right under the
  -- input), and the two-row Liner/Session bar.
  local tbuf = make_scratch(
    "\n" .. PAD .. "olwb — one line with benefits\n", TITLE_PATH)
  tbuf:SetOption("ruler", "false")
  tbuf:SetOption("scrollbar", "false")
  tbuf:SetOption("statusline", "false")
  tbuf:SetOption("cursorline", "false")
  tbuf:SetOption("filetype", "olwbui")
  tbuf.Type.Readonly = true

  local cbuf = make_scratch("", COMPOSE_PATH)
  cbuf:SetOption("softwrap", "true")
  cbuf:SetOption("ruler", "false")
  cbuf:SetOption("scrollbar", "false")
  cbuf:SetOption("statusline", "false")
  cbuf:SetOption("cursorline", "true") -- highlight the input row
  cbuf:SetOption("filetype", "olwb")

  local fbuf = make_scratch("", FEED_PATH)
  fbuf:SetOption("softwrap", "true")
  fbuf:SetOption("wordwrap", "true") -- wrap at word boundaries, never mid-word
  fbuf:SetOption("ruler", "false")
  fbuf:SetOption("scrollbar", "true") -- indicator when content overflows
  fbuf:SetOption("statusline", "false")
  fbuf:SetOption("cursorline", "false")
  fbuf:SetOption("filetype", "olwb")
  fbuf.Type.Readonly = true

  local bbuf = make_scratch(bar_text(), BAR_PATH)
  bbuf:SetOption("softwrap", "false") -- truncate, never push Liner/Session out
  bbuf:SetOption("ruler", "false")
  bbuf:SetOption("scrollbar", "false")
  bbuf:SetOption("statusline", "false")
  bbuf:SetOption("cursorline", "false")
  bbuf:SetOption("filetype", "olwbui")
  bbuf.Type.Readonly = true

  local base = micro.CurPane()
  -- Never clobber unsaved work: replace only an unmodified pane.
  local modified = false
  pcall(function() modified = base.Buf:Modified() end)
  if modified then
    title_pane = base:HSplitBuf(tbuf)
  else
    base:OpenBuffer(tbuf)
    title_pane = base
  end
  compose_pane = title_pane:HSplitBuf(cbuf)
  feed_pane = compose_pane:HSplitBuf(fbuf)
  bar_pane = feed_pane:HSplitBuf(bbuf)

  compose_rows = math.max(1, math.floor(tonumber(opt("composesize")) or 1))
  overlay_kind = nil
  layout_panes()
  focus(compose_pane)
  ui_open = true

  prefill_resume()
  last_input = compose_input()
  rerender()
end

-------------------------------------------------------------------------------
-- Native >olwb command + operations
-------------------------------------------------------------------------------

local function to_table(args)
  local t = {}
  if args == nil then return t end
  local ok, n = pcall(function() return #args end)
  if ok and n then
    for i = 1, n do t[i] = args[i] end
  end
  return t
end

function do_migrate(src)
  if not src or src == "" then
    err("usage: >olwb migrate <electron-userData-dir>")
    return
  end
  local function readjson(name)
    local s = olwb_store.read_file(src .. "/" .. name)
    if not s then return nil end
    local ok, v = pcall(olwb_json.decode, s)
    if ok then return v end
    return nil
  end
  local flat = {
    liners = readjson("liners.json") or {},
    sessions = readjson("sessions.json") or {},
    messages = readjson("messages.json") or {},
  }
  local result = olwb_migrate.reconstruct(flat, { now = now_ms(), new_id = new_id })
  local written = 0
  for _, liner in ipairs(result.liners) do
    if not liner.id or liner.id == "" then liner.id = new_id() end
    if not olwb_store.exists(olwb_store.liner_path(liner.id)) then
      olwb_store.save_liner(liner)
      persist_registry(liner)
      written = written + 1
    end
  end
  olwb_store.save_state(state)
  info(string.format("migrated %d liners / %d msgs / %d orphans; wrote %d new file(s)",
    result.stats.liners, result.stats.messages, result.stats.orphans, written))
end

function rescan()
  local ids = olwb_store.list_liner_ids()
  local n = 0
  for _, id in ipairs(ids) do
    local liner = olwb_store.load_liner(id)
    if liner then persist_registry(liner); n = n + 1 end
  end
  olwb_store.save_state(state)
  info("rescanned " .. n .. " liner file(s)")
end

function selftest()
  local results = {}
  local function check(name, cond)
    results[#results + 1] = (cond and "PASS  " or "FAIL  ") .. name
  end

  local id1 = olwb_model.new_id(1000, function() return 0 end)
  local id2 = olwb_model.new_id(2000, function() return 0 end)
  check("id is time-sortable", id1 < id2)

  local liner = olwb_model.new_liner("selftest", "self test", {})
  liner.id = "olwb-selftest-tmp"
  local s = olwb_model.new_session(new_id(), now_ms())
  liner.sessions[1] = s
  s.messages[1] = olwb_model.new_message(new_id(), "héllo ✓ unicode", now_ms(), { "x" })
  s.messages[2] = olwb_model.new_message(new_id(), "second", now_ms() + 1, {})

  check("save liner", olwb_store.save_liner(liner) == true)
  local loaded = olwb_store.load_liner(liner.id)
  check("load liner", loaded ~= nil)
  check("unicode round-trip",
    loaded and loaded.sessions[1].messages[1].content == "héllo ✓ unicode")

  local entries = olwb_model.flatten_desc(loaded, {})
  check("descending order", entries[1] and entries[1].message.content == "second")

  local labels = olwb_model.resolve_labels(loaded, loaded.sessions[1], loaded.sessions[1].messages[1])
  check("label resolution", labels[1] == "x")

  olwb_store.remove_liner(liner.id)
  check("cleanup", not olwb_store.exists(olwb_store.liner_path(liner.id)))

  local out = "olwb selftest (datadir: " .. tostring(olwb_store.dir) .. ")\n\n"
    .. table.concat(results, "\n") .. "\n"
  local hb = make_scratch(out, "olwb://selftest")
  hb.Type.Readonly = true
  micro.CurPane():HSplitBuf(hb)
end

-- >olwb [verb] [args...] : bare form opens the UI; migrate/selftest/rescan are
-- native; anything else is routed through the slash-command dispatcher.
function olwb_command(bp, args)
  local a = to_table(args)
  local verb = a[1]
  if not verb then open_olwb(); return end
  if verb == "migrate" then do_migrate(a[2]); return end
  if verb == "selftest" then selftest(); return end
  if verb == "rescan" then rescan(); return end
  if verb == "open" and not a[2] then open_olwb(); return end
  if not ui_open then open_olwb() end
  olwb_cmd.dispatch(build_ctx(), "/" .. table.concat(a, " "))
end

-------------------------------------------------------------------------------
-- micro callbacks
-------------------------------------------------------------------------------

-- Intercept Enter in the compose pane: submit a message or run a command,
-- keeping the compose buffer to a single (cleared) line.
function preInsertNewline(bp)
  if not bp or not bp.Buf then return true end
  local path = bp.Buf.Path
  if path == FEED_PATH or path == TITLE_PATH or path == BAR_PATH then
    -- Enter while browsing opens the destination picker: pre-fill "/send "
    -- and start the Tab-cycle so the candidates appear immediately. Falls
    -- back to a plain return-to-line when there is nothing to send with.
    local pick = path == FEED_PATH and browsing
      and feed_index and #feed_index > 0
      and state.destinations and #state.destinations > 0
    if path == FEED_PATH then reset_feed_scroll() end
    focus(compose_pane) -- Enter in the chrome just returns to the one line
    if pick then
      pcall(function()
        local buf = compose_pane.Buf
        set_buffer_text(buf, "/send ")
        compose_pane.Cursor:GotoLoc(
          buffer.Loc(util.CharacterCountInString(buf:Line(0)), 0))
      end)
      cycle_step(compose_pane, 1)
    end
    return false
  end
  if path ~= COMPOSE_PATH then
    return true -- not ours; let micro insert the newline
  end
  local n = bp.Buf:LinesNum()
  local parts = {}
  for i = 0, n - 1 do parts[#parts + 1] = bp.Buf:Line(i) end
  local text = table.concat(parts, "\n")

  local last = bp.Buf:Line(n - 1)
  bp.Buf:Remove(buffer.Loc(0, 0), buffer.Loc(util.CharacterCountInString(last), n - 1))
  bp.Cursor:GotoLoc(buffer.Loc(0, 0))

  overlay_kind = nil
  cycle = nil
  if olwb_cmd.is_command(text) then
    olwb_cmd.dispatch(build_ctx(), text)
  else
    submit_message(text)
  end
  last_input = ""
  sync_compose_size()
  rerender()
  return false -- cancel the newline; the compose line is cleared instead
end

-- Tab / Shift-Tab in the compose line cycle through the completion options
-- (verbs, subverbs, liner/destination/repo names); the menu marks the
-- selection and the line is filled in — Enter runs it. Typing resets the
-- cycle. (Bare `function`: assigns the forward-declared local.)
function cycle_step(bp, dir)
  if not cycle then
    local cands, _, kept = olwb_cmd.candidates(compose_input(), cmd_extra())
    if #cands == 0 then return end
    cycle = { cands = cands, kept = kept, idx = 0 }
  end
  cycle.idx = cycle.idx + dir
  if cycle.idx > #cycle.cands then cycle.idx = 1 end
  if cycle.idx < 1 then cycle.idx = #cycle.cands end
  cycle.detail = false -- moving the selection closes the detail card
  local filled = cycle.kept .. cycle.cands[cycle.idx]
  set_buffer_text(bp.Buf, filled)
  bp.Cursor:GotoLoc(buffer.Loc(util.CharacterCountInString(bp.Buf:Line(0)), 0))
  last_input = filled -- our own edit: keep onAnyEvent from resetting the cycle
  sync_compose_size()
  rerender()
end

-- Leaving the feed puts its scroll position back at the top (newest entry)
-- and ends browse mode. The selection deliberately survives (so /send works
-- from the one line); it clears on a successful send or via `a`.
function reset_feed_scroll()
  local was_browsing = browsing
  browsing = false
  pcall(function() feed_pane.Buf:SetOption("cursorline", "false") end)
  pcall(function()
    feed_pane.Cursor:GotoLoc(buffer.Loc(0, 0))
    local v = feed_pane:GetView()
    v.StartLine.Line = 0
    v.StartLine.Row = 0
  end)
  if was_browsing then rerender() end -- bar swaps its shortcut line back
end

function preInsertTab(bp)
  if not bp or not bp.Buf then return true end
  if bp.Buf.Path == FEED_PATH then
    reset_feed_scroll()
    focus(compose_pane)
    return false
  end
  if bp.Buf.Path ~= COMPOSE_PATH then return true end
  if not olwb_cmd.is_command(compose_input()) then return true end
  cycle_step(bp, 1)
  return false
end

-- Enter the feed in browse mode: message-granular navigation with the
-- current entry's first line highlighted. Plain focus when the feed is empty
-- or an overlay is showing (feed_index is nil then).
local function enter_browse()
  if overlay_kind then -- browsing is about the feed; dismiss any overlay
    overlay_kind = nil
    rerender()
  end
  focus(feed_pane)
  if not feed_index or #feed_index == 0 then return end
  browsing = true
  browse_pos = 1
  pcall(function() feed_pane.Buf:SetOption("cursorline", "true") end)
  pcall(function()
    feed_pane.Cursor:GotoLoc(buffer.Loc(0, feed_index[browse_pos].start))
    feed_pane:Relocate()
  end)
  rerender() -- bar swaps to the browse shortcut line
end

-- Move the browse cursor entry-by-entry (not line-by-line).
local function browse_move(dir)
  if not feed_index or #feed_index == 0 then return end
  browse_pos = browse_pos + dir
  if browse_pos < 1 then browse_pos = 1 end
  if browse_pos > #feed_index then browse_pos = #feed_index end
  pcall(function()
    feed_pane.Cursor:GotoLoc(buffer.Loc(0, feed_index[browse_pos].start))
    feed_pane:Relocate()
  end)
end

-- Shift-Tab: cycle backwards while a /command is typed; otherwise toggle
-- between the one line and the feed's browse mode (leaving snaps the scroll
-- back to the top).
function preOutdentSelection(bp)
  if not bp or not bp.Buf then return true end
  local p = bp.Buf.Path
  if p == FEED_PATH then
    reset_feed_scroll()
    focus(compose_pane)
    return false
  end
  if p ~= COMPOSE_PATH then return true end
  if olwb_cmd.is_command(compose_input()) then
    cycle_step(bp, -1)
  else
    enter_browse()
  end
  return false
end

-- Up/Down walk the options while a slash command is being typed, and jump
-- message-to-message while browsing the feed.
function preCursorUp(bp)
  if not bp or not bp.Buf then return true end
  if bp.Buf.Path == FEED_PATH then
    if browsing and feed_index and #feed_index > 0 then
      browse_move(-1)
      return false
    end
    return true
  end
  if bp.Buf.Path ~= COMPOSE_PATH then return true end
  if not olwb_cmd.is_command(compose_input()) then return true end
  cycle_step(bp, -1)
  return false
end

function preCursorDown(bp)
  if not bp or not bp.Buf then return true end
  if bp.Buf.Path == FEED_PATH then
    if browsing and feed_index and #feed_index > 0 then
      browse_move(1)
      return false
    end
    return true
  end
  if bp.Buf.Path ~= COMPOSE_PATH then return true end
  if not olwb_cmd.is_command(compose_input()) then return true end
  cycle_step(bp, 1)
  return false
end

-- Typed characters: Space toggles the detail card while cycling; typing in
-- any other olwb pane bounces focus (and the character) into the one line,
-- so a stray mouse click never strands the keyboard.
function preRune(bp, r)
  if not ui_open or not bp or not bp.Buf then return true end
  local p = bp.Buf.Path
  -- Browse-mode keys: Space toggles the entry under the cursor in the
  -- selection, `a` selects the whole scope (or clears it when everything is
  -- already selected). Any other rune falls through to the compose bounce.
  if p == FEED_PATH and browsing and feed_index and #feed_index > 0 then
    if r == " " then
      local row = feed_index[browse_pos]
      if row and row.id then
        selected[row.id] = not selected[row.id] and true or nil
        rerender()
      end
      return false
    elseif r == "a" then
      local all = true
      for _, row in ipairs(feed_index) do
        if not selected[row.id] then all = false break end
      end
      if all then
        selected = {}
      else
        for _, row in ipairs(feed_index) do selected[row.id] = true end
      end
      rerender()
      return false
    end
  end
  if p == FEED_PATH or p == TITLE_PATH or p == BAR_PATH then
    if p == FEED_PATH then reset_feed_scroll() end
    pcall(function()
      focus(compose_pane)
      local buf = compose_pane.Buf
      local n = buf:LinesNum()
      local eol = buffer.Loc(util.CharacterCountInString(buf:Line(n - 1)), n - 1)
      buf:Insert(eol, r)
      compose_pane.Cursor:GotoLoc(
        buffer.Loc(util.CharacterCountInString(buf:Line(buf:LinesNum() - 1)),
          buf:LinesNum() - 1))
    end)
    return false
  end
  -- Only while cycling liner candidates: elsewhere Space must type normally
  -- (e.g. right after Tab-selecting a verb that takes arguments).
  if p == COMPOSE_PATH and cycle and cycle.kept == "/open " and r == " " then
    cycle.detail = not cycle.detail
    rerender()
    return false
  end
  return true
end

-- Scroll only makes sense in the feed, and only when its content is taller
-- than the pane; the title, input, and bar are pinned.
local function scroll_guard(bp)
  if not bp or not bp.Buf then return true end
  local p = bp.Buf.Path
  if p == TITLE_PATH or p == COMPOSE_PATH or p == BAR_PATH then return false end
  if p == FEED_PATH then
    local ok, allow = pcall(function()
      return bp.Buf:LinesNum() > bp:GetView().Height - 1
    end)
    if ok then return allow end
  end
  return true
end
function preScrollUp(bp) return scroll_guard(bp) end
function preScrollDown(bp) return scroll_guard(bp) end

-- Fires after every event: re-assert the layout after a terminal resize
-- (micro rescales splits proportionally, crushing the fixed-row panes),
-- auto-grow the compose line, and refresh the live menu as input changes.
local last_dims
function onAnyEvent()
  drain_jobs() -- safety net for job completions (see start_job)
  if not ui_open or not compose_pane then return end
  pcall(function()
    if compose_pane.Buf.Path ~= COMPOSE_PATH then return end

    local h = 0
    for _, p in ipairs({ title_pane, compose_pane, feed_pane, bar_pane }) do
      h = h + p:GetView().Height
    end
    local dims = feed_pane:GetView().Width .. "x" .. h
    if dims ~= last_dims then
      last_dims = dims
      layout_panes()
      sync_compose_size()
      rerender() -- feed rules are clamped to the (new) pane width
    end

    local input = compose_input()
    if input == last_input then return end
    if input ~= "" then overlay_kind = nil end
    last_input = input
    cycle = nil -- the user typed; drop the Tab-cycle state
    sync_compose_size()
    rerender()
  end)
end

-- Statusline token: >set statusformatr "...$(olwb.statusinfo)..." to show it.
function statusinfo(b)
  local parts = {}
  if active_liner then
    local ln = active_liner.metadata and active_liner.metadata.name or ""
    if ln == "" then ln = olwb_render.short_id(active_liner.id) end
    parts[#parts + 1] = ln
    local s = olwb_model.active_session(active_liner, state)
    if s then
      local sn = s.metadata and s.metadata.name or ""
      if sn == "" then sn = olwb_render.short_id(s.id) end
      parts[#parts + 1] = "· " .. sn
    end
  else
    parts[#parts + 1] = "no liner"
  end
  if state and state.activeLabels and #state.activeLabels > 0 then
    parts[#parts + 1] = "+" .. #state.activeLabels
  end
  if state and state.filter then
    parts[#parts + 1] = "[filtered]"
  end
  return table.concat(parts, " ")
end

function key_open(bp) open_olwb(); return true end
function key_compose(bp)
  reset_feed_scroll()
  focus(compose_pane)
  return true
end

-- Alt-i: toggle active liner ↔ the default inbox liner (where destination
-- responses land), remembering where you came from so a second Alt-i
-- returns. Creates inbox on first use.
function key_inbox(bp)
  if not ui_open then open_olwb() end
  save_active()
  if active_liner and active_liner.metadata.name == "inbox" then
    if prev_liner_key and open_liner(prev_liner_key) then
      info("back to " .. (active_liner.metadata.name ~= ""
        and active_liner.metadata.name or olwb_render.short_id(active_liner.id)))
    end
  else
    prev_liner_key = active_liner and active_liner.id or nil
    if not open_liner("inbox") then create_liner("inbox", "") end
    info("inbox")
  end
  rerender()
  return true
end

-- Seed the destination presets once (only when the key is absent, so user
-- edits and removals stick). Clipboard tooling is probed at seed time.
local function seed_destinations()
  local clip = "wl-copy"
  local _, e = shell.ExecCommand("sh", "-c", "command -v wl-copy")
  if e ~= nil then
    local _, e2 = shell.ExecCommand("sh", "-c", "command -v xclip")
    if e2 == nil then clip = "xclip -selection clipboard" end
  end
  local prompt = "Summarize these notes: group brainstormed ideas, "
    .. "extract action items and open questions."
  return {
    { name = "claude", cmd = 'claude -p "' .. prompt .. '"',
      into = "inbox", kind = "claude" },
    { name = "codex", cmd = "codex exec", into = "inbox", kind = "codex" },
    { name = "opencode", cmd = 'opencode run "' .. prompt .. '"',
      into = "inbox", kind = "opencode" },
    { name = "leather", cmd = "leather ingest -kind olwb -source olwb",
      into = "" },
    { name = "clipboard", cmd = clip, into = "" },
    { name = "file",
      cmd = "cat >> " .. olwb_dest.shell_quote(olwb_store.dir .. "/outbox.md"),
      into = "" },
  }
end

function init()
  math.randomseed(now_ms())

  config.RegisterCommonOption("olwb", "datadir", "")
  config.RegisterCommonOption("olwb", "autostart", false)
  config.RegisterCommonOption("olwb", "timefmt", "%Y-%m-%d %H:%M:%S")
  config.RegisterCommonOption("olwb", "composesize", 1)
  config.RegisterCommonOption("olwb", "rulewidth", 48)
  config.RegisterCommonOption("olwb", "theme", false)

  olwb_store.setup(opt("datadir"))
  state = olwb_store.load_state()

  -- Benefits/issues state: backfill missing keys so callers can rely on
  -- shape; seed the destination presets only when the key is absent.
  if type(state.dest_sessions) ~= "table" then state.dest_sessions = {} end
  if type(state.unread) ~= "table" then state.unread = {} end
  if type(state.issue_repos) ~= "table" then state.issue_repos = {} end
  if state.issues_model_cmd == nil or state.issues_model_cmd == "" then
    state.issues_model_cmd = "claude -p"
  end
  if state.destinations == nil then
    state.destinations = seed_destinations()
    olwb_store.save_state(state)
  end

  -- Sweep job/payload files orphaned by a crash or kill (jobs never survive
  -- a micro restart).
  pcall(function()
    for _, pat in ipairs({ "/job-*", "/tmp-send-*", "/issues/tmp-*-prompt.md" }) do
      for _, p in ipairs(olwb_store.glob(olwb_store.dir .. pat)) do
        goos.Remove(p)
      end
    end
  end)

  config.AddRuntimeFileFromMemory(config.RTSyntax, "olwb.yaml", OLWB_SYNTAX)
  config.AddRuntimeFileFromMemory(config.RTSyntax, "olwbui.yaml", OLWB_UI_SYNTAX)
  config.AddRuntimeFileFromMemory(config.RTColorscheme, "olwb", OLWB_COLORSCHEME)
  config.AddRuntimeFileFromMemory(config.RTHelp, "olwb", OLWB_HELP)

  config.MakeCommand("olwb", olwb_command, config.NoComplete)

  micro.SetStatusInfoFn("olwb.statusinfo")

  -- Overridable keybinds (best-effort; failures are non-fatal).
  pcall(function() config.TryBindKey("Alt-o", "lua:olwb.key_open", false) end)
  pcall(function() config.TryBindKey("Alt-m", "lua:olwb.key_compose", false) end)
  pcall(function() config.TryBindKey("Alt-i", "lua:olwb.key_inbox", false) end)

  if opt("theme") == true then
    pcall(function() config.SetGlobalOption("colorscheme", "olwb") end)
  end

  if opt("autostart") == true then
    local bp = micro.CurPane()
    local emptyish = false
    pcall(function()
      emptyish = bp and bp.Buf and bp.Buf.Path == "" and not bp.Buf:Modified()
    end)
    if emptyish then open_olwb() end
  end
end

function deinit()
  if state then olwb_store.save_state(state) end
end
