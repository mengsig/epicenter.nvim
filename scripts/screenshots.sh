#!/usr/bin/env bash
# Regenerates assets/*.svg: a real Neovim, driving the real panels against a
# real `navgraph lsp`, captured out of a 120x36 tmux pane.
#
#   make screenshots                       # navgraph from $PATH
#   NAVGRAPH_BIN=/path/to/navgraph make screenshots
#
# The fixture tree is copied under a throwaway HOME first, so a committed asset
# shows `~/demo` rather than the path it happened to be built from.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nvim="${NVIM:-nvim}"
navgraph="${NAVGRAPH_BIN:-navgraph}"
scheme="${EPICENTER_SHOT_COLORS:-habamax}"
shots=(search blast explorer outline-status)

for tool in tmux "$nvim"; do
  command -v "$tool" >/dev/null || { echo "screenshots: $tool is not installed" >&2; exit 1; }
done
command -v "$navgraph" >/dev/null || [ -x "$navgraph" ] || {
  echo "screenshots: no navgraph binary at '$navgraph' (set NAVGRAPH_BIN)" >&2
  exit 1
}
navgraph="$(command -v "$navgraph" || printf '%s' "$navgraph")"

# A private tmux server on its own socket: nothing here can reach, resize or
# kill a session the user already had open.
socket="epicenter-shots-$$"
work="$(mktemp -d)"
cleanup() {
  tmux -L "$socket" kill-server 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

cp -r "$repo/tests/fixtures/real" "$work/demo"
rm -rf "$work/demo/.navgraph"
mkdir -p "$work/demo/.navgraph" "$repo/assets"

for shot in "${shots[@]}"; do
  session="shot-$shot"
  tmux -L "$socket" -f /dev/null new-session -d -s "$session" -x 120 -y 36 \
    -e "HOME=$work" \
    -e "NAVGRAPH_BIN=$navgraph" \
    -e "EPICENTER_SHOT=$shot" \
    -e "EPICENTER_SHOT_ROOT=$work/demo" \
    -e "EPICENTER_SHOT_COLORS=$scheme" \
    -e "EPICENTER_SHOT_NORMAL_FILE=$work/normal.txt" \
    -e "COLORTERM=truecolor" \
    "cd '$repo' && '$nvim' --clean -u scripts/shot_init.lua; sleep 120"

  # The driver indexes the tree and drives the surface before it settles; poll
  # for the frame rather than guessing a sleep long enough for a cold index.
  for _ in $(seq 1 60); do
    sleep 1
    tmux -L "$socket" capture-pane -p -t "$session" | grep -q '[^[:space:]]' && break
  done
  sleep 2

  tmux -L "$socket" capture-pane -p -e -N -t "$session" > "$work/$shot.ans"
  tmux -L "$socket" kill-session -t "$session" 2>/dev/null || true

  read -r fg bg < "$work/normal.txt"
  "$nvim" --headless --clean -l "$repo/scripts/ansi2svg.lua" \
    "$work/$shot.ans" "$repo/assets/$shot.svg" "$fg" "$bg"
  echo "assets/$shot.svg"
done
