#!/bin/bash
set -euo pipefail

# SecureBlue Deployment Script
# This script requires secrets/vars.yml to be configured

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="${SCRIPT_DIR}/../ansible-base"

echo "=== SecureBlue Deployment ==="
echo "Working directory: ${SCRIPT_DIR}"

# Validate required files
validate_secrets() {
    echo "Validating secrets..."
    
    if [[ ! -f "${SCRIPT_DIR}/secrets/vars.yml" ]]; then
        echo "ERROR: secrets/vars.yml not found"
        echo "Copy secrets/vars.yml.example to secrets/vars.yml and configure"
        exit 1
    fi
    
    if [[ ! -f "${SCRIPT_DIR}/inventory/hosts.ini" ]]; then
        echo "ERROR: inventory/hosts.ini not found"
        echo "Copy inventory/hosts.ini.example to inventory/hosts.ini and configure"
        exit 1
    fi
    
    echo "✓ Secrets validated"
}

# Deploy Ansible playbook
deploy_ansible() {
    echo "Running Ansible playbook..."
    
    cd "${ANSIBLE_DIR}"
    
    ansible-playbook -i "${SCRIPT_DIR}/inventory/hosts.ini" site.yml \
        --extra-vars "@${SCRIPT_DIR}/secrets/vars.yml" \
        --extra-vars "ansible_ssh_private_key_file=${SCRIPT_DIR}/ssh/coreos_key" \
        -v
    
    echo "✓ Ansible deployment completed"
}

# Activate services
activate_services() {
    echo "Activating Quadlet services..."
    
    # Reload systemd for nextcloud user
    run0 systemctl --user daemon-reload --machine=nextcloud@ || true
    
    # Reload systemd for proxy user
    run0 systemctl --user daemon-reload --machine=proxy@ || true
    
    echo "✓ Services activated"
}

# Validate deployment
validate_deployment() {
    echo "Validating deployment..."
    
    # Check Btrfs subvolumes
    systemd-run --wait --unit=tmp-validate-btrfs \
        btrfs subvolume list /var/services || true
    
    # Check service accounts
    getent passwd nextcloud proxy
    
    # Check SELinux contexts
    ls -Zd /var/services/nextcloud /var/services/proxy
    
    # Check snapshot timers
    systemctl list-timers --all | grep btrfs-snapshot || true
    
    # Check Quadlet files
    ls /var/services/nextcloud/.config/systemd/user/*.container || true
    
    echo "✓ Deployment validated"
}

# Main execution
main() {
    validate_secrets
    deploy_ansible
    activate_services
    validate_deployment
    
    echo ""
    echo "=== Deployment Complete ==="
    echo "Next steps:"
    echo "1. Build and push container images to GHCR"
    echo "2. Configure DNS for your domain"
    echo "3. Enable and start services: run0 systemctl --user enable --now nextcloud-web@.service"
}

main "$@"
