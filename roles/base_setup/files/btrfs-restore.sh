#!/bin/bash
# Make a snapshot the live subvolume of a service: btrfs-restore.sh
# /var/services/<name> <snapshot>. The snapshot is a dated copy under
# /var/services/snapshots/<name>/ or on a backup target. The live subvolume
# moves aside, not away. Start the service again with a deploy.
set -euo pipefail

LIVE="${1:?live subvolume not given, e.g. /var/services/nextcloud}"
SNAP="${2:?snapshot not given, e.g. /var/backup/nas/nextcloud/2026-09-29}"
LIVE="${LIVE%/}"
SNAP="${SNAP%/}"
SVC="$(basename "${LIVE}")"
LOCAL="$(dirname "${LIVE}")/snapshots/${SVC}"

btrfs subvolume show "${SNAP}" >/dev/null

# A snapshot on a target is received next to the local ones first: a writable
# snapshot must be on the same filesystem as the live subvolume.
if [ "$(dirname "${SNAP}")" != "${LOCAL}" ]; then
	if [ -e "${LOCAL}/$(basename "${SNAP}")" ]; then
		echo "${LOCAL}/$(basename "${SNAP}") exists; using it"
	else
		mkdir -p "${LOCAL}"
		btrfs send -q "${SNAP}" | btrfs receive "${LOCAL}"
	fi
	SNAP="${LOCAL}/$(basename "${SNAP}")"
fi

if id -u "${SVC}" >/dev/null 2>&1; then
	systemctl --user -M "${SVC}@" stop "${SVC}-pod.service" || true
fi

ASIDE=""
if [ -e "${LIVE}" ]; then
	ASIDE="${LOCAL}/before-restore-$(date +%Y-%m-%dT%H%M%S)"
	mv "${LIVE}" "${ASIDE}"
	echo "Moved ${LIVE} to ${ASIDE}"
fi

btrfs subvolume snapshot "${SNAP}" "${LIVE}"

# A snapshot holds no nested subvolume, so each one comes over from the old
# live subvolume. Inode 256 is the root of a Btrfs subvolume.
if [ -n "${ASIDE}" ]; then
	while IFS= read -r nested; do
		rel="${nested#"${ASIDE}"/}"
		if [ -d "${LIVE}/${rel}" ]; then
			rmdir "${LIVE}/${rel}"
		fi
		mv "${nested}" "${LIVE}/${rel}"
		echo "Moved nested subvolume ${rel} back"
	done < <(find "${ASIDE}" -mindepth 1 -maxdepth 3 -type d -inum 256)
fi

# The snapshot holds Podman's record of the containers that ran when it was
# taken, with locks of another boot. renumber gives them locks of this one,
# then the pods go, and the deploy starts from a clean state. Images and
# volumes stay.
if id -u "${SVC}" >/dev/null 2>&1; then
	for cmd in "system renumber" "pod rm --all --force"; do
		# shellcheck disable=SC2086
		systemd-run --machine="${SVC}@" --user --wait --pipe --quiet podman ${cmd}
	done
fi

echo "Restored ${LIVE} from ${SNAP}. Deploy the host to start ${SVC} again."
