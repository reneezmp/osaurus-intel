#!/bin/zsh
# Same as gate.sh but runs swift test under a pseudo-terminal. Falls back to
# the plain gate when no terminal is available (script(1) fails with
# "tcgetattr/ioctl: Operation not supported on socket" under some agents).
G="$(cd "$(dirname "$0")" && pwd)/gate.sh"
if script -q /dev/null true </dev/null >/dev/null 2>&1; then RUNNER="script -q /dev/null" exec "$G" "$@"; fi
echo "(no pty available; plain gate)"; exec "$G" "$@"
