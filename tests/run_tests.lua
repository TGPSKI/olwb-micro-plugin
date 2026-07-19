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
load_mod("dest")
load_mod("issues")
load_mod("migrate")

local json = olwb_json
local model = olwb_model
local render = olwb_render
local cmd = olwb_cmd
local dest = olwb_dest
local issues = olwb_issues
local migrate = olwb_migrate

local function read_fixture(name)
  local f = assert(io.open(here .. "fixtures/" .. name, "rb"),
    "missing fixture " .. name)
  local s = f:read("*a")
  f:close()
  return s
end

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
print("== render: feed index + selection ==")
-------------------------------------------------------------------------------
do
  local liner = model.new_liner("L", "idx", "", {})
  local s = model.new_session("S", 0, "", {})
  liner.sessions = { s }
  s.messages = {
    model.new_message("m1", "one", 100, {}),
    model.new_message("m2", "two\nlines here", 200, {}),
  }
  local out, idx = render.render_feed(liner, {}, { fmt_time = fmt_time, rule_width = 10 })
  eq(#idx, 2, "index has one row per entry")
  -- Newest first: m2 (rule, 2 content lines, meta) then m1.
  eq(idx[1].id, "m2", "index row 1 is the newest message")
  eq(idx[1].start, 0, "first entry starts at buffer line 0")
  eq(idx[1].stop, 3, "multi-line entry spans rule + 2 content + meta")
  eq(idx[2].start, 4, "second entry starts right after")
  eq(idx[2].id, "m1", "second entry id")
  ok(idx[1].entry.message.content:find("two", 1, true) ~= nil, "index carries the entry")
  ok(out:find("▌", 1, true) == nil, "no selection markers when nothing selected")

  local sout = render.render_feed(liner, {}, {
    fmt_time = fmt_time, rule_width = 10, selected = { m1 = true },
  })
  ok(sout:find("▌ one", 1, true) ~= nil, "selected content line marked")
  ok(sout:find("▌ two", 1, true) == nil, "unselected entry unmarked")
  -- Every line of the selected entry is marked (rule, content, meta).
  local marked = 0
  for line in (sout .. "\n"):gmatch("(.-)\n") do
    if line:sub(1, #"▌") == "▌" then marked = marked + 1 end
  end
  eq(marked, 3, "all lines of the selected entry are marked")

  -- Empty feed: empty index.
  local _, eidx = render.render_feed(nil, {}, { fmt_time = fmt_time })
  eq(#eidx, 0, "empty feed yields empty index")

  -- Payload builder: explicit entry list, feed order, with metadata.
  local entries = model.flatten_desc(liner, {})
  local md = render.render_selection_md(liner, { entries[2] }, { fmt_time = fmt_time })
  ok(md:find("# idx", 1, true) ~= nil, "selection md carries the liner title")
  ok(md:find("- one", 1, true) ~= nil, "selection md has the chosen entry")
  ok(md:find("two", 1, true) == nil, "selection md excludes unchosen entries")
  ok(md:find(fmt_time(100), 1, true) ~= nil, "selection md has the timestamp")
end

-------------------------------------------------------------------------------
print("== dest: adapters ==")
-------------------------------------------------------------------------------
do
  eq(dest.infer_kind("claude -p \"hi\""), "claude", "kind inferred from claude")
  eq(dest.infer_kind("codex exec"), "codex", "kind inferred from codex")
  eq(dest.infer_kind("opencode run"), "opencode", "kind inferred from opencode")
  eq(dest.infer_kind("wl-copy"), nil, "plain pipes have no kind")
  eq(dest.infer_kind("/usr/local/bin/claude -p"), "claude", "kind tolerates paths")

  eq(dest.shell_quote("a'b"), "'a'\\''b'", "shell_quote escapes single quotes")

  -- wrap: fresh vs resumed, per kind.
  eq(dest.wrap("claude", "claude -p", nil), "claude -p --output-format json",
    "claude wrap appends json flag")
  eq(dest.wrap("claude", "claude -p", "sid-1"),
    "claude -p --output-format json --resume sid-1", "claude wrap resumes")
  eq(dest.wrap("codex", "codex exec", nil), "codex exec --json",
    "codex wrap appends --json")
  eq(dest.wrap("codex", "codex exec", "tid-9"),
    "codex exec resume tid-9 --json", "codex resume rewrites the exec prefix")
  local w, werr = dest.wrap("codex", "codex-wrapper go", "tid-9")
  ok(w == nil and werr ~= nil, "codex wrap rejects non-'codex exec' cmds on resume")
  eq(dest.wrap("opencode", "opencode run", "ses_1"),
    "opencode run --format json -s ses_1", "opencode wrap resumes with -s")
  local bad = dest.wrap("claude", "claude -p", "evil; rm -rf /")
  ok(bad == nil, "wrap rejects shell metacharacters in session ids")

  -- parse: per-CLI fixtures.
  local p = dest.parse("claude", read_fixture("claude-response.json"))
  ok(p and p.text:find("liner tabs", 1, true) ~= nil, "claude parse extracts result")
  eq(p and p.session_id, "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
    "claude parse extracts session id")
  local pc = dest.parse("codex", read_fixture("codex-response.ndjson"))
  ok(pc and pc.text:find("padding fix", 1, true) ~= nil,
    "codex parse joins agent messages, skips noise")
  eq(pc and pc.session_id, "0198a213-a2c1-7f32-9f2e-3c77deadbeef",
    "codex parse extracts thread id")
  local po = dest.parse("opencode", read_fixture("opencode-response.ndjson"))
  ok(po and po.text:find("Action items", 1, true) ~= nil,
    "opencode parse extracts text parts")
  eq(po and po.session_id, "ses_8fb3c2d1a4e5f6", "opencode parse extracts sessionID")

  local nope, perr = dest.parse("claude", "not json at all")
  ok(nope == nil and perr ~= nil, "claude parse rejects non-JSON")
  local nc = dest.parse("codex", '{"type":"turn.started"}\n')
  ok(nc == nil, "codex parse rejects output with no agent message")
  local ne = dest.parse("opencode", "")
  ok(ne == nil, "opencode parse rejects empty output")

  -- tui: resume vs fresh-with-payload-pointer.
  eq(dest.tui("claude", "sid-1", "/tmp/p.md"), "claude --resume sid-1",
    "claude tui resumes")
  ok(dest.tui("claude", nil, "/tmp/p.md"):find("Process the notes in /tmp/p.md", 1, true) ~= nil,
    "claude tui fresh points at the payload")
  eq(dest.tui("codex", "tid-9", "/tmp/p.md"), "codex resume tid-9", "codex tui resumes")
  eq(dest.tui("opencode", "ses_1", "/tmp/p.md"), "opencode run -i -s ses_1",
    "opencode tui resumes interactively")
end

-------------------------------------------------------------------------------
print("== issues: parse_response ==")
-------------------------------------------------------------------------------
do
  local drafts = issues.parse_response(read_fixture("issues-response.json"))
  ok(drafts ~= nil, "bare JSON accepted")
  eq(#drafts, 2, "two drafts parsed")
  eq(drafts[1].labels[1], "agent-work", "existing agent-work label kept first")
  eq(drafts[2].labels[1], "agent-work", "agent-work force-added when missing")

  local fenced = issues.parse_response(read_fixture("issues-response-fenced.md"))
  ok(fenced ~= nil and #fenced == 1, "fenced ```json block accepted")
  eq(fenced[1].labels[1], "agent-work", "fenced draft gets agent-work")
  eq(fenced[1].labels[2], "docs", "fenced draft keeps its own labels")

  local pr, perrs = issues.parse_response(read_fixture("issues-response-broken.txt"))
  ok(pr == nil and perrs and #perrs > 0, "prose response rejected")

  local nowork, nerrs = issues.parse_response(
    '[{"title":"a: b","body":"## Context\\n- x"}]')
  ok(nowork == nil, "missing ## Work rejected")
  ok(nerrs and nerrs[1]:find("issue 1", 1, true) ~= nil,
    "errors are indexed by element")

  local notarray = issues.parse_response('{"title":"a","body":"b"}')
  ok(notarray == nil, "non-array JSON rejected")

  local longtitle = issues.parse_response(
    '[{"title":"' .. string.rep("x", 95) .. '","body":"## Context\\n## Work\\n- [ ] y"}]')
  ok(longtitle == nil, "over-long title rejected")
end

-------------------------------------------------------------------------------
print("== issues: script / prompt / summary rendering ==")
-------------------------------------------------------------------------------
do
  local drafts = issues.parse_response(read_fixture("issues-response.json"))
  local script = issues.render_script("t/t", drafts, { id = "d1", source = "lot" })
  ok(script:find("#!/usr/bin/env bash", 1, true) == 1, "script has a shebang")
  ok(script:find("set -euo pipefail", 1, true) ~= nil, "script sets strict mode")
  ok(script:find("command -v gh", 1, true) ~= nil, "script checks for gh")
  ok(script:find("REPO='t/t'", 1, true) ~= nil, "script pins the repo")
  local creates = 0
  for _ in script:gmatch("gh issue create") do creates = creates + 1 end
  eq(creates, 2, "one gh create per draft")
  local aw = 0
  for _ in script:gmatch("%-%-label 'agent%-work'") do aw = aw + 1 end
  eq(aw, 2, "--label agent-work on every create")
  ok(script:find("--label 'bug'", 1, true) ~= nil, "extra labels carried")
  ok(script:find("<<'EOF'", 1, true) ~= nil, "quoted heredoc marker")
  -- Draft 2's body contains a literal EOF line: marker walks to OLWB_EOF_1.
  ok(script:find("<<'OLWB_EOF_1'", 1, true) ~= nil,
    "literal EOF body gets a collision-free marker")
  ok(script:find("%[1/2%]") ~= nil and script:find("%[2/2%]") ~= nil,
    "progress echoes numbered")
  -- Label preflight: create-if-absent for the union of labels, before the
  -- first create, without --force (which would clobber existing labels).
  ok(script:find("for L in 'agent-work' 'bug'; do", 1, true) ~= nil,
    "preflight loops over the deduped label union")
  ok(script:find('gh label create "$L" --repo "$REPO" >/dev/null 2>&1 || true',
    1, true) ~= nil, "preflight creates labels, swallowing already-exists")
  ok(script:find("--force", 1, true) == nil,
    "preflight never uses --force")
  local pre_at = script:find("gh label create", 1, true)
  local create_at = script:find("gh issue create", 1, true)
  ok(pre_at ~= nil and create_at ~= nil and pre_at < create_at,
    "preflight precedes the first gh issue create")

  -- build_prompt: sections present, payload passed through.
  local p = issues.build_prompt({
    template = "TPL", repo = "o/r", repo_context = "CTX", payload = "PAY",
  })
  ok(p:find("TPL", 1, true) ~= nil, "prompt includes template")
  ok(p:find("## Target repository\n\no/r", 1, true) ~= nil, "prompt names the repo")
  ok(p:find("## Repository context\n\nCTX", 1, true) ~= nil, "prompt includes context")
  ok(p:find("## Notes to process\n\nPAY", 1, true) ~= nil, "prompt includes payload")
  local p2 = issues.build_prompt({ template = "TPL", repo = "o/r", payload = "PAY" })
  ok(p2:find("cite AGENTS.md", 1, true) ~= nil, "nil context falls back to AGENTS.md")

  -- build_repo_context: injected read_file, truncation + routing table.
  local files = {
    ["/repo/AGENTS.md"] = "# router\n| domain | context |\n|---|---|\n| ui | AGENTS-UI.md |\nrest",
    ["/repo/.subagents/README.md"] = "context modules here",
  }
  local ctx = issues.build_repo_context(function(pp) return files[pp] end, "/repo")
  ok(ctx:find("Root AGENTS.md", 1, true) ~= nil, "repo context includes router")
  ok(ctx:find("context modules here", 1, true) ~= nil, "repo context includes .subagents")
  ok(ctx:find("AGENTS%-UI%.md") ~= nil, "routing table extracted")
  local none = issues.build_repo_context(function() return nil end, "/repo")
  eq(none, nil, "no readable files -> nil context")

  -- render_draft_md: id, repo, per-issue lines, follow-up instruction.
  local md = issues.render_draft_md("d1", "t/t", drafts, "/x/d1.sh")
  ok(md:find("issues draft d1 → t/t", 1, true) ~= nil, "summary header")
  ok(md:find("1. render: fix label inheritance", 1, true) ~= nil, "summary lists titles")
  ok(md:find("- [ ] Reproduce", 1, true) ~= nil, "summary shows first checkbox")
  ok(md:find("/issues file d1", 1, true) ~= nil, "summary ends with the file command")
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
print("== cmd: send/dest/issues dispatch (mock ctx) ==")
-------------------------------------------------------------------------------
do
  local function make_ctx()
    local ctx
    ctx = {
      model = model, render = render, dest = dest,
      state = { destinations = {}, dest_sessions = {}, issue_repos = {},
                activeLabels = {}, liners = {} },
      infos = {}, errors = {}, calls = {},
    }
    ctx.info = function(m) ctx.infos[#ctx.infos + 1] = m end
    ctx.error = function(m) ctx.errors[#ctx.errors + 1] = m end
    ctx.save_state = function() end
    ctx.rerender = function() end
    ctx.get_active_liner = function() return ctx.liner end
    ctx.require_active_liner = function()
      if not ctx.liner then ctx.error("no active liner") return nil end
      return ctx.liner
    end
    local function record(name)
      return function(...) ctx.calls[#ctx.calls + 1] = { name, ... } end
    end
    ctx.send_to = record("send_to")
    ctx.show_dests = record("show_dests")
    ctx.show_sessions = record("show_sessions")
    ctx.show_issues_list = record("show_issues_list")
    ctx.issues_draft = record("issues_draft")
    ctx.issues_file = record("issues_file")
    return ctx
  end

  -- /send: validation + routing.
  local ctx = make_ctx()
  cmd.dispatch(ctx, "/send")
  ok(#ctx.errors == 1, "/send without a destination errors")
  ctx = make_ctx()
  cmd.dispatch(ctx, "/send claude")
  ok(ctx.calls[1] and ctx.calls[1][1] == "send_to" and ctx.calls[1][2] == "claude",
    "/send routes to ctx.send_to")
  ctx = make_ctx()
  cmd.dispatch(ctx, "/send claude tui")
  eq(ctx.calls[1] and ctx.calls[1][3], "tui", "/send passes the tui mode")
  ctx = make_ctx()
  cmd.dispatch(ctx, "/send claude gui")
  ok(#ctx.errors == 1, "/send rejects unknown modes")

  -- /dest add infers kind; into/kind/rm round-trip.
  ctx = make_ctx()
  cmd.dispatch(ctx, "/dest add oc-review opencode run --agent review")
  local d = ctx.state.destinations[1]
  ok(d and d.name == "oc-review", "/dest add stores the destination")
  eq(d and d.cmd, "opencode run --agent review", "/dest add keeps the full cmd")
  eq(d and d.kind, "opencode", "/dest add infers kind from the leading token")
  cmd.dispatch(ctx, "/dest into oc-review reviews")
  eq(d.into, "reviews", "/dest into sets the response liner")
  cmd.dispatch(ctx, "/dest into oc-review -")
  eq(d.into, "", "/dest into - discards responses")
  cmd.dispatch(ctx, "/dest kind oc-review -")
  eq(d.kind, nil, "/dest kind - overrides inference to plain pipe")
  cmd.dispatch(ctx, "/dest kind oc-review claude")
  eq(d.kind, "claude", "/dest kind sets an explicit kind")
  cmd.dispatch(ctx, "/dest rm oc-review")
  eq(#ctx.state.destinations, 0, "/dest rm removes it")
  cmd.dispatch(ctx, "/dest rm ghost")
  ok(#ctx.errors == 1, "/dest rm on a missing name errors")

  -- /dest with no args shows the overlay; session subcommands route/validate.
  ctx = make_ctx()
  cmd.dispatch(ctx, "/dest")
  eq(ctx.calls[1] and ctx.calls[1][1], "show_dests", "bare /dest shows the overlay")
  cmd.dispatch(ctx, "/dest session list")
  eq(ctx.calls[2] and ctx.calls[2][1], "show_sessions", "/dest session list overlay")
  cmd.dispatch(ctx, "/dest session clear claude")
  ok(ctx.errors[#ctx.errors] == "no active liner",
    "/dest session clear needs an active liner")
  ctx.liner = model.new_liner("L1", "notes", "")
  ctx.state.dest_sessions["claude|L1"] = "sid"
  cmd.dispatch(ctx, "/dest session clear claude")
  eq(ctx.state.dest_sessions["claude|L1"], nil, "/dest session clear forgets the id")

  -- /issues: routing + validation.
  ctx = make_ctx()
  cmd.dispatch(ctx, "/issues draft myrepo")
  ok(ctx.calls[1] and ctx.calls[1][1] == "issues_draft" and ctx.calls[1][2] == "myrepo",
    "/issues draft routes with the alias")
  cmd.dispatch(ctx, "/issues file")
  ok(#ctx.errors == 1, "/issues file requires an id")
  cmd.dispatch(ctx, "/issues file latest")
  eq(ctx.calls[2] and ctx.calls[2][2], "latest", "/issues file latest routes")
  cmd.dispatch(ctx, "/issues list")
  eq(ctx.calls[3] and ctx.calls[3][1], "show_issues_list", "/issues list overlay")

  ctx = make_ctx()
  cmd.dispatch(ctx, "/issues repo add olwb TGPSKI/olwb-micro-plugin /home/x")
  local r = ctx.state.issue_repos[1]
  ok(r and r.alias == "olwb" and r.repo == "TGPSKI/olwb-micro-plugin"
    and r.path == "/home/x", "/issues repo add stores alias/repo/path")
  cmd.dispatch(ctx, "/issues repo add bad not-a-repo")
  ok(#ctx.errors == 1, "/issues repo add rejects malformed owner/repo")
  cmd.dispatch(ctx, "/issues repo rm olwb")
  eq(#ctx.state.issue_repos, 0, "/issues repo rm removes the alias")

  ctx = make_ctx()
  cmd.dispatch(ctx, "/issues model")
  ok(ctx.infos[1] and ctx.infos[1]:find("claude -p", 1, true) ~= nil,
    "/issues model shows the default")
  cmd.dispatch(ctx, "/issues model codex exec")
  eq(ctx.state.issues_model_cmd, "codex exec", "/issues model sets the command")
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

  -- New pools: destinations, repo aliases, deeper token levels.
  local extra = { dests = { "claude", "clipboard" }, repos = { "olwb" },
                  liners = { "notes" } }
  local dc = cmd.candidates("/send ", extra)
  eq(#dc, 2, "/send cycles destination names")
  eq(cmd.complete("/send cli", extra), "/send clipboard ", "/send completes a dest")
  local d3 = cmd.candidates("/send claude ", extra)
  eq(d3[1], "tui", "/send <dest> offers tui")
  local rm = cmd.candidates("/dest rm ", extra)
  eq(#rm, 2, "/dest rm cycles destination names")
  local ki = cmd.candidates("/dest kind claude ", extra)
  eq(#ki, 3, "/dest kind <name> cycles the kinds")
  local sc = cmd.candidates("/dest session clear ", extra)
  eq(#sc, 2, "/dest session clear cycles destination names")
  local rp = cmd.candidates("/issues draft ", extra)
  eq(rp[1], "olwb", "/issues draft cycles repo aliases")
  eq(cmd.complete("/issues f"), "/issues file ", "issues subverb completion")
  eq(cmd.complete("/set term"), "/set termcmd ", "termcmd is a /set option")
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
