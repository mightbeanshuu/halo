# halo

![version](https://img.shields.io/badge/version-0.3.0-orange) macOS 14+ · Swift (AppKit/SwiftUI/Charts/PDFKit) + Python 3 stdlib · no dependencies

**Install:** open `dist/Halo-<version>.dmg` (or `./build.sh`), drag Halo to Applications, launch once — it symlinks the `halo` CLI into `~/.local/bin` and `/opt/homebrew/bin` and opens the deck. Or just `ln -s $PWD/halo /opt/homebrew/bin/halo`.

Open a fresh Claude Code terminal window, inject prompts into it, read the answers back,
and wrap the window in an animated wave/glow border — the Claude-in-Chrome look, for a CLI.

```
halo open  cc --cwd ~/some/project          # new Terminal window, tmux session, `claude` started, halo on
halo send  cc "refactor foo.py, no tests"    # types the prompt, waits for the screen to settle, prints what's new
halo keys  cc Down Enter --wait               # answer menus / permission prompts (Enter Escape C-c Tab y ...)
halo read  cc [--lines 60 | --all]            # current screen / full scrollback
halo wait  cc                                 # keep waiting on a long run
halo state cc active|idle|done|error|off [label]   # drive the border manually
halo shot  cc out.png                         # screenshot of window + halo (current Space only)
halo list / halo close cc
```

How it works
- `halo` (Python, stdlib only) creates `tmux` session `halo_<name>`, opens a Terminal.app window attached
  to it via AppleScript (no `activate`, so it never switches Spaces), and finds the new window by diffing
  Terminal's window ids (they are CGWindowIDs).
- `overlay.swift` → `bin/halo-overlay` (auto-compiled) draws a transparent click-through window glued
  around that Terminal window: rotating conic-gradient stroke + blurred glow + status pill. It re-reads
  `~/.halo/<name>.state` (`state|label`) 4×/s and tracks the window 10×/s, hiding it when the window is
  on another Space and quitting when it closes.
- "Done" = the pane content stopped changing for `--settle` seconds (Claude Code's spinner keeps the
  screen changing while it works). A permission prompt or menu also settles, so `send` returns it and
  you answer with `halo keys`.
- `CLAUDE*` env vars are stripped from the tmux session so the nested `claude` starts clean.

Gotchas
- First `open` in a new folder shows Claude's trust prompt → `halo keys cc Down Enter --wait`, then
  usually an MCP prompt → `halo keys cc Escape --wait`.
- `halo shot` only works when the window is on the Space currently displayed.

## Deck — the workspace (`halo deck`)

```
halo deck [--clean]        # start: halos on every agent window + your own (blue), arrow connectors, HUD
halo deck stop
halo tile                  # tile you + agents on this Space, left of the HUD
halo hud tab files|agents · halo hud select PATH · halo hud clean on|off · halo hud connectors on|off
halo open --app chrome|antigravity|cursor|vscode   # GUI-app agents (halo + stats, no prompt injection)
halo open --cmd codex      # any CLI agent
halo focus NAME
```

HUD (SwiftUI + Swift Charts, glass panel, all Spaces): host CPU sparkline, memory, load, total output tokens;
per agent: state, CPU% and RSS of its process tree, model, context %, 5h and 7d rate-limit gauges, tokens
in/out, cost, prompt box (Enter sends), focus, close. Launch bar: Claude, Codex, Antigravity, Chrome, Cursor,
VS Code, Shell. Files tab: files edited in the agents' folders in the last 45 min; text files open in a live
editor that follows agent edits until you type (Save/⌘S writes back); PDFs re-render in place when they change;
"open in" Cursor / VS Code / Antigravity / default app.

Data sources: `~/.halo/*.json|.state` (driver), `~/.halo/status/<session>.json` (statusline hook — 2 lines
added to ~/.claude/statusline-command.sh, backup at .bak), `~/.claude/projects/<cwd>/*.jsonl` (tokens).
Space rule: halos use `.moveToActiveSpace` and live on their window's Space; the HUD/connector canvas join all
Spaces; the clean backdrop sits just above desktop icons.

## Focused full-screen workspace

```
halo deck --focus          # or the ⤢ button in the HUD, or: halo full on / halo full off
```
Hides the Dock and menu bar (System Events, restored on `off`), turns the clean backdrop on, docks the
sidebar edge-to-edge and tiles you + every agent inside the full screen. Agents opened later are auto-aligned.

## Prompt injection for GUI apps

`halo send NAME "text"` on an app session raises its window, presses the app's chat hotkey
(Cursor/Antigravity/Chrome `cmd+l`, VS Code `cmd+i`, Claude/Codex apps: none — override with `--hotkey`),
pastes the text from the clipboard (clipboard restored afterwards) and presses Enter (`--no-enter` to skip),
then saves a screenshot of that window to `~/.halo/NAME.png` — `halo read NAME` re-captures it.
Needs Accessibility permission for your terminal app (System Settings → Privacy & Security → Accessibility).

Launch buttons for Claude and Codex ask **CLI or App** — CLI gives full prompt injection + text output in a halo
terminal; App gives paste injection + screenshots in the desktop app.

## Versioning
`VERSION` is the single source: `halo --version`, the HUD header, `Info.plist` and the DMG name all read it.
Bump it, run `./build.sh`, commit.
