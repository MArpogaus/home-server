#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
require_vault_password
ssh_opts
CTL_DIR=$(mktemp -d)
trap 'rm -rf "${CTL_DIR}"' EXIT
SSH=(ssh -p "${TARGET_PORT}" "${SSH_OPTS[@]}" -o LogLevel=ERROR
     -o ControlMaster=auto -o ControlPersist=60s -o ControlPath="${CTL_DIR}/%C"
     "core@${TARGET_HOST}")
# Name of a configured backup target to check, e.g. usb. Empty skips it.
BACKUP_TARGET="${BACKUP_TARGET:-}"
PASS=0
FAIL=0

pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# 255 is ssh's own failure; every other status is the remote command's, which
# several checks expect to be non-zero while still printing a value. The
# optional second argument is the remote stdin, so a credential stays off
# every command line; without it stdin is empty.
remote() {
  local out rc=0
  out=$(printf '%s' "${2-}" | "${SSH[@]}" "$1" 2>/dev/null) || rc=$?
  [[ ${rc} -eq 255 ]] && { echo "__HOST_UNREACHABLE__"; return 0; }
  printf '%s\n' "${out//$'\r'/}"
}

b64() { printf '%s' "$1" | base64 -w0; }

RUN0="run0 --pty --setenv=SYSTEMD_PAGER=cat --setenv=SYSTEMD_COLORS=0 --setenv=NO_COLOR=1"

run_root() {
  remote "${RUN0} -- sh -c \"\$(echo $(b64 "$1") | base64 -d)\""
}

run_user() {
  remote "${RUN0} --user=$1 -- /usr/bin/bash -c \"\$(echo $(b64 "$2") | base64 -d)\""
}

# As core, with `lq <path> [curl args]` querying Loki through Grafana's
# datasource proxy. The admin credential travels on ssh stdin.
GRAFANA_CFG=$(printf 'user = "admin:%s"\n' "$(read_var monitoring_service_grafana_admin_password)")
run_loki() {
  remote "bash -c 'cfg=\$(cat); lq() { curl -sf -K <(printf %s \"\$cfg\") \"http://127.0.0.2:3000/api/datasources/proxy/uid/loki\$@\"; }; eval \"\$(echo $(b64 "$1") | base64 -d)\"'" "${GRAFANA_CFG}"
}

# Both numbers of the ruler's notifier, on one line. A series Loki has not
# created yet reads as 0 rather than an empty field.
NOTIFY_AWK="awk '/^loki_prometheus_notifications_sent_total/{s=\$2} /^loki_prometheus_notifications_errors_total/{e=\$2} END{print (s+0) \" \" (e+0)}'"

# The host knows which services it carries, so a service the inventory adds
# is tested too.
SERVICES="${SERVICES:-$(run_root "cut -d: -f1 /etc/subuid | grep -vx core | tr '\\n' ' '")}"

expect() {
  if grep -q -- "$3" <<<"$2"; then
    pass "$1"
  else
    fail "$1 (expected pattern: $3, got: $2)"
  fi
}
check_output() { expect "$1" "$(run_root "$2")" "$3"; }
RULES_HEALTH=$'grep -o \'"health":"[a-z]*"\' | awk \'/err/{e++} /ok/{o++} END{print "err=" e+0 " ok=" o+0}\''
check_user_output() { expect "$2" "$(run_user "$1" "$3")" "$4"; }
check_loki() { expect "$1" "$(run_loki "$2")" "$3"; }

echo "=== Functional tests ==="
echo ""

echo "--- Firewall ---"
check_output "SSH, HTTP and HTTPS allowed" "firewall-cmd --list-services | tr ' ' '\\n' | grep -cxE 'ssh|http|https'" "^3$"
# Prints something only when firewalld runs, so an empty answer cannot pass.
check_output "Port 3000 blocked" \
  "[ -z \"\$(firewall-cmd --list-ports)\" ] && firewall-cmd --state" "^running$"

echo "--- Btrfs Subvolumes ---"
for svc in ${SERVICES} snapshots; do
  # Anchored: the snapshots of a deleted subvolume carry its name in their path.
  check_output "Subvolume ${svc} exists" "btrfs subvolume list /var/services" " path .*/${svc}$"
done

# A nested subvolume stays out of every snapshot and backup.
check_output "custom_apps is a nested subvolume" \
  "btrfs subvolume show /var/services/nextcloud/data/custom_apps" "Subvolume ID"

echo "--- Signature Policy ---"
check_output "An unknown image is rejected" \
  "jq -r '.default[0].type' /etc/containers/policy.json" "^reject$"
check_output "This project's registry needs a signature" \
  "jq -r '.transports.docker[\"ghcr.io/marpogaus\"][0].type' /etc/containers/policy.json" \
  "^sigstoreSigned$"

echo "--- SELinux Labels ---"
# A label stays on disk once set, so these catch a missing z or Z on a fresh
# host only.
check_user_output nextcloud "Nextcloud logs to the journal" \
  "podman exec -u www-data nextcloud-app php occ log:manage" "backend: syslog"
check_output "Nextcloud's files are container_file_t" \
  "stat -c %C /var/services/nextcloud/data/data" "container_file_t"
check_output "Alloy's config is relabelled for the container" \
  "stat -c %C /var/services/monitoring/.config/containers/systemd/configs/config.alloy" \
  "container_file_t"
echo "--- Snapshot Timers ---"
for svc in ${SERVICES}; do
  check_output "Snapshot timer ${svc} enabled" "systemctl is-enabled btrfs-snapshot@${svc}.timer" "^enabled$"
done

echo "--- Auto-reboot Timer ---"
# Anchored: enabled-runtime is gone after a reboot.
check_output "Auto-reboot timer enabled" "systemctl is-enabled auto-reboot-staged.timer" "^enabled$"
# A rollback disables this timer, and no role enables it.
check_output "Update staging timer enabled" "systemctl is-enabled rpm-ostreed-automatic.timer" "^enabled$"

echo "--- Service Users ---"
for svc in ${SERVICES}; do
  check_output "User ${svc} exists" "id ${svc}" "uid="
  # The start depends on the uid; the size is the invariant.
  check_output "Subuid range for ${svc}" "grep ^${svc}: /etc/subuid" ":65536$"
  check_output "Linger enabled for ${svc}" "loginctl show-user ${svc} -p Linger --value" "yes"
done

echo "--- Containers ---"
# Every Quadlet container of a service runs, and none reports unhealthy. Retried:
# a deploy that pulled a new image restarts the pod.
# shellcheck disable=SC2016  # expanded by the service user's shell
CONTAINERS_CMD='units=$(ls "$HOME"/.config/containers/systemd/*.container | xargs -n1 basename | sed "s/\.container$/.service/")
echo "units=$(echo $units | wc -w) inactive=$(systemctl --user is-active $units | grep -cvx active) unhealthy=$(podman ps --filter health=unhealthy -q | wc -l)"'
for svc in ${SERVICES}; do
  for _ in $(seq 1 12); do
    out=$(run_user "${svc}" "${CONTAINERS_CMD}")
    grep -q "inactive=0 unhealthy=0$" <<<"${out}" && break
    sleep 10
  done
  expect "Containers of ${svc} run and none is unhealthy" "${out}" "^units=[1-9][0-9]* inactive=0 unhealthy=0$"
done

echo "--- Nextcloud via host port (BunkerWeb upstream path) ---"
check_output "status.php answers on 8080" "curl -sf http://127.0.0.1:8080/status.php" '"installed":true'

echo "--- pg_dumpall ---"
check_output "the snapshot pulls in the dump" \
  "systemctl show btrfs-snapshot@nextcloud.service -p Wants -p After" "nextcloud-pg-dumpall.service"
check_output "pg_dumpall produces a dump" \
  "systemctl start nextcloud-pg-dumpall.service && systemctl is-failed nextcloud-pg-dumpall.service" "inactive"
# A truncated dump still has bytes, so assert the structure a restore needs.
check_output "dump contains the database and roles" \
  "grep -lE '^CREATE DATABASE' \$(find /var/services/nextcloud/data/db_dumps -name 'dump-*.sql' | sort | tail -1)" "dump-"
check_output "dump contains Nextcloud tables" \
  "grep -cE '^CREATE TABLE.*oc_' \$(find /var/services/nextcloud/data/db_dumps -name 'dump-*.sql' | sort | tail -1)" "^[1-9]"
check_output "dump ends cleanly" \
  "grep -c 'cluster dump complete' \$(find /var/services/nextcloud/data/db_dumps -name 'dump-*.sql' | sort | tail -1)" "^[1-9]"

echo "--- Btrfs Snapshot ---"
check_output "snapshot service succeeds" \
  "systemctl start btrfs-snapshot@nextcloud.service && systemctl is-failed btrfs-snapshot@nextcloud.service" "inactive"

echo "--- Loki Reachability ---"
# A query, not the label list: a label value outlives the lines that made it.
# Retried, because a deploy restarts Alloy.
check_loki "Loki received journal lines in the last 10 minutes" \
  "for i in \$(seq 1 18); do out=\$(lq /loki/api/v1/query -G --data-urlencode 'query=sum(count_over_time({job=\"systemd-journal\"}[10m]))'); case \"\$out\" in *'\"value\"'*) break;; esac; sleep 5; done; echo \"\$out\"" \
  '"value"'
# A rule whose query does not compile loads and then evaluates to "err".
check_loki "Every Loki alert rule evaluates" \
  "lq /prometheus/api/v1/rules | ${RULES_HEALTH}" \
  "^err=0 ok=[1-9]"

echo "--- HTTP/HTTPS ---"
SERVER_NAME="${SERVER_NAME:-$(read_var nextcloud_hostname)}"
# DISABLE_DEFAULT_SERVER drops a request whose Host or SNI matches no server:
# with TLS configured, BunkerWeb redirects HTTP to HTTPS, so 301 is the pass.
check_output "HTTP redirects to HTTPS" \
  "curl -s -o /dev/null -w %{http_code} -H 'Host: ${SERVER_NAME}' http://127.0.0.1:80" "30[18]"
# status.php, not /, which redirects to /login. Proves TLS, the proxy's site,
# nginx, php-fpm and the database in one request; 127.0.0.1 is on BunkerWeb's
# whitelist, so the WAF checks are not part of it. A wrong upstream gives 502.
check_output "HTTPS reaches Nextcloud through the proxy" \
  "curl -sk --max-time 15 --resolve ${SERVER_NAME}:443:127.0.0.1 https://${SERVER_NAME}/status.php" \
  '"installed":true'

echo "--- ntfy ---"
check_output "ntfy refuses anonymous publishing" \
  "curl -s -o /dev/null -w %{http_code} -d probe http://127.0.0.1:8081/alerts" "^403$"
# The token travels on ssh stdin into curl's config, so it is on no command line.
expect "ntfy accepts the token" \
  "$(remote 'curl -s -o /dev/null -w %{http_code} -K - -H "Title: functional test" -d "functional test" http://127.0.0.1:8081/alerts' \
    "$(printf 'header = "Authorization: Bearer %s"\n' "$(read_var monitoring_service_ntfy_token)")")" \
  "^200$"

# One burst of failed logins walks the whole path: journald, Alloy, Loki, the
# ruler and Alertmanager.
echo "--- Alerting end to end ---"
# Cumulative counters, so the delivery check compares against these.
NOTIFY_BEFORE=$(run_loki "lq /metrics | ${NOTIFY_AWK}")
PROBE_KEY=$(mktemp -u)
ssh-keygen -q -t ed25519 -N "" -f "${PROBE_KEY}"
for _ in $(seq 1 8); do
  ssh -p "${TARGET_PORT}" "${HOST_KEY_OPTS[@]}" -o LogLevel=ERROR -o BatchMode=yes \
      -o IdentitiesOnly=yes -o ConnectTimeout=10 -i "${PROBE_KEY}" \
      "core@${TARGET_HOST}" true </dev/null 2>/dev/null || true
done
rm -f "${PROBE_KEY}" "${PROBE_KEY}.pub"
# Reports the hop it reached: the shipper, the ruler API, or the rule.
check_loki "Failed logins make SshLoginFailed fire" \
  "for i in \$(seq 1 18); do
     line=\$(lq /loki/api/v1/query -G --data-urlencode 'query=sum(count_over_time({job=\"systemd-journal\", unit=\"sshd.service\"} |~ \"Connection closed by authenticating\" [5m]))' | grep -c '\"value\"')
     state=\$(lq /prometheus/api/v1/rules | jq -r '[.data.groups[].rules[] | select(.name == \"SshLoginFailed\") | .state] | first // \"absent\"' 2>/dev/null)
     [ -z \"\$state\" ] && state=no-api
     [ \"\$state\" = firing ] && { echo alert; exit 0; }
     sleep 10
   done
   [ \"\$line\" = 0 ] && echo 'no-line: the shipper never delivered it' || echo \"no-alert: Loki has the line, the rule is \$state\"" \
  "^alert$"
check_loki "The ruler delivers to Alertmanager" \
  "set -- ${NOTIFY_BEFORE}; was_sent=\$1; was_err=\$2
   for i in \$(seq 1 12); do
     set -- \$(lq /metrics | ${NOTIFY_AWK}); now_sent=\$1; now_err=\$2
     [ \"\$now_err\" != \"\$was_err\" ] && { echo \"errors rose \$was_err -> \$now_err\"; exit 0; }
     [ \"\$now_sent\" -gt \"\$was_sent\" ] 2>/dev/null && { echo ok; exit 0; }
     sleep 10
   done
   echo \"sent stuck at \$was_sent\"" \
  "^ok$"

echo "--- Prometheus ---"
# The filesystem collector fails silently: the scrape still succeeds.
check_output "The disk metric HostLowDiskSpace reads exists" \
  "curl -sf --get http://127.0.0.2:9090/api/v1/query --data-urlencode 'query=count(node_filesystem_avail_bytes{mountpoint=\"/var\"})'" \
  '"value":\[[0-9.]*,"1"\]'
check_output "The textfile metrics are scraped" \
  "curl -sf --get http://127.0.0.2:9090/api/v1/query --data-urlencode 'query=count(snapshot_last_success_timestamp_seconds)'" \
  '"value":\[[0-9.]*,"[1-9]'
check_output "Every Prometheus alert rule evaluates" \
  "curl -sf http://127.0.0.2:9090/api/v1/rules | ${RULES_HEALTH}" \
  "^err=0 ok=[1-9]"
# A host without probe URLs has no probe_success series and reads 1.
check_output "Blackbox probes succeed" \
  "curl -sfG http://127.0.0.2:9090/api/v1/query --data-urlencode 'query=min(probe_success) or vector(1)'" '"1"\]'

echo "--- Capabilities ---"
# SYS_CHROOT is in Podman's default set and no container adds it back, so
# seeing it means the drop-in did not apply. Infra containers are excluded.
CAPS_FILE="${CTL_DIR}/caps"
for svc in ${SERVICES}; do
  run_user "$svc" "podman ps -a --format '{{.Names}}' | grep -v -- '-infra\$' | xargs -r podman inspect --format '{{.Name}} {{.EffectiveCaps}}'" >> "${CAPS_FILE}"
done
if grep -q 'CAP_' "${CAPS_FILE}" && ! grep -q '__HOST_UNREACHABLE__' "${CAPS_FILE}" \
   && ! grep -q CAP_SYS_CHROOT "${CAPS_FILE}"; then
  pass "No container keeps the default capability set"
else
  fail "No container keeps the default capability set ($(grep CAP_SYS_CHROOT "${CAPS_FILE}"))"
fi

echo "--- System Configuration ---"
check_output "Unprivileged port start = 80" "sysctl -n net.ipv4.ip_unprivileged_port_start" "^80$"
check_output "zram swap active" "swapon --show --noheadings" "zram0"

if [[ -n "${BACKUP_TARGET}" ]]; then
  echo "--- Backup Target: ${BACKUP_TARGET} ---"
  check_output "Backup completes" \
    "systemctl start btrfs-backup@${BACKUP_TARGET}.service && systemctl is-failed btrfs-backup@${BACKUP_TARGET}.service" "inactive"
  check_output "Backup logs a completed run" \
    "journalctl -u btrfs-backup@${BACKUP_TARGET}.service -n 20 --no-pager" "run complete"
  check_output "Target is mounted by its automount" \
    "findmnt -no FSTYPE /var/backup/${BACKUP_TARGET}" "btrfs"
  check_output "Target is encrypted" \
    "cryptsetup status backup-${BACKUP_TARGET}" "LUKS2"
  check_output "Target holds a received subvolume" \
    "btrfs subvolume list /var/backup/${BACKUP_TARGET}" "nextcloud/"
fi

echo "--- logind ---"
# Last, after every run0 call above.
check_output "No logind session is stuck in closing" \
  "for s in \$(loginctl list-sessions --no-legend | awk '{print \$1}'); do loginctl show-session \"\$s\" -p State --value; done | grep -c closing" \
  "^[0-4]$"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
