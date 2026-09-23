# home-server

This repository deploys a home server: the Ansible roles that prepare a Fedora
CoreOS host for rootless containers, the playbook, the inventory, the scripts
that deploy and test a host, the Ignition config that installs it, and the test
VM. It shows what the server runs, on which hosts, and how to operate it. This
README is the entry point for the project.

The roles make one unprivileged user and one Btrfs subvolume for each service.
They also set up snapshots, off-box backup and the firewall. They name no
service: `base_setup_services` in `inventory/group_vars/homeserver.yml` says
what the host runs, and each service lives in a repository of its own.

The repository also holds the SecureBlue platform files (`platform/`),
templates for the secrets (`secrets.example/`), the hardening notes
(`docs/HARDENING.md`) and the design notes (`docs/DESIGN.md`). It holds no
secret. The credentials and the SSH identities sit in `home-server-secrets`, a
private repository cloned beside this one.

## The repos

| Repo | Purpose |
|---|---|
| `home-server` | Host setup (Btrfs, users, snapshots, backup, firewall), the playbook, Ignition, the test VM, the inventory and the deploy and test scripts |
| `home-server-nextcloud` | Nextcloud pod, Ansible role, custom image build |
| `home-server-bunker` | BunkerWeb reverse proxy pod (WAF, TLS) and role |
| `home-server-monitoring` | Prometheus, Alertmanager, Grafana, Loki, Alloy, node-exporter, ntfy |
| `home-server-template` | Skeleton to copy for a new service; "Adding a service" has the checklist |
| `home-server-secrets` | The credentials and the SSH identities (**private**) |
| `image-builder-action` | Reusable GitHub Action that builds and signs images; a deploy does not need it |

Clone the repositories into one directory, with these names. `site.yml` finds
each service role at `../home-server-<repo>/ansible-role`, and `deploy.sh`
finds the credentials at `../home-server-secrets`. `SECRETS_DIR` overrides that
path.

```bash
git clone https://github.com/MArpogaus/home-server.git            home-server
git clone https://github.com/MArpogaus/home-server-nextcloud.git  home-server-nextcloud
git clone https://github.com/MArpogaus/home-server-bunker.git     home-server-bunker
git clone https://github.com/MArpogaus/home-server-monitoring.git home-server-monitoring
git clone https://github.com/MArpogaus/home-server-template.git   home-server-template
git clone <the private secrets repo>                              home-server-secrets
```

## Architecture

```
site.yml
  base_setup role                   Btrfs subvolumes, users, subuid,
          │                         snapshots, off-box backup, zram, firewall,
          │                         auto-update / auto-reboot timers
          └── one service role per entry in base_setup_services
                └── quadlet_service role   deploys quadlets/, quadlets/container.d/
                                           and quadlets/configs/, reloads, restarts
                                           the pod on change
```

One Linux user per service, each with its own systemd user manager and Podman
network. Cross-service traffic goes through host-published ports, never
container names.

### What `base_setup` does

| Area | How |
|---|---|
| Storage | Btrfs subvolume per service under `/var/services`, `snapshots` subvolume on the same disk: a rollback mechanism, not a backup |
| Users | System users, linger, optional extra `groups`; the subuid/subgid range starts at `uid * base_setup_subuid_range_size + 100000`, so it is stable and collision-free |
| Snapshots | `btrfs-snapshot@<svc>.timer`, on `base_setup_btrfs_snapshot_schedule`; read-only, retention by the date in the name |
| Backup | `btrfs-backup@<target>.service`, started by a finished snapshot: incremental `btrfs send` to each target |
| Memory | Swap on zram, sized `min(ram / 2, 4096)` |
| Power | `sleep`, `suspend`, `hibernate` and `hybrid-sleep` targets masked: a server that suspends is down |
| Updates | `podman-auto-update.timer` per user for the containers. A staged OS image is applied by a reboot right after the night's backup (`OnSuccess=` on each backup unit starts `auto-reboot-staged.service`), and `auto-reboot-staged.timer` repeats that check at 03:00 as the fallback. The platform stages the image with `rpm-ostreed-automatic.timer`. Stock Fedora CoreOS runs Zincati instead, which stages and reboots on its own schedule |
| Firewall | firewalld: ssh, http and https are opened, permanent and immediate, with no `firewall-cmd --reload`, which would drop the SSH connection the deploy runs over. `ip_unprivileged_port_start=80`, so any service user can bind 80 and 443 while the proxy is down |
| Metrics | `/var/lib/node-textfile`, see "Metrics" |

## Requirements

This project needs Ansible Core 2.21 or newer with the collections in
`requirements.yml`. The host needs Fedora CoreOS 44 or newer. Ansible's Python
needs `passlib` and `bcrypt` (ntfy hashes its users):
`uv tool install --reinstall ansible --with passlib --with bcrypt`.

`ansible.cfg` sets `force_handlers`. A handler then still runs when a later
task fails. Without it, the next run finds the files unchanged, notifies
nothing, and the systemd reload never happens.

## Development

`CONTRIBUTING.md` in each repository with code has the workflow:
branches, commits, hooks and action pinning.

Dependabot cannot read a container image tag out of an Ansible variable, so
Renovate does that. Each repository with a service role carries
`.github/renovate.json`, which extends
`.github/renovate-image-tags.json`. That preset reads each
`*_image` default and opens one pull request per version tag against `dev`. It
skips this project's own images, because the build workflow owns their major
version.

Three references move by hand:

- the SecureBlue signing key, `secureblue-2025.pub` in `platform/secureblue.bu`.
  The rebase follows the image's `latest` tag, so the image itself does not
  move by hand.
- the Fedora CoreOS release in `test/start_vm.py`, with its checksum
- the Nextcloud majors (`home-server-nextcloud/README.md`, "Major upgrade")

## Deploy

The controller needs what "Requirements" lists and, for the test VM, what
`test/README.md`, "Requirements", lists. The commands run from this
repository.

### A new deployment

The Vault password comes first, because the secrets are encrypted with it.
`docs/HARDENING.md` says why a copy of it belongs in a password manager.

```bash
mkdir -p -m 700 ~/.config/home-server
(umask 077; openssl rand -base64 48 > ~/.config/home-server/vault-password)
echo 'export ANSIBLE_VAULT_PASSWORD_FILE=~/.config/home-server/vault-password' >> ~/.bashrc
```

Open both terminals after that, so each one has the variable. Terminal 1
starts the VM. `start_vm.py` creates the key pair in `test/`,
because none is there yet:

```bash
python3 test/start_vm.py --fresh --platform platform/secureblue.bu
```

Terminal 2 creates the secrets repository from this repository's templates.
Fill in the values (see "Variables") before the encrypt step:

```bash
S=../home-server-secrets
mkdir -p $S/secrets $S/ssh && git -C $S init -q
cp secrets.example/vars.yml.example $S/secrets/vars.yml
cp secrets.example/vars.host.yml.example $S/secrets/vars.test.yml
echo 'secrets/vars*.yml diff=ansible-vault' > $S/.gitattributes
ansible-vault encrypt $S/secrets/vars.yml $S/secrets/vars.test.yml
cp test/coreos_key{,.pub} $S/ssh/
```

Once the VM has rebased and rebooted, deploy and test it:

```bash
ssh -p 2222 -i test/coreos_key -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  core@127.0.0.1 systemctl is-active install-secureblue.service   # inactive
./deploy.sh
./functional_test.sh
```

### With an existing secrets repository

The VM boots with the key in `test/`, and the scripts log in with
`ssh/coreos_key` of the secrets repository, so the pair goes to `test/` first:

```bash
cp ../home-server-secrets/ssh/coreos_key{,.pub} test/
python3 test/start_vm.py --fresh --platform platform/secureblue.bu   # terminal 1
```

In terminal 2, once the VM has rebased and rebooted:

```bash
ssh -p 2222 -i test/coreos_key -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  core@127.0.0.1 systemctl is-active install-secureblue.service   # inactive
./deploy.sh && ./functional_test.sh
```

### Installing the real host

`ignition/` holds one Butane template for the test VM and the
real hardware. It sets up the Btrfs root, the SSH key, the cosign public key,
the polkit rule that lets `run0` escalate without a password, and a first-boot
unit that layers python3 when the image has none.
`--platform ../platform/secureblue.bu` adds the unit that
rebases to SecureBlue, removes itself and reboots.

1. Point DNS at the public address of the machine. Forward ports 80 and 443
   from the router, and no other port. Let's Encrypt validates over port 80,
   so TLS works only after the record resolves from the internet.
2. Boot the unmodified live ISO on the target once and read the disk name:
   `lsblk -dno NAME,SIZE,MODEL` and `ls -l /dev/disk/by-id/ | grep -v part`.
   If a USB stick is attached during the install, use the
   `/dev/disk/by-id/ata-<model>_<serial>` path, because the stick can take
   the name `sda`.
3. Plug in the YubiKey, then build:

   ```bash
   cd ignition
   INSTALLER=$(sed -n 's/^INSTALLER_IMAGE="\(.*\)"$/\1/p' build.sh)   # the pinned digest
   podman run --rm -v "$PWD":/data:z -w /data \
     "$INSTALLER" download -s stable -p metal -f iso
   P=../platform/secureblue.bu
   ./build.sh --platform $P ign         # render config.ign only; read it
   ./build.sh --platform $P iso fedora-coreos-<version>-live.x86_64.iso /dev/sda
   cd ..
   ```

   `./build.sh --platform $P install /dev/sdX` writes a disk attached to this
   computer instead, and needs `sudo podman`. `build.sh` needs `podman`. It
   authorises the smartcard key from your SSH agent, the key whose comment
   contains `cardno:`, unless `SSH_PUBLIC_KEY` names another. It asks for a
   console password, which is for the machine's own console; SSH refuses
   passwords. `PASSWORD_HASH=none` leaves the console without one.

   CAUTION: `install.iso` installs onto the named device of the target and
   reboots, with no prompt. It erases that disk.
4. Boot the stick. The machine installs Fedora CoreOS, rebases to SecureBlue
   and reboots. SSH answers throughout. The host is ready when the first-boot
   unit is done:
   `ssh core@<host> systemctl is-active install-secureblue.service` prints
   `inactive`.
5. Record the host key (see "Script settings"). Copy
   `secrets.example/vars.host.yml.example` to `secrets/vars.<name>.yml`, fill
   in the host's values, delete the two certificate lines that only a host
   without public DNS keeps, encrypt the file, and deploy an empty host:

   ```bash
   TARGET_HOST=<address> TARGET_PORT=22 TARGET_NAME=<host> SSH_AUTH_KEY=agent ./deploy.sh
   TARGET_HOST=<address> TARGET_PORT=22 TARGET_NAME=<host> SSH_AUTH_KEY=agent ./functional_test.sh
   ```

   Get 0 failed before you restore data.
6. Before you trust the host with data, do the checks the functional test
   cannot do: restore a dump into a scratch database and read a table, reboot
   and check that each container starts again, read a file back from a backup
   target, disconnect a target and start the sync (it must fail clearly), and
   stop a container and wait for the ntfy alert.

A host that boots in legacy BIOS mode needs no new installation for a change to
UEFI, because the ESP holds the files and bootupd keeps them current.

### A controller in a container

`start_vm.py` publishes the VM's ports on `127.0.0.1`. A controller in a
container reaches the host through another address. Start the VM with
`--listen <address>`, the one host address the container reaches, and run the
scripts with `TEST_VM=1 TARGET_HOST=<address>`. `--listen 0.0.0.0` also works,
and it opens the VM's SSH, HTTP and HTTPS to every network the host is on.

### Script settings

Each `secrets/` and `ssh/` path below is inside `home-server-secrets`.

| Variable | Default | Selects |
|---|---|---|
| `TARGET_HOST`, `TARGET_PORT` | `127.0.0.1`, `2222` | The address |
| `TARGET_NAME` | `test` | The host vars, `secrets/vars.<name>.yml`. A name, so a host keeps its settings when its address changes |
| `ANSIBLE_VAULT_PASSWORD_FILE` | `~/.config/home-server/vault-password` | The Vault password; see "Vault" |
| `SSH_KEY_FILE` | `ssh/coreos_key` | The key file |
| `SSH_AUTH_KEY` | `file` | `agent` uses the SSH agent, the YubiKey that a real host accepts |
| `SERVICES` | every service user on the host | The per-user checks |
| `SERVER_NAME` | from the secrets | The hostname the HTTPS checks use |
| `BACKUP_TARGET` | none | A configured backup target that the test runs a real backup against |
| `TEST_VM` | none | `1` marks a target at another address, such as the host's LAN IP, as the test VM |

A target on loopback or link-local, or one run with `TEST_VM=1`, is the test VM.
It gets a new host key on every `--fresh`, so the scripts do not check its key,
and they refuse such a target unless `TARGET_NAME` is `test`.
Every other target is checked against `ssh/known_hosts`, and the scripts refuse
to start without a record. An unchecked key lets a device that wins an ARP race
receive every secret as extra-vars. Record the key once, from a session you
trust, and compare the fingerprint with the console:
`ssh-keyscan -H -p <port> <host> 2>/dev/null >> ../home-server-secrets/ssh/known_hosts`.

`deploy.sh` checks the secrets, the Vault password, the SSH identity and that
Ansible's Python has `passlib` and `bcrypt` ("Requirements"). It
installs the collections and removes group and other access from
`home-server-secrets`. It runs the playbook from this repository, where
`ansible.cfg` is, and passes the host key and identity options through
`ANSIBLE_SSH_COMMON_ARGS`. The secrets go in as extra-vars, which have the
highest precedence, so no inventory can shadow one. If the ntfy site is
configured, `deploy.sh` posts "Deploy to `<host>` succeeded" or "FAILED" to the
topic with the token.

`functional_test.sh` does real work on the target. It starts
`nextcloud-pg-dumpall` and a Btrfs snapshot, and a finished snapshot starts a
backup to every target and, when an update is staged, the reboot after it. It
makes eight failed SSH logins to prove that an alert fires, and publishes one
message titled `functional test` to the target's `alerts` topic.
It reads Loki through Grafana's datasource proxy with the Grafana admin
credential, which travels on ssh stdin.

### Vault

Every `secrets/vars*.yml` of the secrets repository that holds a credential is
encrypted with Ansible Vault. The scripts read the password from
`ANSIBLE_VAULT_PASSWORD_FILE`, which they default to
`~/.config/home-server/vault-password`. `ansible-vault` itself has no such
default, so the shell profile exports the variable. Edit a file with
`ansible-vault edit secrets/vars.yml`. With the `.gitattributes` line from "A
new deployment", this shows readable diffs:
`git config diff.ansible-vault.textconv "ansible-vault view"`.

## Variables

| Variable | Required | Default | Controls |
|---|---|---|---|
| `nextcloud_service_db_password` | yes | | PostgreSQL |
| `nextcloud_service_admin_password` | yes | | Nextcloud admin |
| `nextcloud_service_app_image` | no | `ghcr.io/marpogaus/nextcloud:35` | App image |
| `nextcloud_hostname` | yes | | Nextcloud's public hostname; the proxy site and the trusted domain follow from it |
| `bunker_service_letsencrypt_email` | no | `""` | ACME contact; empty registers `contact@<server name>` |
| `bunker_service_generate_self_signed_ssl` | no | `no` | `yes` only for a host without public DNS |
| `bunker_service_auto_lets_encrypt` | no | `yes` | `no` together with the self-signed certificate; the role refuses both set to `yes` |
| `ntfy_hostname` | no | `""` | ntfy's public hostname, with its own DNS record; the site and the ntfy URL follow from it |
| `monitoring_service_ntfy_password` / `_token` | yes | | The phone's password for user `ntfy`; the token Alertmanager and `deploy.sh` publish with (`tk_` + 29 lowercase alphanumerics) |
| `monitoring_service_grafana_admin_password` | yes | | Grafana `admin`; the role refuses to run without it |
| `monitoring_service_probe_urls` | on a real host | `[]` | `https://` URLs probed every minute; empty means no public-path alerting |
| `base_setup_iscsi_*` | no | no iSCSI | An iSCSI LUN as a backup target |

The passwords and the ntfy token belong to one host each and go to
`secrets/vars.<name>.yml`, so the test VM holds throwaway values that no other
host accepts.

All other settings (PHP sizing, rate limits, image tags) have defaults in
`defaults/main.yml` of the service roles. Override them here. Memory ceilings
are `Memory=` lines in each service's Quadlets.

Machine-to-machine secrets are 48 alphanumeric characters with no symbols.
Thus YAML, env files, shells and URLs need no quotation marks:

```bash
openssl rand -base64 48 | tr -d '/+=' | cut -c1-48
```

The Nextcloud passwords are an exception to this rule. Each dump names the
database role, and a person types the admin password on a phone. The ntfy token
has a fixed format:

```bash
echo "tk_$(openssl rand -hex 15 | cut -c1-29)"
```

### base_setup variables

`roles/base_setup/defaults/main.yml` holds every base_setup variable and its
default. The ones whose default is not the whole story:

| Var | Note |
|---|---|
| `base_setup_backup_targets` | `[]` means no off-box backup. A target that leaves the list loses its config file and its backup metric on the next deploy |
| `base_setup_iscsi_portal` | Set: the deploy logs in to the iSCSI target, with or without a backup target |
| `base_setup_luks_passphrase` | Required as soon as a backup target is set; one passphrase for every target |

### The VM and the real host

`vars.yml` holds what both hosts share, including the public hostnames.
`vars.test.yml` and one `vars.<host>.yml` per real host override it; read them
for what differs.

## Adding a service

1. Copy `home-server-template` to `home-server-<name>`. Replace `__NAME__` with
   the service name and `__PORT__` with a free loopback port (table below).
2. Add the service to `base_setup_services` in
   `inventory/group_vars/homeserver.yml`:

   ```yaml
   base_setup_services:
     - name: immich
       uid: 1003
   ```

   `repo` names the repository `home-server-<repo>` and defaults to `name`. A
   service's `uid` never changes after its first deploy. It sets the subuid
   range, and every image layer and data file of the service is owned inside
   that range.
3. For a public service, add its site to `bunker_service_sites` in the same
   file, its hostname to the vault vars, and a DNS record for that name.
4. Add its public URL to `monitoring_service_probe_urls`.
5. Give each container a `Memory=` ceiling, and lower another service's ceiling
   first when the sum outgrows the host (`docs/DESIGN.md`, "Memory ceilings are
   ceilings, not reservations").
6. Put the service's alert rules, dashboards and log filters in its
   `monitoring/` folder (`home-server-monitoring/README.md`, "Monitoring files
   of a repository"). Its credentials go into the vault vars.
7. Deploy.

| Port | Used by |
|---|---|
| `80`, `443` | the proxy, on every interface |
| `127.0.0.1:8080` | Nextcloud |
| `127.0.0.1:8081` | ntfy |
| `127.0.0.2:3000` | Grafana |
| `127.0.0.2:9090` | Prometheus |

An image that this project's cosign key does not sign needs nothing further.
`base_setup` reads every `*_image` default of every service role, and every
`<repo>_service_*_image` variable the deployment sets for this host, and writes
each repository into the signature policy. The policy keeps the image's own
entries and sets the default to `reject`, so a repository that no role declares
does not pull, whatever default the OS image ships.

Each service gets a subvolume, user, subuid range, linger, snapshot timer and
auto-update timer. This repository's own `monitoring/` covers snapshots,
backups, reboots, SSH and SELinux.

## Host-specific tasks

A step that one host needs and no other host needs does not belong in these
roles. The deployment names a task file, and `site.yml` includes it before
`base_setup`, so a later task can depend on it (a device, a policy exception):

```yaml
host_tasks_pre: "{{ secrets_dir }}/tasks/<host>-pre.yml"
```

It is optional. `deploy.sh` sets `secrets_dir`.

Use this for the genuinely singular. A mechanism that two hosts can share
belongs in the role, with its value in the deployment. A platform step is the
exception. These roles target stock Fedora CoreOS, so a step that only a
derivative image needs lives in the deployment too, even when every host runs
one: SecureBlue's tasks are `platform/secureblue.yml`. The
same holds for the Ignition config: `ignition/build.sh` merges the Butane
fragment that `--platform` names, such as
`platform/secureblue.bu`, into the config.

## Privilege escalation

Ansible becomes root and the service users with `run0`, through
`community.general.run0`. The plugin needs a terminal, and Ansible sees one only
in its own SSH arguments: `ssh_extra_args` in `ansible.cfg` carries
`-o RequestTTY=force`, which reaches `ssh` alone: `sftp` with a terminal hangs.
With a terminal each `run0` session closes when the call ends. A session that
stays in `closing` counts against logind's session limit, and a few hundred of
them stop logind from opening new ones; `functional_test.sh` checks for them.
Pipelining is off, because it cannot work with a terminal. `become_exe` sets
`TERM=dumb`, so `run0` writes no terminal escape codes into the module output.

The polkit rule `/etc/polkit-1/rules.d/60-run0-fast-user-auth.rules`, installed
by Ignition, grants `org.freedesktop.systemd1.manage-units` to `core` without
authentication. `manage-units` starts transient units, so `core` has
unauthenticated root on this host. The SSH key is the whole perimeter.

## Metrics

`/var/lib/node-textfile` holds Prometheus text files that root writes when a
job succeeds. node-exporter's textfile collector reads them. The directory is
`container_ro_file_t`, so a rootless container mounts it read-only without a
relabel. A service role may add its own files there.

| File | Metric | Written by |
|---|---|---|
| `snapshot-<service>.prom` | `snapshot_last_success_timestamp_seconds{service}` | `btrfs-snapshot@<service>` |
| `backup-<target>.prom` | `backup_last_success_timestamp_seconds{target}`, `backup_target_size_bytes`, `backup_target_avail_bytes` | `btrfs-backup@<target>` |

The first deploy writes each file with the deploy time, so a job that never
succeeds reads as stale 30 hours later.

## Alerts

`monitoring/` holds the rules for what this repository sets up.
`home-server-monitoring` collects them and routes them by severity.

| Alert | Severity | Fires when |
|---|---|---|
| `JobStale` | critical | A `*_last_success_timestamp_seconds` metric is older than 30 hours |
| `BackupTargetLow` | warning | A backup target has less than 10 % free space |
| `ScheduledJobFailed` | warning | A `btrfs-backup@` or `btrfs-snapshot@` unit failed in the last 6 hours |
| `AutoRebootBlocked` | warning | `auto-reboot-staged` was refused more than once in 50 hours |
| `SshLogin` | info | An SSH login with a key succeeded |
| `SshLoginFailed` | warning | More than 5 failed SSH logins in 15 minutes |
| `SelinuxDenials` | warning | More than 20 enforced SELinux denials in 15 minutes, pasta's start-up probes excluded |

## Backup targets

Each target is a LUKS2 container that holds Btrfs. This applies to a USB disk
and to an iSCSI LUN on the NAS. `btrfs send` needs a block device. A file
share holds no ownership and no xattrs. SecureBlue also blocks NFS and SMB at
module level. Nested subvolumes are the exclude list: a snapshot does not go
into a nested subvolume (`home-server-nextcloud/README.md`, "Backups").

```yaml
base_setup_luks_passphrase: "<one passphrase for every target>"
base_setup_backup_targets:
  - uuid: 7f3c8e2a-...      # UUID of the LUKS container
    name: usb
    retention_days: 30
  - uuid: a91b4d17-...
    name: nas
    retention_days: 180
```

The UUID of the LUKS container identifies each target. Thus a disk continues
to work after it moves to another port. `name` gives the mount point, the unit
instance and the alert label. Each target gets a `crypttab` entry with
`nofail`, which opens when the disk appears, and `/var/backup/<name>` as an
automount, which unmounts after five idle minutes. Each target also gets
`btrfs-backup@<name>.service` with its own retention.

The sync has no timer. A finished snapshot starts the sync through
`OnSuccess=`. Thus the copy is always the snapshot that the host made. systemd
merges the identical start jobs, thus each target syncs one time. The sync
needs its mount. If a target is absent, the unit fails and
`ScheduledJobFailed` fires. If you disconnect a disk on purpose, that alert
comes each night. `JobStale` fires when a target has had no successful sync
for 30 h, which also covers a sync that never starts.

A sync that stops in the middle leaves a subvolume without a `Received UUID`.
The script deletes these subvolumes before it looks for work. Thus it never
counts a partial copy as complete. It never uses a partial copy as an
incremental parent.

The script reads the `Received UUID` from `btrfs subvolume show` to decide if a
copy on the target is complete. A wrong answer there deletes a good backup.
Two guards limit that risk. First, the script treats output without the field
as complete. Second, more than one unreceived copy of one service skips that
service and fails the run, because an interrupted receive leaves at most one
such copy. The other services still get their backup.

CAUTION: Keep `base_setup_luks_passphrase` on a different machine. One
passphrase opens each target. Without the passphrase, you cannot read a
backup.

### What each layer covers

| Layer | Covers | Does not |
|---|---|---|
| Btrfs snapshot, nightly per service | `/var/services/<service>`, including the database dump | a service's nested subvolumes (`home-server-nextcloud/README.md`, "Backups") |
| `btrfs send` to a target | the same, off the machine | the same exclusion |
| `pg_dumpall` before the snapshot | the cluster, as SQL | nothing the snapshot does not already hold; it exists so the snapshot is consistent |
| `rpm-ostree` rollback | the OS image | `/etc` and `/var/home/core`, which only a deploy restores |

`/etc` is the gap. A deploy restores crypttab, the LUKS keyfile, the subuid
maps, the local SELinux module and `policy.json`. A backup does not restore
them. The host snapshots and sends `home-server-bunker` and
`home-server-monitoring` in the same way as Nextcloud, and they restore in the
same way.

No `btrfs scrub` runs on a schedule, on either filesystem. Thus a restore
finds bit rot on a target when it reads the data, not before. Run
`run0 btrfs scrub start /var/backup/<target>` by hand on a disk that has been
in service for a long time.

## Operations

A service user has `/usr/sbin/nologin`, so `su` and `ssh` cannot reach it.
Run a command as that user with `run0`, which opens a session for it and so
sets `XDG_RUNTIME_DIR` and the user bus:

```bash
run0 --user=nextcloud -- bash -c 'podman ps'
run0 --user=nextcloud -- systemctl --user status nc-pod.service
```

Replace `nextcloud` with `proxy` or `monitoring`. A root command is
`run0 <command>`.

### Adding a backup target

**A LUN on the NAS.** Create and export the LUN on the NAS, with no filesystem
on it. Permit this host's initiator name,
`iqn.2026-01.local.homeserver:<inventory_hostname>` unless
`base_setup_iscsi_initiator` overrides it. The LUN number must be 0, or
`base_setup_iscsi_lun` must match it. Then set in the host vars:

```yaml
base_setup_iscsi_portal: <nas address>
base_setup_iscsi_target: iqn.<vendor>:<target>
base_setup_iscsi_chap_user: <user>
base_setup_iscsi_chap_password: "<password>"
base_setup_luks_passphrase: "<passphrase>"
```

Require CHAP for the target on the NAS, with the same user and password. The
initiator name alone admits any device on the LAN that claims it, and LUKS
keeps such a device from reading the backups, not from overwriting them.

SecureBlue's policy stops iscsid from creating its netlink socket, so the host
task file must make `iscsid_t` permissive (`secrets/tasks/<host>-pre.yml`, see
"Host-specific tasks"). The deploy logs in to the target. Format the LUN once by
hand, with `D=/dev/disk/by-path/<by-path name>`:

```bash
run0 cryptsetup luksFormat --type luks2 "$D" /etc/luks/backup.key
run0 cryptsetup open --key-file /etc/luks/backup.key "$D" tmp
run0 sh -c 'mkfs.btrfs -L backup /dev/mapper/tmp && cryptsetup close tmp'
run0 blkid -s UUID -o value "$D"      # the value for the target list
```

Add the entry to `base_setup_backup_targets` and deploy again. The deploy does
not open the new container: reboot, or run
`run0 systemctl start 'systemd-cryptsetup@backup\x2dnas.service'`. Start the
first sync with `run0 systemctl start btrfs-backup@nas.service`, and read a file
back from `/var/backup/nas/<service>/<date>` before you trust the target.

**A USB disk.** Set `base_setup_luks_passphrase` and deploy first, so
`/etc/luks/backup.key` exists. Then:

```bash
run0 cryptsetup luksFormat --type luks2 /dev/sdX /etc/luks/backup.key
run0 cryptsetup open --key-file /etc/luks/backup.key /dev/sdX tmp
run0 sh -c 'mkfs.btrfs -L backup /dev/mapper/tmp && cryptsetup close tmp'
run0 blkid -s UUID -o value /dev/sdX      # the value for the target list
```

### When a backup fails

```bash
run0 systemctl status nextcloud-pg-dumpall.service 'btrfs-backup@*.service' 'btrfs-snapshot@*.service'
run0 journalctl -u btrfs-backup@<name>.service -n 20
```

- **The target is absent.** The host still boots, because `crypttab` carries
  `nofail` and the mount is an automount. Check
  `ls -l /dev/disk/by-uuid/<uuid>` and `run0 cryptsetup status backup-<name>`.
  For iSCSI, `run0 iscsiadm -m session` shows whether the session exists.
- **The target is full.** `btrfs send` fails with "No space left on device". The
  received subvolumes stay valid. Read
  `run0 btrfs filesystem usage /var/backup/<name>`. Lower `retention_days`, or
  grow the LUN and run `run0 cryptsetup resize backup-<name>` and
  `run0 btrfs filesystem resize max /var/backup/<name>`. Delete a received
  subvolume with `btrfs subvolume delete`, never with `rm -rf`.
- **Every read fails with `Input/output error` when the NAS comes back.** A LUN
  that comes back is a new disk, while `backup-<name>` still maps the old one,
  and the kernel keeps the dead Btrfs registered. `cryptsetup close` and
  `btrfs device scan --forget` refuse. Reboot.

### Restoring from a backup target

A target holds read-only received subvolumes at
`/var/backup/<target>/<service>/<date>`, one per day that the sync ran. The
service home is also the user's Podman store, so the user manager is down
while the subvolume is replaced:

```bash
run0 --user=nextcloud -- systemctl --user stop nc-pod.service
run0 systemctl stop "user@$(id -u nextcloud).service"
run0 mv /var/services/nextcloud /var/services/nextcloud.old
run0 sh -c 'btrfs send /var/backup/nas/nextcloud/<date> | btrfs receive /var/services'
run0 mv /var/services/<date> /var/services/nextcloud
run0 btrfs property set -f /var/services/nextcloud ro false
run0 rm -rf /var/services/nextcloud/data/custom_apps
run0 btrfs subvolume create /var/services/nextcloud/data/custom_apps
run0 chown nextcloud:nextcloud /var/services/nextcloud/data/custom_apps
run0 restorecon -R /var/services/nextcloud
run0 systemctl start "user@$(id -u nextcloud).service"
```

- `-f` is needed, because btrfs refuses to clear the read-only flag while the
  `Received UUID` is set.
- A send does not carry the nested `custom_apps`, so it is created again. The
  next deploy downloads the apps and the Recognize models into it.
- `restorecon -R` is needed: a received subvolume carries the labels it had at
  send time, and no other step corrects them.

The incremental chain lives in the snapshot directory and its received copies,
which this does not touch. Deploy again after the restore. When the service
answers, delete `nextcloud.old` with `btrfs subvolume delete`, innermost first.

To read a target on another machine, run
`cryptsetup open /dev/<disk> backup-<name>` with `base_setup_luks_passphrase`,
mount it, and `btrfs send` the subvolumes.

### Rolling back

**The OS.** rpm-ostree keeps the previous deployment. Without the disabled
timer, `rpm-ostreed-automatic` stages the same update again and
`auto-reboot-staged` reboots into it after the next backup:

```bash
run0 rpm-ostree rollback
run0 ostree admin pin 0                                    # keeps it through a later update
run0 systemctl disable --now rpm-ostreed-automatic.timer   # enable again when fixed
run0 systemctl reboot
```

**A service.** The snapshots are read-only subvolumes under
`/var/services/snapshots/<service>/<date>`. Use the restore steps above, with
`run0 btrfs subvolume snapshot /var/services/snapshots/<service>/<date> /var/services/<service>`
(writable, so no `-r`) in place of the send and receive. The snapshot lands at
its final path and is writable, so the `mv /var/services/<date>` and the
`btrfs property set` steps are skipped. A snapshot does not carry the nested
`custom_apps` either, so that step stays.

### Troubleshooting

**A container restarts again and again.** Read
`run0 journalctl _UID=$(id -u <service>) -n 100`.

| Log line | Cause |
|---|---|
| `setpriv: setresuid failed`, `runuser: cannot set groups`, `Operation not permitted` on `chown` | the entrypoint needs a capability that `container.d/hardening.conf` drops; add it with `AddCapability=` in that container's Quadlet |
| `executable file ... not found` with the whole flag string | `Entrypoint=` takes one executable; arguments belong in `Exec=` |
| `cannot set on-failure action to kill without a health check` | `HealthOnFailure=` without `HealthCmd=` |
| `rsync ... failed: Operation not permitted` | a mount point the container cannot chown; check group ownership |
| `open() "/dev/stdout" failed (6: No such device or address)` | the image opens its log by path under `passthrough`; log via syslog instead |
| `Cannot write into "apps" directory` | `custom_apps` is not readable or writable for the container user; check owner and mode `0755` |

A deploy that restarts a pod writes some of these lines too. They stop within
fifteen minutes.

**The host runs but does not answer.** Ping, SSH and HTTPS fail, the console
shows a running system with `Link detected: yes`. On a Realtek NIC that is
Energy Efficient Ethernet: `ethtool --show-eee <interface>` shows
`EEE status: enabled - active`. A host task file turns EEE off when the
interface comes up. `run0 journalctl -b -1 | tail` shows how the previous boot
ended.

**A deploy waits a long time.** The Nextcloud install and the monitoring
readiness waits cover a cold image pull and a major upgrade, which each take
more than ten minutes on a thin client. Read the container's journal instead of
waiting.

## Test VM

`test/README.md` has the commands. Test each change on the VM before it goes to
the real host. The two hosts run the same code. They differ only in
`secrets/vars.<name>.yml`.

## Interfaces

| What | Where |
|---|---|
| Nextcloud | `https://<nextcloud_hostname>` |
| ntfy | `https://<ntfy_hostname>`, user `ntfy` + `monitoring_service_ntfy_password`, topic `alerts` |
| Grafana | `ssh -L 3000:127.0.0.2:3000 core@host`, then http://localhost:3000, `admin` + `monitoring_service_grafana_admin_password` |
| Nextcloud direct (BunkerWeb upstream) | `127.0.0.1:8080` on the host, loopback only |

## Design

`docs/DESIGN.md` says why the roles are shaped as they are, and
`docs/HARDENING.md` what the hardening covers and where its gaps are.

## License

MIT
