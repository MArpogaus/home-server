#!/bin/bash
# Make a snapshot the live subvolume of a service: btrfs-restore.sh
# /var/services/<name> <snapshot>. The snapshot is a dated copy under
# /var/services/snapshots/<name>/, one on a backup target, or a subvolume that
# restic restored into. The live subvolume moves aside, not away. Start the
# service again with a deploy.
set -euo pipefail

LIVE="$(realpath -m "${1:?live subvolume not given, e.g. /var/services/nextcloud}")"
SNAP="$(realpath -e "${2:?snapshot not given, e.g. /var/backup/nas/nextcloud/2026-09-29}")"
SVC="$(basename "${LIVE}")"
LOCAL="$(dirname "${LIVE}")/snapshots/${SVC}"

btrfs subvolume show "${SNAP}" >/dev/null

# A snapshot on a target is received next to the local ones first: a writable
# snapshot must be on the same filesystem as the live subvolume. receive sets
# the copy read-only when it finishes, so a writable copy is a partial one.
readonly_subvolume() {
	btrfs property get -ts "$1" ro | grep -qx 'ro=true'
}
if [ "$(dirname "${SNAP}")" != "${LOCAL}" ]; then
	COPY="${LOCAL}/$(basename "${SNAP}")"
	if [ -e "${COPY}" ] && ! readonly_subvolume "${COPY}"; then
		btrfs subvolume delete "${COPY}"
	fi
	if [ ! -e "${COPY}" ]; then
		mkdir -p "${LOCAL}"
		btrfs send -q "${SNAP}" | btrfs receive "${LOCAL}"
	fi
	readonly_subvolume "${COPY}"
	SNAP="${COPY}"
fi

systemctl --user -M "${SVC}@" stop "${SVC}-pod.service"

ASIDE=""
if [ -e "${LIVE}" ]; then
	ASIDE="${LOCAL}/before-restore-$(date +%Y-%m-%dT%H%M%S)"
	mv "${LIVE}" "${ASIDE}"
	echo "Moved ${LIVE} to ${ASIDE}"
fi

btrfs subvolume snapshot "${SNAP}" "${LIVE}"

# A restic restore leaves its target directory to root, so the owner and
# mode come from the old live subvolume. So does each nested subvolume, which
# no snapshot holds; a path through a symlink of the restored tree is skipped.
# Inode 256 is the root of a Btrfs subvolume.
if [ -n "${ASIDE}" ]; then
	chown --reference="${ASIDE}" "${LIVE}"
	chmod --reference="${ASIDE}" "${LIVE}"
	while IFS= read -r nested; do
		rel="${nested#"${ASIDE}"/}"
		parent="$(dirname "${LIVE}/${rel}")"
		if [ "$(realpath -m "${parent}")" != "${parent}" ] || [ -L "${LIVE}/${rel}" ]; then
			echo "WARNING: ${rel} runs through a symlink; it stays in ${ASIDE}" >&2
			continue
		fi
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
systemd-run --machine="${SVC}@" --user --wait --pipe --quiet podman system renumber
systemd-run --machine="${SVC}@" --user --wait --pipe --quiet podman pod rm --all --force

echo "Restored ${LIVE} from ${SNAP}. Deploy the host to start ${SVC} again."
