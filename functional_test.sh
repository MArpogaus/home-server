#!/bin/bash
# SecureBlue Functional Tests
# Run from the deployment machine: ./functional_test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_OPTS="-p 2222 -i ${SCRIPT_DIR}/ssh/coreos_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o LogLevel=ERROR"
SSH="ssh ${SSH_OPTS} core@host.containers.internal"
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
  ${SSH} "systemd-run --service-type=exec --uid=0 --wait --collect --quiet -- sh -c \"\$(echo ${b64} | base64 -d) > /tmp/ff-out\"" 2>/dev/null || true
  # Read temp file
  ${SSH} "cat /tmp/ff-out" 2>/dev/null || true
}

# Run a command as a specific service user via root-wrapped machinectl shell
run_user() {
  local user="$1" cmd="$2"
  local b64
  b64=$(printf '%s' "$cmd" | base64 -w0)
  # machinectl shell as user, wrapped in systemd-run as root
  ${SSH} "systemd-run --service-type=exec --uid=0 --wait --collect --quiet -- sh -c \"machinectl shell ${user}@ /usr/bin/bash -c \\\"\\\$(echo ${b64} | base64 -d)\\\" > /tmp/ff-out\"" 2>/dev/null || true
  ${SSH} "cat /tmp/ff-out" 2>/dev/null || true
}

check_output() {
  local desc="$1" cmd="$2" pattern="$3"
  local out
  out=$(run_root "${cmd}")
  if echo "$out" | grep -q "$pattern"; then
    pass "$desc"
  else
    fail "$desc (expected pattern: $pattern, got: $(echo "$out"))"
  fi
}

check_user_output() {
  local user="$1" desc="$2" cmd="$3" pattern="$4"
  local out
  out=$(run_user "${user}" "${cmd}")
  if echo "$out" | grep -q "$pattern"; then
    pass "$desc"
  else
    fail "$desc: expected pattern $pattern, got: $(echo "$out")"
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
check_output "Nextcloud subvolume exists" "btrfs subvolume list /var/services" "nextcloud"
check_output "Proxy subvolume exists" "btrfs subvolume list /var/services" "proxy"
check_output "Monitoring subvolume exists" "btrfs subvolume list /var/services" "monitoring"
check_output "Snapshots subvolume exists" "btrfs subvolume list /var/services" "snapshots"

echo "--- Snapshot Timers ---"
check_output "Nextcloud snapshot timer enabled" "systemctl is-enabled btrfs-snapshot@nextcloud.timer" "enabled"
check_output "Proxy snapshot timer enabled" "systemctl is-enabled btrfs-snapshot@proxy.timer" "enabled"
check_output "Monitoring snapshot timer enabled" "systemctl is-enabled btrfs-snapshot@monitoring.timer" "enabled"

echo "--- Auto-reboot Timer ---"
check_output "Auto-reboot timer enabled" "systemctl is-enabled auto-reboot-staged.timer" "enabled"

echo "--- Service Users ---"
check_output "Nextcloud user exists" "id nextcloud" "uid=82"
check_output "Proxy user exists" "id proxy" "uid=1001"
check_output "Monitoring user exists" "id monitoring" "uid=1002"

echo "--- Subuid/Subgid ---"
check_output "Nextcloud subuid" "grep ^nextcloud: /etc/subuid" "100000"
check_output "Proxy subuid" "grep ^proxy: /etc/subuid" "165536"
check_output "Monitoring subuid" "grep ^monitoring: /etc/subuid" "231072"

echo "--- Containers ---"
run_for_user nextcloud "Nextcloud" "nextcloud-db nextcloud-redis nextcloud-app nextcloud-web nextcloud-cron promtail-nc"
run_for_user proxy "Bunker" "bunker-nginx bunker-scheduler promtail-proxy"
run_for_user monitoring "Monitoring" "monitoring-loki monitoring-prometheus monitoring-grafana monitoring-node-exporter monitoring-promtail"

echo "--- pg_dumpall Timer ---"
check_output "pg_dumpall timer enabled" "systemctl is-enabled pg-dumpall.timer" "enabled"

echo "--- Loki Reachability ---"
check_output "Loki is ready" "curl -sf -o /dev/null -w %{http_code} http://localhost:3100/ready" "200"

echo "--- HTTP/HTTPS ---"
check_output "HTTP 200 from Bunkerweb" "curl -sf -o /dev/null -w %{http_code} http://localhost:80" "200"
check_output "HTTPS 200 from Bunkerweb" "curl -sfk -o /dev/null -w %{http_code} https://localhost:443" "200"

echo "--- Grafana ---"
check_output "Grafana API health" "curl -sf http://localhost:3000/api/health" "ok"

echo "--- Prometheus ---"
check_output "Prometheus API targets" "curl -sf -o /dev/null -w %{http_code} http://localhost:9090/api/v1/targets" "200"

echo "--- System Configuration ---"
check_output "Unprivileged port start = 80" "sysctl -n net.ipv4.ip_unprivileged_port_start" "^80$"

echo "--- Existing Snapshots ---"
check_output "At least one snapshot exists" "ls /var/services/snapshots/nextcloud/" "^[0-9]"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
exit $FAIL
