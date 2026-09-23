#!/bin/bash
# Read-only Btrfs snapshot of one service subvolume, plus retention by the date
# in the snapshot name.
set -euo pipefail

VOLUME_NAME="$1"
SOURCE="${BTRFS_SERVICES_DIR:?}/${VOLUME_NAME}"
SNAPSHOT_DIR="${BTRFS_SNAPSHOT_DIR:?}/${VOLUME_NAME}"
TEXTFILE_DIR="${NODE_TEXTFILE_DIR:?}"
CUTOFF="$(date -d "-${BTRFS_SNAPSHOT_RETENTION_DAYS:?} days" +%Y-%m-%d)"

mkdir -p "${SNAPSHOT_DIR}"

TODAY="$(date +%Y-%m-%d)"
if [ -d "${SNAPSHOT_DIR}/${TODAY}" ]; then
    echo "Snapshot ${SNAPSHOT_DIR}/${TODAY} already exists, skipping."
else
    btrfs subvolume snapshot -r "${SOURCE}" "${SNAPSHOT_DIR}/${TODAY}"
    echo "Created snapshot: ${SNAPSHOT_DIR}/${TODAY}"
fi

for snap in "${SNAPSHOT_DIR}"/????-??-??; do
    [ -d "${snap}" ] || continue
    if [[ "$(basename "${snap}")" < "${CUTOFF}" ]]; then
        btrfs subvolume delete "${snap}" || rm -rf "${snap}"
        echo "Deleted snapshot: ${snap}"
    fi
done

tmp="${TEXTFILE_DIR}/snapshot-${VOLUME_NAME}.prom.$$"
echo "snapshot_last_success_timestamp_seconds{service=\"${VOLUME_NAME}\"} $(date +%s)" >"${tmp}"
mv "${tmp}" "${TEXTFILE_DIR}/snapshot-${VOLUME_NAME}.prom"
