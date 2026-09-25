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
| `home-server-monitoring` | `services/monitoring` | Metrics, logs, dashboards, alerts to ntfy |
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
  `host_tasks_pre` before `base_setup`. The host is named after its inventory
  entry.
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

The controller needs Ansible Core 2.21 or newer with passlib and bcrypt. Run
every command from this repository: `ansible.cfg` names this inventory, the
secrets repository's inventory after it, and the Vault password file.
`secrets.example/` holds the templates for the secrets repository.

```bash
uv tool install --reinstall ansible --with passlib --with bcrypt
ansible-galaxy collection install -r requirements.yml   # again after requirements.yml changes
mkdir -p -m 700 ~/.config/home-server
(umask 077; openssl rand -base64 48 > ~/.config/home-server/vault-password)

S=../home-server-secrets                   # a new secrets repository
git init -q $S && cp -r secrets.example/. $S/ && mkdir -p $S/ssh
printf 'group_vars/*.yml diff=ansible-vault\nhost_vars/*.yml diff=ansible-vault\n' > $S/.gitattributes
# fill in the values, then:
ansible-vault encrypt $S/group_vars/homeserver.yml $S/host_vars/test.yml
```

Every playbook run takes `-l <host>`: `site.yml` refuses a run without it.

### Test VM

The VM needs `qemu-system-x86_64` with `/dev/kvm`, `qemu-img`, `unxz`,
`ssh-keygen` and `podman`. It has 8 GB and 2 vCPUs, and publishes SSH, HTTP
and HTTPS on `127.0.0.1:2222`, `:8080` and `:8443`.

```bash
python3 test/start_vm.py --fresh --platform platform/secureblue.bu   # terminal 1
ansible-playbook site.yml -l test && ./functional_test.sh test       # terminal 2, after the rebase
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
host uses the agent.

```bash
cd ignition
podman run --rm --security-opt label=disable -v "$PWD":/data -w /data \
  quay.io/coreos/coreos-installer:release download -s stable -p metal -f iso
./build.sh --platform ../platform/secureblue.bu ign    # render config.ign; read it
./build.sh --platform ../platform/secureblue.bu iso fedora-coreos-<version>-live-iso.x86_64.iso \
  /dev/disk/by-id/<target disk>                        # install.iso erases that disk, no prompt
cd ..
ssh-keyscan -H <host> 2>/dev/null >> ../home-server-secrets/ssh/known_hosts
ansible-playbook site.yml -l <host>
./functional_test.sh <host>
```

## Configuration

In the secrets repository, `group_vars/homeserver.yml` holds what every host
shares, and `host_vars/<host>.yml` one host's credentials and overrides. The
role defaults files are the full reference.

| Variable | Required | Controls |
|---|---|---|
| `base_setup_services` | yes | The services, in `inventory/group_vars/homeserver.yml` |
| `nextcloud_hostname` | yes | Nextcloud's public hostname |
| `ntfy_hostname` | no | ntfy's public hostname; empty means no ntfy site |
| Nextcloud passwords | yes | `home-server-nextcloud/README.md`, "Configuration" |
| Monitoring credentials | yes | `home-server-monitoring/README.md`, "Configuration". `functional_test.sh` reads the ntfy token and the Grafana password through the inventory |
| `monitoring_service_probe_urls` | on a real host | Public URLs that blackbox probes |
| `bunker_service_generate_self_signed_ssl`, `bunker_service_auto_lets_encrypt` | without public DNS | Self-signed certificate instead of Let's Encrypt |
| `base_setup_backup_targets` | no | `uuid` and `name` of each target; `[]` means no off-box backup. A removed target keeps its `backup-<name>.prom`, so `JobStale` fires until you delete it |
| `base_setup_luks_passphrase` | with a target | One passphrase for every target; keep a copy off the host |
| `base_setup_iscsi_portal`, `base_setup_iscsi_target` | no | An iSCSI LUN; the deploy logs in to it |
| `host_tasks_pre` | no | A task file that runs before `base_setup` |

Machine secrets are 48 alphanumerics, so no file format needs quotes:
`openssl rand -base64 48 | tr -d '/+=' | cut -c1-48`. The ntfy token:
`echo "tk_$(openssl rand -hex 15 | cut -c1-29)"`.

`functional_test.sh <host>` passes further arguments to `ansible`, such as
`-e ansible_host=<address>`. `BACKUP_TARGET=<name>` also runs a real backup to
that target.

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
- **Container output goes through `passthrough` where it can.** conmon's
  journald driver files every stderr line as `err`. With
  `LogDriver=passthrough` the unit's priority applies. Each service sets it in
  its own `container.d/`; bunker cannot and keeps journald.
- **Updates are unattended.** Digest pinning and auto-update exclude each
  other, and this project chose auto-update. The reboot uses
  `--check-inhibitors=yes`, so it never interrupts a backup or a dump.
- **The secrets repository is a second inventory.** `ansible.cfg` lists it
  after this one, so its `group_vars/` and `host_vars/` win over this
  repository's, and Ansible decrypts them by itself.

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
- SSH checks a real host against `ssh/known_hosts` of the secrets repository.
  Only the inventory entry `test` skips the check.
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
- A compromised ntfy reaches Loki and Alertmanager
  (`home-server-monitoring/README.md`, "Specifics").

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
