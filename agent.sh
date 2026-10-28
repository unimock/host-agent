#!/usr/bin/env bash
# agent.sh — host command agent (hook directory instead of regex whitelist)
# Started by socat per connection (see host-agent.service).
# Reads ONE line from the client (stdin); the reply goes back via stdout.
#
# Concept:
#   The first token of the line is the NAME of a hook script.
#   If /root/.host-agent/<name> exists as an executable script,
#   it is called with ALL following parameters. Otherwise: error.
#   => The "whitelist" is simply the contents of the hook directory.
#
# Reply modes:
#   "<name> args..."       -> ONE line: the hook's exit code (e.g. "0").
#   "+out <name> args..."  -> the hook's output, streamed line by line:
#                               O <stdout line>
#                               E <stderr line>
#                               X <exit code>      (always the last line)
#   Rejected requests reply "DENIED: <reason>" in both modes.
#   '+' can never be part of a hook name, so the marker cannot collide
#   with an existing hook, and older agents simply deny it.
set -euo pipefail

# socat/systemd start us without a login environment. Provide the
# variables hook scripts commonly rely on (e.g. docker reads
# $HOME/.docker). Values already present in the environment win.
export HOME="${HOME:-/root}"
export USER="${USER:-root}"
export LOGNAME="${LOGNAME:-root}"
export PATH="${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"

# ── hook directory ──────────────────────────────────────────────────
HOOK_DIR=/root/.host-agent
# ───────────────────────────────────────────────────────────────────

# Audit log to journald/syslog (tag "host-agent").
#   journalctl -t host-agent
audit() { logger -t host-agent -- "$1"; }

# Log a DENIED event, reply to the client, exit.
deny() {
  audit "DENIED: $1"
  echo "DENIED: $1"
  exit 1
}

# Read the line (with timeout so hanging connections do not block a
# socat fork forever).
if ! read -r -t 5 line; then
  deny "no input (timeout)"
fi

# Split into argv -> NO shell interpretation of the parameters.
read -ra parts <<< "$line"

# Optional "+out" marker: return the hook's STDOUT/STDERR as well.
mode=rc
if [ "${parts[0]:-}" = "+out" ]; then
  mode=out
  parts=("${parts[@]:1}")
fi
name="${parts[0]:-}"

if [ -z "$name" ]; then
  deny "empty input"
fi

# Prevent path traversal: allow simple names only,
# no '/', no leading dot, no '..' tricks.
if [[ ! "$name" =~ ^[A-Za-z0-9_-]+$ ]]; then
  deny "invalid script name '$name'"
fi

script="$HOOK_DIR/$name"

# Must be a regular, executable file.
if [ ! -f "$script" ] || [ ! -x "$script" ]; then
  deny "no hook script '$name' in $HOOK_DIR"
fi

# Prefix every line read from stdin with "$1 ". Also emits a final line
# that lacks its newline, so the "X" line always starts on a line of its own.
prefix() {
  local l
  while IFS= read -r l || [ -n "$l" ]; do
    printf '%s %s\n' "$1" "$l"
  done
}

# Call the hook script WITHOUT a shell, with all following parameters,
# and wait for it to finish completely.
#   mode rc:  reply with ONLY the exit code as a string. STDOUT/STDERR of
#             the hook are discarded (neither returned nor logged).
#   mode out: stream STDOUT/STDERR as "O ..."/"E ..." lines, then "X <rc>".
cmd=("$script" "${parts[@]:1}")
audit "RUN: $line"

rc=0
if [ "$mode" = out ]; then
  exec 5> >(prefix O); pO=$!
  exec 6> >(prefix E); pE=$!
  "${cmd[@]}" >&5 2>&6 || rc=$?
  exec 5>&- 6>&-
  # Make sure all output has been sent before the closing "X" line.
  wait "$pO" "$pE" || true
  audit "DONE: $name (rc=$rc)"
  echo "X $rc"
else
  "${cmd[@]}" >/dev/null 2>&1 || rc=$?
  audit "DONE: $name (rc=$rc)"
  echo "$rc"
fi
