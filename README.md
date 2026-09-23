# home-server-deploy

This repository deploys a home server. It shows what the server runs, on which
hosts, and how to operate it. This README is the entry point for the project.

The repository holds the inventory, the scripts that deploy and test a host,
the SecureBlue platform files (`platform/`), templates for the secrets
(`secrets.example/`) and the hardening notes (`docs/HARDENING.md`). It holds no
secret. The credentials and the SSH identities sit in `home-server-secrets`, a
private repository cloned beside this one.

## The repos

| Repo | Purpose |
|---|---|
| `home-server-core` | Host setup (Btrfs, users, snapshots, backup, firewall), Ignition, the test VM |
| `home-server-nextcloud` | Nextcloud pod, Ansible role, custom image build |
| `home-server-bunker` | BunkerWeb reverse proxy pod (WAF, TLS, ntfy site) and role |
| `home-server-monitoring` | Prometheus, Alertmanager, Grafana, Loki, Alloy, node-exporter, ntfy |
| `home-server-template` | Skeleton to copy for a new service |
| `home-server-deploy` | Inventory, the deploy and test scripts, the platform files, the secrets templates |
| `home-server-secrets` | The credentials and the SSH identities (**private**) |
| `image-builder-action` | Reusable GitHub Action that builds and signs images; a deploy does not need it |

Clone the repositories into one directory, with these names. `site.yml` finds
each service role at `../home-server-<repo>/ansible-role`. `deploy.sh` finds
the playbook at `../home-server-core` and the credentials at
`../home-server-secrets`. `SECRETS_DIR` overrides the second path.

```bash
git clone https://github.com/MArpogaus/home-server-core.git       home-server-core
git clone https://github.com/MArpogaus/home-server-nextcloud.git  home-server-nextcloud
git clone https://github.com/MArpogaus/home-server-bunker.git     home-server-bunker
git clone https://github.com/MArpogaus/home-server-monitoring.git home-server-monitoring
git clone https://github.com/MArpogaus/home-server-template.git   home-server-template
git clone https://github.com/MArpogaus/home-server-deploy.git     home-server-deploy
git clone <the private secrets repo>                              home-server-secrets
```

## Development

`CONTRIBUTING.md` in each `home-server-*` repository with code has the workflow:
branches, commits, hooks and action pinning.

Dependabot cannot read a container image tag out of an Ansible variable, so
Renovate does that. Each repository with a service role carries
`.github/renovate.json`, which extends
`home-server-core/.github/renovate-image-tags.json`. That preset reads each
`*_image` default and opens one pull request per version tag against `dev`. It
skips this project's own images, because the build workflow owns their major
version.

Three references move by hand:

- the SecureBlue signing key, `secureblue-2025.pub` in `platform/secureblue.bu`.
  The rebase follows the image's `latest` tag, so the image itself does not
  move by hand.
- the Fedora CoreOS release in `home-server-core/test/start_vm.py`
- the Nextcloud majors: `versions` in `home-server-nextcloud`'s
  `.github/workflows/build.yml` and the role default
  `nextcloud_service_app_image`

## Deploy

The controller needs what `home-server-core/README.md`, "Usage", lists
(Ansible Core, the collections, `passlib` and `bcrypt`) and, for the test VM,
what `home-server-core/test/README.md`, "Requirements", lists. The commands run
from `home-server-deploy/`:

```bash
cd home-server-deploy
cp ../home-server-secrets/ssh/coreos_key{,.pub} ../home-server-core/test/
# Terminal 1: the VM, on its serial console
python3 ../home-server-core/test/start_vm.py --fresh --platform platform/secureblue.bu
# Terminal 2, once the VM has rebased and rebooted
ssh -p 2222 -i ../home-server-core/test/coreos_key -o IdentitiesOnly=yes \
  core@127.0.0.1 systemctl is-active install-secureblue.service   # inactive
./deploy.sh
./functional_test.sh
```

The VM boots with the key in `home-server-core/test/`, and the scripts log in
with `ssh/coreos_key` of the secrets repository, so the two hold the same pair.
`start_vm.py` publishes the VM's ports on `127.0.0.1`. A controller in a
container reaches the host through another address: start the VM with
`--listen 0.0.0.0`, or with the host's LAN address, and run the scripts with
`TEST_VM=1 TARGET_HOST=<that address>`.

A new deployment creates its secrets repository from this repository's
templates. `start_vm.py` creates a key pair in `home-server-core/test/` when
none is there, and that pair goes to the secrets repository:

```bash
mkdir -p ../home-server-secrets/secrets ../home-server-secrets/ssh
cp secrets.example/vars.yml.example ../home-server-secrets/secrets/vars.yml
cp secrets.example/vars.host.yml.example ../home-server-secrets/secrets/vars.test.yml
# Fill in the values, then encrypt both files.
ansible-vault encrypt ../home-server-secrets/secrets/vars.yml ../home-server-secrets/secrets/vars.test.yml
cp ../home-server-core/test/coreos_key{,.pub} ../home-server-secrets/ssh/
```

`home-server-secrets/README.md`, "Vault", has the password file that
`ansible-vault` and the scripts read.

Each `secrets/` and `ssh/` path below is inside `home-server-secrets`.

| Variable | Default | Selects |
|---|---|---|
| `TARGET_HOST`, `TARGET_PORT` | `127.0.0.1`, `2222` | The address |
| `TARGET_NAME` | `test` | The host vars, `secrets/vars.<name>.yml`. A name, so a host keeps its settings when its address changes |
| `ANSIBLE_VAULT_PASSWORD_FILE` | `~/.config/home-server/vault-password` | The Vault password; `home-server-secrets/README.md`, "Vault" |
| `SSH_KEY_FILE` | `ssh/coreos_key` | The key file |
| `SSH_AUTH_KEY` | `file` | `agent` uses the SSH agent. The t630 accepts the YubiKey only |
| `SERVICES` | every service user on the host | The per-user checks |
| `SERVER_NAME` | from the secrets | The hostname the HTTPS checks use |
| `BACKUP_TARGET` | none | A configured backup target that the test runs a real backup against |
| `TEST_VM` | none | `1` marks a target at another address, such as the host's LAN IP, as the test VM |

A target on loopback or link-local, or one run with `TEST_VM=1`, is the test VM.
It gets a new host key on every `--fresh`, so the scripts do not check its key.
Every other target is checked against `ssh/known_hosts`, and the scripts refuse
to start without a record. An unchecked key lets a device that wins an ARP race
receive every secret as extra-vars. Record the key once, from a session you
trust, and compare the fingerprint with the console:
`ssh-keyscan -H -p <port> <host> 2>/dev/null >> ssh/known_hosts`.

`deploy.sh` checks the secrets, the Vault password, the SSH identity and that
Ansible's Python has `passlib` and `bcrypt`, which the ntfy user hash needs
(`uv tool install --reinstall ansible --with passlib --with bcrypt`). It
installs the collections and removes group and other access from
`home-server-secrets`. It runs the playbook from `home-server-core/`, where
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

## Variables

| Variable | Required | Default | Controls |
|---|---|---|---|
| `nextcloud_service_db_password` | yes | | PostgreSQL |
| `nextcloud_service_admin_password` | yes | | Nextcloud admin |
| `nextcloud_service_app_image` | no | `ghcr.io/marpogaus/nextcloud:35` | App image |
| `nextcloud_service_trusted_domains` | no | `cloud.example.com` | Trusted domains, separated by spaces; the first is the public URL |
| `nextcloud_service_url` | no | `https://<first trusted domain>` | The URL notify_push uses to reach Nextcloud |
| `bunker_service_server_name` | yes | | Public hostname |
| `bunker_service_letsencrypt_email` | no | `""` | ACME contact; empty registers `contact@<server name>` |
| `bunker_service_generate_self_signed_ssl` | no | `no` | `yes` only for a host without public DNS |
| `bunker_service_auto_lets_encrypt` | no | `yes` | `no` together with the self-signed certificate; the role refuses both set to `yes` |
| `bunker_service_ntfy_server_name` | no | `""` | The ntfy site, with its own DNS record |
| `monitoring_service_ntfy_password` / `_token` | yes | | The phone's password for user `ntfy`; the token Alertmanager and `deploy.sh` publish with (`tk_` + 29 lowercase alphanumerics) |
| `monitoring_service_ntfy_base_url` | no | loopback | `https://` and the ntfy hostname |
| `monitoring_service_grafana_admin_password` | yes | | Grafana `admin`; the role refuses to run without it |
| `monitoring_service_probe_urls` | on a real host | `[]` | `https://` URLs probed every minute; empty means no public-path alerting |
| `base_setup_backup_targets` | no | `[]` | Encrypted Btrfs backup targets, by LUKS UUID |
| `base_setup_luks_passphrase` | with targets | | One passphrase for every target; keep a copy off the box |
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
database role, and a person types the admin password on a phone.

### The VM and the real host

`vars.yml` holds what both hosts share, including the public hostnames.
`vars.test.yml` and `vars.t630.yml` override it; read them for what differs.

A restore of a copy from another host is the risk. The dump creates the roles
that it names again. Thus the database credentials here must agree with the
source host.

## Backup targets

Each target is a LUKS2 container that holds Btrfs. This applies to a USB disk
and to an iSCSI LUN on the NAS. `btrfs send` needs a block device. A file
share holds no ownership and no xattrs. SecureBlue also blocks NFS and SMB at
module level. Nested subvolumes are the exclude list. A snapshot does not go
into a nested subvolume. Thus `data/custom_apps` (app code, Recognize models)
never enters a snapshot or a backup.

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

The script reads the sender UUID from `btrfs subvolume show` to decide if a
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
| Btrfs snapshot, nightly per service | `/var/services/<service>`, including the database dump | `data/custom_apps`, a nested subvolume, deliberately: app code and the Recognize models are gigabytes and are re-downloaded |
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

### Installing the real host

`home-server-core/ignition/` holds one Butane template for the test VM and the
real hardware. It sets up the Btrfs root, the SSH key, the cosign public key,
the polkit rule that lets `run0` escalate without a password, and a first-boot
unit that layers python3 when the image has none.
`--platform ../../home-server-deploy/platform/secureblue.bu` adds the unit that
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
   cd home-server-core/ignition
   podman run --rm -v "$PWD":/data:z -w /data \
     quay.io/coreos/coreos-installer:release download -s stable -p metal -f iso
   P=../../home-server-deploy/platform/secureblue.bu
   ./build.sh --platform $P ign         # render config.ign only; read it
   ./build.sh --platform $P iso fedora-coreos-<version>-live.x86_64.iso /dev/sda
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
5. Record the host key (see "Deploy"), put the host's values in
   `secrets/vars.<name>.yml`, and deploy an empty host:

   ```bash
   TARGET_HOST=<address> TARGET_PORT=22 TARGET_NAME=t630 SSH_AUTH_KEY=agent ./deploy.sh
   TARGET_HOST=<address> TARGET_PORT=22 TARGET_NAME=t630 SSH_AUTH_KEY=agent ./functional_test.sh
   ```

   Get 0 failed before you restore data.
6. Before you trust the host with data, do the checks the functional test
   cannot do: restore a dump into a scratch database and read a table, reboot
   and check that each container starts again, read a file back from a backup
   target, disconnect a target and start the sync (it must fail clearly), and
   stop a container and wait for the ntfy alert.

The t630 boots in legacy BIOS mode. A change to UEFI needs no new
installation, because the ESP holds the files and bootupd keeps them current.

### Adding a backup target

**A LUN on the NAS.** Create and export the LUN on the NAS, with no filesystem
on it. Permit this host's initiator name,
`iqn.2026-01.local.homeserver:<inventory_hostname>` unless
`base_setup_iscsi_initiator` overrides it. The LUN number must be 0, or
`base_setup_iscsi_lun` must match it. Then set in the host vars:

```yaml
base_setup_iscsi_portal: <nas address>
base_setup_iscsi_target: iqn.<vendor>:<target>
base_setup_luks_passphrase: "<passphrase>"
```

SecureBlue's policy stops iscsid from creating its netlink socket, so the host
task file must make `iscsid_t` permissive
(`home-server-secrets/tasks/t630-pre.yml`). The deploy logs in to the target.
Format the LUN once by hand, with `D=/dev/disk/by-path/<by-path name>`:

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
  sender UUID is set.
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
shows a running system with `Link detected: yes`. On the t630 that is Energy
Efficient Ethernet on the Realtek NIC: `ethtool --show-eee enp1s0` shows
`EEE status: enabled - active`. The host task file turns EEE off when the
interface comes up. `run0 journalctl -b -1 | tail` shows how the previous boot
ended.

**A deploy waits a long time.** The Nextcloud install and the monitoring
readiness waits cover a cold image pull and a major upgrade, which each take
more than ten minutes on the t630. Read the container's journal instead of
waiting.

## Test VM

`home-server-core/test/README.md` has the commands. Deploy the playbook against
the VM from `home-server-deploy/`. Test each change on the VM before it goes to
the real host. The two hosts run the same code. They differ only in
`secrets/vars.<name>.yml`.

## Interfaces

| What | Where |
|---|---|
| Nextcloud | `https://<bunker_service_server_name>` |
| ntfy | `https://<bunker_service_ntfy_server_name>`, user `ntfy` + `monitoring_service_ntfy_password`, topic `alerts` |
| Grafana | `ssh -L 3000:127.0.0.2:3000 core@host`, then http://localhost:3000, `admin` + `monitoring_service_grafana_admin_password` |
| Nextcloud direct (BunkerWeb upstream) | `127.0.0.1:8080` on the host, loopback only |

## License

MIT
