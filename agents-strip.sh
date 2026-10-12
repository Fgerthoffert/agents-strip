#!/bin/bash
# Agent strip: a rich, multi-line dashboard — one card per Claude Code session,
# plus the Claude quota as labelled progress bars. Runs on its own tmux server
# (socket "agents") so nothing here touches the main tmux.
#
# The dashboard is drawn IN THE PANE (not as tmux window tabs), so each agent
# card can be several lines: state, a wrapped summary, its project and its age.
# Clicks are mapped back to a card by pane x-coordinate (see the colmap file).
#
# Subcommands:
#   open         launch the dedicated Ghostty window on the rightmost screen
#   boot         (inside that window) start/attach the strip tmux session
#   watch        refresh loop: redraw the dashboard every few seconds
#   render W H    print one frame for a pane W columns by H rows (used by watch)
#   click X       click handler: map pane column X to a card and focus it
#   focus LABEL   raise the Ghostty window whose title matches LABEL
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
SELF="$HOME/.config/tmux/agents-strip.sh"
CONF="$HOME/.config/tmux/agents-strip.conf"
COLMAP="$HOME/.cache/agents-strip.cols"
SUMDIR="$HOME/.cache/agents-strip/summaries"   # per-session Haiku summaries
LLMCWD="$HOME/.cache/agents-strip/llm"          # neutral cwd for the summarizer
CLAUDE_BIN="$HOME/.local/bin/claude"
SOCK=agents
T() { tmux -L "$SOCK" "$@"; }

render() {
  COLMAP="$COLMAP" SUMDIR="$SUMDIR" AGENTS_SELF="$SELF" /usr/bin/python3 - "$1" "$2" <<'PY'
import json, os, glob, subprocess, time, textwrap, sys

W = max(40, int(sys.argv[1]))
H = max(7, int(sys.argv[2]))
home = os.path.expanduser("~")
colmap = os.environ["COLMAP"]
sumdir = os.environ.get("SUMDIR", "")
self_sh = os.environ.get("AGENTS_SELF", "")
now = time.time()

def cached_summary(sid):
    try:
        with open(os.path.join(sumdir, sid + ".txt")) as fh:
            return fh.read().strip()
    except OSError:
        return ""
def cached_sig(sid):
    try:
        with open(os.path.join(sumdir, sid + ".sig")) as fh:
            return fh.read().strip()
    except OSError:
        return ""
def trigger_summary(jsonl, sid, sig):
    # regenerate once per finished turn: idle state + content changed + not already running
    lock = os.path.join(sumdir, sid + ".lock")
    if os.path.exists(lock):
        try:
            if now - os.path.getmtime(lock) < 180:  # a fresh run is in flight
                return
        except OSError:
            return
    try:
        os.makedirs(sumdir, exist_ok=True)
        open(lock, "w").close()
        subprocess.Popen(["/bin/bash", self_sh, "summarize", jsonl, sid, sig],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
    except OSError:
        pass

# --- live claude CLI processes -> munged project dir + real cwd --------------
live = {}
pids = subprocess.run(["/usr/bin/pgrep", "-f", r"(/|^)claude$"],
                      capture_output=True, text=True).stdout.split()
for pid in pids:
    out = subprocess.run(["/usr/sbin/lsof", "-a", "-p", pid, "-d", "cwd", "-Fn"],
                         capture_output=True, text=True).stdout
    for line in out.splitlines():
        if line.startswith("n/"):
            p = line[1:]  # "/Users/..."
            key = "-" + p[1:].replace("/", "-").replace(".", "-")
            live[key] = p

# --- sessions active in the last 2h -----------------------------------------
agents = []
for f in glob.glob(home + "/.claude/projects/*/*.jsonl"):
    try:
        age = now - os.path.getmtime(f)
    except OSError:
        continue
    if age > 7200:
        continue
    proj = os.path.basename(os.path.dirname(f))
    if "cache-agents-strip" in proj:   # the summarizer's own Haiku sessions
        continue
    sid = os.path.basename(f)[:-6]     # strip ".jsonl"
    try:
        sig = "%d:%d" % (int(os.path.getmtime(f)), os.path.getsize(f))
    except OSError:
        sig = ""
    state = "RUN" if age < 90 else ("WAIT" if proj in live else "DONE")
    project = os.path.basename(live[proj].rstrip("/")) if proj in live else proj.rsplit("-", 1)[-1]

    # regenerate the Haiku summary once each time the agent finishes a turn
    if sumdir and self_sh and state != "RUN" and sig and cached_sig(sid) != sig:
        trigger_summary(f, sid, sig)

    label = cached_summary(sid)
    if not label:   # fall back to the auto-title until the first summary lands
        try:
            with open(f, "rb") as fh:
                chunk = fh.read(65536).decode("utf-8", "ignore")
                fh.seek(max(0, os.path.getsize(f) - 65536))
                chunk += fh.read().decode("utf-8", "ignore")
            for line in chunk.splitlines():
                if '"custom-title"' in line:
                    try:
                        raw = (json.loads(line).get("customTitle", "") or "").replace("-", " ").strip()
                        if raw:
                            label = raw
                    except json.JSONDecodeError:
                        pass
        except OSError:
            pass
    if not label:
        label = proj.rsplit("-", 1)[-1]
    agents.append({"order": ("RUN", "WAIT", "DONE").index(state),
                   "age": age, "state": state, "label": label, "project": project or "/"})
agents.sort(key=lambda a: (a["order"], a["age"]))

# --- quota (latest reading per window across Cortex session spools) ----------
best = {}
for q in glob.glob(home + "/GitHub/Jahia/cortex/local/sessions/*/quota.json"):
    try:
        readings = json.load(open(q))
    except (OSError, json.JSONDecodeError):
        continue
    for r in readings:
        w = r.get("window")
        if w in ("five_hour", "seven_day") and r.get("at", 0) > best.get(w, (0,))[0]:
            best[w] = (r["at"], r.get("used_percentage"), r.get("resets_at"))
q5 = best.get("five_hour", (0, None, None))
q7 = best.get("seven_day", (0, None, None))

# --- layout ------------------------------------------------------------------
CW, SEP, QW, BAR, CARD_H = 40, " │ ", 34, 14, 5
SEPN = len(SEP)
STYLE = {"RUN": ("114", "▸", "RUNNING"), "WAIT": ("214", "◆", "WAITING"), "DONE": ("245", "✔", "DONE")}

import unicodedata
def ch_w(ch):            # display cells for one char (emoji/CJK = 2, combining = 0)
    if unicodedata.combining(ch):
        return 0
    o = ord(ch)
    if (0x1F000 <= o <= 0x1FAFF) or (0x2600 <= o <= 0x27BF) or (0x2B00 <= o <= 0x2BFF):
        return 2
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
def c(code, s):          # wrap plain text in an SGR colour
    return f"\033[{code}m{s}\033[0m"
def pad(s, w):           # truncate/pad to exactly w display cells (emoji-aware)
    out, cur = [], 0
    for ch in s:
        cw = ch_w(ch)
        if cur + cw > w:
            break
        out.append(ch); cur += cw
    return "".join(out) + " " * (w - cur)
def agefmt(s):
    s = int(s)
    if s < 60:   return "just now"
    if s < 3600: return f"{s // 60}m ago"
    return f"{s // 3600}h ago"

ncols = max(1, (W - QW - 1) // (CW + SEPN))
shown = agents[:ncols]
hidden = len(agents) - len(shown)

# per-card lines: list of (colour, plaintext)
cards = []
for a in shown:
    col, icon, word = STYLE[a["state"]]
    wrapped = (textwrap.wrap(a["label"], CW - 4) + ["", ""])[:2]
    cards.append([
        (col,   f" {icon} {word}"),
        ("252", " 💬 " + wrapped[0]),
        ("252", "    " + wrapped[1]),
        ("110", " 📁 " + a["project"]),
        ("240", " 🕒 " + agefmt(a["age"])),
    ])

# quota card (far right), aligned to the same rows
def bar(label, pct):
    if pct is None:
        return c("240", f"{label:<7}[{'─' * BAR}]   n/a")
    p = float(pct)
    fill = max(0, min(BAR, int(round(p / 100 * BAR))))
    bcol = "114" if p < 50 else ("214" if p < 80 else "203")
    glyph = c(bcol, "█" * fill) + c("238", "░" * (BAR - fill))
    return c("245", f"{label:<7}") + "[" + glyph + "]" + c("252", f" {p:4.0f}%")
def resetfmt(ts):        # reset time: time only if it resets today, else weekday + time
    if not ts:
        return c("238", f"{'':<8}↻ resets    n/a")
    lt = time.localtime(ts)
    same_day = time.strftime("%Y%j", lt) == time.strftime("%Y%j", time.localtime(now))
    when = time.strftime("%H:%M" if same_day else "%a %H:%M", lt)
    return c("240", f"{'':<8}↻ resets {when}")
quota = [
    c("250", "\033[1mCLAUDE QUOTA\033[0m"),
    bar("session", q5[1]), resetfmt(q5[2]),
    bar("weekly",  q7[1]), resetfmt(q7[2]),
]

sep_c = c("237", SEP)
body_vis = len(shown) * CW + max(0, len(shown) - 1) * SEPN

# --- compose frame -----------------------------------------------------------
lines = []
plain_head = f" AGENTS  · {len(agents)} session(s)" + (f"  (+{hidden} more)" if hidden > 0 else "")
clock = time.strftime("%H:%M")
gap = max(1, W - len(plain_head) - len(clock) - 1)
header = (c("252", "\033[1m AGENTS\033[0m")
          + c("240", f"  · {len(agents)} session(s)")
          + (c("240", f"  (+{hidden} more)") if hidden > 0 else "")
          + " " * gap + c("240", clock) + " ")
lines.append(header)
lines.append("")  # blank spacer

if not shown:
    lines.append(c("240", "  no active Claude sessions in the last 2h"))
else:
    for r in range(CARD_H):
        parts = [c(col, pad(txt, CW)) for col, txt in (cd[r] for cd in cards)]
        body = sep_c.join(parts)
        between = max(1, (W - QW) - body_vis)
        lines.append(body + " " * between + quota[r])

# write the colmap for click -> card focus (0-indexed pane columns)
try:
    with open(colmap, "w") as fh:
        for i, a in enumerate(shown):
            start = i * (CW + SEPN)
            fh.write(f"{start} {start + CW - 1} {a['label']}\n")
except OSError:
    pass

# --- paint (home, clear each line to EOL, clear to end) ----------------------
sys.stdout.write("\033[H")
for ln in lines[:H]:
    sys.stdout.write(ln + "\033[K\n")
sys.stdout.write("\033[J")
sys.stdout.flush()
PY
}

watch() {
  # the dashboard is a single pane; drop every other window (e.g. leftovers from
  # the old tab-based design). Identify our own window via $TMUX_PANE — the
  # attached client's active window is not necessarily the one running watch.
  local self_win
  self_win=$(T display -p -t "${TMUX_PANE:-}" '#{window_index}' 2>/dev/null)
  if [ -n "$self_win" ]; then
    for w in $(T list-windows -F '#{window_index}' 2>/dev/null); do
      [ "$w" != "$self_win" ] && T kill-window -t "agents:$w" 2>/dev/null
    done
  fi
  printf '\033[2J'
  while :; do
    local size w h
    size=$(T display -p '#{pane_width} #{pane_height}' 2>/dev/null)
    w=${size% *}; h=${size#* }
    render "${w:-120}" "${h:-12}"
    sleep 4
  done
}

click() {
  local x="${1:-0}" s e lbl
  [ -r "$COLMAP" ] || return 0
  while read -r s e lbl; do
    if (( x >= s && x <= e )); then
      focus "$lbl"
      return 0
    fi
  done < "$COLMAP"
}

focus() {
  local needle="$*"
  [ -z "$needle" ] && return 0
  /usr/bin/osascript - "$needle" <<'APPLESCRIPT' 2>/dev/null
on run argv
  set needle to item 1 of argv
  tell application "System Events"
    tell process "Ghostty"
      repeat with w in windows
        if name of w contains needle then
          perform action "AXRaise" of w
          set frontmost to true
          return "focused: " & needle
        end if
      end repeat
    end tell
  end tell
  return "no window titled like: " & needle
end run
APPLESCRIPT
}

# Rightmost screen in AX (top-left origin) coordinates: "x y width height".
screen_geo() {
  swift -e 'import AppKit
let prim = NSScreen.screens[0].frame
let right = NSScreen.screens.max { $0.frame.origin.x < $1.frame.origin.x }!.frame
print("\(Int(right.origin.x)) \(Int(prim.maxY - right.maxY)) \(Int(right.width)) \(Int(right.height))")'
}

open_strip() {
  read -r sx sy sw sh < <(screen_geo)
  local cols=$(( sw * 10 / 72 )) rows=$(( sh / 150 ))
  (( rows < 8 )) && rows=8
  # Keep the title bar (decoration on): a borderless Ghostty window exposes an
  # empty AX title, which the positioner needs to find it. Magnet still snaps it.
  # Font size 17 = Ghostty's default (13) plus 4 zoom steps (Cmd-+ x4).
  /usr/bin/open -na Ghostty --args \
    --title="agents-strip" --font-size=17 \
    --window-width="$cols" --window-height="$rows" \
    --window-position-x="$sx" --window-position-y="$sy" \
    -e "$SELF" boot
}

# Place the strip window on the right screen's top section. Uses Magnet's
# "Very Top" command (as the developer asked); falls back to sizing it via the
# Accessibility API if Magnet isn't available. Needs Accessibility permission
# for whatever runs this (Ghostty, and the launcher's osascript).
position_strip() {
  read -r sx sy sw sh < <(screen_geo)
  /usr/bin/osascript - "$sx" "$sy" "$sw" "$sh" <<'APPLESCRIPT'
on run argv
  set sx to (item 1 of argv) as integer
  set sy to (item 2 of argv) as integer
  set sw to (item 3 of argv) as integer
  set sh to (item 4 of argv) as integer
  set theWin to missing value
  tell application "System Events"
    if not (exists process "Ghostty") then return "no ghostty"
    -- Single-instance Ghostty spreads windows across processes; search all.
    -- The strip's title is "agents-strip" if the terminal honours it, else it
    -- is the only EMPTY-titled Ghostty window (Claude windows are always named).
    -- Gather candidate windows: titled "agents-strip" first, then empty-titled
    -- (the strip is untitled when the terminal doesn't honour the title).
    set cands to {}
    repeat with p in (every process whose name is "Ghostty")
      try
        repeat with w in (every window of p whose name contains "agents-strip")
          set end of cands to {w, p}
        end repeat
      end try
    end repeat
    repeat with p in (every process whose name is "Ghostty")
      try
        repeat with w in (every window of p whose name is "")
          set end of cands to {w, p}
        end repeat
      end try
    end repeat
    -- Act on the first candidate that is live (skips stale/orphan handles).
    repeat with cp in cands
      try
        set w to item 1 of cp
        set p to item 2 of cp
        set frontmost of p to true
        perform action "AXRaise" of w
        set position of w to {sx + 20, sy + 20}
        set theWin to w
        exit repeat
      end try
    end repeat
    if theWin is missing value then return "no window"
  end tell
  delay 0.4
  set didMagnet to false
  tell application "System Events"
    if exists process "Magnet" then
      tell process "Magnet"
        -- Magnet's snapping commands live in its status-icon menu (menu bar 2).
        try
          set mb to menu bar item 1 of menu bar 2
          click mb
          delay 0.3
          click menu item "Very Top" of menu 1 of mb
          set didMagnet to true
        on error
          try
            key code 53 -- Esc: close the menu if "Very Top" isn't there
          end try
        end try
      end tell
    end if
  end tell
  if not didMagnet then
    tell application "System Events"
      set position of theWin to {sx, sy}
      set size of theWin to {sw, (sh / 8) as integer}
    end tell
    return "positioned via AX fallback (Magnet 'Very Top' not found)"
  end if
  return "positioned via Magnet 'Very Top'"
end run
APPLESCRIPT
}

# Login entrypoint: wait for the GUI, ensure the strip is running, then position
# it. Launched by the LaunchAgent at every login.
start() {
  local i
  # at login the GUI/Dock may not be ready yet; wait briefly for it
  for i in $(seq 1 30); do
    /usr/bin/pgrep -xq Dock && break
    sleep 1
  done
  # Ensure a visible Ghostty window is ATTACHED to the strip. The server can
  # outlive its window (0 clients); boot's `new -A` re-attaches to it.
  if [ "$(T list-clients 2>/dev/null | wc -l | tr -d ' ')" = "0" ]; then
    open_strip
    for i in $(seq 1 50); do
      [ "$(T list-clients 2>/dev/null | wc -l | tr -d ' ')" != "0" ] && break
      sleep 0.5
    done
    sleep 1
  fi
  # Magnet does the snapping; give it a chance to come up (falls back to AX if not)
  for i in $(seq 1 20); do
    /usr/bin/pgrep -xq Magnet && break
    sleep 1
  done
  position_strip
}

# Background summarizer: Haiku writes a terse label of what the agent is doing.
# Invoked by the renderer when a session goes idle with new content.
summarize() {
  local jsonl="$1" sid="$2" sig="$3"
  mkdir -p "$SUMDIR" "$LLMCWD"
  local lock="$SUMDIR/$sid.lock" ctx prompt out
  ctx=$(JSONL="$jsonl" /usr/bin/python3 <<'PY'
import json, os
f = os.environ["JSONL"]
def text_of(content):
    if isinstance(content, str):
        return content
    parts = []
    if isinstance(content, list):
        for b in content:
            if not isinstance(b, dict):
                continue
            t = b.get("type")
            if t == "text":
                parts.append(b.get("text", ""))
            elif t == "tool_use":
                parts.append("[uses %s]" % b.get("name", ""))
    return " ".join(p for p in parts if p)
try:
    lines = open(f, encoding="utf-8", errors="ignore").read().splitlines()
except OSError:
    lines = []
msgs = []
for line in lines[-80:]:
    try:
        r = json.loads(line)
    except json.JSONDecodeError:
        continue
    if r.get("type") not in ("user", "assistant"):
        continue
    txt = " ".join(text_of((r.get("message") or {}).get("content")).split())
    if txt:
        msgs.append("%s: %s" % (r["type"], txt[:240]))
print("\n".join(msgs[-10:]))
PY
)
  [ -z "$ctx" ] && { rm -f "$lock"; return 0; }
  prompt="You are labeling a coding-agent session for a compact dashboard column. From the recent transcript below, write a plain label of 3 to 7 words describing what the agent is currently working on, or what it is waiting for. Output only the label: no quotes, no punctuation, no trailing period.

Transcript:
$ctx"
  out=$(env -C "$LLMCWD" "$CLAUDE_BIN" -p --model haiku "$prompt" 2>/dev/null \
        | tr '\n' ' ' | sed 's/"//g; s/^ *//; s/ *$//')
  if [ -n "$out" ]; then
    printf '%s' "${out:0:60}" > "$SUMDIR/$sid.txt"
    printf '%s' "$sig" > "$SUMDIR/$sid.sig"
  fi
  rm -f "$lock"
}

boot() { exec tmux -L "$SOCK" -f "$CONF" new -A -s agents "$SELF watch"; }

case "${1:-open}" in
  open)     open_strip ;;
  boot)     boot ;;
  watch)    watch ;;
  render)   render "${2:-120}" "${3:-12}" ;;
  click)    shift; click "$@" ;;
  focus)    shift; focus "$*" ;;
  start)    start ;;
  position) position_strip ;;
  summarize) shift; summarize "$@" ;;
  *) echo "usage: agents-strip.sh [open|boot|watch|render W H|click X|focus <name>|start|position]" >&2; exit 2 ;;
esac
