# Sending — `/send` and browse mode

`/send` pipes notes to a destination (see [dest.md](dest.md) for defining
those). What gets sent is the current *scope*:

1. If messages are selected in browse mode, the selection.
2. Otherwise, everything currently in view — the whole liner, narrowed by
   the active `/filter` if one is set.

The payload is rendered as markdown: liner title, message content,
timestamps, and labels.

## Selecting messages: browse mode

Press `Shift-Tab` on an empty (or plain-text) line to drop into the feed.
The current message's first line is highlighted:

| Key | Effect |
|---|---|
| `↑` / `↓` | jump message-to-message (not line-by-line) |
| `Space` | toggle the message in the selection (`▌` marker + highlight) |
| `a` | select everything in scope — or clear a full selection |
| `Enter` | open the destination picker (`/send ` pre-filled, Tab-cycling) |
| `Shift-Tab` | back to the one line (the selection survives) |

The bar shows `N selected` while a selection exists; it clears after a
successful send.

## Firing a send

```
/send <dest>          pipe the scope to the destination
/send <dest> tui      open the CLI interactively in a terminal instead
```

You can type it directly, or press Enter in browse mode and Tab through the
picker. While a send is running the bar shows `<dest> working…`; sends run
in the background and don't block the editor.

For destinations with a CLI adapter kind (`claude` / `codex` / `opencode`),
the send resumes that liner's stored session — repeated sends from one liner
are one ongoing conversation. Details in [dest.md](dest.md#cli-adapters-dest-kind).

## The `tui` variant

`/send <dest> tui` opens the CLI in a new terminal window instead of piping:
it resumes the stored session when one exists, otherwise it starts fresh
with a pointer to the payload file. The terminal is auto-detected
(`$TERMINAL`, then konsole/foot/alacritty/kitty/xterm); override it with:

```
/set termcmd "<command>"
```

## The inbox

Responses from a destination land as messages labeled `#<dest>` in that
destination's `into` liner. When that liner isn't the active one, the bar
shows a badge (`inbox: 2 new`). `Alt-i` toggles between the active liner and
the inbox; a second `Alt-i` returns.

## A full round trip

```
(jot a few notes)
Shift-Tab                 enter browse mode
Space, ↓, Space           pick two messages
Enter                     picker opens with /send pre-filled
Tab … Enter               choose `claude`
Alt-i                     read the response in the inbox once the badge shows
```
