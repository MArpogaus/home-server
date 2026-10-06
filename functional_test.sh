#!/bin/bash
set -euo pipefail

HOST="${1:?usage: $0 <host> -i <deployment dir>/inventory.yml [ansible options]}"
shift
cd "$(dirname "${BASH_SOURCE[0]}")"

LOOKUP_ERR=$(mktemp)
mapfile -t V < <(ANSIBLE_LOAD_CALLBACK_PLUGINS=1 ANSIBLE_STDOUT_CALLBACK=ansible.posix.json \
  ansible "${HOST}" "$@" -m debug -a 'msg={{ [ansible_host, ansible_port | default(22),
    ansible_ssh_common_args | default(""), ansible_ssh_private_key_file | default(""),
    base_setup_services | map(attribute="name") | join(" "), nextcloud_service_hostname,
    monitoring_service_grafana_admin_password, monitoring_service_alert_webhook_token | default(""),
    (base_setup_services | selectattr("name", "eq", "nextcloud") | first).port,
    base_setup_services | selectattr("name", "eq", "ntfy") | map(attribute="port") | first | default("")] }}' 2>"${LOOKUP_ERR}" \
  | python3 -c '
import json, sys
host = json.load(sys.stdin)["plays"][0]["tasks"][0]["hosts"][sys.argv[1]]
if host.get("failed"):
    sys.exit(host["msg"])
print("\n".join(map(str, host["msg"])))' "${HOST}" 2>>"${LOOKUP_ERR}")
if [[ ${#V[@]} -ne 10 ]]; then
  echo "ERROR: cannot read ${HOST} from the inventory:" >&2
  grep -v '^Traceback\|^  \|^json.decoder\|^KeyError\|^IndexError' "${LOOKUP_ERR}" >&2
  rm -f "${LOOKUP_ERR}"
  exit 1
fi
rm -f "${LOOKUP_ERR}"
TARGET_HOST=${V[0]}
TARGET_PORT=${V[1]}
read -ra HOST_KEY_OPTS <<<"${V[2]}"
SSH_OPTS=("${HOST_KEY_OPTS[@]}")
[[ -n "${V[3]}" ]] && SSH_OPTS+=(-i "${V[3]}")
SERVICES=${V[4]}
SERVER_NAME=${V[5]}
NEXTCLOUD_PORT=${V[8]}
NTFY_PORT=${V[9]}

CTL_DIR=$(mktemp -d)
HOLD=/run/systemd/system/auto-reboot-staged.service.d/functional-test.conf
RELEASE="while [ -n \"\$(systemctl list-jobs --no-legend 'btrfs-snapshot@*' 'btrfs-backup@*')\" ]; do sleep 10; done
rm -rf ${HOLD%/*}
systemctl daemon-reload"
release_hold() {
  [[ -n "${HELD-}" ]] || return 0
  run_root "systemd-run --quiet --collect --unit=functional-test-release sh -c \"\$(echo $(b64 "${RELEASE}") | base64 -d)\" && echo released" |
    grep -q released ||
    echo "WARNING: the staged reboot is still held; on the host run: run0 rm -r ${HOLD%/*} && run0 systemctl daemon-reload" >&2
}
trap 'release_hold; rm -rf "${CTL_DIR}"' EXIT
SSH=(ssh -p "${TARGET_PORT}" "${SSH_OPTS[@]}" -o LogLevel=ERROR
     -o ControlMaster=auto -o ControlPersist=60s -o ControlPath="${CTL_DIR}/%C"
     "core@${TARGET_HOST}")
BACKUP_TARGET="${BACKUP_TARGET:-}"
PASS=0
FAIL=0

pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

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

[[ "$(remote true)" != __HOST_UNREACHABLE__ ]] \
  || { echo "ERROR: cannot reach core@${TARGET_HOST}:${TARGET_PORT}" >&2; exit 1; }
remote 'test -e /run/polkit/root-gate && echo open' | grep -q open \
  || { echo "ERROR: The root gate is closed. Run \`root-gate on\` as core on the host; README.md, \"Deploy\"." >&2; exit 1; }

HELD=1
run_root "systemctl stop functional-test-release.service 2>/dev/null; mkdir -p ${HOLD%/*} && printf '[Unit]\\nConditionPathExists=/nonexistent\\n' > ${HOLD} && systemctl daemon-reload && echo held" |
  grep -q held || { echo "ERROR: cannot hold the staged reboot" >&2; exit 1; }

GRAFANA_CFG=$(printf 'user = "admin:%s"\n' "${V[6]}")
run_loki() {
  remote "bash -c 'cfg=\$(cat); lq() { curl -sf -K <(printf %s \"\$cfg\") \"http://127.0.0.2:3000/api/datasources/proxy/uid/loki\$@\"; }; eval \"\$(echo $(b64 "$1") | base64 -d)\"'" "${GRAFANA_CFG}"
}

NOTIFY_AWK="awk '/^loki_prometheus_notifications_sent_total/{s=\$2} /^loki_prometheus_notifications_errors_total/{e=\$2} END{print (s+0) \" \" (e+0)}'"

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

echo "--- Btrfs Subvolumes ---"
check_output "custom_apps is a nested subvolume" \
  "btrfs subvolume show /var/services/nextcloud/data/custom_apps" "Subvolume ID"

LAN_IP="\$(ip -4 route get 1.1.1.1 | grep -o 'src [0-9.]*' | cut -d' ' -f2)"

echo "--- Egress ---"
# shellcheck disable=SC2016
SSH_CONNECT='timeout 5 bash -c "</dev/tcp/$ip/22" 2>/dev/null; echo $?'
check_user_output nextcloud "A service user reaches no private address" \
  "ip=${LAN_IP}; ${SSH_CONNECT}" "^1$"
check_user_output nextcloud "A subuid reaches no private address" \
  "ip=${LAN_IP}; podman unshare setpriv --reuid 1000 --regid 1000 --clear-groups ${SSH_CONNECT}" "^1$"

echo "--- SELinux Labels ---"
check_user_output nextcloud "Nextcloud logs to the journal" \
  "podman exec -u www-data nextcloud-app php occ log:manage" "backend: syslog"
check_output "Nextcloud's files are container_file_t" \
  "stat -c %C /var/services/nextcloud/data/data" "container_file_t"
check_output "Alloy's config is relabelled for the container" \
  "stat -c %C /var/services/monitoring/.config/containers/systemd/configs/config.alloy" \
  "container_file_t"
echo "--- Auto-reboot Timer ---"
check_output "Auto-reboot timer enabled" "systemctl is-enabled auto-reboot-staged.timer" "^enabled$"
check_output "Update staging enabled" "systemctl is-enabled rpm-ostreed-automatic.timer zincati.service" "^enabled$"

echo "--- Containers ---"
# shellcheck disable=SC2016
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
check_output "status.php answers on the loopback port" "curl -sf http://127.0.0.1:${NEXTCLOUD_PORT}/status.php" '"installed":true'

echo "--- pg_dumpall ---"
check_output "pg_dumpall produces a dump" \
  "systemctl start nextcloud-pg-dumpall.service && systemctl is-failed nextcloud-pg-dumpall.service" "inactive"
LATEST_DUMP="\$(find /var/services/nextcloud/data/db_dumps -name 'dump-*.sql' | sort | tail -1)"
check_output "dump contains the database and roles" \
  "grep -lE '^CREATE DATABASE' ${LATEST_DUMP}" "dump-"
check_output "dump contains Nextcloud tables" \
  "grep -cE '^CREATE TABLE.*oc_' ${LATEST_DUMP}" "^[1-9]"
check_output "dump ends cleanly" \
  "grep -c 'cluster dump complete' ${LATEST_DUMP}" "^[1-9]"

echo "--- Btrfs Snapshot ---"
check_output "snapshot service succeeds" \
  "systemctl start btrfs-snapshot@nextcloud.service && systemctl is-failed btrfs-snapshot@nextcloud.service" "inactive"

echo "--- Loki Reachability ---"
check_loki "Loki received journal lines in the last 10 minutes" \
  "for i in \$(seq 1 18); do out=\$(lq /loki/api/v1/query -G --data-urlencode 'query=sum(count_over_time({job=\"systemd-journal\"}[10m]))'); case \"\$out\" in *'\"value\"'*) break;; esac; sleep 5; done; echo \"\$out\"" \
  '"value"'
check_loki "Every Loki alert rule evaluates" \
  "lq /prometheus/api/v1/rules | ${RULES_HEALTH}" \
  "^err=0 ok=[1-9]"

echo "--- HTTP/HTTPS ---"
check_output "HTTP redirects to HTTPS" \
  "curl -s -o /dev/null -w %{http_code} -H 'Host: ${SERVER_NAME}' http://127.0.0.1:80" "30[18]"
check_output "HTTPS reaches Nextcloud through the proxy" \
  "curl -sk --max-time 15 --resolve ${SERVER_NAME}:443:127.0.0.1 https://${SERVER_NAME}/status.php" \
  '"installed":true'
check_output "Push answers a WebSocket upgrade through the proxy" \
  "curl -sk --http1.1 --max-time 5 -o /dev/null -w %{http_code} -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' --resolve ${SERVER_NAME}:443:127.0.0.1 https://${SERVER_NAME}/push/ws" \
  "^101$"
check_output "HTTPS answers a client on the LAN" \
  "curl -sk --max-time 15 --resolve ${SERVER_NAME}:443:${LAN_IP} https://${SERVER_NAME}/status.php" \
  '"installed":true'

if [[ " ${SERVICES} " == *" ntfy "* ]]; then
  echo "--- ntfy ---"
  check_output "ntfy refuses anonymous publishing" \
    "curl -s -o /dev/null -w %{http_code} -d probe http://127.0.0.1:${NTFY_PORT}/alerts" "^403$"
  expect "ntfy accepts the token" \
    "$(remote 'curl -s -o /dev/null -w %{http_code} -K - -H "Title: functional test" -d "functional test" http://127.0.0.1:'"${NTFY_PORT}"'/alerts' \
      "$(printf 'header = "Authorization: Bearer %s"\n' "${V[7]}")")" \
    "^200$"
  expect "ntfy refuses a read with the token" \
    "$(remote 'curl -s -o /dev/null -w %{http_code} -K - "http://127.0.0.1:'"${NTFY_PORT}"'/alerts/json?poll=1"' \
      "$(printf 'header = "Authorization: Bearer %s"\n' "${V[7]}")")" \
    "^403$"
fi

echo "--- Alerting end to end ---"
NOTIFY_BEFORE=$(run_loki "lq /metrics | ${NOTIFY_AWK}")
PROBE_KEY=$(mktemp -u)
ssh-keygen -q -t ed25519 -N "" -f "${PROBE_KEY}"
for _ in $(seq 1 8); do
  ssh -p "${TARGET_PORT}" "${HOST_KEY_OPTS[@]}" -o LogLevel=ERROR -o BatchMode=yes \
      -o IdentitiesOnly=yes -o ConnectTimeout=10 -i "${PROBE_KEY}" \
      "core@${TARGET_HOST}" true </dev/null 2>/dev/null || true
done
rm -f "${PROBE_KEY}" "${PROBE_KEY}.pub"
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
check_output "The disk metric HostLowDiskSpace reads exists" \
  "curl -sf --get http://127.0.0.2:9090/api/v1/query --data-urlencode 'query=count(node_filesystem_avail_bytes{mountpoint=\"/var\"})'" \
  '"value":\[[0-9.]*,"1"\]'
check_output "The textfile metrics are scraped" \
  "curl -sf --get http://127.0.0.2:9090/api/v1/query --data-urlencode 'query=count(snapshot_last_success_timestamp_seconds)'" \
  '"value":\[[0-9.]*,"[1-9]'
check_output "Every Prometheus alert rule evaluates" \
  "curl -sf http://127.0.0.2:9090/api/v1/rules | ${RULES_HEALTH}" \
  "^err=0 ok=[1-9]"
check_output "Blackbox probes succeed" \
  "curl -sfG http://127.0.0.2:9090/api/v1/query --data-urlencode 'query=min(probe_success) or vector(1)'" '"1"\]'

echo "--- Capabilities ---"
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
check_output "No logind session is stuck in closing" \
  "for s in \$(loginctl list-sessions --no-legend | awk '{print \$1}'); do loginctl show-session \"\$s\" -p State --value; done | grep -c closing" \
  "^[0-4]$"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
