# CLAUDE.md — working notes for agents-strip

This file is context for an AI assistant iterating on this repo. It records the
architecture and the **non-obvious gotchas** that were expensive to discover, so a
fresh session doesn't rediscover them.

## What this is

A single-pane terminal dashboard (one card per Claude Code session + a Claude quota
panel) that lives in a dedicated Ghostty window pinned to the top of the right
monitor. Everything is one bash script with embedded Python and AppleScript.

## Files and where they install

| Repo file | Installs to | Role |
|---|---|---|
| `agents-strip.sh` | `~/.config/tmux/agents-strip.sh` | the whole engine (all subcommands) |
| `agents-strip.conf` | `~/.config/tmux/agents-strip.conf` | tmux config for the `agents` socket only |
| `agents-strip.plist` | `~/Library/LaunchAgents/` (replace `USERNAME`) | login auto-start (`start` subcommand) |

Runtime state (not in the repo): `~/.cache/agents-strip.cols` (click colmap),
`~/.cache/agents-strip/summaries/<sid>.{txt,sig,lock}` (Haiku summaries),
`~/.cache/agents-strip/llm/` (neutral cwd for the summarizer),
`~/.cache/agents-strip.launch.log` (LaunchAgent stdout/stderr).

## Control flow

`start` (LaunchAgent) → waits for Dock/Magnet → `open_strip` (launches Ghostty with
`-e agents-strip.sh boot`) → `boot` (`tmux -L agents new -A -s agents 'agents-strip.sh
watch'`) → `watch` (loop: measure pane, `render W H`, sleep 4) → `position_strip`
(Magnet "Very Top"). Mouse click in the pane → `click X` (tmux binding) → `focus`.

## Hard-won gotchas (do not relearn these)

- **Ghostty is single-instance on macOS.** A clean `open -na Ghostty …` persists, but
  repeated back-to-back launches collide — extra instances quit and tear down windows.
  Also, one Ghostty *app* can spread windows across multiple *processes*, so window
  searches must iterate `every process whose name is "Ghostty"`, not just one.
- **The strip window's AX title is often empty.** Ghostty's terminfo doesn't advertise
  the title capability to tmux, so `set-titles` doesn't reach the OS. `position_strip`
  therefore matches the strip window as: titled `agents-strip` first, else the only
  **empty-titled** Ghostty window (Claude's own windows are always named). Keep the
  title bar on — a borderless window also exposes an empty AX title and breaks this.
- **Magnet's snap commands live in `menu bar 2`** (its status-bar icon), not `menu bar
  1` (which is the Apple menu). Clicking `menu bar item 1 of menu bar 1` opens the
  Apple menu and, if the script errors before closing it, leaves it stuck open — and
  it's owned by Magnet's process, so `killall SystemUIServer` won't clear it;
  `killall Magnet; open -a Magnet` does. The installed code only ever touches
  `menu bar 2` and always closes the menu (select "Very Top" or send Esc).
- **Accessibility (TCC) permission is required** for `/usr/bin/osascript` to drive
  System Events. Error `-25211` = "not allowed assistive access". Grant it in System
  Settings → Privacy & Security → Accessibility (it's partway down a scrollable list;
  `open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"`
  jumps straight there).
- **`watch` must find its own window via `$TMUX_PANE`**, not the attached client's
  active window — otherwise a reload kills window 1 (its own). It drops every other
  window to clean up leftovers from the old tab-based design.
- **The tmux server can outlive its window** (0 clients). `start` checks the *attached
  client count* (`list-clients | wc -l`), not `has-session`; `boot`'s `new -A`
  re-attaches to a surviving server.
- **Summarizer feedback loop:** the Haiku summarizer runs `claude -p --model haiku`,
  which itself creates a `~/.claude/projects/*cache-agents-strip*` transcript. `render`
  **excludes any project containing `cache-agents-strip`** so the dashboard doesn't
  show (and summarize) its own summarizer sessions.
- **Summaries regenerate only when idle + changed.** `render` triggers `summarize`
  only when `state != "RUN"` and the transcript signature (`mtime:size`) differs from
  the cached `.sig`. A `.lock` (stale after 180s) prevents concurrent runs. Running
  agents keep their auto-title until the first idle summary lands — by design.
- **Emoji are double-width.** `pad()` measures display cells via `ch_w()` (emoji/CJK
  ranges + East-Asian width = 2, combining = 0) so columns align. Changing the emoji
  in the cards is fine; keep them inside the handled ranges or extend `ch_w()`.
- **Font size 17 = Ghostty default (13) + 4 zoom steps.** The user means "press Cmd-+
  four times" by "4x zoom", not 4× the point size.

## Testing / iterating

- Live redraw: press `r` inside the strip, or `agents-strip.sh render 200 12` to print
  one frame to any terminal.
- Reposition without relaunch: `agents-strip.sh position`.
- Clean restart: `tmux -L agents kill-server` then `agents-strip.sh start`.
- Reload LaunchAgent: `launchctl bootout gui/$(id -u)/agents-strip;
  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/agents-strip.plist`.

## Environment-specific assumptions

Configure these to reuse the strip on another machine:

- **Quota** is optional and off by default. Set `AGENTS_STRIP_QUOTA` (or write the glob
  to `~/.config/agents-strip/quota.glob`) to a glob of JSON files, each a list of
  readings `[{window: five_hour|seven_day, used_percentage, at, resets_at}, …]` (epoch
  seconds; latest `at` wins per window). Unset → bars show `n/a`. `render()` resolves
  the glob and passes it to the Python as `QUOTA_GLOB`.
- Claude CLI is expected at `~/.local/bin/claude` (`CLAUDE_BIN` near the top of the
  script). The plist ships with a `USERNAME` placeholder. The strip targets the
  rightmost screen (`screen_geo()`).
