#!/bin/bash
set -euo pipefail

# Keep in sync with base_setup_services in ansible-base.
SERVICES="${SERVICES:-nextcloud proxy monitoring}"

echo "=== Resetting SecureBlue VM ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The VM is a local QEMU guest with SSH forwarded to 2222; override for a real host.
TARGET_HOST="${TARGET_HOST:-127.0.0.1}"
SSH_OPTS=(-p 2222 -i "${SCRIPT_DIR}/ssh/coreos_key"
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

ssh -tt "${SSH_OPTS[@]}" "core@${TARGET_HOST}" "SERVICES='${SERVICES}' bash -s" <<'REMOTE'
set -euxo pipefail

RUN0="systemd-run --service-type=exec --uid=0 --pty --working-directory=/tmp --wait"

# Stop and disable snapshot timers/services
for svc in ${SERVICES}; do
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
for path in "/var/services/snapshots(/.*)?" "/var/services(/.*)?"; do
  $RUN0 semanage fcontext -d "$path" 2>/dev/null || true
done

# Snapshots are read-only subvolumes nested inside /var/services/snapshots,
# so they must go before their parent.
$RUN0 sh -c 'for snap in /var/services/snapshots/*/*; do
  [ -d "$snap" ] && btrfs subvolume delete "$snap"
done' || true

for svc in ${SERVICES} snapshots; do
  $RUN0 btrfs subvolume delete "/var/services/${svc}" 2>/dev/null \
    || $RUN0 rm -rf "/var/services/${svc}" 2>/dev/null || true
done

# Delete service users and their subuid/subgid entries
for svc in ${SERVICES}; do
  $RUN0 loginctl disable-linger "${svc}" 2>/dev/null || true
  $RUN0 userdel -r "${svc}" 2>/dev/null || true
  $RUN0 sed -i "/^${svc}:/d" /etc/subuid /etc/subgid 2>/dev/null || true
done

# Reload systemd
$RUN0 systemctl daemon-reload

echo "=== RESET COMPLETE ==="
REMOTE
