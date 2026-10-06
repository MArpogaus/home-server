#!/bin/bash
set -euo pipefail
shopt -s nullglob

SNAP_DIR="${BTRFS_SNAPSHOT_DIR:?}"
TEXTFILE_DIR="${NODE_TEXTFILE_DIR:?}"

snapshots() {
	local today
	today="$(date +%Y-%m-%d)"
	find "$1" -mindepth 1 -maxdepth 1 -type d -name '????-??-??' -printf '%f\n' 2>/dev/null |
		sort | awk -v t="${today}" '$0 <= t'
}

mounts=""
for src in "${SNAP_DIR}"/*/; do
	latest="$(snapshots "${src}" | tail -n1)"
	[ -n "${latest}" ] || continue
	mounts="${mounts} -v ${src}${latest}:/data/$(basename "${src}"):ro"
done
if [ -z "${mounts}" ]; then
	echo "ERROR: no service snapshot found under ${SNAP_DIR}" >&2
	exit 1
fi

RESTIC_PODMAN_ARGS="${mounts}" /usr/local/bin/restic backup --no-scan /data

tmp="${TEXTFILE_DIR}/backup-restic.prom.$$"
echo "backup_last_success_timestamp_seconds{target=\"restic\"} $(date +%s)" >"${tmp}"
mv "${tmp}" "${TEXTFILE_DIR}/backup-restic.prom"
echo "restic-backup: run complete"
