#!/bin/bash
set -euo pipefail

LIVE="$(realpath -m "${1:?live subvolume not given, e.g. /var/services/nextcloud}")"
SNAP="$(realpath -e "${2:?snapshot not given, e.g. /var/backup/nas/nextcloud/2026-09-29}")"
SVC="$(basename "${LIVE}")"
LOCAL="$(dirname "${LIVE}")/snapshots/${SVC}"

btrfs subvolume show "${SNAP}" >/dev/null

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

systemd-run --machine="${SVC}@" --user --wait --pipe --quiet podman system renumber
systemd-run --machine="${SVC}@" --user --wait --pipe --quiet podman pod rm --all --force

echo "Restored ${LIVE} from ${SNAP}. Deploy the host to start ${SVC} again."
