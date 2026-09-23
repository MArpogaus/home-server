#!/bin/bash
# Self-check for roles/base_setup/files/btrfs-backup.sh. `btrfs` is a stub on
# PATH and the "subvolumes" are directories, so it needs no Btrfs and no root.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/../roles/base_setup/files/btrfs-backup.sh"
# Inside the 90-day retention window the cases configure; DOLD is outside it.
D1="$(date -d '-3 days' +%F)"
D2="$(date -d '-2 days' +%F)"
D3="$(date -d '-1 day' +%F)"
DOLD="$(date -d '-100 days' +%F)"
PASS=0
FAIL=0

# `subvolume show` answers from marker files. A `.fail` file in the receive
# directory makes the receive stop short of finishing.
make_stub() {
	cat >"$1/btrfs" <<'STUB'
#!/bin/bash
case "$1 $2" in
"subvolume show")
	d="$3"
	[ -d "${d}" ] || { echo "ERROR: not a subvolume" >&2; exit 1; }
	echo "Name: $(basename "${d}")"
	if [ -e "${d}/.no-field" ]; then :                      # btrfs-progs changed
	elif [ -e "${d}/.received" ]; then
		echo "	Received UUID: 		f4d2b1a0-1111-2222-3333-444455556666"
	else
		echo "	Received UUID: 		-"
	fi
	;;
"subvolume delete")
	d="$3"
	[ -e "${d}/.subvol" ] || { echo "ERROR: not a subvolume" >&2; exit 1; }
	rm -rf "${d}"
	;;
"send -q")
	for a in "$@"; do last="$a"; done
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

# A dated copy on the target. Only a received copy is a real subvolume, so
# `subvolume delete` refuses the others.
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

# want_name: a copy that must exist afterwards. want_err: text the output must
# hold. A run that succeeds writes the metric, and a failed one does not.
run_case() {
	local desc="$1" want_rc="$2" want_left="$3" want_name="${5-}" want_err="${6-}"
	local root out rc=0 left named=ok
	root="$(mktemp -d)"
	mkdir -p "${root}/bin" "${root}/snap" "${root}/backup"
	make_stub "${root}/bin"
	"${4}" "${root}"   # the case's own setup
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

echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ "${FAIL}" -eq 0 ]]
