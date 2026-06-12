#!/bin/sh
# deb postinst — $1 is "configure" on install and upgrade
set -e
if [ -d /run/systemd/system ]; then
  systemctl daemon-reload
  systemctl enable host-agent.service >/dev/null
  if systemctl is-active --quiet host-agent.service; then
    systemctl restart host-agent.service
  else
    systemctl start host-agent.service
  fi
fi
