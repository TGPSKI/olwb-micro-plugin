-- assets.lua -- embedded runtime files (syntax, colorscheme, help) exposed as
-- shared-namespace globals so olwb.lua can register them via
-- config.AddRuntimeFileFromMemory. Kept out of olwb.lua to avoid drowning the
-- wiring in long string literals. No micro/Go imports.

-- micro syntax file (YAML). Highlights the feed's rule lines, timestamps,
-- #labels and header rows using standard groups the user's colorscheme colours.
OLWB_SYNTAX = [[
filetype: olwb

detect:
    filename: "olwb://"

rules:
    - comment: "^\\s*─+\\s*$"
    - constant.number: "[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}"
    - identifier: "#[A-Za-z0-9_/-]+"
    - special: "\\[direct\\]"
    - special: "^\\s+/[a-z?]+"
    - olwb.selection: "^\\s*▶ .*$"
]]

-- Chrome panes (title line, Liner/Session bar): the title renders in the same
-- colour as timestamps (constant.number), the bar's field names in comment.
OLWB_UI_SYNTAX = [[
filetype: olwbui

detect:
    filename: "olwb://(title|bar)"

rules:
    - constant.number: "^\\s*olwb\\b.*$"
    - comment: "^\\s*(Liner|Session):"
    - comment: "^\\s*Enter submits.*$"
]]

-- Optional colorscheme mapping the syntax groups to the OLWB palette. Opt in
-- with olwb.theme=true, or >set colorscheme olwb. Respects the user's scheme
-- otherwise (this file is only offered, never forced).
OLWB_COLORSCHEME = [[
color-link default "#d4d4d4,#1e1e1e"
color-link comment "#5c6370,#1e1e1e"
color-link constant.number "#a370f7,#1e1e1e"
color-link identifier "#7ef4b9,#1e1e1e"
color-link preproc "#3da9fc,#1e1e1e"
color-link special "#e5c07b,#1e1e1e"
color-link cursor-line "#32374d"
color-link olwb.selection "#e0e0e0,#32374d"
color-link divider "#44475a,#1e1e1e"
color-link statusline "#d4d4d4,#252526"
color-link tabbar "#d4d4d4,#252526"
]]

-- In-editor help. Shown by /help and reachable via >help olwb.
OLWB_HELP = [[
# olwb — one-line-with-benefits

A one-line-input notepad inside micro. Capture happens in the one line near
the top; each entered line drops into the feed directly beneath it and pushes
the older lines down the stack. The two-row bar at the bottom shows the active
liner and session.

Domain model: Liner -> Session -> Message. Labels are inherited
(liner ∪ session ∪ message) and resolved at render time.

## Getting started

    > olwb                 open the olwb layout
    (type a line)          press Enter to capture it as a message
    /?                     toggle the command menu in the feed area
    /set                   view olwb options; /set <name> <value> changes one
    Tab / Shift-Tab        cycle through the menu's options (Enter runs)
    Up / Down              also cycle the options while typing a /command
    Space                  during /open cycling: expand the selection's
                           details (id, description, labels, counts)
    Shift-Tab              (empty/plain line) jump into the feed to browse:
                           arrows scroll, Shift-Tab or typing returns and
                           snaps the scroll back to the top
    Alt-o                  open / focus olwb
    Alt-m                  jump to the one line

Typing in any other olwb pane bounces focus (and the keystroke) back into
the one line, so a stray mouse click never strands the keyboard.

Nothing is loaded automatically on open: the one line is pre-filled with
"/open <your most recent liner>" — press Enter to resume it, or clear the
line and type something else. Messages auto-create a "notes" liner and a
session if none is active. Typing "/" shows the command menu live, filtered
as you type; the input grows automatically when a long line wraps.

## Slash commands (typed in the one line)

    /new [name]                    create + activate a new liner
    /open <name|id>                load + activate an existing liner
    /close                         deactivate liner (ends its session)
    /save                          force a save (saves are automatic)

    /liner start|end               start / end the active liner
    /liner name <s> | desc <s>     set liner name / description
    /liner label <l>               toggle a liner-level label

    /session start|end             start / end a session
    /session name <s>              name the active session
    /session label <l>             toggle a session-level label

    /label <name>                  toggle a label applied to new messages
    /labels                        list known labels with counts

    /filter label:<l> [since:<d>] [until:<d>] [term:<t>]
    /filter clear                  remove the active filter
    /search <term>                 substring search over the current scope
    /export [md|json] [path]       write the current scope to a file
    /list                          list liners with message counts
    /help  (or /?)                 toggle the command menu

Dates are YYYY-MM-DD (optionally with HH:MM[:SS]).

## Native commands

    > olwb                         open / focus the UI
    > olwb <slash-verb> [args]     run any command above without the leading /
    > olwb migrate <dir>           import an Electron OLWB userData directory
    > olwb rescan                  rebuild the liner registry from disk
    > olwb selftest                run built-in storage self-tests

## Options (set from inside olwb with /set <name> <value>)

    olwb.datadir       storage dir (default $XDG_DATA_HOME/olwb)
    olwb.autostart     open olwb on launch when no file is given (default off)
    olwb.timefmt       strftime for timestamps (default %Y-%m-%d %H:%M:%S)
    olwb.composesize   minimum one-line height in rows (default 1; grows as
                       needed up to 8)
    olwb.rulewidth     feed separator width (default 48)
    olwb.theme         apply the bundled olwb colorscheme (default off)

## Storage

    <datadir>/liners/<id>.json     one file per liner (atomic writes)
    <datadir>/state.json           active liner/session, labels, filter, registry
    <datadir>/backups/             timestamped copies before destructive ops
]]
