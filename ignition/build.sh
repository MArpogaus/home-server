#!/bin/bash
# Renders the Ignition config for the real hardware and writes it into an
# installer ISO. It needs podman, which runs butane and the installer.
#
#   ./build.sh [--platform <file.bu>] ign                      only render config.ign
#   ./build.sh [--platform <file.bu>] iso <live.iso> /dev/sdX  write an installer ISO
#
# <live.iso> is the stock Fedora CoreOS live image. /dev/sdX is the disk of the
# machine that will boot the ISO, not a disk of this one.
#
# --platform names a Butane fragment that the deployment provides, such as a
# rebase to a derivative image. It is merged into the config.
set -euo pipefail
# config.bu and config.ign carry the console password hash.
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/config.bu.template"
BUTANE_CONFIG="${SCRIPT_DIR}/config.bu"
IGNITION="${SCRIPT_DIR}/config.ign"
INSTALLER_IMAGE="quay.io/coreos/coreos-installer:release@sha256:2c94387e76ae351a4183f29707fd7be57a9290675524391bdb17b40de1e088ff"

usage() { echo "usage: $0 [--platform <file.bu>] [ign | iso <live.iso> /dev/sdX]"; exit 1; }

PLATFORM=""
if [ "${1:-}" = "--platform" ]; then
	[ -f "${2:-}" ] || { echo "ERROR: no such platform fragment: ${2:-}"; exit 1; }
	PLATFORM="$(realpath "$2")"
	shift 2
fi
MODE="${1:-ign}"
case "${MODE}" in
ign) ;;
iso)
	SRC_ISO="${2:-}"; DEVICE="${3:-}"
	[ -n "${SRC_ISO}" ] && [ -n "${DEVICE}" ] || usage
	[ -f "${SRC_ISO}" ] || { echo "ERROR: no such file: ${SRC_ISO}"; exit 1; }
	;;
*) usage ;;
esac

BUTANE=(podman run --rm -i --security-opt label=disable
	-v "${SCRIPT_DIR}":/pwd -w /pwd quay.io/coreos/butane:release@sha256:d264fba5a02ec7a5525b7cd4ab04090e8c70d0ee42a74a90a0e2f89633ae720c)

SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"
if [ -z "${SSH_PUBLIC_KEY}" ]; then
	SSH_PUBLIC_KEY="$(ssh-add -L 2>/dev/null | grep -m1 'cardno:' || true)"
	[ -n "${SSH_PUBLIC_KEY}" ] || {
		echo "ERROR: no smartcard key in the agent. Plug in the YubiKey, or"
		echo "       set SSH_PUBLIC_KEY to the key you want to authorise."
		exit 1
	}
fi
echo "Authorising: ${SSH_PUBLIC_KEY%% *} ...${SSH_PUBLIC_KEY##* }"

# Console password, for physical recovery only. PASSWORD_HASH=none sets none.
if [ -z "${PASSWORD_HASH:-}" ]; then
	command -v mkpasswd >/dev/null || { echo "ERROR: mkpasswd not found; set PASSWORD_HASH"; exit 1; }
	echo "Console password for the 'core' user (physical recovery):"
	PASSWORD_HASH="$(mkpasswd --method=yescrypt)"
fi

config="$(<"${TEMPLATE}")"
# shellcheck disable=SC2016  # the patterns are the literal placeholders
{
	config="${config//'${SSH_PUBLIC_KEY}'/"${SSH_PUBLIC_KEY}"}"
	config="${config//'${PASSWORD_HASH}'/"${PASSWORD_HASH}"}"
}
printf '%s\n' "${config}" > "${BUTANE_CONFIG}"
if [ "${PASSWORD_HASH}" = "none" ]; then
	sed -i '/password_hash:/d' "${BUTANE_CONFIG}"
fi
rm -f "${SCRIPT_DIR}/platform.ign"
if [ -n "${PLATFORM}" ]; then
	"${BUTANE[@]}" --strict < "${PLATFORM}" > "${SCRIPT_DIR}/platform.ign"
	printf 'ignition:\n  config:\n    merge:\n      - local: platform.ign\n' >> "${BUTANE_CONFIG}"
fi
(cd "${SCRIPT_DIR}" && "${BUTANE[@]}" --pretty --strict --files-dir . config.bu) > "${IGNITION}"
echo "Wrote ${IGNITION}"

case "${MODE}" in
iso)
	SRC_DIR="$(cd "$(dirname "${SRC_ISO}")" && pwd)"
	podman run --pull=always --rm --security-opt label=disable \
		-v "${SCRIPT_DIR}":/data -v "${SRC_DIR}":/iso -w /data \
		"${INSTALLER_IMAGE}" \
		iso customize --force --dest-ignition config.ign \
		--dest-device "${DEVICE}" \
		-o install.iso "/iso/$(basename "${SRC_ISO}")"
	echo "Wrote ${SCRIPT_DIR}/install.iso"
	echo "Booting it installs onto ${DEVICE} and reboots, with no prompt."
	;;
esac
