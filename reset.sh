#!/bin/bash
set -euo pipefail

echo "=== Resetting SecureBlue VM ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_OPTS="-p 2222 -i ${SCRIPT_DIR}/ssh/coreos_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

ssh -tt ${SSH_OPTS} core@host.containers.internal 'set -euxo pipefail

RUN0="systemd-run --service-type=exec --uid=0 --pty --working-directory=/tmp --wait"

# Stop and disable snapshot timers/services
for svc in nextcloud proxy monitoring; do
  $RUN0 systemctl stop  "btrfs-snapshot@${svc}.timer"  2>/dev/null || true
  $RUN0 systemctl disable "btrfs-snapshot@${svc}.timer" 2>/dev/null || true
  $RUN0 systemctl stop  "btrfs-snapshot@${svc}.service"  2>/dev/null || true
  $RUN0 systemctl disable "btrfs-snapshot@${svc}.service" 2>/dev/null || true
done

# Remove systemd unit files for snapshots
$RUN0 rm -f /etc/systemd/system/btrfs-snapshot@.service
$RUN0 rm -f /etc/systemd/system/btrfs-snapshot@.timer
$RUN0 rm -f /usr/local/bin/btrfs-snapshot-cleanup.sh

# Remove SELinux file contexts
$RUN0 semanage fcontext -d "/var/services/nextcloud(/.*)?"  2>/dev/null || true
$RUN0 semanage fcontext -d "/var/services/proxy(/.*)?"     2>/dev/null || true
$RUN0 semanage fcontext -d "/var/services/monitoring(/.*)?"  2>/dev/null || true
$RUN0 semanage fcontext -d "/var/services/snapshots(/.*)?"  2>/dev/null || true
$RUN0 semanage fcontext -d "/var/services(/.*)?"            2>/dev/null || true

# Delete Btrfs subvolumes
for svc in nextcloud proxy monitoring snapshots; do
  $RUN0 sh -c "if [ -d \"/var/services/${svc}\" ]; then btrfs subvolume delete \"/var/services/${svc}\" 2>/dev/null || rm -rf \"/var/services/${svc}\"; fi"
done

# Delete service users
$RUN0 userdel -r nextcloud  2>/dev/null || true
$RUN0 userdel -r proxy      2>/dev/null || true
$RUN0 userdel -r monitoring 2>/dev/null || true

# Remove subuid/subgid entries
$RUN0 sed -i "/^nextcloud:/d" /etc/subuid /etc/subgid 2>/dev/null || true
$RUN0 sed -i "/^proxy:/d"     /etc/subuid /etc/subgid 2>/dev/null || true
$RUN0 sed -i "/^monitoring:/d" /etc/subuid /etc/subgid 2>/dev/null || true

# Reload systemd
$RUN0 systemctl daemon-reload

echo "=== RESET COMPLETE ==="
' 2>&1