#!/bin/bash
# restic backup of the newest snapshot of every service. Each one appears at
# /data/<name>, so every run finds the previous one as its parent.
set -euo pipefail

SNAP_DIR="${BTRFS_SNAPSHOT_DIR:?}"
TEXTFILE_DIR="${NODE_TEXTFILE_DIR:?}"
TODAY="$(date +%Y-%m-%d)"

mounts=""
for src in "${SNAP_DIR}"/*/; do
	# A hand-made or future-dated name never becomes the latest.
	latest="$(find "${src}" -mindepth 1 -maxdepth 1 -type d -name '????-??-??' -printf '%f\n' |
		sort | awk -v t="${TODAY}" '$0 <= t' | tail -n1)"
	[ -n "${latest}" ] || continue
	mounts="${mounts} -v ${src}${latest}:/data/$(basename "${src}"):ro"
done
if [ -z "${mounts}" ]; then
	echo "ERROR: no service snapshot found under ${SNAP_DIR}" >&2
	exit 1
fi

RESTIC_PODMAN_ARGS="${mounts}" /usr/local/bin/restic backup --no-scan /data

tmp="${TEXTFILE_DIR}/restic-backup.prom.$$"
echo "restic_backup_last_success_timestamp_seconds{target=\"restic\"} $(date +%s)" >"${tmp}"
mv "${tmp}" "${TEXTFILE_DIR}/restic-backup.prom"
echo "restic-backup: run complete"
