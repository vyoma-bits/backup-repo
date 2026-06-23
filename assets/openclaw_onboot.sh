#!/usr/bin/env bash
###############################################################################
# OpenClaw on-boot recovery
#
# Counterpart to openclaw_bootstrap.sh. Runs on EVERY boot via the
# openclaw-onboot.service systemd unit - reboot, stop/start, and instance-type
# resize (stop -> change size -> start).
#
#   openclaw_bootstrap.sh = HEAVY first-boot install (Node, OpenClaw, AWS CLI, secret,
#                           config, gateway). Run ONCE by cloud-init UserData.
#   openclaw_onboot.sh    = LIGHT every-boot recovery. Installs NOTHING - packages, Node,
#                           OpenClaw and the AWS CLI all survive a restart on the persistent
#                           disk. It only:
#                             1. re-mounts the data EBS volume at ~/.openclaw if needed,
#                             2. makes sure the gateway is running.
#                           It does NOT pull config from S3 - config is seeded ONCE at bootstrap and
#                           then lives on the persistent volume.
###############################################################################
set -uo pipefail
export PATH="/usr/local/bin:$PATH"   # systemd boot context PATH is minimal; AWS CLI v2 is in /usr/local/bin
LOG=/var/log/openclaw-onboot.log
exec >> "$LOG" 2>&1
ts() { date -u +%FT%TZ; }
echo "[onboot $(ts)] start (reboot/stop-start/resize recovery)"

# Runtime values written by the first-boot bootstrap. Fall back sensibly if the file is missing.
[ -f /etc/openclaw/refresh.env ] && . /etc/openclaw/refresh.env
RUN_USER="${OC_RUN_USER:-ubuntu}"
OC_HOME="${OC_HOME:-$(getent passwd "$RUN_USER" | cut -d: -f6)/.openclaw}"

# 1) Make sure the data EBS volume is mounted at ~/.openclaw (fstab mounts it with nofail; re-mount if not).
if ! mountpoint -q "$OC_HOME"; then
  echo "[onboot] $OC_HOME not mounted - attempting mount"
  mount "$OC_HOME" 2>/dev/null || mount -a 2>/dev/null || echo "[onboot] WARN: could not mount $OC_HOME"
fi

# 2) Ensure the gateway is up. It is systemd-enabled so it should already auto-start on boot; this is the
#    belt-and-suspenders that recovers it (with a log line) if it didn't.
systemctl start openclaw-gateway.service 2>/dev/null || true
if systemctl is-active --quiet openclaw-gateway.service; then
  echo "[onboot] gateway active"
else
  echo "[onboot] WARN: gateway inactive after start - restarting"
  systemctl restart openclaw-gateway.service 2>/dev/null || true
fi
echo "[onboot $(ts)] done"
