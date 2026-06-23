# deployment-private

Private configurations and secrets for SecureBlue deployment.

**WARNING: This repository MUST remain PRIVATE.**

Contains: SSH keys, database passwords, GHCR authentication, domain configs.

## Structure

```
deployment-private/
  secrets/
    vars.yml              # All config vars (gitignored)
    vars.yml.example      # Template for new deployments
  inventory/
    hosts.ini             # Target host connection details (gitignored)
  ssh/
    coreos_key            # SSH key for VM access (gitignored)
    coreos_key.pub
  deploy.sh               # Entry point: validate → ansible-playbook
  functional_test.sh      # Post-deployment validation suite
  reset.sh                # Nuclear teardown of all deployment artifacts
```

## Deployment Flow

```
./deploy.sh [deploy|validate]
  ├── validate_secrets()     — checks vars.yml, hosts.ini, coreos_key exist
  ├── deploy_ansible()       — runs ansible-playbook from ansible-base repo
  │     └── ansible-playbook -i deployment-private/inventory/hosts.ini \
  │           --extra-vars @secrets/vars.yml site.yml -v
  └── validate_deployment()  — SSHes into VM, checks subvols, pods, timers
```

## What File Does What

| File | Purpose |
|---|---|
| `secrets/vars.yml` | **Everything you change per deployment**: domains, passwords, UIDs, image tags, PHP tuning, rate limits |
| `inventory/hosts.ini` | Target host: `ansible_host`, `ansible_port` (default 2222), `ansible_user` (default `core`) |
| `ssh/coreos_key` | SSH private key (regenerate with `ssh-keygen -t ed25519 -f ssh/coreos_key -N ""`) |
| `deploy.sh` | Orchestrator: validates, runs Ansible, reports result |
| `functional_test.sh` | 133-line shell test: checks firewall, Btrfs, users, subuid, containers, HTTP reachability, Grafana, Prometheus |
| `reset.sh` | Removes everything Ansible created: subvolumes, users, subuid/subgid, SELinux contexts, timers |

## Setup

```bash
git clone git@github.com:your-username/deployment-private.git
cd deployment-private

# Configure secrets
cp secrets/vars.yml.example secrets/vars.yml
# Edit vars.yml with your values

# Generate SSH key
ssh-keygen -t ed25519 -f ssh/coreos_key -N ""
chmod 600 ssh/coreos_key

# The public key must be baked into the FCOS Ignition config (config.bu)
```

**Prerequisite:** The target VM must already be running and reachable.

## Required Variables (in secrets/vars.yml)

| Variable | Required | Default | Controls |
|---|---|---|---|
| `nextcloud_uid` | No | 82 | System UID for nextcloud user |
| `proxy_uid` | No | 1001 | System UID for proxy user |
| `monitoring_uid` | No | 1002 | System UID for monitoring user |
| `nextcloud_image` | **Yes** | — | Container image tag for Nextcloud |
| `nextcloud_db_password` | **Yes** | — | PostgreSQL user password |
| `nextcloud_db_root_password` | **Yes** | — | PostgreSQL superuser password |
| `nextcloud_admin_user` | No | admin | Nextcloud admin username |
| `nextcloud_admin_password` | **Yes** | — | Nextcloud admin password |
| `nextcloud_trusted_domains` | No | cloud.example.com | Trusted Nextcloud domains |
| `nextcloud_url` | No | — | Override URL for Nextcloud |
| `bunker_server_name` | **Yes** | — | Public domain for Bunkerweb |
| `bunker_letsencrypt_email` | **Yes** | — | Let's Encrypt registration email |
| `bunker_whitelist_country` | No | DE CH AT | Geo-allowlist |
| `bunker_limit_req_rate` | No | 3r/s | Rate limit |

## User-Facing Interfaces

| Interface | URL | Port | Service |
|---|---|---|---|
| Nextcloud | `https://cloud.example.com` | 443 → 8080 | nextcloud-web |
| Grafana | `http://<host>:3000` | 3000 | monitoring-grafana |
| Bunkerweb API | `https://cloud.example.com` | 443 → 8443 | bunker-nginx |

## Custom Deployment Checklist

- [ ] Edit `secrets/vars.yml` — all passwords, domains, email
- [ ] Edit `inventory/hosts.ini` — target host IP/port
- [ ] Generate SSH key and bake pubkey into Butane/Ignition config
- [ ] Verify VM is running and reachable
- [ ] Run `./deploy.sh`
- [ ] Run `./deploy.sh validate` to verify

## Generalization Gaps

Still hardcoded (change in template files, not vars):

| What | Where | Hardcoded Value |
|---|---|---|
| Network subnet | Each repo `shared-network.network` | `10.89.0.0/24` |
| Loki endpoint | Promtail YAML in each service repo | `http://10.0.2.2:3100` |
| Postgres/Redis/Nginx images | `.container.j2` files in service-nextcloud | `postgres:15`, `redis:7`, `nginx:1.25` |
| Host port (Nextcloud) | `nc.pod` | `127.0.0.1:8080:80` |
| Host ports (Bunker) | `proxy.pod` | `80:8080`, `443:8443` |
| Upstream backend | `bunkerized_nginx.env.j2` | `http://nextcloud-web:80` |

## Troubleshooting

```bash
# Check containers per service user
./deploy.sh validate

# Nuclear reset (removes everything)
./reset.sh

# Individual service
ssh -p 2222 -i ssh/coreos_key core@host.containers.internal \
  "systemd-run --service-type=exec --uid=<UID> --wait podman ps -a"
```

See `../ansible-base/Agent.md` for detailed troubleshooting.

## Backup

Regular backups of `/var/services/snapshots` to external storage.
