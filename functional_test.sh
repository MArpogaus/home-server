#!/bin/bash
# SecureBlue Functional Tests
# Run from the deployment machine: ./functional_test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The VM is a local QEMU guest with SSH forwarded to 2222; override for a real host.
TARGET_HOST="${TARGET_HOST:-127.0.0.1}"
SSH=(ssh -p 2222 -i "${SCRIPT_DIR}/ssh/coreos_key"
     -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
     -o IdentitiesOnly=yes -o LogLevel=ERROR "core@${TARGET_HOST}")
# Keep in sync with base_setup_services in ansible-base.
SERVICES="${SERVICES:-nextcloud proxy monitoring}"
PASS=0
FAIL=0

pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# Run a command as root via systemd-run with output capture via temp file
run_root() {
  local cmd="$1"
  local b64
  b64=$(printf '%s' "$cmd" | base64 -w0)
  # Execute via systemd-run as root, redirect output to temp file
  "${SSH[@]}" "systemd-run --service-type=exec --uid=0 --wait --collect --quiet -- sh -c \"\$(echo ${b64} | base64 -d) > /tmp/ff-out\"" 2>/dev/null || true
  # Read temp file
  "${SSH[@]}" "cat /tmp/ff-out" 2>/dev/null || true
}

# Run a command inside a service user's systemd user manager (wrapped in systemd-run as root)
run_user() {
  local user="$1" cmd="$2"
  local b64
  b64=$(printf '%s' "$cmd" | base64 -w0)
  # run inside the service user's systemd user manager, wrapped in systemd-run as root
  "${SSH[@]}" "systemd-run --service-type=exec --uid=0 --wait --collect --quiet -- sh -c \"systemd-run --machine=${user}@ --user --wait --pipe --collect --quiet /usr/bin/bash -c \\\"\\\$(echo ${b64} | base64 -d)\\\" > /tmp/ff-out\"" 2>/dev/null || true
  "${SSH[@]}" "cat /tmp/ff-out" 2>/dev/null || true
}

check_output() {
  local desc="$1" cmd="$2" pattern="$3"
  local out
  out=$(run_root "${cmd}")
  if echo "$out" | grep -q "$pattern"; then
    pass "$desc"
  else
    fail "$desc (expected pattern: $pattern, got: ${out})"
  fi
}

check_user_output() {
  local user="$1" desc="$2" cmd="$3" pattern="$4"
  local out
  out=$(run_user "${user}" "${cmd}")
  if echo "$out" | grep -q "$pattern"; then
    pass "$desc"
  else
    fail "$desc: expected pattern $pattern, got: ${out}"
  fi
}

run_for_user() {
  local user="$1" desc="$2" expected="$3"
  local actual
  actual=$(run_user "${user}" "podman ps --format {{.Names}}")
  for container in $expected; do
    if echo "$actual" | grep -q "$container"; then
      pass "$desc: $container running"
    else
      fail "$desc: $container NOT running (found: $(echo "$actual" | tr '\n' ' '))"
    fi
  done
}

echo "=== SecureBlue Functional Tests ==="
echo ""

echo "--- Firewall ---"
check_output "SSH allowed" "firewall-cmd --list-services" "ssh"
check_output "HTTP allowed" "firewall-cmd --list-services" "http"
check_output "HTTPS allowed" "firewall-cmd --list-services" "https"
check_output "Port 3000 blocked" "firewall-cmd --list-ports" "^$"

echo "--- Btrfs Subvolumes ---"
for svc in ${SERVICES} snapshots; do
  check_output "Subvolume ${svc} exists" "btrfs subvolume list /var/services" "${svc}"
done

echo "--- Snapshot Timers ---"
for svc in ${SERVICES}; do
  check_output "Snapshot timer ${svc} enabled" "systemctl is-enabled btrfs-snapshot@${svc}.timer" "enabled"
done

echo "--- Auto-reboot Timer ---"
check_output "Auto-reboot timer enabled" "systemctl is-enabled auto-reboot-staged.timer" "enabled"

echo "--- Service Users ---"
for svc in ${SERVICES}; do
  check_output "User ${svc} exists" "id ${svc}" "uid="
  # subuid start is uid * 65536 + 100000, so just assert an entry exists
  check_output "Subuid range for ${svc}" "grep ^${svc}: /etc/subuid" ":65536$"
  check_output "Linger enabled for ${svc}" "loginctl show-user ${svc} -p Linger --value" "yes"
done

echo "--- Containers ---"
run_for_user nextcloud "Nextcloud" "nextcloud-db nextcloud-redis nextcloud-app nextcloud-web nextcloud-cron nextcloud-push"
run_for_user proxy "Bunker" "bunker-nginx bunker-scheduler"
run_for_user monitoring "Monitoring" "monitoring-loki monitoring-alloy monitoring-prometheus monitoring-alertmanager monitoring-grafana monitoring-node-exporter"

echo "--- Health ---"
check_user_output nextcloud "No unhealthy nextcloud containers" "podman ps --filter health=unhealthy --format {{.Names}}" "^$"
check_user_output monitoring "No unhealthy monitoring containers" "podman ps --filter health=unhealthy --format {{.Names}}" "^$"

echo "--- Nextcloud via host port (Bunkerweb upstream path) ---"
check_output "status.php answers on 8080" "curl -sf http://127.0.0.1:8080/status.php" "installed"

echo "--- pg_dumpall Timer ---"
check_output "pg_dumpall timer enabled" "systemctl is-enabled pg-dumpall.timer" "enabled"

echo "--- Loki Reachability ---"
check_output "Loki is ready" "curl -sf -o /dev/null -w %{http_code} http://127.0.0.1:3100/ready" "200"
check_output "Loki receives journal logs from Alloy" "curl -sf -G http://127.0.0.1:3100/loki/api/v1/label/job/values" "systemd-journal"

echo "--- HTTP/HTTPS ---"
check_output "HTTP 200 from Bunkerweb" "curl -sf -o /dev/null -w %{http_code} http://127.0.0.1:80" "200"
check_output "HTTPS 200 from Bunkerweb" "curl -sfk -o /dev/null -w %{http_code} https://127.0.0.1:443" "200"

echo "--- Grafana ---"
check_output "Grafana API health" "curl -sf http://127.0.0.1:3000/api/health" "ok"

echo "--- Prometheus ---"
check_output "Prometheus scrapes node exporter" "curl -sf http://127.0.0.1:9090/api/v1/targets" '"job":"node".*"health":"up"'
check_output "Prometheus loaded alert rules" "curl -sf http://127.0.0.1:9090/api/v1/rules" "HostLowDiskSpace"

echo "--- System Configuration ---"
check_output "Unprivileged port start = 80" "sysctl -n net.ipv4.ip_unprivileged_port_start" "^80$"
check_output "zram swap active" "swapon --show --noheadings" "zram0"

echo "--- Existing Snapshots ---"
check_output "At least one snapshot exists" "ls /var/services/snapshots/nextcloud/" "^[0-9]"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
exit $FAIL
