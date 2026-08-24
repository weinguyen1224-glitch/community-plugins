#!/bin/sh
# Open omp's TUI in a terminal and auto-enter a slash command.
# Usage: open-tui.sh "/model"   (slash command, may include args)
set -eu

slash="${1:-}"

# Unique session name so concurrent opens don't collide.
session="omp-tui-$$"

# Pane runs `omp` directly (no shell), so keystrokes are buffered in the PTY
# until omp reads them — timing is not critical.
tmux new-session -d -s "$session" omp

# Give omp a moment to start, then inject the slash command literally + Enter.
sleep 1
tmux send-keys -t "$session" -l "$slash"
tmux send-keys -t "$session" Enter

# Attach; the terminal shows omp's TUI. Session ends when omp exits.
tmux attach-session -t "$session"
