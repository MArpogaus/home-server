# home-server

This repository deploys a home server on Fedora CoreOS with rootless Podman.
It holds the host roles, the playbook, the inventory, the deploy and test
scripts, the Ignition config and the test VM. Each service is a repository of
its own, pinned as a submodule under `services/<name>`, so one commit here
names every service version it deploys.

| Repository | Where | Purpose |
|---|---|---|
| `home-server` | this one | Host setup, playbook, Ignition, test VM, scripts |
| `home-server-nextcloud` | `services/nextcloud` | Nextcloud pod, role and custom image |
| `home-server-bunker` | `services/bunker` | BunkerWeb reverse proxy (WAF, TLS) |
| `home-server-monitoring` | `services/monitoring` | Metrics, logs, dashboards, alerts to ntfy |
| `home-server-secrets` | `../home-server-secrets` | Credentials, SSH host keys, host settings and tasks (**private**) |
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
  `host_tasks_pre` before `base_setup`.
- **Service users and rootless Quadlets.** For each entry in
  `base_setup_services`, `base_setup` makes a system user, a Btrfs subvolume
  under `/var/services` and a subuid range from
  `uid * base_setup_subuid_range_size + 100000`. `site.yml` then runs the
  service role from `services/<name>/ansible-role`, which calls
  `quadlet_service`. Services reach each other through host-published ports.
- **Snapshots and backup targets.** `btrfs-snapshot@<service>.timer` takes a
  read-only snapshot each night. The finished snapshot starts
  `btrfs-backup@<target>.service`, an incremental `btrfs send` to each target.
  A target is a LUKS2 container with Btrfs (USB disk or iSCSI LUN), found by
  UUID, opened with `nofail` and automounted at `/var/backup/<name>`. A nested
  subvolume is not in a snapshot.
- **Updates and auto-reboot.** `podman-auto-update.timer` runs per user. When
  rpm-ostree has staged a deployment, `auto-reboot-staged.service` reboots
  after the last backup, or at 03:00.
- **Monitoring.** A snapshot or backup that succeeds writes
  `/var/lib/node-textfile/*.prom`. `monitoring/` holds this repository's
  rules, which `home-server-monitoring` collects.

## Deploy

The controller needs Ansible Core 2.21 or newer. `secrets.example/` holds the
templates for the secrets repository.

```bash
uv tool install --reinstall ansible --with passlib --with bcrypt
mkdir -p -m 700 ~/.config/home-server
(umask 077; openssl rand -base64 48 > ~/.config/home-server/vault-password)
echo 'export ANSIBLE_VAULT_PASSWORD_FILE=~/.config/home-server/vault-password' >> ~/.bashrc

S=../home-server-secrets                   # a new secrets repository
mkdir -p $S/secrets $S/ssh && git -C $S init -q
cp secrets.example/vars.yml.example $S/secrets/vars.yml
cp secrets.example/vars.host.yml.example $S/secrets/vars.test.yml
echo 'secrets/vars*.yml diff=ansible-vault' > $S/.gitattributes
# fill in the values, then:
ansible-vault encrypt $S/secrets/vars.yml $S/secrets/vars.test.yml
```

### Test VM

The VM needs `qemu-system-x86_64` with `/dev/kvm`, `qemu-img`, `unxz`,
`ssh-keygen` and `podman`. It has 8 GB and 2 vCPUs, and publishes SSH, HTTP
and HTTPS on `127.0.0.1:2222`, `:8080` and `:8443`.

```bash
python3 test/start_vm.py --fresh --platform platform/secureblue.bu   # terminal 1
./deploy.sh && ./functional_test.sh                                  # terminal 2, after the rebase
python3 test/start_vm.py --save-base   # VM shut down: keep this disk as "base"
python3 test/start_vm.py --restore     # back to "base"
```

`--fresh` deletes the disk and its `base` snapshot. For a controller in a
container, start the VM with `--listen <address>` and run the scripts with
`TEST_VM=1 TARGET_HOST=<address>`.

### Real host

Point the DNS names at the host and forward only 80 and 443; Let's Encrypt
needs 80. Copy `secrets.example/vars.host.yml.example` to
`../home-server-secrets/secrets/vars.<host>.yml`, drop its self-signed and
`-dev` lines, fill it in and encrypt it with `ansible-vault encrypt`.

```bash
cd ignition
INSTALLER=$(sed -n 's/^INSTALLER_IMAGE="\(.*\)"$/\1/p' build.sh)
podman run --rm -v "$PWD":/data:z -w /data "$INSTALLER" download -s stable -p metal -f iso
./build.sh --platform ../platform/secureblue.bu ign    # render config.ign; read it
./build.sh --platform ../platform/secureblue.bu iso fedora-coreos-<version>-live-iso.x86_64.iso \
  /dev/disk/by-id/<target disk>                        # install.iso erases that disk, no prompt
cd ..
ssh-keyscan -H <host> 2>/dev/null >> ../home-server-secrets/ssh/known_hosts
TARGET_HOST=<address> TARGET_PORT=22 TARGET_NAME=<host> SSH_AUTH_KEY=agent ./deploy.sh
TARGET_HOST=<address> TARGET_PORT=22 TARGET_NAME=<host> SSH_AUTH_KEY=agent ./functional_test.sh
```

## Configuration

`secrets/vars.yml` holds what every host shares, and `secrets/vars.<name>.yml`
one host's credentials and overrides. The role defaults files are the full
reference.

| Variable | Required | Controls |
|---|---|---|
| `base_setup_services` | yes | The services, in `inventory/group_vars/homeserver.yml` |
| `nextcloud_hostname` | yes | Nextcloud's public hostname |
| `ntfy_hostname` | no | ntfy's public hostname; empty means no ntfy site |
| `nextcloud_service_db_password`, `nextcloud_service_admin_password` | yes | Nextcloud credentials |
| `monitoring_service_ntfy_password` / `_token` | yes | The phone's ntfy login; the token that Alertmanager and `deploy.sh` use |
| `monitoring_service_grafana_admin_password` | yes | Grafana `admin` |
| `monitoring_service_probe_urls` | on a real host | Public URLs probed every minute |
| `bunker_service_generate_self_signed_ssl`, `bunker_service_auto_lets_encrypt` | without public DNS | Self-signed certificate instead of Let's Encrypt |
| `base_setup_backup_targets` | no | `uuid` and `name` of each target; `[]` means no off-box backup. A removed target keeps its `backup-<name>.prom`, so `JobStale` fires until you delete it |
| `base_setup_luks_passphrase` | with a target | One passphrase for every target; keep a copy off the host |
| `base_setup_iscsi_portal`, `base_setup_iscsi_target` | no | An iSCSI LUN; the deploy logs in to it |
| `host_tasks_pre` | no | A task file that runs before `base_setup` |

Machine secrets are 48 alphanumerics, so no file format needs quotes:
`openssl rand -base64 48 | tr -d '/+=' | cut -c1-48`. The ntfy token:
`echo "tk_$(openssl rand -hex 15 | cut -c1-29)"`.

| Script variable | Default | Selects |
|---|---|---|
| `TARGET_HOST`, `TARGET_PORT` | `127.0.0.1`, `2222` | The address |
| `TARGET_NAME` | `test` | `secrets/vars.<name>.yml` |
| `SECRETS_DIR` | `../home-server-secrets` | The secrets repository |
| `SSH_KEY_FILE`, `SSH_AUTH_KEY` | `test/coreos_key`, `file` | The identity; `agent` uses the SSH agent |
| `TEST_VM` | none | `1` marks another address as the test VM |
| `SERVICES` | the host's `/etc/subuid` | The functional test's service users |
| `SERVER_NAME` | `nextcloud_hostname` | The hostname the functional test calls |
| `BACKUP_TARGET` | none | A target for a real backup in the functional test |

## Adding a service

1. Copy `home-server-template` as its `README.md` says, and add the new
   repository: `git submodule add <its URL> services/<name>`.
2. Add `name` and `uid` to `base_setup_services` in
   `inventory/group_vars/homeserver.yml`. The `uid` never changes after the
   first deploy, because it sets the subuid range that owns the service's files.
3. For a public service, add a `<name>_site` to `bunker_service_sites`, a DNS
   record and a probe URL. Then deploy.

A service publishes on a loopback port that no other service uses:

| Address | Service |
|---|---|
| `:80`, `:443` on every address | bunker |
| `127.0.0.1:8080` | Nextcloud |
| `127.0.0.1:8081` | ntfy |
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
- **Container output goes through `passthrough`.** conmon's journald driver
  files every stderr line as `err`. With `LogDriver=passthrough` the unit's
  priority applies.
- **Updates are unattended.** Digest pinning and auto-update exclude each
  other, and this project chose auto-update. The reboot uses
  `--check-inhibitors=yes`, so it never interrupts a backup or a dump.
- **Secrets go in as extra-vars.** They have the highest precedence, so no
  inventory value can shadow one.

## Security

Threat model: a single-user server on a home LAN, reachable from the internet
only through BunkerWeb on 80 and 443. Physical theft is out of scope.

Covered:

- SSH accepts only the hardware-backed key, and no root login. The admin user
  may forward local ports only, because Grafana is reachable only through a
  tunnel.
- Every container drops all capabilities and sets `no-new-privileges` and a
  pids limit.
- `policy.json` rejects every image that no service role declares
  (`home-server-template/README.md`, "Role contract").
- The scripts check a real host against `ssh/known_hosts`. Only a loopback,
  link-local or `TEST_VM=1` target named `test` skips the check.
- Credentials in the secrets repository are Vault-encrypted. Keep a copy of
  the Vault password in a password manager: it also guards the LUKS passphrase.

Known gaps:

- The polkit rule from Ignition gives `core` unauthenticated root, so the SSH
  key is the whole perimeter.
- `ip_unprivileged_port_start=80` lets any local user bind 80 and 443 while
  the proxy is down.
- Unattended updates reach production with no gate. Images outside
  `ghcr.io/marpogaus` pull without a signature.
- The test VM is root for anyone with `test/coreos_key`, which has no
  passphrase. `test/start_vm.py` creates it when it is missing.
- Without CHAP, the NAS admits any LAN device with this host's initiator name.
  LUKS stops it from reading the backups, not from overwriting them.
- No script restores a backup, and no `btrfs scrub` runs on a schedule.

SELinux exceptions:

- `platform/secureblue.yml` runs `ujust set-container-userns on`, because
  SecureBlue's `harden_container_userns` blocks rootless Podman.
- iscsid needs a permissive `iscsid_t`, which the host task file sets. A
  constraint, not an allow rule, stops its netlink socket.

## Alerts

| Alert | Severity | Fires when |
|---|---|---|
| `JobStale` | critical | A snapshot, backup or dump (a `*_last_success` textfile metric) has not succeeded for 30 hours |
| `BackupTargetLow` | warning | A backup target has less than 10 % free space |
| `ScheduledJobFailed` | warning | A snapshot or backup unit failed in the last 6 hours |
| `AutoRebootBlocked` | warning | The staged-update reboot was refused twice in 50 hours |
| `SshLogin` | info | An SSH key login succeeded |
| `SshLoginFailed` | warning | More than 5 failed SSH logins in 15 minutes |
| `SelinuxDenials` | warning | More than 20 enforced SELinux denials in 15 minutes |

## LLM coding tools

This project is developed with LLM-based coding tools. They write most of the
code and documentation. The maintainer sets the goals and the design, reviews
every change and is responsible for it. Changes are tested on a VM before they
reach a host.

## License

MIT
