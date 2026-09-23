#!/bin/bash
# Incremental `btrfs send` of the newest snapshot of every service to the
# target named by the instance: btrfs-backup@<name>.
set -euo pipefail
shopt -s nullglob

TARGET="${1:?target name not given}"
# shellcheck source=/dev/null
. "/etc/btrfs-backup/${TARGET}.conf"

SNAP_DIR="${BTRFS_SNAPSHOT_DIR:?}"
DEST="${BACKUP_ROOT:?}/${TARGET}"
TEXTFILE_DIR="${NODE_TEXTFILE_DIR:?}"
CUTOFF="$(date -d "-${RETENTION_DAYS:?} days" +%Y-%m-%d)"

# A path that is no subvolume is a partial receive. Output without the field
# counts as received, because deleting a good copy is the worse error.
received() {
	local out
	out="$(btrfs subvolume show "$1" 2>/dev/null)" || return 1
	grep -q 'Received UUID:' <<<"${out}" || {
		echo "WARNING: no 'Received UUID' field for $1; refusing to treat it as partial" >&2
		return 0
	}
	grep -qE 'Received UUID:\s+[0-9a-f-]{36}' <<<"${out}"
}

# Dated names up to today, oldest first. A hand-made or future-dated name
# never becomes the latest.
snapshots() {
	local today
	today="$(date +%Y-%m-%d)"
	find "$1" -mindepth 1 -maxdepth 1 -type d -name '????-??-??' -printf '%f\n' 2>/dev/null |
		sort | awk -v t="${today}" '$0 <= t'
}

received_snapshots() {
	for s in $(snapshots "$1"); do
		received "$1/$s" && echo "$s"
	done
}

# The target filesystem carries no label, and node-exporter statfs()es its root.
chcon -t container_file_t "${DEST}" || echo "WARNING: cannot label ${DEST}" >&2

copied=0
refused=0
for src in "${SNAP_DIR}"/*/; do
	svc="$(basename "${src}")"
	mkdir -p "${DEST}/${svc}"

	# A partial receive leaves at most one unreceived copy. More than one means
	# the test is wrong, so nothing of this service is deleted.
	partial=()
	for snap in "${DEST}/${svc}"/????-??-??; do
		[ -d "${snap}" ] || continue
		received "${snap}" || partial+=("${snap}")
	done
	if [ "${#partial[@]}" -gt 1 ]; then
		echo "ERROR: ${#partial[@]} backups of ${svc} look unreceived; refusing to delete" >&2
		refused=1
		continue
	fi
	for snap in "${partial[@]}"; do
		btrfs subvolume delete "${snap}" || rm -rf "${snap}"
		echo "Deleted partial backup: ${snap}"
	done

	latest="$(snapshots "${src}" | tail -n1)"
	[ -n "${latest}" ] || continue

	if [ -e "${DEST}/${svc}/${latest}" ]; then
		echo "${svc}/${latest} already backed up."
	else
		parent="$(comm -12 <(snapshots "${src}") <(received_snapshots "${DEST}/${svc}") | tail -n1)"
		if [ -n "${parent}" ]; then
			btrfs send -q -p "${src}${parent}" "${src}${latest}" | btrfs receive "${DEST}/${svc}" || true
		else
			btrfs send -q "${src}${latest}" | btrfs receive "${DEST}/${svc}" || true
		fi
		if ! received "${DEST}/${svc}/${latest}"; then
			echo "ERROR: ${svc}/${latest} did not finish" >&2
			refused=1
			continue
		fi
		echo "Backed up ${svc}/${latest}"
	fi
	copied=$((copied + 1))

	for snap in "${DEST}/${svc}"/????-??-??; do
		[ -d "${snap}" ] || continue
		if [[ "$(basename "${snap}")" < "${CUTOFF}" && "$(basename "${snap}")" != "${latest}" ]]; then
			btrfs subvolume delete "${snap}" || rm -rf "${snap}"
			echo "Deleted backup: ${snap}"
		fi
	done
done

if [ "${refused}" -ne 0 ]; then
	echo "ERROR: at least one service was skipped; see the errors above" >&2
	exit 1
fi
if [ "${copied}" -eq 0 ]; then
	echo "ERROR: no service snapshot found under ${SNAP_DIR}" >&2
	exit 1
fi

read -r size avail < <(df -B1 --output=size,avail "${DEST}" | tail -n1)
tmp="${TEXTFILE_DIR}/backup-${TARGET}.prom.$$"
cat >"${tmp}" <<METRICS
backup_last_success_timestamp_seconds{target="${TARGET}"} $(date +%s)
backup_target_size_bytes{target="${TARGET}"} ${size}
backup_target_avail_bytes{target="${TARGET}"} ${avail}
METRICS
mv "${tmp}" "${TEXTFILE_DIR}/backup-${TARGET}.prom"
echo "btrfs-backup: run complete"
