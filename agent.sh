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

# Call the hook script WITHOUT a shell, with all following parameters.
cmd=("$script" "${parts[@]:1}")
audit "RUN: $line"

if out=$("${cmd[@]}" 2>&1); then
  audit "OK: $name (rc=0)"
  echo "OK"
  echo "$out"
else
  rc=$?
  audit "FAIL: $name (rc=$rc)"
  echo "FAIL ($rc)"
  echo "$out"
fi
