#!/bin/sh
# deb postrm
set -e
if [ -d /run/systemd/system ]; then
  systemctl daemon-reload
fi
