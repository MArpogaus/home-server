# home-server

This repository deploys a home server on Fedora CoreOS with rootless Podman.
It holds the host roles, the playbook, the inventory, the functional test,
the Ignition config and the test VM. Each service is a repository of
its own, pinned as a submodule under `services/<name>`, so one commit here
names every service version it deploys.

| Repository | Where | Purpose |
|---|---|---|
| `home-server` | this one | Host setup, playbook, Ignition, test VM, functional test |
| `home-server-nextcloud` | `services/nextcloud` | Nextcloud pod, role and custom image |
| `home-server-bunker` | `services/bunker` | BunkerWeb reverse proxy (WAF, TLS) |
| `home-server-monitoring` | `services/monitoring` | Metrics, logs, dashboards, alerts |
| `home-server-ntfy` | `services/ntfy` | Push notifications, the alerts on the phone |
| `home-server-secrets` | `../home-server-secrets` | Credentials, SSH `known_hosts`, host settings and tasks (**private**) |
| `home-server-template` | anywhere | Skeleton for a new service |
| `image-builder-action` | not cloned | GitHub Action that builds and signs the images |

```bash
git clone --recurse-submodules https://github.com/MArpogaus/home-server.git
git clone <the private secrets repo> home-server-secrets
```

## Architecture

- **Host and platform.** The roles target stock Fedora CoreOS, installed from
  `ignition/`. SecureBlue's steps are platform files: `platform/secureblue.bu`
  for Ignition, and `platform/secureblue.yml`, which `site.yml` runs as
  `host_tasks_pre` before `base_setup`. The inventory entry names the host.
- **Service users and rootless Quadlets.** For each entry in
  `base_setup_services`, `base_setup` makes a system user, a Btrfs subvolume
  under `/var/services` and a subuid range from
  `uid * 65536 + 100000`. `site.yml` then runs the
  service role from `services/<name>/ansible-role`, which calls
  `quadlet_service`. Services reach each other through host-published ports.
- **Snapshots and backup targets.** The finished snapshot of a service starts
  `btrfs-backup@<target>.service`. A target is a LUKS2 container with Btrfs
  (USB disk or iSCSI LUN), found by UUID, opened with `nofail` and automounted
  at `/var/backup/<name>`. "Backup and restore" has the whole flow.
- **Updates and auto-reboot.** `podman-auto-update.timer` runs per user. When
  rpm-ostree has staged a deployment, `auto-reboot-staged.service` reboots
  after the last backup, or at 03:00.
- **Monitoring.** A snapshot or backup that succeeds writes
  `/var/lib/node-textfile/*.prom`. `monitoring/` holds this repository's
  rules, which `home-server-monitoring` collects.

## Deploy

The controller needs Ansible Core 2.21 or newer with passlib and bcrypt. Run
every command from this repository: `ansible.cfg` names this inventory, the
secrets repository's inventory after it, and the Vault password file.
`secrets.example/` holds the templates for the secrets repository.

```bash
uv tool install --reinstall ansible --with-executables-from ansible-core --with passlib --with bcrypt
ansible-galaxy collection install -r requirements.yml   # again after requirements.yml changes
mkdir -p -m 700 ~/.config/home-server
(umask 077; openssl rand -base64 48 > ~/.config/home-server/vault-password)

S=../home-server-secrets                   # a new secrets repository
git init -q $S && cp -r secrets.example/. $S/ && mkdir -p $S/ssh
# fill in the values, then:
ansible-vault encrypt $S/group_vars/homeserver.yml $S/host_vars/test.yml
```

Every playbook run takes `-l <host>`: `site.yml` refuses a run without it.

The deploy and the functional test escalate with `run0`, which needs the root
gate open: `ssh -t core@<address> root-gate on` asks for core's password once.
The gate closes after 2 h. `--timer <time>` sets another time, and
`--no-timer` keeps it open until the next boot. `root-gate off` closes it at
once.

### Test VM

The VM needs `qemu-system-x86_64` with `/dev/kvm`, `qemu-img`, `unxz`,
`ssh-keygen`, `mkpasswd` and `podman`. core's password on the VM is `test`, or
`VM_PASSWORD`. It has 8 GB and 2 vCPUs, and publishes SSH, HTTP
and HTTPS on `127.0.0.1:2222`, `:8080` and `:8443`.

```bash
python3 test/start_vm.py --fresh --platform platform/secureblue.bu   # terminal 1
ssh -t -p 2222 -i test/coreos_key core@127.0.0.1 root-gate on        # terminal 2, after the rebase
ansible-playbook site.yml -l test && ./functional_test.sh test
python3 test/start_vm.py --save-base   # VM shut down: keep this disk as "base"
python3 test/start_vm.py --restore     # back to "base"
```

`--fresh` deletes the disk and its `base` snapshot. For a controller in a
container, start the VM with `--listen <address>` and add
`-e ansible_host=<address>` to both commands.

### Real host

Point the DNS names at the host and forward only 80 and 443; Let's Encrypt
needs 80. Add the host to `../home-server-secrets/inventory.yml`, copy
`secrets.example/host_vars/test.yml` to
`../home-server-secrets/host_vars/<host>.yml`, drop its self-signed and `-dev`
lines, fill it in and encrypt it with `ansible-vault encrypt`. SSH to a real
host uses the agent. `build.sh` authorises the smartcard key in the agent and
asks `mkpasswd` for core's password, which the console and `root-gate` use.
`SSH_PUBLIC_KEY` and `PASSWORD_HASH` set them instead. The console shows the
host key fingerprints; compare them with `ssh-keyscan -l <address>` before the
key goes into `known_hosts`.

```bash
cd ignition
podman run --rm --security-opt label=disable -v "$PWD":/data -w /data \
  quay.io/coreos/coreos-installer:release@sha256:2c94387e76ae351a4183f29707fd7be57a9290675524391bdb17b40de1e088ff \
  download -s stable -p metal -f iso
./build.sh --platform ../platform/secureblue.bu ign    # render config.ign; read it
./build.sh --platform ../platform/secureblue.bu iso fedora-coreos-<version>-live-iso.x86_64.iso \
  /dev/disk/by-id/<target disk>                        # install.iso erases that disk, no prompt
cd ..
ssh-keyscan -H <address> 2>/dev/null >> ../home-server-secrets/ssh/known_hosts
ssh -t core@<address> root-gate on
ansible-playbook site.yml -l <host>
./functional_test.sh <host>
```

## Configuration

Every service takes the same kinds of variables:
`home-server-template/README.md`, "Configuration interface". Each role's
defaults are generic; this deployment's own settings, such as the geo
allowlist and the phone region, are in `inventory/group_vars/homeserver.yml`.
In the secrets repository, `group_vars/homeserver.yml` holds what every host
shares, and `host_vars/<host>.yml` one host's credentials and overrides. The
inventory sets `base_setup_services`, `bunker_service_sites`,
`nextcloud_service_config` and `bunker_service_config`. A host that overrides
one of them repeats all its entries.

| Variable | Required | Controls |
|---|---|---|
| `base_setup_services` | yes | The services with their uid and port, in `inventory/group_vars/homeserver.yml` |
| `bunker_service_sites` | yes | The proxy site of each public service, in `inventory/group_vars/homeserver.yml` |
| `nextcloud_service_hostname` | yes | Nextcloud's public hostname |
| `ntfy_service_hostname` | no | ntfy's public hostname; empty means no ntfy site |
| Nextcloud passwords | yes | `home-server-nextcloud/README.md`, "Configuration" |
| Monitoring credentials | yes | `home-server-monitoring/README.md`, "Configuration" |
| ntfy credentials | with ntfy | `home-server-ntfy/README.md`, "Configuration" |
| `monitoring_service_probe_urls` | on a real host | Public URLs that blackbox probes |
| `bunker_service_certificates` | without public DNS | `self-signed` instead of Let's Encrypt |
| `base_setup_backup_targets` | no | `uuid` and `name` of each target; `[]` means no backup target; the name `restic` is taken. A removed target keeps its `backup-<name>.prom`, so `JobStale` fires until you delete it |
| `base_setup_btrfs_snapshot_retention_days` | no | Days a local snapshot stays; 30 |
| `base_setup_backup_retention_days` | no | Days a snapshot stays on a target; 90 |
| `base_setup_luks_passphrase` | with a target | One passphrase for every target; keep a copy off the host |
| `base_setup_iscsi_portal`, `base_setup_iscsi_target` | no | LUN 0 of an iSCSI target on port 3260; the deploy logs in to it |
| `base_setup_restic_repository`, `base_setup_restic_password` | no | A restic repository for the newest snapshots; empty means none |
| `base_setup_restic_env` | with restic | The backend's settings, such as `RESTIC_REST_USERNAME` and `RESTIC_REST_PASSWORD` |
| `host_tasks_pre` | no | A task file that runs before `base_setup` |

Machine secrets are 48 alphanumerics, so no file format needs quotes:
`openssl rand -base64 48 | tr -d '/+=' | cut -c1-48`.

`functional_test.sh <host>` passes further arguments to `ansible`, such as
`-e ansible_host=<address>`. `BACKUP_TARGET=<name>` also runs a real backup to
that target.

## Backup and restore

Each night `btrfs-snapshot@<service>.timer` takes a read-only snapshot. The
Nextcloud snapshot holds a database dump from just before it.

- Each target in `base_setup_backup_targets` receives the snapshots with an
  incremental `btrfs send`. A target is fast to restore from, but the host can
  delete it.
- With `base_setup_restic_repository` set, `restic-backup.timer` copies the
  newest snapshot of every service to a restic repository. restic encrypts,
  deduplicates and sends only the changes.

A new target needs `base_setup_luks_passphrase` and a deploy first, so the key
file exists. Then format the USB disk or the iSCSI LUN by hand:

```bash
D=/dev/disk/by-id/<disk>        # or /dev/disk/by-path/<LUN>
run0 cryptsetup luksFormat --type luks2 "$D" /etc/luks/backup.key
run0 cryptsetup open --key-file /etc/luks/backup.key "$D" tmp
run0 sh -c 'mkfs.btrfs -L backup /dev/mapper/tmp && cryptsetup close tmp'
run0 blkid -s UUID -o value "$D"    # the uuid of the target
```

Add the `uuid` and a `name` to `base_setup_backup_targets` and deploy again.
Read a file back from `/var/backup/<name>/<service>/<date>` after the first
backup, before you trust the target.

Once a month `btrfs-scrub@<path>.timer` scrubs the host (through `/var`, as
`/sysroot` is read-only) and each target. A scrub reads every block and
checks it against its checksum. An error it cannot repair fails the unit, and
`ScheduledJobFailed` fires.

The restic repository survives a compromised host only if its server is
append-only: the backend credentials in `base_setup_restic_env` add data but
delete none. `rest-server --append-only` does this, and so do hosted services
with an append-only mode. The restic password alone does not protect the
repository.

Prune from another machine, with backend credentials that may delete: `restic
forget --keep-daily 30 --keep-monthly 12 --prune`. A compromised host can add
snapshots with a false time, which push the good ones out of these rules. A
snapshot names its own time, so trust the time its file arrived on the server
(`ls -l --time-style=full-iso <repository>/snapshots/` there). Run `restic
check` and read `restic snapshots` before each prune, and after a compromise
keep the good snapshots by ID.

`/usr/local/bin/restic` runs restic on the host with the host's repository,
for example `run0 restic snapshots`. It mounts no host path by itself;
`RESTIC_PODMAN_ARGS` adds the mounts.

### Restore a service

For a snapshot on a target, `btrfs-restore.sh` first receives it into
`snapshots/<service>/`. It then stops the service's pod and moves its live
subvolume to `snapshots/<service>/before-restore-<time>`. It makes a writable
copy of the snapshot and uses it as the live subvolume. Nested subvolumes,
such as Nextcloud's `data/custom_apps`, come over from the old state. The
deploy starts the service again.

```bash
run0 btrfs-restore.sh /var/services/nextcloud /var/services/snapshots/nextcloud/2026-09-29
run0 btrfs-restore.sh /var/services/nextcloud /var/backup/nas/nextcloud/2026-09-29
ansible-playbook site.yml -l <host>
```

The first line restores from a local snapshot, the second from a backup
target. From restic, restore into a new subvolume first. Pick the snapshot by
its ID from `restic snapshots`, not `latest`. After a compromise, the newest
snapshot can be a forgery. On a new host, it can be the new host's empty one.

```bash
run0 restic snapshots
S=/var/services/snapshots/nextcloud/restic-2026-09-29
run0 mkdir -p $(dirname $S)
run0 btrfs subvolume create $S
run0 --setenv=RESTIC_PODMAN_ARGS="-v $S:$S" restic restore <ID>:/data/nextcloud --target $S
run0 find $S -xdev -perm /6000 \( -uid 0 -o -gid 0 -o -not -path '*/.local/share/containers/*' \) -ls
run0 getcap -r $S | grep -v rootid
run0 btrfs-restore.sh /var/services/nextcloud $S
ansible-playbook site.yml -l <host>
```

The `find` and the `getcap` list what a rootless service does not bring. The
`find` shows setuid and setgid files outside Podman's image layers, and those
that root owns: no rootless image layer holds such a file. The `getcap` shows
file capabilities that are not namespaced to a container. Each hit is
suspect. Run both on a snapshot from a target before you restore it.

Delete the `before-restore-*` copy, and a received or restic copy, when the
service works again.

On a new host, deploy first, so the users, their uids and the subvolumes
exist. Then restore each service and deploy again. A nested subvolume is in
no backup: install the Nextcloud apps of `custom_apps` again with `occ
app:install`, and download the Recognize models with `occ
recognize:download-models`.

## Adding a service

1. Copy `home-server-template` as its `README.md` says, and add the new
   repository: `git submodule add <its URL> services/<name>`.
2. Add `name`, `uid` and, for a pod that the proxy or another pod reaches,
   `port` to `base_setup_services` in `inventory/group_vars/homeserver.yml`.
   `groups` adds host groups, such as `systemd-journal`.
   The `uid` never changes after the first deploy, because it sets the subuid
   range that owns the service's files.
3. For a public service, set `<name>_service_hostname`, add an entry for
   `<name>` to `bunker_service_sites`, a DNS record and a probe URL. Then
   deploy.

The ports in use:

| Address | Service |
|---|---|
| `:80`, `:443` on every address | bunker |
| `127.0.0.1:<port>` | a service with a `port` in `base_setup_services` |
| `127.0.0.2:3000`, `127.0.0.2:9090` | Grafana, Prometheus |

## Design decisions

- **Fedora CoreOS.** The Ignition config alone reproduces the host, and a bad
  update rolls back.
- **`run0` for every escalation.** It is part of systemd, so it works on a
  derivative without `sudo`. It needs a terminal, so `ansible.cfg` sets
  `RequestTTY=force` and pipelining stays off.
- **One Btrfs subvolume and one rootless user per service.** A bad deploy
  rolls back one service alone, and a compromised service does not reach
  another's files. No quotas: qgroups cost too much on a thin client.
- **One role deploys every service's Quadlets as one archive.** A changed
  archive replaces the whole Quadlet directory, so a file that leaves a
  repository leaves the host; `home-server-template/README.md`, "Role
  contract", has the steps. One archive replaces one Ansible task per file,
  which costs seconds each on a thin client.
- **Memory ceilings are ceilings, not reservations.** The `Memory=` keys add
  up to more than 8 GB. They stop one container taking the host down. Lower a
  ceiling before you add a service.
- **Container output goes through `passthrough` where it can.** conmon's
  journald driver files every stderr line as `err`. With
  `LogDriver=passthrough` the unit's priority applies. Each service sets it in
  its own `container.d/`. Bunker keeps journald:
  `home-server-bunker/README.md`, "Specifics".
- **Updates are unattended.** Digest pinning and auto-update exclude each
  other, and this project chose auto-update. The restic image is the
  exception: it runs as root, so a digest pins it, and Renovate updates it.
  The reboot uses `--check-inhibitors=yes`, so it never interrupts a backup or
  a dump.
- **The secrets repository is a second inventory.** `ansible.cfg` lists it
  after this one, so its `group_vars/` and `host_vars/` win over this
  repository's, and Ansible decrypts them by itself.

## Security

Threat model: a single-user server on a home LAN, reachable from the internet
only through BunkerWeb on 80 and 443. Physical theft is out of scope.

Covered:

- SSH accepts only the hardware-backed key, and no root login. The admin user
  may forward local ports only, because Grafana is reachable only through a
  tunnel. sshd drops a dead client after 10 to 15 minutes, so a broken
  connection does not block the staged reboot.
- Every service container drops all capabilities and sets `no-new-privileges`
  and a pids limit.
- `policy.json` rejects every image that no role declares
  (`home-server-template/README.md`, "Role contract").
- SSH checks a real host against `ssh/known_hosts` of the secrets repository.
  Only the inventory entry `test` skips the check.
- Credentials in the secrets repository are Vault-encrypted. Keep a copy of
  the Vault password in a password manager: it also guards the LUKS passphrase.

Known gaps:

- While the root gate is open, the SSH key alone gives root. Closed, `run0`
  asks for core's password. The gate is a file in `/run/polkit/`, which the
  polkit rule from Ignition checks, so a boot closes it. The gate is for all
  of core's processes, so an intruder as core gets root the next time it opens.
- `ip_unprivileged_port_start=80` lets any local user bind 80 and 443 while
  the proxy is down.
- Unattended updates reach production with no gate. Images outside
  `ghcr.io/marpogaus` pull without a signature.
- The test VM is root for anyone with `test/coreos_key`, which has no
  passphrase. `test/start_vm.py` creates it when it is missing.
- `btrfs-restore.sh` stops only the service's pod. A compromised service user
  whose own units keep running can swap a directory for a symlink while the
  script moves a nested subvolume.
- The `monitoring` user is in `systemd-journal` and reads the whole host
  journal. Alloy redacts only what it sends to Loki, so a compromised
  monitoring service reads tokens that other units log.
- Without CHAP, the NAS admits any LAN device with this host's initiator name.
  LUKS stops it from reading the backups, not from overwriting them.

SELinux exceptions:

- `platform/secureblue.yml` runs `ujust set-container-userns on`, because
  SecureBlue's `harden_container_userns` blocks rootless Podman.
- iscsid needs a permissive `iscsid_t`, which `platform/secureblue.yml` sets. A
  constraint, not an allow rule, stops its netlink socket.
- `/usr/local/bin/restic` runs its root container with `label=disable` and
  Podman's default capabilities, so it can read and restore the files of every
  service.
- Alloy runs as `container_logreader_t` with a local policy module:
  `home-server-monitoring/README.md`, "Specifics".
- `btrfs-backup.sh` labels the root of each backup target `container_file_t`,
  so node-exporter can read its free space.

## Alerts

| Alert | Severity | Fires when |
|---|---|---|
| `JobStale` | critical | A snapshot, backup or dump (a `*_last_success` textfile metric) has not succeeded for 30 hours |
| `BackupTargetLow` | warning | A backup target has less than 10 % free space |
| `ScheduledJobFailed` | warning | A snapshot, backup or scrub unit failed in the last 6 hours |
| `AutoRebootBlocked` | warning | The staged-update reboot failed twice in 50 hours |
| `SshLogin` | info | An SSH key login succeeded |
| `SshLoginFailed` | warning | More than 5 failed SSH logins in 15 minutes |
| `SelinuxDenials` | warning | More than 20 enforced SELinux denials in 15 minutes |

## LLM coding tools

LLM-based coding tools write most of the code and documentation of this
project. The maintainer sets the goals and the design, reviews every change and
is responsible for it. Each change runs on a VM before it reaches a host.

## License

MIT
