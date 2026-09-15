# deployment-private

Private configuration for the SecureBlue home server. **Keep this repo private.**

```
deployment-private/
  secrets/vars.yml          # everything you change per deployment (gitignored)
  inventory/hosts.ini       # target host (gitignored)
  ssh/coreos_key            # SSH key baked into Ignition (gitignored)
  deploy.sh                 # validate → ansible-playbook
  functional_test.sh        # post-deploy checks over SSH
  reset.sh                  # tear down everything Ansible created (VM stays up)
```

## Deploy

```bash
cp secrets/vars.yml.example secrets/vars.yml   # fill in
ssh-keygen -t ed25519 -f ssh/coreos_key -N ""  # pubkey goes into config.bu
./deploy.sh
./functional_test.sh
```

To start over: `./reset.sh` undoes what Ansible created. For a clean host,
roll the test VM back with `python3 ../ansible-base/test/start_vm.py --restore`.

## Variables

| Variable | Required | Default | Controls |
|---|---|---|---|
| `nextcloud_db_password` | yes | | PostgreSQL |
| `nextcloud_admin_password` | yes | | Nextcloud admin |
| `nextcloud_image` | no | `ghcr.io/marpogaus/nextcloud:31` | App image |
| `nextcloud_trusted_domains` | no | `cloud.example.com` | Trusted domains |
| `bunker_server_name`, `bunker_letsencrypt_email` | yes | | Public hostname, ACME |
| `monitoring_service_ntfy_url` | no | `""` | Alert delivery (ntfy topic URL) |
| `base_setup_backup_dir` | no | `""` | Mounted Btrfs USB disk for `btrfs send` backups |
| `*_uid` | no | 82 / 1001 / 1002 | Service user UIDs |

All other knobs (memory ceilings, PHP sizing, rate limits, image tags) have
defaults in the service roles' `defaults/main.yml`; override them here.

## Interfaces

| What | Where |
|---|---|
| Nextcloud | `https://<bunker_server_name>` |
| Grafana | `ssh -L 3000:localhost:3000 core@host`, then http://localhost:3000 |
| Nextcloud direct (Bunkerweb upstream) | host port 8080, blocked by firewalld |

## Development

```bash
pre-commit install --install-hooks -t pre-commit -t commit-msg -t pre-push
```

Plain `pre-commit install` wires up only the pre-commit stage, so the
commitizen message and branch checks stay dormant. Hooks: shellcheck,
pretty-format-yaml, commitizen for conventional commits.
CI runs the same set on push and pull request. Actions are pinned to SHAs, and
dependabot updates actions and hook revisions weekly against `dev`.

## License

MIT
