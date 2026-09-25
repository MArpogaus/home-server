#!/usr/bin/env python3
"""Boot a Fedora CoreOS test VM.

Builds the Ignition config with ../ignition/build.sh and starts QEMU.
Stdlib only.
"""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import urllib.request

TEST_DIR = os.path.dirname(os.path.abspath(__file__))
FCOS_VERSION = "44.20260510.3.1"
# images.qemu.sha256 of the build's meta.json; it moves with FCOS_VERSION.
FCOS_SHA256 = "b8f0ae906a1ff357b9f5e62eb7f64ee19a42d01a16d9ac4d2132380601aa84da"
DISK = os.path.join(TEST_DIR, "fcos.qcow2")
DISK_XZ = DISK + ".xz"
BUILD_SH = os.path.join(TEST_DIR, os.pardir, "ignition", "build.sh")
IGNITION = os.path.join(TEST_DIR, os.pardir, "ignition", "config.ign")
SSH_KEY = os.path.join(TEST_DIR, "coreos_key")
URL = (f"https://builds.coreos.fedoraproject.org/prod/streams/stable/builds/"
       f"{FCOS_VERSION}/x86_64/fedora-coreos-{FCOS_VERSION}-qemu.x86_64.qcow2.xz")

BASE_SNAPSHOT = "base"
# Match the 8 GB target, so a cold start is not tested under false pressure.
MEMORY_MB = "8192"
CPUS = "2"
DISK_SIZE = "40G"
SSH_PORT = 2222
# Unprivileged, so the forwards need no root.
HTTP_PORT = 8080
HTTPS_PORT = 8443


def fail(msg):
    sys.exit(f"ERROR: {msg}")


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--fresh", action="store_true",
                      help="rebuild the disk and re-run Ignition")
    mode.add_argument("--restore", action="store_true",
                      help=f'roll back to the "{BASE_SNAPSHOT}" snapshot and boot')
    mode.add_argument("--save-base", action="store_true",
                      help=f'tag the current disk state "{BASE_SNAPSHOT}" '
                           "(the VM must be shut down) and exit")
    parser.add_argument("--listen", default="127.0.0.1", metavar="ADDR",
                        help="host address the forwarded ports bind to")
    parser.add_argument("--platform", type=os.path.abspath, metavar="FILE.bu",
                        help="Butane fragment merged into the config on --fresh")
    return parser.parse_args(argv)


def save_base_snapshot():
    """Tag the current disk state so a reset is a rollback, not a rebuild."""
    if not os.path.exists(DISK):
        fail(f"No disk at {DISK}")
    # Before the delete below, so a locked disk keeps its old snapshot.
    busy = subprocess.run(["qemu-img", "snapshot", "-l", DISK],
                          capture_output=True, text=True)
    if busy.returncode != 0:
        fail(f"Could not open the disk (is the VM still running?):\n{busy.stderr}")
    subprocess.run(["qemu-img", "snapshot", "-d", BASE_SNAPSHOT, DISK],
                   capture_output=True)
    result = subprocess.run(["qemu-img", "snapshot", "-c", BASE_SNAPSHOT, DISK],
                            capture_output=True, text=True)
    if result.returncode != 0:
        fail(f"Could not snapshot (is the VM still running?):\n{result.stderr}")
    print(f'Saved snapshot "{BASE_SNAPSHOT}". Roll back with --restore.')


def restore_base_snapshot():
    result = subprocess.run(["qemu-img", "snapshot", "-a", BASE_SNAPSHOT, DISK],
                            capture_output=True, text=True)
    if result.returncode != 0:
        fail(f'No "{BASE_SNAPSHOT}" snapshot to restore '
             f"(take one with --save-base):\n{result.stderr}")
    print(f'Rolled back to "{BASE_SNAPSHOT}"')


def ensure_ssh_key():
    if not os.path.exists(SSH_KEY):
        print(f"Creating SSH key: {SSH_KEY}")
        subprocess.run(["ssh-keygen", "-t", "ed25519", "-f", SSH_KEY, "-N", "",
                        "-C", "coreos"], check=True, capture_output=True)


def ensure_disk(fresh):
    """Download and extract the image if needed.

    Ignition only runs on first boot, so re-testing it needs a fresh disk. The
    .xz download is kept as a cache, which makes --fresh cost seconds.
    """
    if fresh and os.path.exists(DISK):
        print("--fresh: removing existing disk")
        os.remove(DISK)

    if not os.path.exists(DISK):
        if not os.path.exists(DISK_XZ):
            print(f"Downloading Fedora CoreOS {FCOS_VERSION}")
            urllib.request.urlretrieve(URL, DISK_XZ)
        with open(DISK_XZ, "rb") as handle:
            digest = hashlib.file_digest(handle, "sha256")
        if digest.hexdigest() != FCOS_SHA256:
            os.remove(DISK_XZ)
            fail(f"{DISK_XZ} does not match FCOS_SHA256; deleted it")
        print("Extracting disk image")
        subprocess.run(["unxz", "-k", DISK_XZ], check=True)
        subprocess.run(["qemu-img", "resize", DISK, DISK_SIZE], check=True)
    print(f"Disk: {os.path.getsize(DISK) // 1024 // 1024} MB")


def build_ignition(platform):
    """Hand the key and the password to ignition/build.sh, the one renderer."""
    env = dict(os.environ)
    with open(SSH_KEY + ".pub") as handle:
        env["SSH_PUBLIC_KEY"] = handle.read().strip()

    # Serial console only, so it is optional. Without mkpasswd, boot key-only.
    if shutil.which("mkpasswd"):
        password = os.environ.get("VM_PASSWORD", "test")
        env["PASSWORD_HASH"] = subprocess.run(
            ["mkpasswd", "--method=yescrypt", "--stdin"], input=password,
            check=True, capture_output=True, text=True).stdout.strip()
    else:
        print("mkpasswd not found — no console password, SSH key only")
        env["PASSWORD_HASH"] = "none"

    platform_args = ["--platform", platform] if platform else []
    result = subprocess.run([BUILD_SH, *platform_args, "ign"], env=env,
                            capture_output=True, text=True)
    if result.returncode != 0:
        fail(f"build.sh failed:\n{result.stdout}{result.stderr}")
    with open(IGNITION) as handle:
        json.load(handle)  # refuse to boot a truncated config
    print("Generated config.ign")


def boot(ignition_args, listen):
    subprocess.run([
        "qemu-system-x86_64",
        "-machine", "q35,accel=kvm",
        "-cpu", "host",
        "-m", MEMORY_MB,
        "-smp", CPUS,
        "-drive", f"file={DISK},format=qcow2,if=virtio",
        *ignition_args,
        "-netdev", ",".join([
            "user", "id=net0",
            f"hostfwd=tcp:{listen}:{SSH_PORT}-:22",
            f"hostfwd=tcp:{listen}:{HTTP_PORT}-:80",
            f"hostfwd=tcp:{listen}:{HTTPS_PORT}-:443",
        ]),
        "-device", "virtio-net-pci,netdev=net0",
        "-display", "none",
        "-serial", "mon:stdio",
    ], check=True)


def main(argv=None):
    args = parse_args(argv)

    if args.save_base:
        save_base_snapshot()
        return 0

    if not os.path.exists("/dev/kvm"):
        fail("/dev/kvm not available")

    if args.restore:
        restore_base_snapshot()

    ensure_ssh_key()
    ensure_disk(args.fresh)

    if args.restore:
        # Ignition runs on first boot only, so it would ignore the config.
        ignition_args = []
    else:
        build_ignition(args.platform)
        ignition_args = ["-fw_cfg", f"name=opt/com.coreos/config,file={IGNITION}"]

    print(f"SSH: ssh -p {SSH_PORT} -i {SSH_KEY} -o StrictHostKeyChecking=no "
          f"-o UserKnownHostsFile=/dev/null core@localhost   Stop: Ctrl+C")
    boot(ignition_args, args.listen)
    return 0


if __name__ == "__main__":
    sys.exit(main())
