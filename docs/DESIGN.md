# Design notes

Why this repository's roles are shaped as they are. The READMEs say how to use
them. The hardening status of a deployment is not here: it describes one host,
so it lives with that host's private configuration.

## Why it is built this way

**Fedora CoreOS.** An immutable rpm-ostree base makes the host reproducible
from the Ignition config alone, and a bad update rolls back. All privileged
automation goes through `run0` and one polkit rule. `run0` is part of systemd,
so it works on stock Fedora CoreOS and on a derivative that removes `sudo`.

**Memory ceilings are ceilings, not reservations.** Everything is sized for
8 GB. The `Memory=` keys across the pods add up to more than the host has. They
stop one container taking the machine down, and zram and the `OomKill` alert
cover the peaks. Lower a ceiling before you add a service, not after.

**Btrfs, one subvolume per service.** Snapshots are per service and cheap, so
a bad deploy of one service rolls back without touching the others. No
quotas: qgroups cost real CPU and memory on a thin client, and the disk-space
alert covers the need.

**Podman Quadlet, one rootless user per service.** systemd owns the lifecycle:
restart policy, ordering and journald. A compromise of one service does not
reach another's files. The price is that each user has its own container
network. `home-server-template/CONTRIBUTING.md` has the rules a new service
follows.

**One role deploys every service's Quadlets.** `quadlet_service` renders the
`.j2` files on the controller. It packs them with the static files into one
archive with fixed mtimes. It ships and unpacks that archive in one task. It
removes what left the repo, which is config files, units and drop-in
directories. It restarts the pod only after a change. Every container gets the
role's `container.d/` drop-ins (capabilities dropped, no new privileges, a pids
limit, auto-update, restart on failure), and a service's own drop-in of the same
name replaces one. `quadlet_service_extra_files` adds files from elsewhere on
the controller (`src`) or generated content (`content`), which is how monitoring
ships every repository's rules and dashboards. The archive matters because one
Ansible task per file costs seconds on the thin client, and a Quadlet tree holds
dozens of files. A service role holds only what is specific to that service, so
a fix lands in one place.

**Container output goes through `passthrough`.** conmon's journald driver files
every stderr line as `err`, which makes `journalctl -p err` useless. With
`LogDriver=passthrough` (a `container.d/log.conf` drop-in per pod) the unit's
stream priority applies and lines land as `info`. The cost is that a program
cannot open its log by path. Each pod therefore has to say how it logs.
`home-server-template/CONTRIBUTING.md` has the rule, and each service README has
its own answer. Quadlet also stops a pod with `podman pod stop --time=10`,
whatever a container's `StopTimeout` says.

**Updates are unattended.** `AutoUpdate=registry` runs per user. The host
reboots when rpm-ostree has staged a deployment, right after the night's backup
finished (`OnSuccess=` on the backup unit), or at 03:00 as the fallback. It
never reboots while a sync or a dump runs:
`systemctl reboot --check-inhibitors=yes` asks logind, and the backup and the
dump hold a shutdown inhibitor. The reboot unit is ordered after every backup
unit, so with several targets the first finished sync queues the reboot and the
last one releases it. A refused reboot fails the unit, which happens when the
03:00 fallback meets a running sync. `AutoRebootBlocked` reports it once it
repeats. Every long oneshot job carries a `TimeoutStartSec=`, so a
hung job fails and releases its inhibitor. Only the project's own GHCR images
are signature-verified, and Docker Hub images are pulled on trust. Digest
pinning and auto-update exclude each other, and this project chose auto-update.
