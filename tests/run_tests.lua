-- run_tests.lua -- dependency-free test runner for olwb's pure modules.
-- Run from the repo root:  lua tests/run_tests.lua   (or: make test)
--
-- Loads json/model/render/cmd/migrate via dofile (each sets its olwb_* global),
-- exactly as micro's shared-namespace loader would expose them.

local passed, failed = 0, 0
local failures = {}

local function ok(cond, name)
  if cond then
    passed = passed + 1
  else
    failed = failed + 1
    failures[#failures + 1] = name
    io.write("  FAIL  " .. name .. "\n")
  end
end

local function eq(a, b, name)
  if a == b then
    ok(true, name)
  else
    ok(false, name .. "  (got " .. tostring(a) .. ", want " .. tostring(b) .. ")")
  end
end

-- Resolve repo root from this script's location so it runs from anywhere.
local here = (arg and arg[0] or "tests/run_tests.lua"):gsub("[^/]*$", "")
local root = here .. "../"
local function load_mod(name) dofile(root .. name .. ".lua") end

load_mod("json")
load_mod("model")
load_mod("render")
load_mod("cmd")
load_mod("migrate")

local json = olwb_json
local model = olwb_model
local render = olwb_render
local cmd = olwb_cmd
local migrate = olwb_migrate

-- Deterministic time formatter for tests (UTC).
local function fmt_time(ms) return os.date("!%Y-%m-%d %H:%M:%S", math.floor(ms / 1000)) end
local function zero_rand() return 0 end

-------------------------------------------------------------------------------
print("== json ==")
-------------------------------------------------------------------------------
do
  local obj = { a = 1, b = "two", c = { 1, 2, 3 }, d = true, e = {} }
  local round = json.decode(json.encode(obj))
  eq(round.a, 1, "json number round-trip")
  eq(round.b, "two", "json string round-trip")
  eq(round.c[2], 2, "json array round-trip")
  eq(round.d, true, "json bool round-trip")
  eq(#round.e, 0, "json empty array round-trip")

  local uni = { s = "héllo ✓ \"quote\" \n newline \\ slash" }
  local ru = json.decode(json.encode(uni))
  eq(ru.s, uni.s, "json unicode + escapes round-trip")
end

-------------------------------------------------------------------------------
print("== model: ids ==")
-------------------------------------------------------------------------------
do
  local a = model.new_id(1000, zero_rand)
  local b = model.new_id(2000, zero_rand)
  eq(#a, 20, "id length is 20")
  ok(a < b, "ids sort by creation time")
  ok(a:match("^[0-9A-HJKMNP-TV-Z]+$") ~= nil, "id is uppercase base32 (Crockford)")
  eq(model.encode_base32(0, 4), "0000", "base32 zero pads")
  eq(model.encode_base32(31, 1), "Z", "base32 max digit")
  eq(model.encode_base32(32, 2), "10", "base32 carry")
end

-------------------------------------------------------------------------------
print("== model: trim / labels ==")
-------------------------------------------------------------------------------
do
  eq(model.trim("  hi \n\n"), "hi", "trim strips surrounding whitespace")
  eq(model.trim("\n\n\n"), "", "trim all-whitespace -> empty")
  ok(model.is_blank("   "), "is_blank on whitespace")

  local l = {}
  eq(model.toggle_label(l, "x"), true, "toggle adds label")
  eq(#l, 1, "label list has one entry")
  eq(model.toggle_label(l, "x"), false, "toggle removes label")
  eq(#l, 0, "label list empty after removal")
  model.add_label(l, "a"); model.add_label(l, "a")
  eq(#l, 1, "add_label dedups")
end

-------------------------------------------------------------------------------
print("== model: label resolution (inheritance) ==")
-------------------------------------------------------------------------------
do
  local liner = model.new_liner("L", "n", "d", { "root" })
  local sess = model.new_session("S", 0, "", { "sess" })
  local msg = model.new_message("M", "hi", 0, { "msg", "root" })
  local labels = model.resolve_labels(liner, sess, msg)
  eq(labels[1], "root", "resolution order: liner first")
  eq(labels[2], "sess", "resolution order: session second")
  eq(labels[3], "msg", "resolution order: message third")
  eq(#labels, 3, "resolution dedups shared labels")
end

-------------------------------------------------------------------------------
print("== model: descending flatten + stability ==")
-------------------------------------------------------------------------------
do
  local liner = model.new_liner("L", "n", "d", {})
  local s1 = model.new_session("S1", 0, "", {})
  local s2 = model.new_session("S2", 0, "", {})
  liner.sessions = { s1, s2 }
  -- Two sessions, interleaved timestamps, plus a tie at t=100.
  s1.messages = {
    model.new_message("a", "A", 100, {}),
    model.new_message("b", "B", 300, {}),
  }
  s2.messages = {
    model.new_message("c", "C", 100, {}), -- ties with A
    model.new_message("d", "D", 200, {}),
  }
  local e = model.flatten_desc(liner, {})
  eq(e[1].message.content, "B", "newest (300) first")
  eq(e[2].message.content, "D", "then 200")
  -- Tie at 100: original append order A (s1) before C (s2) preserved.
  eq(e[3].message.content, "A", "stable tie-break keeps append order (A)")
  eq(e[4].message.content, "C", "stable tie-break keeps append order (C)")

  -- Filtering by label.
  s1.messages[1].metadata.labels = { "keep" }
  local f = model.flatten_desc(liner, { filter = { label = "keep" } })
  eq(#f, 1, "label filter keeps only matching")
  eq(f[1].message.content, "A", "label filter returns A")

  -- Filtering by term (case-insensitive substring).
  local t = model.flatten_desc(liner, { filter = { term = "b" } })
  eq(#t, 1, "term filter matches content substring")
  eq(t[1].message.content, "B", "term filter returns B")

  -- since / until.
  local w = model.flatten_desc(liner, { filter = { since = 200, until_ = 300 } })
  eq(#w, 2, "since/until window count")
end

-------------------------------------------------------------------------------
print("== model: direct messages + label counts ==")
-------------------------------------------------------------------------------
do
  local liner = model.new_liner("L", "n", "d", { "top" })
  local s = model.new_session("S", 0, "", {})
  liner.sessions = { s }
  s.messages = { model.new_message("m", "in-session", 10, { "a" }) }
  liner.directMessages = { model.new_message("dm", "direct", 20, { "b" }) }

  local no_direct = model.flatten_desc(liner, {})
  eq(#no_direct, 1, "direct excluded by default")
  local with_direct = model.flatten_desc(liner, { include_direct = true })
  eq(#with_direct, 2, "direct included when requested")
  eq(with_direct[1].message.content, "direct", "direct newest-first")
  ok(with_direct[1].direct == true, "direct entry flagged")

  local counts = model.label_counts(liner)
  eq(counts["top"], 2, "inherited label counted on both messages")
  eq(counts["a"], 1, "session message label counted")
  eq(counts["b"], 1, "direct message label counted")
end

-------------------------------------------------------------------------------
print("== render ==")
-------------------------------------------------------------------------------
do
  local liner = model.new_liner("Labcd1234", "my notes", "a description", {})
  local s = model.new_session("Sxyz9876", 0, "", {})
  liner.sessions = { s }
  s.messages = {
    model.new_message("m1", "first thing", 1700000000000, { "work" }),
    model.new_message("m2", "second thing", 1700000100000, { "debug" }),
  }
  local state = { activeLinerId = "Labcd1234", activeSessionId = "Sxyz9876", activeLabels = { "work" } }
  local out = render.render_feed(liner, state, { fmt_time = fmt_time, rule_width = 20 })

  ok(out:find("━━━", 1, true) == nil, "no header block in the feed")
  ok(out:find("#debug", 1, true) ~= nil, "labels rendered")
  -- Newest first: a fresh capture enters at the top, under the compose line.
  local p1 = out:find("second thing", 1, true)
  local p2 = out:find("first thing", 1, true)
  ok(p1 and p2 and p1 < p2, "feed renders newest-first, at the top")
  ok(out:find(fmt_time(1700000000000), 1, true) ~= nil, "timestamp formatted")

  -- Empty liner shows the placeholder.
  local empty = render.render_feed(model.new_liner("E", "e", "", {}), { activeLabels = {} },
    { fmt_time = fmt_time })
  ok(empty:find("no messages yet", 1, true) ~= nil, "empty feed placeholder")

  -- Markdown export.
  local md = render.render_export_md(liner, { fmt_time = fmt_time })
  ok(md:find("# my notes", 1, true) ~= nil, "md export title")
  ok(md:find("- second thing", 1, true) ~= nil, "md export bullet")
end

-------------------------------------------------------------------------------
print("== cmd: parse ==")
-------------------------------------------------------------------------------
do
  local c, a, rest = cmd.parse("/liner name My Cool Liner")
  eq(c, "liner", "parse command verb")
  eq(a[1], "name", "parse first arg")
  eq(rest, "name My Cool Liner", "parse rest")
  ok(cmd.is_command("/new"), "is_command true for slash")
  ok(not cmd.is_command("hello"), "is_command false for plain text")
  eq(cmd.parse("   "), nil, "parse blank -> nil")

  local ms = cmd.parse_date("2024-08-31")
  ok(ms ~= nil and ms > 0, "parse_date returns ms")
  eq(cmd.parse_date("not-a-date"), nil, "parse_date rejects garbage")
end

-------------------------------------------------------------------------------
print("== cmd: dispatch (mock ctx) ==")
-------------------------------------------------------------------------------
do
  -- Minimal in-memory ctx mirroring olwb.lua's wiring.
  local function make_ctx()
    local state = { activeLabels = {}, filter = nil, liners = {} }
    local liner = nil
    local msgs = {}
    local ctx
    ctx = {
      model = model, render = render, state = state,
      now = function() return 1000 end,
      new_id = function() return "id-" .. tostring(#msgs + 1) end,
      infos = {}, errors = {},
      rerenders = 0,
    }
    ctx.info = function(m) ctx.infos[#ctx.infos + 1] = m end
    ctx.error = function(m) ctx.errors[#ctx.errors + 1] = m end
    ctx.get_active_liner = function() return liner end
    ctx.require_active_liner = function()
      if not liner then ctx.error("no active liner") return nil end
      return liner
    end
    ctx.create_liner = function(name)
      liner = model.new_liner("L", name or "", "")
      state.activeLinerId = "L"
      return liner
    end
    ctx.open_liner = function() return nil end
    ctx.close_liner = function() liner = nil end
    ctx.save_active = function() end
    ctx.save_state = function() end
    ctx.start_session = function(l)
      local s = model.new_session("S", ctx.now())
      l.sessions[#l.sessions + 1] = s
      state.activeSessionId = "S"
      return s
    end
    ctx.end_session = function() state.activeSessionId = nil end
    ctx.submit_message = function(text)
      local l = liner or ctx.create_liner("notes")
      local s = model.active_session(l, state) or ctx.start_session(l)
      s.messages[#s.messages + 1] = model.new_message(ctx.new_id(), text, ctx.now(),
        model.copy_list(state.activeLabels))
    end
    ctx.rerender = function() ctx.rerenders = ctx.rerenders + 1 end
    ctx.set_filter = function(f) state.filter = f end
    ctx.clear_filter = function() state.filter = nil end
    ctx.export = function() return true, "exported" end
    ctx.list_liners = function() return {} end
    ctx.open_help = function() ctx.helped = true end
    ctx.show_options = function() ctx.optioned = true end
    ctx.set_option = function(n, v) ctx.setopt = { n, v }; return true end
    return ctx
  end

  -- /label toggles the active-label set.
  local ctx = make_ctx()
  cmd.dispatch(ctx, "/label debug")
  eq(ctx.state.activeLabels[1], "debug", "/label activates label")
  cmd.dispatch(ctx, "/label debug")
  eq(#ctx.state.activeLabels, 0, "/label toggles label off")

  -- /new creates + activates a liner.
  ctx = make_ctx()
  cmd.dispatch(ctx, "/new project x")
  ok(ctx.get_active_liner() ~= nil, "/new creates active liner")

  -- /msg was removed: it must be unknown now.
  ctx = make_ctx()
  cmd.dispatch(ctx, "/msg hello world")
  ok(#ctx.errors == 1 and ctx.errors[1]:find("unknown", 1, true),
    "/msg is gone (unknown command)")

  -- /filter sets state.filter.
  ctx = make_ctx()
  cmd.dispatch(ctx, "/filter label:debug since:2024-01-01")
  ok(ctx.state.filter and ctx.state.filter.label == "debug", "/filter parses label")
  ok(ctx.state.filter.since ~= nil, "/filter parses since")
  cmd.dispatch(ctx, "/filter clear")
  eq(ctx.state.filter, nil, "/filter clear resets")

  -- unknown command reports an error and is still "handled".
  ctx = make_ctx()
  local handled = cmd.dispatch(ctx, "/bogus")
  ok(handled, "unknown command is handled (not passed through)")
  ok(#ctx.errors == 1, "unknown command reports an error")

  -- /set: bare shows the panel, name+value sets.
  ctx = make_ctx()
  cmd.dispatch(ctx, "/set")
  ok(ctx.optioned, "bare /set shows options")
  ctx = make_ctx()
  cmd.dispatch(ctx, "/set theme true")
  ok(ctx.setopt and ctx.setopt[1] == "theme" and ctx.setopt[2] == "true",
    "/set name value routes to set_option")
  ctx = make_ctx()
  cmd.dispatch(ctx, "/set theme")
  ok(ctx.optioned and not ctx.setopt, "/set with no value shows options")

  -- /help opens help; /? is an alias.
  ctx = make_ctx()
  cmd.dispatch(ctx, "/help")
  ok(ctx.helped, "/help opens help")
  ctx = make_ctx()
  cmd.dispatch(ctx, "/?")
  ok(ctx.helped, "/? aliases /help")
end

-------------------------------------------------------------------------------
print("== cmd: completion ==")
-------------------------------------------------------------------------------
do
  eq(cmd.complete("/op"), "/open ", "unique verb completes with trailing space")
  eq(cmd.complete("/l"), nil, "ambiguous with no extension -> nil")
  ok(cmd.complete("/la") == "/label", "label/labels share the prefix")
  eq(cmd.complete("/zzz"), nil, "no match -> nil")
  eq(cmd.complete("hello"), nil, "non-command -> nil")
  eq(cmd.complete("/liner d"), "/liner desc ", "subverb completion")
  eq(cmd.complete("/open my", { liners = { "mystuff", "notes" } }),
    "/open mystuff ", "liner-name completion for /open")
  local cands = cmd.candidates("/liner ", {})
  ok(#cands == 5, "trailing space lists all subverbs")
  eq(cmd.complete("/filter si"), "/filter since:", "filter key keeps the colon")
end

-------------------------------------------------------------------------------
print("== migrate: flat -> nested ==")
-------------------------------------------------------------------------------
do
  local flat = {
    messages = {
      { id = "m1", content = "one", timestamp = 100, metadata = { labels = { "x" } } },
      { id = "m2", content = "two", timestamp = 200 },
      { id = "orphan", content = "lost", timestamp = 50 },
      { id = "dm", content = "direct", timestamp = 300 },
    },
    sessions = {
      { id = "s1", startTime = 100, endTime = 200, messageReferences = { "m1", "m2" } },
    },
    liners = {
      { id = "l1", metadata = { name = "main" }, sessionReferences = { "s1" },
        messageReferences = { "dm" } },
    },
  }
  local res = migrate.reconstruct(flat, { now = 999, new_id = function() return "rec" end })

  eq(#res.liners, 2, "reconstruct: main + recovered liner")
  local main = res.liners[1]
  eq(main.metadata.name, "main", "reconstruct: liner name preserved")
  eq(#main.sessions, 1, "reconstruct: session attached")
  eq(#main.sessions[1].messages, 2, "reconstruct: session messages joined")
  eq(main.sessions[1].messages[1].content, "one", "reconstruct: message content")
  eq(#main.directMessages, 1, "reconstruct: direct message attached")
  eq(main.directMessages[1].content, "direct", "reconstruct: direct content")

  local recovered = res.liners[2]
  eq(recovered.metadata.name, "recovered", "reconstruct: orphan liner named 'recovered'")
  eq(recovered.sessions[1].messages[1].content, "lost", "reconstruct: orphan preserved")
  eq(res.stats.orphans, 1, "reconstruct: orphan count")

  -- Idempotency of the join: a second run over the same flat produces same shape.
  local res2 = migrate.reconstruct(flat, { now = 999, new_id = function() return "rec" end })
  eq(#res2.liners, 2, "reconstruct is deterministic")
end

-------------------------------------------------------------------------------
print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
  print("FAILURES:")
  for _, f in ipairs(failures) do print("  - " .. f) end
  os.exit(1)
end
os.exit(0)
