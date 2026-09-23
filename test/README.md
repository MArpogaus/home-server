# Test VM

A Fedora CoreOS guest for the playbook. `--platform` names the deployment's
Butane fragment, so the guest runs the same platform steps as the real host,
such as a rebase to a derivative image:

```bash
python3 start_vm.py --fresh --platform ../platform/secureblue.bu
```

## Use

```bash
python3 start_vm.py             # boot (reuses the existing disk)
python3 start_vm.py --fresh     # rebuild the disk and re-run Ignition
python3 start_vm.py --save-base # VM shut down: tag this disk state "base"
python3 start_vm.py --restore   # roll back to "base" and boot
python3 start_vm.py --help      # all options
```

The guest's SSH is on host port 2222, its HTTP on 8080 and its HTTPS on 8443,
bound to `127.0.0.1`. The key has no passphrase and `core` is root on the
guest, so a wider bind hands the guest to the network. `--listen <address>`
binds another address, such as the one a container on this machine reaches.

The guest gets 8 GB and 2 vCPUs, which match the target thin client. With
`mkpasswd` installed the console password is `VM_PASSWORD` (default `test`);
without it the guest has none.

The Ignition config comes from `../ignition/build.sh`, the same renderer the
real hardware uses.

Then deploy against it as `../README.md`, "Deploy", describes.

## Resetting between test runs

Two levels, cheapest first.

| Want | Do | Cost |
|---|---|---|
| Back to a clean provisioned host | `--restore` | seconds, VM restarts |
| Back to bare Fedora CoreOS | `--fresh` | a fresh disk from the cached image (downloaded once), plus the platform steps |

### Taking the base snapshot

Do this once, after the platform steps have finished:

```bash
ssh -p 2222 -i coreos_key core@localhost rpm-ostree status   # expect the platform image
ssh -p 2222 -i coreos_key core@localhost run0 systemctl poweroff
python3 start_vm.py --save-base
```

The VM must be shut down, and the platform steps must have finished. Re-running
`--save-base` replaces the existing snapshot.

This is a qcow2 internal snapshot: it lives inside `fcos.qcow2`, costs only the
blocks that change afterwards, and needs no second image or backing-file chain.
On `--restore` the Ignition config is not regenerated, because Ignition runs
on a first boot only.

CAUTION: `--fresh` deletes the disk, and the `base` snapshot lives inside that
file. A fresh start therefore repeats the platform steps. Run `--save-base` as
soon as they finish.

## Boot sequence

```
FCOS first boot → Ignition applies config.ign
  → install-python.service layers python3 for Ansible, when the image has none
  → the platform fragment's units, if any (a rebase ends in a reboot)
  → SSH available, ready for Ansible
```

Nothing waits for a login: the first boot does the work on its own. A deploy
that starts before python3 exists fails with
`/usr/bin/python3: No such file or directory`. A fragment whose image ships
python3 disables `install-python.service`.

`../deploy.sh` and `../functional_test.sh` honour `TARGET_HOST` and
`TARGET_PORT`.

`coreos_key` is the SSH identity baked into the Ignition config. `../README.md`,
"Deploy", says where the deployment finds it.

`./test_btrfs_backup.sh` runs `roles/base_setup/files/btrfs-backup.sh` against a
stub `btrfs`, so it needs neither Btrfs nor root.

## Requirements

`qemu-system-x86_64` with `/dev/kvm`, `qemu-img`, `python3`, `unxz`,
`ssh-keygen` and `podman`. Optional: `mkpasswd` for the console password.
