# SecureBlue Deployment (Private)

This repository contains private configurations and secrets for SecureBlue deployment.

## WARNING

**This repository MUST remain PRIVATE and should not be public!**

It contains:
- SSH keys for VM access
- Database passwords
- GHCR authentication
- Domain-specific configurations

## Structure

```
deployment-private/
├── secrets/
│   ├── vars.yml           # Private variables (do not commit!)
│   └── auth.json          # Podman GHCR login
├── inventory/
│   └── hosts.ini          # Host configuration
├── ssh/
│   └── coreos_key         # SSH key for VM
└── deploy.sh              # Deployment script
```

## Setup

1. **Clone repository** (only on trusted machines):
   ```bash
   git clone git@github.com:your-username/deployment-private.git
   cd deployment-private
   ```

2. **Configure secrets**:
   ```bash
   cp secrets/vars.yml.example secrets/vars.yml
   # Edit vars.yml with your values
   ```

3. **Set up SSH key**:
   ```bash
   ssh-keygen -t ed25519 -f ssh/coreos_key -N ""
   chmod 600 ssh/coreos_key
   ```

4. **GHCR login**:
   ```bash
   echo $GHCR_TOKEN | podman login ghcr.io -u $GHCR_USERNAME --password-stdin
   podman login ghcr.io -u $GHCR_USERNAME --password-stdin
   # auth.json will be created automatically
   ```

## Deployment

```bash
./deploy.sh
```

The script performs:
1. Validate secrets
2. Start VM (if needed)
3. Execute Ansible playbook
4. Activate Quadlet services
5. Validate deployment

## Secrets management

- **NEVER** commit real secrets
- Use `secrets/vars.yml` for local development
- For CI/CD: use GitHub Secrets
- `.gitignore` protects against accidental commits

## Backup

Regular backups of `/var/services/snapshots` to external storage.

## Troubleshooting

See `../ansible-base/Agent.md` for detailed troubleshooting.
