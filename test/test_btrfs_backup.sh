#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/../roles/base_setup/files/btrfs-backup.sh"
SNAP_SCRIPT="${SCRIPT_DIR}/../roles/base_setup/files/btrfs-snapshot.sh"
D1="$(date -d '-3 days' +%F)"
D2="$(date -d '-2 days' +%F)"
D3="$(date -d '-1 day' +%F)"
DOLD="$(date -d '-100 days' +%F)"
DOLD2="$(date -d '-101 days' +%F)"
DOLD3="$(date -d '-102 days' +%F)"
PASS=0
FAIL=0

make_stub() {
	cat >"$1/btrfs" <<'STUB'
#!/bin/bash
case "$1 $2" in
"subvolume show")
	d="$3"
	[ -d "${d}" ] || { echo "ERROR: not a subvolume" >&2; exit 1; }
	echo "Name: $(basename "${d}")"
	if [ -e "${d}/.no-field" ]; then :
	elif [ -e "${d}/.received" ]; then
		echo "	Received UUID: 		f4d2b1a0-1111-2222-3333-444455556666"
	else
		echo "	Received UUID: 		-"
	fi
	;;
"subvolume snapshot")
	mkdir -p "$5"
	: >"$5/.subvol"
	;;
"subvolume delete")
	d="$3"
	[ -e "${d}/.subvol" ] || { echo "ERROR: not a subvolume" >&2; exit 1; }
	rm -rf "${d}"
	;;
"send -q")
	for a in "$@"; do last="$a"; done
	[ -z "${SEND_LOG:-}" ] || echo "$*" >>"${SEND_LOG}"
	echo "SEND:${last}"
	;;
receive*)
	read -r line
	src="${line#SEND:}"
	mkdir -p "$2/$(basename "${src}")"
	[ -e "$2/.error" ] && exit 1
	[ -e "$2/.fail" ] && exit 0
	: >"$2/$(basename "${src}")/.received"
	: >"$2/$(basename "${src}")/.subvol"
	;;
*) echo "stub: unexpected btrfs call: $*" >&2; exit 1 ;;
esac
STUB
	chmod +x "$1/btrfs"
	printf '#!/bin/sh\necho "CHCON:$*"\n' >"$1/chcon"
	chmod +x "$1/chcon"
}

place() {
	mkdir -p "$1"
	case "${2}" in
	received)
		: >"$1/.received"
		: >"$1/.subvol"
		;;
	nofield)
		: >"$1/.no-field"
		: >"$1/.subvol"
		;;
	nofield-plain)
		: >"$1/.no-field"
		;;
	esac
}

run_case() {
	local desc="$1" want_rc="$2" want_left="$3" want_name="${5-}" want_err="${6-}"
	local root out rc=0 left named=ok
	root="$(mktemp -d)"
	mkdir -p "${root}/bin" "${root}/snap" "${root}/backup"
	make_stub "${root}/bin"
	"${4}" "${root}"
	out="$(PATH="${root}/bin:${PATH}" bash -c \
		"cd ${root} && BTRFS_SNAPSHOT_DIR=${root}/snap BACKUP_ROOT=${root}/backup RETENTION_DAYS=90 NODE_TEXTFILE_DIR=${root} bash ${SCRIPT} t" 2>&1)" || rc=$?
	left="$(find "${root}/backup" -mindepth 3 -maxdepth 3 -type d | wc -l)"
	if [[ -n "${want_name}" && ! -d "${root}/backup/t/svc/${want_name}" ]]; then
		named="missing ${want_name}"
	fi
	if [[ -n "${want_err}" ]] && ! grep -qF "${want_err}" <<<"${out}"; then
		named="no '${want_err}' in the output"
	fi
	if { [[ "${rc}" == 0 ]] && ! grep -q '^backup_last_success_timestamp_seconds{target="t"} [0-9]' "${root}/backup-t.prom" 2>/dev/null; } ||
		{ [[ "${rc}" != 0 && -e "${root}/backup-t.prom" ]]; }; then
		named="metric does not match rc=${rc}"
	fi
	if [[ "${rc}" == "${want_rc}" && "${left}" == "${want_left}" && "${named}" == ok ]]; then
		PASS=$((PASS + 1)); echo "  PASS: ${desc}"
	else
		FAIL=$((FAIL + 1))
		echo "  FAIL: ${desc} (rc=${rc} want ${want_rc}, copies=${left} want ${want_left}, name ${named})"
		printf '        %s\n' "${out}"
	fi
	rm -rf "${root}"
}

setup_no_snapshots() { :; }

setup_first_sync() {
	mkdir -p "$1/snap/svc/${D1}"
}

setup_one_partial() {
	mkdir -p "$1/snap/svc/${D2}"
	place "$1/backup/t/svc/${D1}" unreceived
}

setup_two_partial() {
	mkdir -p "$1/snap/svc/${D3}"
	place "$1/backup/t/svc/${D1}" unreceived
	place "$1/backup/t/svc/${D2}" unreceived
}

setup_named_snapshot() {
	mkdir -p "$1/snap/svc/${D3}" "$1/snap/svc/${D3}-pre"
}

setup_refuse_one_of_two() {
	mkdir -p "$1/snap/aaa/${D3}" "$1/snap/zzz/${D3}"
	place "$1/backup/t/aaa/${D1}" unreceived
	place "$1/backup/t/aaa/${D2}" unreceived
}

setup_unfinished_one_of_two() {
	mkdir -p "$1/snap/aaa/${D3}" "$1/snap/zzz/${D3}" "$1/backup/t/aaa"
	: >"$1/backup/t/aaa/.fail"
}

setup_failed_one_of_two() {
	mkdir -p "$1/snap/aaa/${D3}" "$1/snap/zzz/${D3}" "$1/backup/t/aaa"
	: >"$1/backup/t/aaa/.error"
}

setup_field_gone() {
	mkdir -p "$1/snap/svc/${D3}"
	place "$1/backup/t/svc/${D1}" nofield
	place "$1/backup/t/svc/${D2}" nofield
}

setup_future_snapshot() {
	mkdir -p "$1/snap/svc/${D3}" "$1/snap/svc/$(date -d '+7 days' +%F)"
}

setup_field_gone_old_partial() {
	mkdir -p "$1/snap/svc/${D3}"
	place "$1/backup/t/svc/${DOLD}" nofield-plain
}

setup_stale_source() {
	mkdir -p "$1/snap/svc/${DOLD}"
	place "$1/backup/t/svc/${DOLD}" received
}

run_marker_case() {
	local desc="$1" setup="$2" want="$3" tgt="${4:-t}" root got=absent
	root="$(mktemp -d)"
	mkdir -p "${root}/bin" "${root}/snap" "${root}/backup"
	make_stub "${root}/bin"
	"${setup}" "${root}"
	PATH="${root}/bin:${PATH}" BTRFS_SNAPSHOT_DIR="${root}/snap" BACKUP_ROOT="${root}/backup" \
		RETENTION_DAYS=90 NODE_TEXTFILE_DIR="${root}" bash "${SCRIPT}" "${tgt}" >/dev/null 2>&1 || true
	[[ -e "${root}/snap/svc/.backed-up-${tgt}" ]] && got="$(cat "${root}/snap/svc/.backed-up-${tgt}")"
	if [[ "${got}" == "${want}" ]]; then
		PASS=$((PASS + 1)); echo "  PASS: ${desc}"
	else
		FAIL=$((FAIL + 1)); echo "  FAIL: ${desc} (marker ${got}, want ${want})"
	fi
	rm -rf "${root}"
}

run_prune_case() {
	local desc="$1" want_left="$2" want_gone="$3" root left gone
	root="$(mktemp -d)"
	mkdir -p "${root}/bin" "${root}/svc/svc" "${root}/snap/svc"
	make_stub "${root}/bin"
	for d in "${DOLD}" "${DOLD2}"; do place "${root}/snap/svc/${d}" received; done
	echo "${DOLD}" >"${root}/snap/svc/.backed-up-t"
	echo "${DOLD3}" >"${root}/snap/svc/.backed-up-u"
	place "${root}/snap/svc/${DOLD3}" received
	PATH="${root}/bin:${PATH}" BTRFS_SERVICES_DIR="${root}/svc" BTRFS_SNAPSHOT_DIR="${root}/snap" \
		RETENTION_DAYS=90 NODE_TEXTFILE_DIR="${root}" bash "${SNAP_SCRIPT}" svc >/dev/null 2>&1 || true
	left="$(find "${root}/snap/svc" -mindepth 1 -maxdepth 1 -type d -name '????-??-??' | wc -l)"
	gone=ok
	[[ -d "${root}/snap/svc/${DOLD2}" ]] && gone="${DOLD2} kept"
	[[ -d "${root}/snap/svc/${DOLD}" && -d "${root}/snap/svc/${DOLD3}" ]] || gone="marked snapshot deleted"
	[[ -d "${root}/snap/svc/$(date +%F)" ]] || gone="today missing"
	if [[ "${left}" == "${want_left}" && "${gone}" == "${want_gone}" ]]; then
		PASS=$((PASS + 1)); echo "  PASS: ${desc}"
	else
		FAIL=$((FAIL + 1)); echo "  FAIL: ${desc} (left ${left} want ${want_left}, ${gone})"
	fi
	rm -rf "${root}"
}

setup_marker_sent() { mkdir -p "$1/snap/svc/${D3}"; }
setup_marker_failed() { mkdir -p "$1/snap/svc/${D3}" "$1/backup/t/svc"; : >"$1/backup/t/svc/.error"; }
setup_marker_failed_old() { setup_marker_failed "$1"; echo "${D1}" >"$1/snap/svc/.backed-up-t"; }
setup_marker_already() { mkdir -p "$1/snap/svc/${D3}"; place "$1/backup/t/svc/${D3}" received; }

echo "=== btrfs-backup.sh ==="
run_case "no snapshot at all fails the run"        1 0 setup_no_snapshots
run_case "first sync sends one copy"               0 1 setup_first_sync
run_case "the target root gets the container label" 0 1 setup_first_sync "" "CHCON:-t container_file_t"
run_case "one partial copy is replaced"            0 1 setup_one_partial
run_case "two partial copies stop the run"         1 2 setup_two_partial "" "at least one service was skipped"
run_case "a missing field keeps every copy"        0 3 setup_field_gone
run_case "a future-dated snapshot is ignored"      0 1 setup_future_snapshot "${D3}"
run_case "a refused service does not stop the rest" 1 3 setup_refuse_one_of_two
run_case "an unfinished receive does not stop the rest" 1 2 setup_unfinished_one_of_two "" "did not finish"
run_case "a failed receive does not stop the rest"  1 2 setup_failed_one_of_two "" "did not finish"
run_case "a named snapshot is not the latest"      0 1 setup_named_snapshot "${D3}"
run_case "retention deletes an unreceivable leftover" 0 1 setup_field_gone_old_partial "${D3}"
run_case "retention keeps the copy of the latest snapshot" 0 1 setup_stale_source "${DOLD}"
run_marker_case "a verified send writes the marker" setup_marker_sent "${D3}"
run_marker_case "a failed receive writes no marker" setup_marker_failed absent
run_marker_case "an already backed up snapshot writes the marker" setup_marker_already "${D3}"

run_marker_case "a failed receive keeps the older marker" setup_marker_failed_old "${D1}"
run_marker_case "the marker is named after the target" setup_marker_sent "${D3}" nas2

run_unmarked_case() {
	local desc="$1" mode="$2" root ok=ok
	root="$(mktemp -d)"
	mkdir -p "${root}/bin" "${root}/svc/svc" "${root}/snap/svc"
	make_stub "${root}/bin"
	place "${root}/snap/svc/${DOLD}" received
	[[ "${mode}" == empty ]] && : >"${root}/snap/svc/.backed-up-t"
	PATH="${root}/bin:${PATH}" BTRFS_SERVICES_DIR="${root}/svc" BTRFS_SNAPSHOT_DIR="${root}/snap" \
		RETENTION_DAYS=90 NODE_TEXTFILE_DIR="${root}" bash "${SNAP_SCRIPT}" svc >/dev/null 2>&1 || true
	[[ -d "${root}/snap/svc/${DOLD}" ]] && ok="old snapshot kept"
	[[ -d "${root}/snap/svc/$(date +%F)" ]] || ok="today missing"
	[[ -e "${root}/snapshot-svc.prom" ]] || ok="no metric"
	if [[ "${ok}" == ok ]]; then
		PASS=$((PASS + 1)); echo "  PASS: ${desc}"
	else
		FAIL=$((FAIL + 1)); echo "  FAIL: ${desc} (${ok})"
	fi
	rm -rf "${root}"
}

run_incremental_case() {
	local root ok=ok
	root="$(mktemp -d)"
	mkdir -p "${root}/bin" "${root}/snap/svc/${DOLD}" "${root}/snap/svc/$(date +%F)" "${root}/backup"
	make_stub "${root}/bin"
	place "${root}/backup/t/svc/${DOLD}" received
	echo "${DOLD}" >"${root}/snap/svc/.backed-up-t"
	PATH="${root}/bin:${PATH}" SEND_LOG="${root}/send.log" BTRFS_SNAPSHOT_DIR="${root}/snap" \
		BACKUP_ROOT="${root}/backup" RETENTION_DAYS=90 NODE_TEXTFILE_DIR="${root}" \
		bash "${SCRIPT}" t >/dev/null 2>&1 || ok="run failed"
	grep -q "send -q -p ${root}/snap/svc/${DOLD} " "${root}/send.log" 2>/dev/null || ok="no incremental send from ${DOLD}"
	[[ "$(cat "${root}/snap/svc/.backed-up-t")" == "$(date +%F)" ]] || ok="marker not on today"
	if [[ "${ok}" == ok ]]; then
		PASS=$((PASS + 1)); echo "  PASS: a pinned old snapshot is the parent and the marker moves on"
	else
		FAIL=$((FAIL + 1)); echo "  FAIL: a pinned old snapshot is the parent and the marker moves on (${ok})"
	fi
	rm -rf "${root}"
}

run_incremental_case

echo "=== btrfs-snapshot.sh ==="
run_unmarked_case "pruning without a marker file deletes the old snapshot" none
run_unmarked_case "pruning with an empty marker file deletes the old snapshot" empty
run_prune_case "pruning keeps every marked snapshot and deletes other old ones" 3 ok

echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ "${FAIL}" -eq 0 ]]
