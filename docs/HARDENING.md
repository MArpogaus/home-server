# Hardening status

What this deployment's hardening covers, what it deliberately does not, and
which SELinux exceptions it makes.

Threat model: a single-user home server on a home LAN, reachable from the
internet only through BunkerWeb on 80/443. Three threats are realistic. A
compromised container escapes to its neighbours. A LAN device reaches a service
that belongs behind the WAF. An unattended update breaks a service. Physical
theft and nation-state adversaries are out of scope.

Done:

- Nextcloud's database and admin passwords are Podman secrets, not
  environment variables. They are absent from `podman inspect` and
  `/proc/<pid>/environ`. Grafana's and ntfy's credentials are environment
  variables, from files the role keeps at `0600`. They are visible to anyone
  who can already run `podman` as that service user. The ntfy token is also in
  Alertmanager's config (`home-server-monitoring/README.md`, "File modes").
- Every container a Quadlet declares drops all capabilities, sets
  `no-new-privileges` and a pids limit. A pod's infra container keeps Podman's
  default set, because a Quadlet has no key for it.
  Seven capabilities are added back, and no others. `SETUID` and `SETGID`
  on every Nextcloud container, to switch to `www-data`. `CHOWN` on the app,
  database, redis and web containers, whose entrypoints take ownership of a
  mount they did not create. `DAC_OVERRIDE` and `FOWNER` on the app and the
  database, which chown a tree they do not own. `KILL` on the app, because
  php-fpm signals its workers. `NET_BIND_SERVICE` on web. Every other container
  runs with an empty set. `DAC_OVERRIDE` is the strongest of these. In the
  app container it lets the php-fpm master read and write every mounted file
  whatever its mode. A worker has already dropped it by then. See
  `quadlets/*.container.j2`.
- `nextcloud-app` gets `Tmpfs=/tmp:exec`, which is a real exception: `/tmp` is
  writable and executable in the container that terminates user uploads. The
  image's own tooling runs helpers from there. The tmpfs is capped at 512M and
  counts against the container's memory ceiling.
- `monitoring-node-exporter` mounts `/` read-only at `/rootfs`, which the
  filesystem collector needs to resolve mount points. It is bounded by what the
  `monitoring` user can read. Podman labels each bind mount that carries
  `z` or `Z`, so the `0750` home mode separates the services, and not SELinux.
- The blackbox exporter probes the URLs in `monitoring_service_probe_urls`
  every minute. `PublicUrlDown` and `CertificateExpiresSoon` fire when DNS,
  TLS, the WAF or the backend break. The list is empty by default. An empty
  list means no public-path coverage, so every real host sets it.
- `ip_unprivileged_port_start=80` lets any unprivileged local user bind 80
  and 443, not just the proxy. The proxy holds both permanently, so the window
  is a reboot. The alternative is `CAP_NET_BIND_SERVICE` on the proxy pod.
- Nextcloud publishes 8080 on loopback only. The proxy reaches it through
  pasta's host-loopback mapping. firewalld refuses the port from the LAN
  anyway, so this is defence in depth.
- SSH accepts the hardware-backed key and no password. Root login is off.
  securecore sets `AllowTcpForwarding no`. `platform/secureblue.yml` gives the
  admin user `local` forwarding back and nothing else, because Grafana is
  reachable only through a tunnel.
- Alerts for container failure, failed backups, host resources and security
  events, delivered to a phone through ntfy. The alert tables in the READMEs of
  `home-server`, `home-server-monitoring`, `home-server-nextcloud` and
  `home-server-bunker` list them.
- Every file in the secrets repository's `secrets/` that holds a credential is
  encrypted with Ansible Vault (AES256). The vault password is a file outside
  the repository, `~/.config/home-server/vault-password`. Keep a copy in a
  password manager: without it the LUKS passphrase is gone, and with it every
  backup.

Rejected or deliberately not done:

- Btrfs quotas. qgroups cost CPU and memory, and the disk-space alert covers
  the need.
- A non-root in-container user for every image. Nextcloud's entrypoint needs
  root to rsync and chown. The rest gains little once capabilities are dropped
  and `no-new-privileges` is set.
- IP-level banning at the firewall. BunkerWeb rate-limits and bans bad
  behaviour itself.

Open:

- No script restores a backup. The functional test proves that the dump is
  complete, and a restore stays a manual check
  (`home-server-nextcloud/README.md`, "Operations").
- Upstream images are pulled on trust, one repository at a time. `policy.json`
  is securecore's reject-by-default file, plus the repositories the service
  roles declare in their `*_image` defaults, plus every `*_image` variable a
  host sets for itself. This project's own GHCR images are
  verified by signature. An image from anywhere else does not pull. A scope
  matches by prefix, so `base_setup` refuses any value that is not
  registry/namespace/name. A service repository therefore writes part of the
  host's policy. An image added there is accepted without a signature, so the
  review that matters happens in that repository.
- Unattended updates reach production with no gate.
- The test VM is root for anyone who holds its key: `ssh/coreos_key` has no
  passphrase, and `core` escalates without one. The VM gets the credentials
  of `secrets/vars.test.yml`, which no other host accepts. A VM disk keeps
  the values of every deploy it received, so a disk that received another
  host's values is deleted. `start_vm.py` publishes its ports on `127.0.0.1`
  (`README.md`, "A controller in a container", says what `--listen` opens).
- Without CHAP, the NAS admits any device on the
  LAN that claims this host's initiator name. LUKS keeps such a device from
  reading the backups, not from overwriting them.
- A service repository's `monitoring/alloy-drop.txt` drops lines of that
  service before Loki stores them, and `alloy-redact.txt` rewrites them. A
  pattern that matches text a client controls hides that client's lines, so
  each pattern is anchored to a field the service writes itself.
- Git history, unreferenced GitHub objects and other clones can hold
  plaintext credentials. Every value that was ever plaintext is rotated. A
  LUKS header backup accepts every passphrase its key slots held when it was
  taken.

SELinux exceptions this project makes, and why:

- **Alloy watches the journal directory.** `container_logreader_t` may read
  the journal but not watch it, and Alloy then stops receiving new lines. The
  monitoring role loads `alloy_journal_watch.cil`, which allows `watch` on
  `var_log_t` directories and nothing else.
- **Container domains create user namespaces.** SecureBlue's module
  `harden_container_userns` denies it, and rootless Podman then fails every
  command with `cannot clone: Permission denied`. `platform/secureblue.yml` runs
  `ujust set-container-userns on`. Rootless Podman is the whole architecture,
  so this is not optional. Containers stay confined by every other rule.
- **iSCSI needs a permissive `iscsid_t`.** SecureBlue's policy stops iscsid
  from creating its netlink socket through a constraint, which an allow rule
  cannot lift.
- **pasta** logs four `dac_override` / `dac_read_search` denials in
  `cap_userns` at every pod start. They are capability probes, nothing fails,
  and the alert rule ignores them.
- **Alloy runs as `container_logreader_t`.** container-selinux ships that type
  for a container that reads the host logs, and `/var/log/journal` is
  `var_log_t`, which it can read (`home-server-monitoring/README.md`,
  "Architecture", says why the directory keeps its label).

firewalld's default zone keeps `forward: yes`, which is intra-zone forwarding.
The host has one interface and the pods use pasta in user space, so nothing is
forwarded. It stays as shipped. A firewall change here can turn a `--reload`
into a lost SSH session.
