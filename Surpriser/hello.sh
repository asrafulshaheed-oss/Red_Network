#!/usr/bin/env bash
# =============================================================================
#  >>>>>>>>>>>>>>>>>>>>>>>>  CHANGE THESE TO ANYTHING  <<<<<<<<<<<<<<<<<<<<<<<<
# =============================================================================

# Line 1: BIG, colorful, thunder-strike animation. Keep it short (a few words).
TELL="Hello Boss"

# Line 2: normal size, colorful, typed out like a real person. Can be a whole
#         paragraph. (Press Enter inside the quotes for a new paragraph.)
TELLAGAIN="You have been hacked. However how's your day going? Everything allright? I hope we can meet someday!"

# TYPING SPEED of line 2, in words per minute. Set any number you like:
#   50 = relaxed, 70 = normal, 90 = fast, 100+ = very fast.
WPM=120

# =============================================================================
#  hello.sh - opens a NEW terminal window and shows TELL + TELLAGAIN.
#
#  Works on : any Linux (Ubuntu, Mint, Fedora, Arch, Manjaro, Omarchy, Kali,
#             Parrot ...) with any desktop / WM (GNOME, KDE, XFCE, MATE,
#             Hyprland ...) and macOS (works with Apple's built-in bash 3.2).
#
#  Run      : bash hello.sh
#             bash hello.sh "I Have Linux, Bro"             -> overrides TELL
#             bash hello.sh "Blockbuster Boss" "Some text"   -> overrides both
#  Skip     : press any key while it types to finish instantly.
# =============================================================================

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
E=$'\033'

# Rainbow for the big banner (256-color codes) - flows smoothly, never shakes.
PAL=(196 202 208 214 220 226 190 154 118 46 48 51 45 39 33 27 57 93 129 165 201 199 198 197)
# Softer rainbow for the typed line.
TPAL=(209 215 221 227 191 155 119 85 86 87 81 75 69 105 141 177 213 212 211 210)

# ---------------------------------------------------------------------------
#  Built-in big font (5 rows high). No figlet/toilet needed.
#  "/" separates rows, "#" = filled pixel, "." = empty pixel.
# ---------------------------------------------------------------------------
glyph() {
  case "$1" in
    A) G=".###./#...#/#####/#...#/#...#" ;;
    B) G="####./#...#/####./#...#/####." ;;
    C) G=".####/#..../#..../#..../.####" ;;
    D) G="####./#...#/#...#/#...#/####." ;;
    E) G="#####/#..../####./#..../#####" ;;
    F) G="#####/#..../####./#..../#...." ;;
    G) G=".####/#..../#..##/#...#/.####" ;;
    H) G="#...#/#...#/#####/#...#/#...#" ;;
    I) G="#####/..#../..#../..#../#####" ;;
    J) G="..###/...#./...#./#..#./.##.." ;;
    K) G="#...#/#..#./###../#..#./#...#" ;;
    L) G="#..../#..../#..../#..../#####" ;;
    M) G="#...#/##.##/#.#.#/#...#/#...#" ;;
    N) G="#...#/##..#/#.#.#/#..##/#...#" ;;
    O) G=".###./#...#/#...#/#...#/.###." ;;
    P) G="####./#...#/####./#..../#...." ;;
    Q) G=".###./#...#/#.#.#/#..#./.##.#" ;;
    R) G="####./#...#/####./#..#./#...#" ;;
    S) G=".####/#..../.###./....#/####." ;;
    T) G="#####/..#../..#../..#../..#.." ;;
    U) G="#...#/#...#/#...#/#...#/.###." ;;
    V) G="#...#/#...#/#...#/.#.#./..#.." ;;
    W) G="#...#/#...#/#.#.#/##.##/#...#" ;;
    X) G="#...#/.#.#./..#../.#.#./#...#" ;;
    Y) G="#...#/.#.#./..#../..#../..#.." ;;
    Z) G="#####/...#./..#../.#.../#####" ;;
    0) G=".###./#..##/#.#.#/##..#/.###." ;;
    1) G="..#../.##../..#../..#../.###." ;;
    2) G=".###./#...#/...#./..#../#####" ;;
    3) G="####./....#/.###./....#/####." ;;
    4) G="#..#./#..#./#####/...#./...#." ;;
    5) G="#####/#..../####./....#/####." ;;
    6) G=".###./#..../####./#...#/.###." ;;
    7) G="#####/....#/...#./..#../..#.." ;;
    8) G=".###./#...#/.###./#...#/.###." ;;
    9) G=".###./#...#/.####/....#/.###." ;;
    '!') G=".#./.#./.#./.../.#." ;;
    '?') G=".###./#...#/..##./...../..#.." ;;
    '.') G=".../.../.../.../.#." ;;
    ',') G=".../.../.../.#./#.." ;;
    ':') G=".../.#./.../.#./..." ;;
    ';') G=".../.#./.../.#./#.." ;;
    "'") G=".#./.#./.../.../..." ;;
    '"') G="#.#/#.#/.../.../..." ;;
    '-') G="..../..../####/..../...." ;;
    '_') G="...../...../...../...../#####" ;;
    '+') G="...../..#../.###./..#../....." ;;
    '=') G="...../#####/...../#####/....." ;;
    '/') G="....#/...#./..#../.#.../#...." ;;
    '(') G="..#/.#./.#./.#./..#" ;;
    ')') G="#../.#./.#./.#./#.." ;;
    '<') G="...#/..#./.#../..#./...#" ;;
    '>') G="#.../.#../..#./.#../#..." ;;
    '*') G="...../#.#.#/.###./#.#.#/....." ;;
    '#') G=".#.#./#####/.#.#./#####/.#.#." ;;
    '@') G=".###./#.###/#.#.#/#.##./.###." ;;
    '&') G=".##../#..#./.##.#/#..#./.##.#" ;;
    '$') G=".####/#.#../.###./..#.#/####." ;;
    '%') G="##..#/##.#./..#../.#.##/#..##" ;;
    *)   G="..../..../..../..../...." ;;   # space / unknown character
  esac
}

# Pixel width of a piece of text (every glyph + 1 pixel gap).
text_px() {
  local s="$1" i w=0 r0
  for ((i = 0; i < ${#s}; i++)); do
    glyph "${s:i:1}"; r0=${G%%/*}
    w=$(( w + ${#r0} + 1 ))
  done
  TPX=$w
}

# Pack the words of TELL into banner lines that fit the window.
# $1 = pixel width (1 or 2 columns per pixel). Result in BLINES.
pack_banner() {
  local pw=$1 maxpx cur="" curpx=0 w wpx chunk ch i
  maxpx=$(( (COLS - 4) / pw ))
  BLINES=()
  for w in "${TWORDS[@]}"; do
    text_px "$w"; wpx=$TPX
    if (( wpx > maxpx )); then          # one giant word: break it up
      [[ -n "$cur" ]] && BLINES+=("$cur")
      cur=""; curpx=0; chunk=""
      for ((i = 0; i < ${#w}; i++)); do
        ch="${w:i:1}"; text_px "$chunk$ch"
        if (( TPX > maxpx )) && [[ -n "$chunk" ]]; then BLINES+=("$chunk"); chunk="$ch"
        else chunk="$chunk$ch"; fi
      done
      cur="$chunk"; text_px "$cur"; curpx=$TPX
      continue
    fi
    if [[ -z "$cur" ]]; then cur="$w"; curpx=$wpx
    elif (( curpx + 5 + wpx <= maxpx )); then cur="$cur $w"; curpx=$(( curpx + 5 + wpx ))
    else BLINES+=("$cur"); cur="$w"; curpx=$wpx; fi
  done
  [[ -n "$cur" ]] && BLINES+=("$cur")
}

# Word-wrap TELLAGAIN to width $1. Result in PLINES.
wrap_text() {
  local width=$1 para line w
  local -a words
  PLINES=()
  while IFS= read -r para || [[ -n "$para" ]]; do
    read -r -a words <<< "$para"
    line=""
    for w in "${words[@]}"; do
      while (( ${#w} > width )); do                # very long word
        [[ -n "$line" ]] && { PLINES+=("$line"); line=""; }
        PLINES+=("${w:0:width}"); w="${w:width}"
      done
      if [[ -z "$line" ]]; then line="$w"
      elif (( ${#line} + 1 + ${#w} <= width )); then line="$line $w"
      else PLINES+=("$line"); line="$w"; fi
    done
    PLINES+=("$line")
  done <<< "$TELLAGAIN"
}

# Build the pixel text of every banner line.
# Placeholders: "X" = solid block, " " = empty.
build_banner() {
  local L r c i rowstr up
  local -a bm g
  TXT=(); WPX=(); LCOL=()
  for ((L = 0; L < ${#BLINES[@]}; L++)); do
    bm=("" "" "" "" "")
    up="${BLINES[L]}"
    for ((i = 0; i < ${#up}; i++)); do
      glyph "${up:i:1}"
      IFS='/' read -r -a g <<< "$G"
      for r in 0 1 2 3 4; do bm[r]="${bm[r]}${g[r]}."; done
    done
    local W=$(( ${#bm[0]} - 1 ))                  # drop the trailing gap
    for ((r = 0; r < 5; r++)); do
      rowstr=""
      for ((c = 0; c < W; c++)); do
        if [[ "${bm[r]:c:1}" == "#" ]]; then rowstr+="$BLK"; else rowstr+="$SPC"; fi
      done
      TXT+=("$rowstr")
    done
    WPX+=("$W")
    c=$(( (COLS - W * PW) / 2 + 1 )); (( c < 1 )) && c=1
    LCOL+=("$c")
  done
}

# Render one banner frame into FRAME. $1 = color offset, $2 = fixed color (opt).
render() {
  local off=$1 fixed=$2 out="" L r c b len seg col W txt S=2 NP=${#PAL[@]}
  for ((L = 0; L < ${#BLINES[@]}; L++)); do
    W=${WPX[L]}
    for ((r = 0; r < 5; r++)); do
      txt="${TXT[L*5 + r]}"
      out+="${E}[$(( BROW + L * 6 + r ));${LCOL[L]}H"
      c=0
      while (( c < W )); do
        b=$(( (c + r + off) / S ))
        len=$(( (b + 1) * S - (c + r + off) ))
        (( c + len > W )) && len=$(( W - c ))
        seg="${txt:c*PW:len*PW}"
        case "$seg" in
          *X*)
            if [[ -n "$fixed" ]]; then col=$fixed; else col=${PAL[b % NP]}; fi
            seg="${seg//X/█}"
            out+="${E}[38;5;${col}m${seg}" ;;
          *) out+="$seg" ;;
        esac
        c=$(( c + len ))
      done
    done
  done
  FRAME="${out}${E}[0m"
}

nap() { sleep "$1" 2>/dev/null || sleep 1; }

# Wait $1 milliseconds; return 0 if a key was pressed meanwhile.
wait_key() {
  local ms=$1 s; (( ms < 1 )) && ms=1
  printf -v s '%d.%03d' $(( ms / 1000 )) $(( ms % 1000 ))
  if (( BASH_VERSINFO[0] >= 4 )); then
    IFS= read -rsn1 -t "$s" KEY && return 0
    return 1
  fi
  nap "$s"                                        # bash 3.2 (macOS)
  KEY=$(dd bs=1 count=1 2>/dev/null)
  [[ -n "$KEY" ]]
}

flash() {   # $1 = background color, $2 = seconds  (whole screen lights up)
  printf '%s' "${E}[48;5;${1}m${E}[2J${FILL}${E}[0m"; nap "$2"; printf '%s' "${E}[0m${E}[2J"
}

# This runs INSIDE the new terminal window.
show() {
  local size i up tw maxlen=0 l BH PL TOP fits=0 tick=0 skip=0 col cidx=0 d ch j line
  OLDSTTY=$(stty -g 2>/dev/null)
  trap 'printf "%s" "${E}[0m${E}[?25h"; [[ -n "$OLDSTTY" ]] && stty "$OLDSTTY" 2>/dev/null' EXIT
  trap 'exit 130' INT TERM
  if (( BASH_VERSINFO[0] >= 4 )); then stty -echo 2>/dev/null
  else stty -echo -icanon min 0 time 0 2>/dev/null; fi

  printf '%s' "${E}[?25l${E}[0m${E}[2J${E}[H"
  sleep 0.3                                       # let the new window settle
  size=$(stty size 2>/dev/null)
  ROWS=${size% *}; COLS=${size#* }
  [[ "$ROWS" =~ ^[0-9]+$ ]] || ROWS=24
  [[ "$COLS" =~ ^[0-9]+$ ]] || COLS=80

  up=$(printf '%s' "$TELL" | tr '[:lower:]' '[:upper:]')
  read -r -a TWORDS <<< "$up"
  (( ${#TWORDS[@]} == 0 )) && TWORDS=("HELLO")

  tw=$(( COLS - 8 )); (( tw > 78 )) && tw=78; (( tw < 20 )) && tw=20
  wrap_text "$tw"
  for l in "${PLINES[@]}"; do (( ${#l} > maxlen )) && maxlen=${#l}; done
  PL=${#PLINES[@]}

  # Big (2 columns per pixel) if it fits, otherwise smaller.
  PW=2; pack_banner 2
  BH=$(( ${#BLINES[@]} * 6 - 1 ))
  if (( BH + PL + 7 > ROWS )); then
    PW=1; pack_banner 1; BH=$(( ${#BLINES[@]} * 6 - 1 ))
  fi
  if (( PW == 2 )); then BLK="XX"; SPC="  "; else BLK="X"; SPC=" "; fi
  (( BH + PL + 7 <= ROWS )) && fits=1

  TOP=$(( (ROWS - (BH + PL + 6)) / 2 )); (( TOP < 0 )) && TOP=0
  BROW=$(( 2 + TOP ))
  local PROW=$(( BROW + BH + 2 ))
  local PCOL=$(( (COLS - maxlen) / 2 + 1 )); (( PCOL < 1 )) && PCOL=1
  local PADS; printf -v PADS '%*s' $(( PCOL - 1 )) ''

  build_banner
  NFR=$(( ${#PAL[@]} * 2 ))
  FR=()
  for ((i = 0; i < NFR; i++)); do render "$i"; FR+=("$FRAME"); done
  render 0 231; F_WHITE="$FRAME"
  render 0 51;  F_BLUE="$FRAME"
  render 0 54;  F_DIM="$FRAME"

  local row blank; printf -v blank '%*s' $(( COLS - 1 )) ''
  FILL=""; for ((row = 1; row <= ROWS; row++)); do FILL+="${E}[${row};1H${blank}"; done

  local BORDER="" k
  for ((k = 0; k < COLS - 1; k++)); do
    if (( k % 2 )); then BORDER+="▄"; else BORDER+="▀"; fi
  done

  # ------------------------- THUNDER STRIKE INTRO -------------------------
  nap 0.5
  flash 255 0.05; nap 0.08
  flash 231 0.09; nap 0.05
  printf '%s' "$F_WHITE"; nap 0.12
  printf '%s' "${E}[2J"; nap 0.35
  flash 231 0.04
  printf '%s' "$F_WHITE"; nap 0.07
  printf '%s' "$F_BLUE";  nap 0.07
  printf '%s' "$F_WHITE"; nap 0.06
  printf '%s' "$F_DIM";   nap 0.25
  printf '%s' "${E}[1;1H${E}[38;5;54m${BORDER}${E}[0m"
  (( fits )) && printf '%s' "${E}[${ROWS};1H${E}[38;5;54m${BORDER}${E}[0m"
  for ((i = 0; i < NFR / 2; i++)); do printf '%s' "${FR[i]}"; nap 0.06; done
  tick=$(( NFR / 2 ))

  # -------------------------- TYPE THE SECOND LINE ------------------------
  local BASE=$(( 12000 / (WPM > 0 ? WPM : 45) ))   # ms per character
  printf '%s' "${E}[${PROW};${PCOL}H"
  for ((j = 0; j < PL; j++)); do
    line="${PLINES[j]}"
    (( j > 0 )) && printf '\r\n%s' "$PADS"
    for ((i = 0; i < ${#line}; i++)); do
      ch="${line:i:1}"
      col=${TPAL[(cidx / 2) % ${#TPAL[@]}]}; cidx=$(( cidx + 1 ))
      printf '%s' "${E}[22;38;5;${col}m${ch}${E}[38;5;252m▌${E}[D"
      (( skip )) && continue
      d=$(( BASE * (60 + RANDOM % 81) / 100 ))
      case "$ch" in
        '.'|'!'|'?') d=$(( d + 350 )) ;;
        ','|';'|':') d=$(( d + 150 )) ;;
        ' ')         d=$(( d * 7 / 10 )) ;;
      esac
      if (( fits )); then
        tick=$(( tick + 1 )); printf '%s' "${E}7${FR[tick % NFR]}${E}8"
      fi
      wait_key "$d" && skip=1
    done
    printf ' \b%s' "${E}[0m"
  done

  # ---------------- footer, then keep the banner gently alive ---------------
  local t2="[ press any key to escape ]"
  printf '\r\n\r\n%*s%s' $(( (COLS - ${#t2}) / 2 )) '' "${E}[38;5;240m${t2}${E}[0m"
  if (( fits )); then
    local strike=$(( 40 + RANDOM % 40 ))
    while :; do
      tick=$(( tick + 1 ))
      if (( tick % strike == 0 )); then          # a lightning strike now and then
        printf '%s' "${E}7${F_WHITE}${E}8"; nap 0.06
        printf '%s' "${E}7${F_BLUE}${E}8";  nap 0.05
        strike=$(( 40 + RANDOM % 40 ))
      fi
      printf '%s' "${E}7${FR[tick % NFR]}${E}8"
      wait_key 80 && break
    done
  else
    while ! wait_key 200; do :; done
  fi
  printf '%s' "${E}[0m${E}[2J${E}[H${E}[?25h"
}

# ---------------------------------------------------------------------------
#  Opening a brand-new terminal window
# ---------------------------------------------------------------------------
terminal_candidates() {
  local pref=""
  case "${XDG_CURRENT_DESKTOP:-}" in
    *KDE*)                               pref="konsole" ;;
    *GNOME*|*Unity*|*Budgie*|*Cinnamon*) pref="ptyxis gnome-terminal kgx" ;;
    *XFCE*)                              pref="xfce4-terminal" ;;
    *MATE*)                              pref="mate-terminal" ;;
    *LXQt*)                              pref="qterminal" ;;
    *LXDE*)                              pref="lxterminal" ;;
  esac
  echo "$pref xdg-terminal-exec ghostty kitty alacritty foot wezterm ptyxis gnome-terminal kgx konsole xfce4-terminal mate-terminal qterminal lxterminal tilix terminator x-terminal-emulator urxvt st xterm"
}

open_in() {   # $1 = terminal program, $2 = launcher script
  local t="$1" l="$2"
  case "$t" in
    xdg-terminal-exec) set -- xdg-terminal-exec bash "$l" ;;
    ghostty)           set -- ghostty -e bash "$l" ;;
    kitty)             set -- kitty bash "$l" ;;
    alacritty)         set -- alacritty -e bash "$l" ;;
    foot)              set -- foot bash "$l" ;;
    wezterm)           set -- wezterm start -- bash "$l" ;;
    ptyxis)            set -- ptyxis --new-window -x "bash $l" ;;
    gnome-terminal)    set -- gnome-terminal --geometry=100x34 -- bash "$l" ;;
    kgx)               set -- kgx -e "bash $l" ;;
    konsole)           set -- konsole --separate -e bash "$l" ;;
    xfce4-terminal)    set -- xfce4-terminal --geometry=100x34 -x bash "$l" ;;
    mate-terminal)     set -- mate-terminal --geometry=100x34 -x bash "$l" ;;
    qterminal)         set -- qterminal -e "bash $l" ;;
    lxterminal)        set -- lxterminal -e "$l" ;;
    tilix)             set -- tilix -e "bash $l" ;;
    terminator)        set -- terminator -x bash "$l" ;;
    x-terminal-emulator) set -- x-terminal-emulator -e bash "$l" ;;
    urxvt)             set -- urxvt -e bash "$l" ;;
    st)                set -- st -e bash "$l" ;;
    xterm)             set -- xterm -geometry 100x34 -fa Monospace -fs 13 -e bash "$l" ;;
    *) return 1 ;;
  esac
  nohup "$@" >/dev/null 2>&1 &
  disown 2>/dev/null
  return 0
}

launch() {
  local launcher t
  launcher="$(mktemp "${TMPDIR:-/tmp}/hello.XXXXXX")" || { show; return; }
  # tiny helper script: runs the banner, then deletes itself
  printf '#!/usr/bin/env bash\nbash %q --show %q %q\nrm -f -- "$0"\n' \
    "$SELF" "$TELL" "$TELLAGAIN" > "$launcher"
  chmod +x "$launcher"

  case "$(uname -s)" in
    Darwin)
      if osascript >/dev/null 2>&1 <<OSA
tell application "Terminal"
  activate
  do script "bash '$launcher'"
  try
    set bounds of front window to {60, 60, 1060, 760}
  end try
end tell
OSA
      then
        echo "Opened a new Terminal window..."
        return 0
      fi
      ;;
    MINGW*|MSYS*|CYGWIN*)
      rm -f "$launcher"
      echo "This is Windows - please use the C# version (hello.cs) instead."
      return 1
      ;;
    *)
      if [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
        for t in $(terminal_candidates); do
          command -v "$t" >/dev/null 2>&1 || continue
          if open_in "$t" "$launcher"; then
            echo "Opened a new terminal window ($t)..."
            return 0
          fi
        done
      fi
      ;;
  esac

  # No GUI terminal available (SSH / TTY): just run it right here.
  rm -f "$launcher"
  show
}

# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--show" ]]; then
  TELL="${2:-$TELL}"; TELLAGAIN="${3:-$TELLAGAIN}"
  show
else
  TELL="${1:-$TELL}"; TELLAGAIN="${2:-$TELLAGAIN}"
  launch
fi
