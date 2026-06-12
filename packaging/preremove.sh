#!/bin/sh
# deb prerm — stop only on real removal, not on upgrade
set -e
if [ "$1" = "remove" ] && [ -d /run/systemd/system ]; then
  systemctl stop host-agent.service || true
  systemctl disable host-agent.service >/dev/null 2>&1 || true
fi
